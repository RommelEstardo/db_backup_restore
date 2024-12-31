-- Create credentials for S3 access
CREATE CREDENTIAL [S3_Backup_Credential]
WITH IDENTITY = 'S3 Access Key',
SECRET = 'your_secret_access_key';
GO

-- Create procedure for all backup types
CREATE OR ALTER PROCEDURE sp_BackupToS3
    @DatabaseName NVARCHAR(128),
    @BackupType VARCHAR(4) -- 'FULL', 'DIFF', or 'LOG'
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Declare variables for error handling
    DECLARE @ErrorMessage NVARCHAR(4000);
    DECLARE @ErrorSeverity INT;
    DECLARE @ErrorState INT;
    
    -- Declare variables for backup locations
    DECLARE @BackupLocation NVARCHAR(1000);
    DECLARE @S3Location NVARCHAR(1000);
    
    BEGIN TRY
        -- Get backup locations from SystemParameter
        SELECT @BackupLocation = ParameterValue
        FROM SystemParameter
        WHERE ParameterName = 'BackupLocation';
        
        SELECT @S3Location = ParameterValue
        FROM SystemParameter
        WHERE ParameterName = 'S3Location';
        
        IF @BackupLocation IS NULL OR @S3Location IS NULL
            RAISERROR('Backup locations not properly configured in SystemParameter table.', 16, 1);
            
        -- Validate input parameters
        IF @DatabaseName IS NULL OR @DatabaseName = ''
            RAISERROR('Database name cannot be null or empty.', 16, 1);
            
        IF @BackupType NOT IN ('FULL', 'DIFF', 'LOG')
            RAISERROR('Invalid backup type. Must be FULL, DIFF, or LOG.', 16, 1);
            
        -- Verify database exists and is online
        IF NOT EXISTS (
            SELECT 1 
            FROM sys.databases 
            WHERE name = @DatabaseName 
            AND state_desc = 'ONLINE'
        )
            RAISERROR('Database %s does not exist or is not online.', 16, 1, @DatabaseName);
            
        -- For LOG backups, verify database is in FULL recovery model
        IF @BackupType = 'LOG' AND NOT EXISTS (
            SELECT 1 
            FROM sys.databases 
            WHERE name = @DatabaseName 
            AND recovery_model_desc = 'FULL'
        )
            RAISERROR('Database %s is not in FULL recovery model. Log backup not possible.', 16, 1, @DatabaseName);
    
        PRINT 'Starting ' + @BackupType + ' backup process for database: ' + @DatabaseName + ' at ' + CONVERT(VARCHAR(20), GETDATE(), 120);
        
        -- Configure paths using SystemParameter values
        DECLARE @LocalBackupPath NVARCHAR(1000) = @BackupLocation + LOWER(@BackupType) + '\'
        DECLARE @Date VARCHAR(8) = CONVERT(VARCHAR(8), GETDATE(), 112) -- Format: YYYYMMDD
        DECLARE @Time VARCHAR(6) = REPLACE(CONVERT(VARCHAR(8), GETDATE(), 108), ':', '') -- Format: HHMMSS
        DECLARE @FileExtension NVARCHAR(4) = CASE @BackupType WHEN 'LOG' THEN '.trn' ELSE '.bak' END
        DECLARE @FileName NVARCHAR(1000) = 
            CASE 
                WHEN @BackupType = 'LOG' THEN @DatabaseName + '_' + @BackupType + '_' + @Date + '_' + @Time + @FileExtension
                ELSE @DatabaseName + '_' + @BackupType + '_' + @Date + @FileExtension
            END
        DECLARE @FullPath NVARCHAR(1000) = @LocalBackupPath + @FileName
        DECLARE @S3Path NVARCHAR(1000) = @S3Location + LOWER(@BackupType) + '/' + @DatabaseName
        DECLARE @AWSCmd NVARCHAR(4000)
        DECLARE @CmdOutput TABLE (Output NVARCHAR(4000))
        DECLARE @ErrorOutput NVARCHAR(4000)
        
        -- Create backup folder if it doesn't exist and clear it
        PRINT 'Creating and clearing backup folder...';
        BEGIN TRY
            EXEC xp_cmdshell 'if not exist "' + @LocalBackupPath + '" mkdir "' + @LocalBackupPath + '"'
            IF @@ERROR <> 0
                RAISERROR('Failed to create backup directory.', 16, 1);
                
            EXEC xp_cmdshell 'del /Q "' + @LocalBackupPath + '*.*"'
            IF @@ERROR <> 0
                RAISERROR('Failed to clear backup directory.', 16, 1);
                
            PRINT 'Backup folder prepared successfully.';
        END TRY
        BEGIN CATCH
            SET @ErrorMessage = ERROR_MESSAGE();
            RAISERROR('Folder operation failed: %s', 16, 1, @ErrorMessage);
        END CATCH
        
        -- Perform the backup
        PRINT 'Starting SQL Server backup...';
        BEGIN TRY
            IF @BackupType = 'FULL'
                BACKUP DATABASE @DatabaseName
                TO DISK = @FullPath
                WITH COMPRESSION,
                STATS = 10;
            ELSE IF @BackupType = 'DIFF'
                BACKUP DATABASE @DatabaseName
                TO DISK = @FullPath
                WITH DIFFERENTIAL,
                COMPRESSION,
                STATS = 10;
            ELSE IF @BackupType = 'LOG'
                BACKUP LOG @DatabaseName
                TO DISK = @FullPath
                WITH COMPRESSION,
                STATS = 10;
                
            IF @@ERROR <> 0
                RAISERROR('Backup operation failed.', 16, 1);
                
            PRINT 'SQL Server backup completed successfully.';
        END TRY
        BEGIN CATCH
            SET @ErrorMessage = ERROR_MESSAGE();
            RAISERROR('Backup operation failed: %s', 16, 1, @ErrorMessage);
        END CATCH
        
        -- Upload to S3
        PRINT 'Starting upload to S3...';
        BEGIN TRY
            SET @AWSCmd = 'aws s3 cp "' + @FullPath + '" "' + @S3Path + @FileName + '"'
            INSERT INTO @CmdOutput
            EXEC xp_cmdshell @AWSCmd;
            
            -- Check for AWS CLI errors
            SELECT @ErrorOutput = Output 
            FROM @CmdOutput 
            WHERE Output LIKE '%error%' OR Output LIKE '%failed%';
            
            IF @ErrorOutput IS NOT NULL
                RAISERROR('AWS upload failed: %s', 16, 1, @ErrorOutput);
                
            PRINT 'S3 upload completed.';
        END TRY
        BEGIN CATCH
            SET @ErrorMessage = ERROR_MESSAGE();
            RAISERROR('S3 upload failed: %s', 16, 1, @ErrorMessage);
        END CATCH
        
        -- Clean up local file after successful upload
        PRINT 'Cleaning up local backup file...';
        BEGIN TRY
            SET @AWSCmd = 'del "' + @FullPath + '"'
            EXEC xp_cmdshell @AWSCmd;
            
            -- Verify file was deleted
            SET @AWSCmd = 'if exist "' + @FullPath + '" (exit 1) else (exit 0)'
            EXEC xp_cmdshell @AWSCmd;
            IF @@ERROR <> 0
                RAISERROR('Failed to delete local backup file.', 16, 1);
                
            PRINT 'Local cleanup completed.';
        END TRY
        BEGIN CATCH
            SET @ErrorMessage = ERROR_MESSAGE();
            RAISERROR('Cleanup operation failed: %s', 16, 1, @ErrorMessage);
        END CATCH
        
        PRINT @BackupType + ' backup process completed for database: ' + @DatabaseName + ' at ' + CONVERT(VARCHAR(20), GETDATE(), 120);
    END TRY
    BEGIN CATCH
        SET @ErrorMessage = ERROR_MESSAGE()
        SET @ErrorSeverity = ERROR_SEVERITY()
        SET @ErrorState = ERROR_STATE()
        
        -- Log error details
        PRINT 'Error occurred in backup process:'
        PRINT 'Error Message: ' + @ErrorMessage
        PRINT 'Error Severity: ' + CAST(@ErrorSeverity AS VARCHAR(10))
        PRINT 'Error State: ' + CAST(@ErrorState AS VARCHAR(10))
        PRINT 'Database: ' + @DatabaseName
        PRINT 'Backup Type: ' + @BackupType
        PRINT 'Timestamp: ' + CONVERT(VARCHAR(20), GETDATE(), 120)
        
        -- Re-raise the error
        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END;
GO

-- Create procedure to backup all user databases
CREATE OR ALTER PROCEDURE sp_BackupAllUserDatabases
    @BackupType VARCHAR(4) -- 'FULL', 'DIFF', or 'LOG'
AS
BEGIN
    SET NOCOUNT ON;
    
    PRINT 'Starting backup process for all user databases - Type: ' + @BackupType + ' at ' + CONVERT(VARCHAR(20), GETDATE(), 120);
    
    -- Create temp table to store database names
    CREATE TABLE #Databases (
        DatabaseName NVARCHAR(128)
    );
    
    -- Get all user databases that are online and not read-only
    INSERT INTO #Databases
    SELECT name
    FROM sys.databases
    WHERE database_id > 4  -- Exclude system databases
    AND state_desc = 'ONLINE'
    AND is_read_only = 0;
    
    -- Declare variables for cursor
    DECLARE @DatabaseName NVARCHAR(128);
    DECLARE @ErrorCount INT = 0;
    
    -- Cursor to process each database
    DECLARE db_cursor CURSOR FOR
    SELECT DatabaseName FROM #Databases;
    
    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DatabaseName;
    
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            IF @BackupType = 'LOG'
            BEGIN
                -- Check if database is in FULL recovery model
                IF EXISTS (
                    SELECT 1 
                    FROM sys.databases 
                    WHERE name = @DatabaseName 
                    AND recovery_model_desc = 'FULL'
                )
                BEGIN
                    PRINT 'Processing LOG backup for database: ' + @DatabaseName;
                    EXEC sp_BackupToS3 @DatabaseName, @BackupType;
                END
                ELSE
                BEGIN
                    PRINT 'Skipping LOG backup for database: ' + @DatabaseName + ' (not in FULL recovery model)';
                END
            END
            ELSE
            BEGIN
                PRINT 'Processing ' + @BackupType + ' backup for database: ' + @DatabaseName;
                EXEC sp_BackupToS3 @DatabaseName, @BackupType;
            END
        END TRY
        BEGIN CATCH
            SET @ErrorCount = @ErrorCount + 1;
            PRINT 'Error backing up database: ' + @DatabaseName;
            PRINT 'Error: ' + ERROR_MESSAGE();
        END CATCH
        
        FETCH NEXT FROM db_cursor INTO @DatabaseName;
    END
    
    CLOSE db_cursor;
    DEALLOCATE db_cursor;
    
    DROP TABLE #Databases;
    
    -- Final status message
    PRINT 'Backup process completed at ' + CONVERT(VARCHAR(20), GETDATE(), 120);
    IF @ErrorCount > 0
        PRINT 'WARNING: ' + CAST(@ErrorCount AS VARCHAR(10)) + ' error(s) occurred during the backup process.';
END;
GO

-- Create SQL Server Agent Jobs
-- 1. Weekly Full Backup Job
DECLARE @JobName NVARCHAR(100) = 'Weekly Full Backup to S3'
EXEC msdb.dbo.sp_add_job 
    @job_name = @JobName,
    @description = 'Weekly full backup of all user databases to S3',
    @enabled = 1;

EXEC msdb.dbo.sp_add_jobstep 
    @job_name = @JobName,
    @step_name = 'Execute Full Backup',
    @subsystem = 'TSQL',
    @command = 'EXEC sp_BackupAllUserDatabases @BackupType = ''FULL''';

EXEC msdb.dbo.sp_add_jobschedule 
    @job_name = @JobName,
    @name = 'Weekly Schedule',
    @freq_type = 8, -- Weekly
    @freq_interval = 1, -- Sunday
    @freq_recurrence_factor = 1,
    @active_start_time = 010000; -- 1:00 AM

-- 2. Daily Differential Backup Job
SET @JobName = 'Daily Differential Backup to S3'
EXEC msdb.dbo.sp_add_job 
    @job_name = @JobName,
    @description = 'Daily differential backup of all user databases to S3',
    @enabled = 1;

EXEC msdb.dbo.sp_add_jobstep 
    @job_name = @JobName,
    @step_name = 'Execute Differential Backup',
    @subsystem = 'TSQL',
    @command = 'EXEC sp_BackupAllUserDatabases @BackupType = ''DIFF''';

EXEC msdb.dbo.sp_add_jobschedule 
    @job_name = @JobName,
    @name = 'Daily Schedule',
    @freq_type = 4, -- Daily
    @freq_interval = 1,
    @active_start_time = 020000; -- 2:00 AM

-- 3. Hourly Log Backup Job
SET @JobName = 'Hourly Log Backup to S3'
EXEC msdb.dbo.sp_add_job 
    @job_name = @JobName,
    @description = 'Hourly transaction log backup of all user databases to S3',
    @enabled = 1;

EXEC msdb.dbo.sp_add_jobstep 
    @job_name = @JobName,
    @step_name = 'Execute Log Backup',
    @subsystem = 'TSQL',
    @command = 'EXEC sp_BackupAllUserDatabases @BackupType = ''LOG''';

EXEC msdb.dbo.sp_add_jobschedule 
    @job_name = @JobName,
    @name = 'Hourly Schedule',
    @freq_type = 4, -- Daily
    @freq_interval = 1,
    @freq_subday_type = 8, -- Hours
    @freq_subday_interval = 1, -- Every 1 hour
    @active_start_time = 000000; -- Starting at midnight

-- Add jobs to the local server
EXEC msdb.dbo.sp_add_jobserver 
    @job_name = 'Weekly Full Backup to S3';
EXEC msdb.dbo.sp_add_jobserver 
    @job_name = 'Daily Differential Backup to S3';
EXEC msdb.dbo.sp_add_jobserver 
    @job_name = 'Hourly Log Backup to S3';
GO 