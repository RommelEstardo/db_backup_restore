# db_backup_restore

# SQL Server Backup & Restore System

A robust SQL Server backup solution that automatically manages full, differential, and transaction log backups with S3 cloud storage integration.

## Features

- Automated backup scheduling for all user databases
- Support for multiple backup types:
  - Full backups (weekly)
  - Differential backups (daily)
  - Transaction log backups (hourly)
- Secure Amazon S3 integration for cloud storage
- Comprehensive error handling and logging
- Point-in-time restore capabilities
- Automatic cleanup of local backup files

## Prerequisites

- SQL Server 2016 or later
- AWS CLI installed and configured with appropriate S3 access
- SQL Server Agent service running
- Appropriate permissions for xp_cmdshell execution
- System Parameter table with required configuration entries

## Configuration

### System Parameters Required

The following entries must exist in the SystemParameter table:

- `BackupLocation`: Local path for temporary backup storage
- `S3Location`: S3 bucket path for cloud storage

### AWS Configuration

1. Configure AWS credentials using S3_Backup_Credential:
```sql
CREATE CREDENTIAL [S3_Backup_Credential]
WITH IDENTITY = 'S3 Access Key',
SECRET = 'your_secret_access_key';
```

2. Ensure AWS CLI is properly configured with the same credentials

## Backup Procedures

### Main Procedures

1. `sp_BackupToS3`
   - Single database backup procedure
   - Parameters:
     - @DatabaseName: Name of the database to backup
     - @BackupType: 'FULL', 'DIFF', or 'LOG'

2. `sp_BackupAllUserDatabases`
   - Backs up all user databases
   - Parameter:
     - @BackupType: 'FULL', 'DIFF', or 'LOG'

### Automated Jobs

Three SQL Server Agent jobs are automatically created:

1. Weekly Full Backup (Sundays at 1:00 AM)
2. Daily Differential Backup (Monday-Saturday at 2:00 AM)
3. Hourly Transaction Log Backup (Every hour)

## Restore Procedures

### sp_RestoreFromS3

Restores databases from S3 backups with flexible options:

Parameters:
- @DatabaseName: Target database name
- @BackupType: 'FULL', 'DIFF', or 'LOG'
- @WithRecovery: 1 (default) for WITH RECOVERY, 0 for NORECOVERY
- @RestoreDate: Optional, format YYYYMMDD
- @RestoreTime: Required for LOG restores when RestoreDate is specified

Example usage:
```sql
-- Restore latest full backup
EXEC sp_RestoreFromS3 @DatabaseName = 'MyDB', @BackupType = 'FULL';

-- Restore specific log backup
EXEC sp_RestoreFromS3 
    @DatabaseName = 'MyDB', 
    @BackupType = 'LOG',
    @RestoreDate = '20241230',
    @RestoreTime = '143000',
    @WithRecovery = 0;
```

## Error Handling

All procedures include comprehensive error handling:
- Detailed error logging
- Transaction management
- Input parameter validation
- S3 operation verification
- Cleanup of temporary files

## Best Practices

1. Regular Monitoring:
   - Check SQL Server Agent job history
   - Monitor S3 storage usage
   - Verify backup success in system logs

2. Testing:
   - Regularly test restore procedures
   - Validate backup integrity
   - Perform disaster recovery drills

3. Security:
   - Regularly rotate AWS credentials
   - Maintain secure backup file permissions
   - Monitor access logs

## Troubleshooting

Common issues and solutions:

1. S3 Upload Failures:
   - Verify AWS CLI configuration
   - Check network connectivity
   - Validate S3 bucket permissions

2. Backup Job Failures:
   - Check SQL Server Agent logs
   - Verify disk space availability
   - Ensure proper permissions

3. Restore Issues:
   - Validate backup file existence in S3
   - Check local disk space
   - Verify database state and recovery model

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Contributing

Contributions are welcome! Please read the contributing guidelines before submitting pull requests.

## Support

For issues and feature requests, please use the GitHub issue tracker.
