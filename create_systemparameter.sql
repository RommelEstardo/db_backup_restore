-- Create SystemParameter table
CREATE TABLE SystemParameter
(
    ParameterName VARCHAR(50) PRIMARY KEY,
    ParameterValue NVARCHAR(1000),
    Description NVARCHAR(500)
);

-- Insert default values
INSERT INTO SystemParameter (ParameterName, ParameterValue, Description)
VALUES 
('BackupLocation', 'D:\SQLBackups\', 'Local backup folder path'),
('S3Location', 's3://your-bucket/sqlbackups/', 'S3 bucket path for backups');
GO 