CREATE OR ALTER PROCEDURE sp_RestoreFromS3
    @DatabaseName NVARCHAR(128),
    @BackupType VARCHAR(4),         -- 'FULL', 'DIFF', or 'LOG'
    @WithRecovery BIT = 1,          -- 1 = WITH RECOVERY, 0 = NORECOVERY
    @RestoreDate VARCHAR(8) = NULL, -- Format: YYYYMMDD, NULL = Latest
    @RestoreTime VARCHAR(6) = NULL  -- Format: HHMMSS, Required for LOG when specific date
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
    DECLARE @AWSCmd NVARCHAR(4000);
    DECLARE @RestorePath NVARCHAR(1000);
    DECLARE @CmdOutput TABLE (Output NVARCHAR(4000));
    DECLARE @ErrorOutput NVARCHAR(4000);
    
    BEGIN TRY
        -- Get locations from SystemParameter
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
            
        IF @BackupType = 'LOG' AND @RestoreDate IS NOT NULL AND @RestoreTime IS NULL
            RAISERROR('RestoreTime is required for LOG restore when RestoreDate is specified.', 16, 1);
            
        -- Configure paths
        DECLARE @LocalBackupPath NVARCHAR(1000) = @BackupLocation + LOWER(@BackupType) + '\'
        DECLARE @S3Path NVARCHAR(1000) = @S3Location + LOWER(@BackupType) + '/' + @DatabaseName + '/'
        DECLARE @FileExtension NVARCHAR(4) = CASE @BackupType WHEN 'LOG' THEN '.trn' ELSE '.bak' END
        
        -- Create local folder if it doesn't exist
        EXEC xp_cmdshell 'if not exist "' + @LocalBackupPath + '" mkdir "' + @LocalBackupPath + '"'
        
        -- Clear local folder
        EXEC xp_cmdshell 'del /Q "' + @LocalBackupPath + '*.*"'
        
        -- List files from S3 and download the appropriate one
        IF @RestoreDate IS NULL
        BEGIN
            -- Get latest backup
            PRINT 'Retrieving latest backup file...';
            SET @AWSCmd = 'aws s3 ls "' + @S3Path + '" --recursive | sort | tail -n 1'
            INSERT INTO @CmdOutput
            EXEC xp_cmdshell @AWSCmd;
            
            -- Extract filename from the ls output
            DECLARE @LatestFile NVARCHAR(1000);
            SELECT @LatestFile = REVERSE(LEFT(REVERSE(Output), CHARINDEX(' ', REVERSE(Output)) - 1))
            FROM @CmdOutput
            WHERE Output IS NOT NULL;
            
            IF @LatestFile IS NULL
                RAISERROR('No backup files found in S3.', 16, 1);
                
            SET @RestorePath = @LocalBackupPath + @LatestFile;
        END
        ELSE
        BEGIN
            -- Construct filename for specific date
            DECLARE @FileName NVARCHAR(1000) = @DatabaseName + '_' + @BackupType + '_' + @RestoreDate +
                CASE 
                    WHEN @BackupType = 'LOG' THEN '_' + @RestoreTime
                    ELSE ''
                END + @FileExtension;
                
            SET @RestorePath = @LocalBackupPath + @FileName;
        END
        
        -- Download from S3
        PRINT 'Downloading backup file from S3...';
        SET @AWSCmd = 'aws s3 cp "' + @S3Path + @FileName + '" "' + @RestorePath + '"'
        EXEC xp_cmdshell @AWSCmd;
        
        -- Verify file was downloaded
        SET @AWSCmd = 'if not exist "' + @RestorePath + '" (exit 1)'
        EXEC xp_cmdshell @AWSCmd;
        IF @@ERROR <> 0
            RAISERROR('Failed to download backup file from S3.', 16, 1);
            
        -- Perform the restore
        PRINT 'Starting database restore...';
        IF @BackupType = 'FULL'
        BEGIN
            RESTORE DATABASE @DatabaseName
            FROM DISK = @RestorePath
            WITH REPLACE,
                CASE @WithRecovery WHEN 1 THEN 'RECOVERY' ELSE 'NORECOVERY' END,
                STATS = 10;
        END
        ELSE IF @BackupType = 'DIFF'
        BEGIN
            RESTORE DATABASE @DatabaseName
            FROM DISK = @RestorePath
            WITH CASE @WithRecovery WHEN 1 THEN 'RECOVERY' ELSE 'NORECOVERY' END,
                STATS = 10;
        END
        ELSE IF @BackupType = 'LOG'
        BEGIN
            RESTORE LOG @DatabaseName
            FROM DISK = @RestorePath
            WITH CASE @WithRecovery WHEN 1 THEN 'RECOVERY' ELSE 'NORECOVERY' END,
                STATS = 10;
        END
        
        PRINT 'Restore completed successfully.';
        
        -- Clean up local file
        PRINT 'Cleaning up local files...';
        EXEC xp_cmdshell 'del /Q "' + @RestorePath + '"'
        
    END TRY
    BEGIN CATCH
        SET @ErrorMessage = ERROR_MESSAGE()
        SET @ErrorSeverity = ERROR_SEVERITY()
        SET @ErrorState = ERROR_STATE()
        
        -- Log error details
        PRINT 'Error occurred in restore process:'
        PRINT 'Error Message: ' + @ErrorMessage
        PRINT 'Error Severity: ' + CAST(@ErrorSeverity AS VARCHAR(10))
        PRINT 'Error State: ' + CAST(@ErrorState AS VARCHAR(10))
        PRINT 'Database: ' + @DatabaseName
        PRINT 'Backup Type: ' + @BackupType
        PRINT 'Restore Date: ' + ISNULL(@RestoreDate, 'Latest')
        PRINT 'Restore Time: ' + ISNULL(@RestoreTime, 'N/A')
        PRINT 'Timestamp: ' + CONVERT(VARCHAR(20), GETDATE(), 120)
        
        -- Re-raise the error
        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END;
GO 