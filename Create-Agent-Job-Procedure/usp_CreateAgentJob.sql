/*==============================================================================
  dbo.usp_CreateAgentJob
  ------------------------------------------------------------------------------
  Creates a SQL Server Agent job with:
    * ONE step   -> pass @Command (+ @DatabaseName / @Subsystem)
    * MANY steps -> pass @StepsJson (JSON array, see examples at bottom)
    * NO schedule, or ONE schedule via scalar params, or MANY via @SchedulesJson
  Schedule types:
    NONE   - job is created unscheduled (run manually / by another process)
    ONCE   - runs one time at @StartDate + @StartTime
    DAILY  - every @EveryN days
    WEEKLY - on @WeekDays ('Mon,Wed,Fri' | 'Weekdays' | 'Weekend' | 'All'),
             every @EveryN weeks
  Any recurring schedule can also repeat within the day:
    @RepeatUnit = SECOND | MINUTE | HOUR, @RepeatEvery = N,
    between @StartTime and @EndTime.
  Active window: @StartDate .. @EndDate (NULL end = no end date).

  Requirements: SQL Server 2016+ (OPENJSON / STRING_SPLIT, compat level >= 130
  in the database where this proc lives). Caller needs rights to create Agent
  jobs (sysadmin, or SQLAgent*Role in msdb; setting another owner = sysadmin).
  Everything is done in one transaction: either the whole job is created or
  nothing is.
==============================================================================*/
-- USE [DBA];   -- <-- your DBA/utility database (or msdb)
GO
CREATE OR ALTER PROCEDURE dbo.usp_CreateAgentJob
    -- Job ------------------------------------------------------------------
    @JobName          nvarchar(128),
    @Description      nvarchar(512)    = NULL,
    @CategoryName     nvarchar(128)    = N'[Uncategorized (Local)]',
    @OwnerLogin       nvarchar(128)    = NULL,    -- NULL = current login
    @Enabled          bit              = 1,
    @NotifyOperator   nvarchar(128)    = NULL,    -- Agent operator to email
    @NotifyLevel      tinyint          = 2,       -- 1=success 2=failure 3=always
    @ReplaceIfExists  bit              = 0,       -- 1 = drop & recreate

    -- Steps: single (@Command) OR multi (@StepsJson) ------------------------
    @Command          nvarchar(max)    = NULL,
    @DatabaseName     nvarchar(128)    = N'master',
    @Subsystem        nvarchar(40)     = N'TSQL',  -- TSQL | CmdExec | PowerShell | SSIS ...
    @StepsJson        nvarchar(max)    = NULL,

    -- Schedule: single via params OR many via @SchedulesJson ---------------
    @ScheduleType     varchar(10)      = 'NONE',   -- NONE | ONCE | DAILY | WEEKLY
    @ScheduleName     nvarchar(128)    = NULL,
    @StartDate        date             = NULL,     -- default today
    @EndDate          date             = NULL,     -- default no end
    @StartTime        time(0)          = '00:00:00',
    @EndTime          time(0)          = NULL,     -- only used with @RepeatUnit
    @WeekDays         varchar(100)     = NULL,     -- WEEKLY only
    @EveryN           int              = 1,        -- every N days / weeks
    @RepeatUnit       varchar(10)      = NULL,     -- NULL | SECOND | MINUTE | HOUR
    @RepeatEvery      int              = NULL,
    @SchedulesJson    nvarchar(max)    = NULL,

    @ServerName       nvarchar(128)    = N'(local)',
    @JobId            uniqueidentifier = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @msg nvarchar(2048);

    /*------------------------------------------------------------------------
      1. Basic validation
    ------------------------------------------------------------------------*/
    IF NULLIF(LTRIM(RTRIM(@JobName)), N'') IS NULL
        THROW 50000, N'@JobName is required.', 1;

    IF @Command IS NULL AND @StepsJson IS NULL
        THROW 50000, N'Provide @Command (single step) or @StepsJson (multi-step).', 1;

    IF @Command IS NOT NULL AND @StepsJson IS NOT NULL
        THROW 50000, N'Provide either @Command or @StepsJson, not both.', 1;

    IF @StepsJson IS NOT NULL AND ISJSON(@StepsJson) = 0
        THROW 50000, N'@StepsJson is not valid JSON.', 1;

    IF @SchedulesJson IS NOT NULL AND ISJSON(@SchedulesJson) = 0
        THROW 50000, N'@SchedulesJson is not valid JSON.', 1;

    IF @NotifyOperator IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = @NotifyOperator)
    BEGIN
        SET @msg = N'Operator not found: ' + @NotifyOperator;
        THROW 50000, @msg, 1;
    END;

    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @JobName) AND @ReplaceIfExists = 0
    BEGIN
        SET @msg = N'Job already exists: ' + @JobName + N' (use @ReplaceIfExists = 1 to recreate).';
        THROW 50000, @msg, 1;
    END;

    /*------------------------------------------------------------------------
      2. Load steps into a table (from @Command or @StepsJson)
    ------------------------------------------------------------------------*/
    DECLARE @steps TABLE
    (
        step_id          int            NOT NULL PRIMARY KEY,
        step_name        nvarchar(128)  NOT NULL,
        command          nvarchar(max)  NULL,
        database_name    nvarchar(128)  NULL,
        subsystem        nvarchar(40)   NOT NULL,
        on_success       varchar(20)    NULL,   -- next | quit_success | quit_fail | goto
        on_success_step  int            NULL,
        on_fail          varchar(20)    NULL,
        on_fail_step     int            NULL,
        retry_attempts   int            NOT NULL,
        retry_interval   int            NOT NULL,  -- minutes
        output_file      nvarchar(200)  NULL,
        proxy_name       nvarchar(128)  NULL
    );

    IF @StepsJson IS NULL
        INSERT @steps (step_id, step_name, command, database_name, subsystem,
                       on_success, on_fail, retry_attempts, retry_interval)
        VALUES (1, N'Step 1', @Command, @DatabaseName, @Subsystem,
                'quit_success', 'quit_fail', 0, 0);
    ELSE
        INSERT @steps (step_id, step_name, command, database_name, subsystem,
                       on_success, on_success_step, on_fail, on_fail_step,
                       retry_attempts, retry_interval, output_file, proxy_name)
        SELECT  CAST(a.[key] AS int) + 1,
                COALESCE(j.name, N'Step ' + CAST(CAST(a.[key] AS int) + 1 AS nvarchar(10))),
                j.command,
                COALESCE(j.[database], @DatabaseName),
                COALESCE(j.subsystem, N'TSQL'),
                LOWER(j.on_success), j.on_success_step,
                LOWER(j.on_fail),    j.on_fail_step,
                ISNULL(j.retry_attempts, 0), ISNULL(j.retry_interval, 0),
                j.output_file, j.proxy
        FROM OPENJSON(@StepsJson) AS a
        CROSS APPLY OPENJSON(a.[value]) WITH
        (
            name            nvarchar(128) '$.name',
            command         nvarchar(max) '$.command',
            [database]      nvarchar(128) '$.database',
            subsystem       nvarchar(40)  '$.subsystem',
            on_success      varchar(20)   '$.on_success',
            on_success_step int           '$.on_success_step',
            on_fail         varchar(20)   '$.on_fail',
            on_fail_step    int           '$.on_fail_step',
            retry_attempts  int           '$.retry_attempts',
            retry_interval  int           '$.retry_interval',
            output_file     nvarchar(200) '$.output_file',
            proxy           nvarchar(128) '$.proxy'
        ) AS j;

    DECLARE @lastStep int = (SELECT MAX(step_id) FROM @steps);

    IF @lastStep IS NULL
        THROW 50000, N'@StepsJson contains no steps.', 1;

    -- Defaults: success -> next (last step -> quit success); failure -> quit failure.
    -- "next" on the last step is turned into the matching quit.
    UPDATE @steps
    SET on_success = CASE WHEN on_success IS NULL OR on_success = 'next'
                          THEN CASE WHEN step_id = @lastStep THEN 'quit_success' ELSE 'next' END
                          ELSE on_success END,
        on_fail    = CASE WHEN on_fail IS NULL THEN 'quit_fail'
                          WHEN on_fail = 'next' AND step_id = @lastStep THEN 'quit_fail'
                          ELSE on_fail END,
        database_name = CASE WHEN subsystem = N'TSQL' THEN database_name END;

    -- Step validation
    SELECT TOP (1) @msg = N'Step ' + CAST(step_id AS nvarchar(10)) + N' (' + step_name + N'): ' +
        CASE
            WHEN NULLIF(LTRIM(RTRIM(command)), N'') IS NULL                 THEN N'command is required.'
            WHEN on_success NOT IN ('next','quit_success','quit_fail','goto') THEN N'invalid on_success "' + on_success + N'".'
            WHEN on_fail    NOT IN ('next','quit_success','quit_fail','goto') THEN N'invalid on_fail "' + on_fail + N'".'
            WHEN on_success = 'goto' AND (on_success_step IS NULL OR on_success_step = step_id
                 OR on_success_step NOT BETWEEN 1 AND @lastStep)             THEN N'on_success_step must be another existing step.'
            WHEN on_fail = 'goto' AND (on_fail_step IS NULL OR on_fail_step = step_id
                 OR on_fail_step NOT BETWEEN 1 AND @lastStep)                THEN N'on_fail_step must be another existing step.'
            WHEN retry_attempts < 0 OR retry_interval < 0                   THEN N'retry values cannot be negative.'
        END
    FROM @steps
    WHERE NULLIF(LTRIM(RTRIM(command)), N'') IS NULL
       OR on_success NOT IN ('next','quit_success','quit_fail','goto')
       OR on_fail    NOT IN ('next','quit_success','quit_fail','goto')
       OR (on_success = 'goto' AND (on_success_step IS NULL OR on_success_step = step_id OR on_success_step NOT BETWEEN 1 AND @lastStep))
       OR (on_fail    = 'goto' AND (on_fail_step    IS NULL OR on_fail_step    = step_id OR on_fail_step    NOT BETWEEN 1 AND @lastStep))
       OR retry_attempts < 0 OR retry_interval < 0
    ORDER BY step_id;

    IF @@ROWCOUNT > 0
        THROW 50000, @msg, 1;

    IF EXISTS (SELECT step_name FROM @steps GROUP BY step_name HAVING COUNT(*) > 1)
        THROW 50000, N'Step names must be unique within the job.', 1;

    /*------------------------------------------------------------------------
      3. Load schedules into a table (from scalar params or @SchedulesJson)
    ------------------------------------------------------------------------*/
    DECLARE @sched TABLE
    (
        sched_no         int            NOT NULL PRIMARY KEY,
        sched_name       nvarchar(128)  NULL,
        sched_type       varchar(10)    NULL,
        start_date       date           NULL,
        end_date         date           NULL,
        start_time       time(0)        NULL,
        end_time         time(0)        NULL,
        week_days        varchar(100)   NULL,
        every_n          int            NULL,
        repeat_unit      varchar(10)    NULL,
        repeat_every     int            NULL,
        is_enabled       bit            NULL,
        -- computed msdb values
        freq_type        int            NULL,
        freq_interval    int            NULL,
        subday_type      int            NULL,
        subday_interval  int            NULL,
        recurrence       int            NULL,
        start_date_int   int            NULL,
        end_date_int     int            NULL,
        start_time_int   int            NULL,
        end_time_int     int            NULL
    );

    IF @SchedulesJson IS NOT NULL
        INSERT @sched (sched_no, sched_name, sched_type, start_date, end_date, start_time,
                       end_time, week_days, every_n, repeat_unit, repeat_every, is_enabled)
        SELECT  CAST(a.[key] AS int) + 1, j.name, UPPER(j.[type]), j.start_date, j.end_date,
                j.start_time, j.end_time, j.[days], j.every_n, UPPER(j.repeat_unit),
                j.repeat_every, ISNULL(j.[enabled], 1)
        FROM OPENJSON(@SchedulesJson) AS a
        CROSS APPLY OPENJSON(a.[value]) WITH
        (
            name          nvarchar(128) '$.name',
            [type]        varchar(10)   '$.type',
            start_date    date          '$.start_date',   -- 'YYYY-MM-DD'
            end_date      date          '$.end_date',
            start_time    time(0)       '$.start_time',   -- 'HH:MM[:SS]'
            end_time      time(0)       '$.end_time',
            [days]        varchar(100)  '$.days',
            every_n       int           '$.every_n',
            repeat_unit   varchar(10)   '$.repeat_unit',
            repeat_every  int           '$.repeat_every',
            [enabled]     bit           '$.enabled'
        ) AS j;
    ELSE IF ISNULL(UPPER(@ScheduleType), 'NONE') <> 'NONE'
        INSERT @sched (sched_no, sched_name, sched_type, start_date, end_date, start_time,
                       end_time, week_days, every_n, repeat_unit, repeat_every, is_enabled)
        VALUES (1, @ScheduleName, UPPER(@ScheduleType), @StartDate, @EndDate, @StartTime,
                @EndTime, @WeekDays, @EveryN, UPPER(@RepeatUnit), @RepeatEvery, 1);

    -- Day-name map (prefix match: 'Mon', 'Monday', 'Tues' ... all work)
    DECLARE @dayMap TABLE (token varchar(10) NOT NULL, day_bit int NOT NULL);
    INSERT @dayMap (token, day_bit) VALUES
        ('SUN',1),('MON',2),('TUE',4),('WED',8),('THU',16),('FRI',32),('SAT',64),
        ('WEEKDAY',2),('WEEKDAY',4),('WEEKDAY',8),('WEEKDAY',16),('WEEKDAY',32),
        ('WEEKEND',1),('WEEKEND',64),
        ('ALL',1),('ALL',2),('ALL',4),('ALL',8),('ALL',16),('ALL',32),('ALL',64);

    DECLARE @i int = 1, @n int = (SELECT COUNT(*) FROM @sched),
            @type varchar(10), @sd date, @ed date, @st time(0), @et time(0),
            @days varchar(100), --@everyN int, 
			@ru varchar(10), @re int,
            @mask int, @badDays int, @label nvarchar(200);

    WHILE @i <= @n
    BEGIN
        SELECT @type = sched_type, @sd = ISNULL(start_date, CAST(GETDATE() AS date)),
               @ed = ISNULL(end_date, '99991231'), @st = ISNULL(start_time, '00:00:00'),
               @et = end_time, @days = week_days, @everyN = ISNULL(every_n, 1),
               @ru = NULLIF(repeat_unit, ''), @re = repeat_every
        FROM @sched WHERE sched_no = @i;

        SET @label = N'Schedule #' + CAST(@i AS nvarchar(10)) + N': ';

        IF @type IS NULL OR @type NOT IN ('ONCE','DAILY','WEEKLY')
        BEGIN
            SET @msg = @label + N'type must be ONCE, DAILY or WEEKLY.';
            THROW 50000, @msg, 1;
        END;

        IF @ed < @sd
        BEGIN
            SET @msg = @label + N'end date is before start date.';
            THROW 50000, @msg, 1;
        END;

        IF @everyN < 1
        BEGIN
            SET @msg = @label + N'every_n must be >= 1.';
            THROW 50000, @msg, 1;
        END;

        -- Intraday repeat
        IF @ru IS NOT NULL
        BEGIN
            IF @type = 'ONCE'
            BEGIN
                SET @msg = @label + N'repeat is not allowed on a ONCE schedule.';
                THROW 50000, @msg, 1;
            END;
            IF @ru NOT IN ('SECOND','MINUTE','HOUR')
            BEGIN
                SET @msg = @label + N'repeat_unit must be SECOND, MINUTE or HOUR.';
                THROW 50000, @msg, 1;
            END;
            IF @re IS NULL OR @re < 1 OR (@ru = 'SECOND' AND @re < 10)
            BEGIN
                SET @msg = @label + N'repeat_every must be >= 1 (>= 10 for SECOND).';
                THROW 50000, @msg, 1;
            END;
            SET @et = ISNULL(@et, '23:59:59');
            IF @et <= @st
            BEGIN
                SET @msg = @label + N'end time must be after start time.';
                THROW 50000, @msg, 1;
            END;
        END
        ELSE
            SET @et = '23:59:59';

        -- ONCE in the past would never run
        IF @type = 'ONCE' AND DATEADD(SECOND, DATEDIFF(SECOND, '00:00:00', @st),
                                      CAST(@sd AS datetime)) <= GETDATE()
        BEGIN
            SET @msg = @label + N'one-time run date/time is in the past.';
            THROW 50000, @msg, 1;
        END;

        -- Weekly day mask
        SET @mask = NULL;
        IF @type = 'WEEKLY'
        BEGIN
            SELECT @mask    = SUM(DISTINCT m.day_bit),
                   @badDays = SUM(CASE WHEN m.day_bit IS NULL THEN 1 ELSE 0 END)
            FROM (SELECT UPPER(LTRIM(RTRIM(value))) AS t
                  FROM STRING_SPLIT(REPLACE(REPLACE(ISNULL(@days, ''), ';', ','), '|', ','), ',')
                  WHERE LTRIM(RTRIM(value)) <> '') AS x
            LEFT JOIN @dayMap AS m ON x.t LIKE m.token + '%';

            IF @mask IS NULL OR @badDays > 0
            BEGIN
                SET @msg = @label + N'invalid or missing days "' + ISNULL(@days, N'') +
                           N'". Use e.g. ''Mon,Wed,Fri'', ''Weekdays'', ''Weekend'', ''All''.';
                THROW 50000, @msg, 1;
            END;
        END;

        UPDATE @sched
        SET sched_name      = LEFT(COALESCE(sched_name,
                                   @JobName + N' - ' + @type + N' #' + CAST(@i AS nvarchar(10))), 128),
            freq_type       = CASE @type WHEN 'ONCE' THEN 1 WHEN 'DAILY' THEN 4 ELSE 8 END,
            freq_interval   = CASE @type WHEN 'ONCE' THEN 0 WHEN 'DAILY' THEN @everyN ELSE @mask END,
            subday_type     = CASE WHEN @type = 'ONCE' THEN 0
                                   WHEN @ru IS NULL    THEN 1
                                   WHEN @ru = 'SECOND' THEN 2
                                   WHEN @ru = 'MINUTE' THEN 4
                                   ELSE 8 END,
            subday_interval = CASE WHEN @ru IS NULL THEN 0 ELSE @re END,
            recurrence      = CASE @type WHEN 'WEEKLY' THEN @everyN ELSE 0 END,
            start_date_int  = CONVERT(int, CONVERT(char(8), @sd, 112)),
            end_date_int    = CONVERT(int, CONVERT(char(8), @ed, 112)),
            start_time_int  = DATEPART(HOUR, @st) * 10000 + DATEPART(MINUTE, @st) * 100 + DATEPART(SECOND, @st),
            end_time_int    = DATEPART(HOUR, @et) * 10000 + DATEPART(MINUTE, @et) * 100 + DATEPART(SECOND, @et)
        WHERE sched_no = @i;

        SET @i += 1;
    END;

    /*------------------------------------------------------------------------
      4. Create everything in one transaction
    ------------------------------------------------------------------------*/
    DECLARE @stepId int, @stepName nvarchar(128), @cmd nvarchar(max), @db nvarchar(128),
            @sub nvarchar(40), @okAct int, @okStep int, @failAct int, @failStep int,
            @retries int, @retryInt int, @outFile nvarchar(200), @proxy nvarchar(128),
            @scheduleId int, @schedName nvarchar(128), @schedEnabled bit,
            @ft int, @fi int, @fst int, @fsi int, @fr int, @asd int, @aed int, @ast int, @aet int;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @JobName)
            EXEC msdb.dbo.sp_delete_job @job_name = @JobName, @delete_unused_schedule = 1;

        IF NOT EXISTS (SELECT 1 FROM msdb.dbo.syscategories
                       WHERE name = @CategoryName AND category_class = 1)
            EXEC msdb.dbo.sp_add_category @class = N'JOB', @type = N'LOCAL', @name = @CategoryName;

        SET @JobId = NULL;
		Declare @notify_level_email int = CASE WHEN @NotifyOperator IS NULL THEN 0 ELSE @NotifyLevel END
        EXEC msdb.dbo.sp_add_job
             @job_name                   = @JobName,
             @enabled                    = @Enabled,
             @description                = @Description,
             @category_name              = @CategoryName,
             @owner_login_name           = @OwnerLogin,
             @start_step_id              = 1,
             @notify_level_email         = @notify_level_email,
             @notify_email_operator_name = @NotifyOperator,
             @job_id                     = @JobId OUTPUT;

        -- Steps (GOTO targets are set afterwards, once every step exists)
        SET @i = 1;
        WHILE @i <= @lastStep
        BEGIN
            SELECT @stepId = step_id, @stepName = step_name, @cmd = command, @db = database_name,
                   @sub = subsystem, @retries = retry_attempts, @retryInt = retry_interval,
                   @outFile = output_file, @proxy = proxy_name,
                   @okAct   = CASE on_success WHEN 'quit_success' THEN 1 WHEN 'quit_fail' THEN 2
                                              WHEN 'next' THEN 3 ELSE 1 END,   -- goto -> fixed below
                   @failAct = CASE on_fail    WHEN 'quit_success' THEN 1 WHEN 'quit_fail' THEN 2
                                              WHEN 'next' THEN 3 ELSE 2 END
            FROM @steps WHERE step_id = @i;

            EXEC msdb.dbo.sp_add_jobstep
                 @job_id            = @JobId,
                 @step_id           = @stepId,
                 @step_name         = @stepName,
                 @subsystem         = @sub,
                 @command           = @cmd,
                 @database_name     = @db,
                 @on_success_action = @okAct,
                 @on_fail_action    = @failAct,
                 @retry_attempts    = @retries,
                 @retry_interval    = @retryInt,
                 @output_file_name  = @outFile,
                 @proxy_name        = @proxy;

            SET @i += 1;
        END;

        -- Apply GOTO actions
        SET @i = 1;
        WHILE @i <= @lastStep
        BEGIN
            SELECT @okStep   = CASE WHEN on_success = 'goto' THEN on_success_step END,
                   @failStep = CASE WHEN on_fail    = 'goto' THEN on_fail_step    END
            FROM @steps WHERE step_id = @i;

            IF @okStep IS NOT NULL
                EXEC msdb.dbo.sp_update_jobstep @job_id = @JobId, @step_id = @i,
                     @on_success_action = 4, @on_success_step_id = @okStep;

            IF @failStep IS NOT NULL
                EXEC msdb.dbo.sp_update_jobstep @job_id = @JobId, @step_id = @i,
                     @on_fail_action = 4, @on_fail_step_id = @failStep;

            SET @i += 1;
        END;

        -- Schedules
        SET @i = 1;
        WHILE @i <= @n
        BEGIN
            SELECT @schedName = sched_name, @schedEnabled = is_enabled,
                   @ft = freq_type, @fi = freq_interval, @fst = subday_type, @fsi = subday_interval,
                   @fr = recurrence, @asd = start_date_int, @aed = end_date_int,
                   @ast = start_time_int, @aet = end_time_int
            FROM @sched WHERE sched_no = @i;

            SET @scheduleId = NULL;
            EXEC msdb.dbo.sp_add_schedule
                 @schedule_name          = @schedName,
                 @enabled                = @schedEnabled,
                 @freq_type              = @ft,
                 @freq_interval          = @fi,
                 @freq_subday_type       = @fst,
                 @freq_subday_interval   = @fsi,
                 @freq_relative_interval = 0,
                 @freq_recurrence_factor = @fr,
                 @active_start_date      = @asd,
                 @active_end_date        = @aed,
                 @active_start_time      = @ast,
                 @active_end_time        = @aet,
                 @schedule_id            = @scheduleId OUTPUT;

            EXEC msdb.dbo.sp_attach_schedule @job_id = @JobId, @schedule_id = @scheduleId;

            SET @i += 1;
        END;

        EXEC msdb.dbo.sp_add_jobserver @job_id = @JobId, @server_name = @ServerName;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    /*------------------------------------------------------------------------
      5. Summary
    ------------------------------------------------------------------------*/
    SELECT  j.name AS job_name, j.job_id, j.enabled,
            s.step_id, s.step_name, s.subsystem, s.database_name,
            CASE s.on_success_action WHEN 1 THEN 'Quit success' WHEN 2 THEN 'Quit failure'
                 WHEN 3 THEN 'Next step' WHEN 4 THEN 'Go to step ' + CAST(s.on_success_step_id AS varchar(10)) END AS on_success,
            CASE s.on_fail_action    WHEN 1 THEN 'Quit success' WHEN 2 THEN 'Quit failure'
                 WHEN 3 THEN 'Next step' WHEN 4 THEN 'Go to step ' + CAST(s.on_fail_step_id AS varchar(10)) END AS on_fail
    FROM msdb.dbo.sysjobs j
    JOIN msdb.dbo.sysjobsteps s ON s.job_id = j.job_id
    WHERE j.job_id = @JobId
    ORDER BY s.step_id;

    SELECT  sc.name AS schedule_name, sc.enabled,
            CASE sc.freq_type WHEN 1 THEN 'Once' WHEN 4 THEN 'Daily' WHEN 8 THEN 'Weekly' END AS schedule_type,
            STUFF(CASE WHEN sc.freq_type = 8 THEN
                    CASE WHEN sc.freq_interval &  1 > 0 THEN ',Sun' ELSE '' END +
                    CASE WHEN sc.freq_interval &  2 > 0 THEN ',Mon' ELSE '' END +
                    CASE WHEN sc.freq_interval &  4 > 0 THEN ',Tue' ELSE '' END +
                    CASE WHEN sc.freq_interval &  8 > 0 THEN ',Wed' ELSE '' END +
                    CASE WHEN sc.freq_interval & 16 > 0 THEN ',Thu' ELSE '' END +
                    CASE WHEN sc.freq_interval & 32 > 0 THEN ',Fri' ELSE '' END +
                    CASE WHEN sc.freq_interval & 64 > 0 THEN ',Sat' ELSE '' END
                  END, 1, 1, '') AS week_days,
            CASE sc.freq_subday_type WHEN 2 THEN 'Every ' + CAST(sc.freq_subday_interval AS varchar(10)) + ' sec'
                                     WHEN 4 THEN 'Every ' + CAST(sc.freq_subday_interval AS varchar(10)) + ' min'
                                     WHEN 8 THEN 'Every ' + CAST(sc.freq_subday_interval AS varchar(10)) + ' hr'
                                     ELSE 'Once at start time' END AS intraday,
            msdb.dbo.agent_datetime(sc.active_start_date, sc.active_start_time) AS first_window_start,
            STUFF(STUFF(RIGHT('000000' + CAST(sc.active_end_time AS varchar(6)), 6), 5, 0, ':'), 3, 0, ':') AS daily_end_time,
            CASE WHEN sc.active_end_date = 99991231 THEN NULL
                 ELSE CONVERT(date, CAST(sc.active_end_date AS char(8)), 112) END AS end_date
    FROM msdb.dbo.sysjobschedules js
    JOIN msdb.dbo.sysschedules sc ON sc.schedule_id = js.schedule_id
    WHERE js.job_id = @JobId;
END;
GO

	/*

/*==============================================================================
  EXAMPLES
==============================================================================
*/

---- 1) Single step, no schedule (run on demand)
EXEC dbo.usp_CreateAgentJob
     @JobName      = N'DBA - Update Stats AdHoc',
     @Command      = N'EXEC sp_updatestats;',
     @DatabaseName = N'sandbox';

---- 2) Single step, ONE-TIME run
EXEC dbo.usp_CreateAgentJob
     @JobName      = N'DBA - One-off Archive',
     @Command      = N'EXEC dbo.usp_ArchiveOrders @Before = ''2025-01-01'';',
     @DatabaseName = N'sandbox',
     @ScheduleType = 'ONCE',
     @StartDate    = '2026-11-07',
     @StartTime    = '23:30';

-- 3) Multi-step, WEEKLY Mon/Wed/Fri, every 15 min from 08:00 to 18:00,
--    active Nov 1 2026 -> Mar 31 2027, email operator on failure
EXEC dbo.usp_CreateAgentJob
     @JobName        = N'ETL - Orders Sync',
     @Description    = N'Pull orders, transform, notify.',
     @CategoryName   = N'ETL',
     @NotifyOperator = N'SQLAdmins',
     @StepsJson      = N'[
        {"name":"Extract",   "database":"sandbox", "command":"EXEC dbo.usp_ExtractOrders;",
         "retry_attempts":3, "retry_interval":5, "on_fail":"goto", "on_fail_step":4},
        {"name":"Transform", "database":"sandbox", "command":"EXEC dbo.usp_TransformOrders;",
         "on_fail":"goto", "on_fail_step":4},
        {"name":"Load",      "database":"sandbox", "command":"EXEC dbo.usp_LoadOrders;",
         "on_success":"quit_success", "on_fail":"goto", "on_fail_step":4},
        {"name":"Log failure", "database":"sandbox",  "command":"EXEC dbo.usp_LogJobFailure N''ETL - Orders Sync'';",
         "on_success":"quit_fail"}
     ]',
     @ScheduleType   = 'WEEKLY',
     @WeekDays       = 'Mon,Wed,Fri',
     @StartDate      = '2026-11-01',
     @EndDate        = '2027-03-31',
     @StartTime      = '08:00',
     @EndTime        = '18:00',
     @RepeatUnit     = 'MINUTE',
     @RepeatEvery    = 15;

---- 4) Several schedules on one job: weekdays at 02:00 + Saturday hourly 06:00-12:00
----    + every other Sunday at 22:00
EXEC dbo.usp_CreateAgentJob
     @JobName         = N'DBA - Index Maintenance',
     @Command         = N'EXEC dbo.IndexOptimize @Databases = ''USER_DATABASES'';',
     @DatabaseName    = N'DBA',
     @ReplaceIfExists = 1,
     @SchedulesJson   = N'[
        {"name":"Weekdays 2am", "type":"WEEKLY", "days":"Weekdays", "start_time":"02:00"},
        {"name":"Sat hourly",   "type":"WEEKLY", "days":"Sat", "start_time":"06:00",
         "end_time":"12:00", "repeat_unit":"HOUR", "repeat_every":1},
        {"name":"Alt Sundays",  "type":"WEEKLY", "days":"Sun", "every_n":2, "start_time":"22:00",
         "start_date":"2026-11-01"}
     ]';

---- 5) Daily every 30 seconds, all day, CmdExec step
EXEC dbo.usp_CreateAgentJob
     @JobName      = N'OPS - Heartbeat',
     @Subsystem    = N'CmdExec',
     @Command      = N'C:\Scripts\heartbeat.cmd',
     @ScheduleType = 'DAILY',
     @RepeatUnit   = 'SECOND', @StartTime      = '08:00',
     @EndTime        = '18:00',
     @RepeatEvery  = 30;
*/

