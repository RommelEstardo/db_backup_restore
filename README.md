# SQL Server S3 Backup System

This system provides automated database backup functionality for SQL Server, supporting full, differential, and transaction log backups with direct integration to Amazon S3 storage.

## Files Overview

1. **create_systemparameter.sql**
   - Creates the SystemParameter table for storing configuration settings
   - Initializes default backup locations for local and S3 storage
   - Required for both backup and restore operations

2. **backup_procedures.sql**
   - Contains the core backup procedures and SQL Agent jobs
   - Includes:
     - `sp_BackupToS3`: Individual database backup procedure
     - `sp_BackupAllUserDatabases`: Batch backup procedure for all user databases
     - Automated SQL Agent jobs for scheduled backups

3. **restore_procedures.sql**
   - Contains the restore procedure `sp_RestoreFromS3`
   - Supports point-in-time recovery options
   - Handles all backup types (FULL, DIFF, LOG)

## Setup Instructions

1. **Initial Setup**
   ```sql
   -- 1. Run the system parameter creation script
   execute create_systemparameter.sql

   -- 2. Update the SystemParameter table with your specific paths
   UPDATE SystemParameter 
   SET ParameterValue = 'YOUR_LOCAL_PATH'
   WHERE ParameterName = 'BackupLocation';

   UPDATE SystemParameter 
   SET ParameterValue = 'YOUR_S3_BUCKET_PATH'
   WHERE ParameterName = 'S3Location';

   -- 3. Run the backup and restore procedure creation scripts
   execute backup_procedures.sql
   execute restore_procedures.sql
   ```

2. **AWS CLI Configuration**
   - Ensure AWS CLI is installed on the SQL Server
   - Configure AWS credentials with appropriate S3 access
   - Test AWS CLI access to your S3 bucket

## Backup Schedule

The system creates three SQL Agent jobs with the following default schedule:

- **Weekly Full Backup**
  - Runs every Sunday at 1:00 AM
  - Backs up all user databases

- **Daily Differential Backup**
  - Runs Monday through Saturday at 2:00 AM
  - Captures changes since the last full backup

- **Hourly Transaction Log Backup**
  - Runs every hour
  - Only backs up databases in FULL recovery model

## Usage Examples

### Performing Manual Backups

```sql
-- Full backup of a single database
EXEC sp_BackupToS3 
    @DatabaseName = 'YourDatabase',
    @BackupType = 'FULL';

-- Differential backup of all user databases
EXEC sp_BackupAllUserDatabases 
    @BackupType = 'DIFF';

-- Transaction log backup
EXEC sp_BackupToS3 
    @DatabaseName = 'YourDatabase',
    @BackupType = 'LOG';
```

### Performing Restores

```sql
-- Restore the latest full backup
EXEC sp_RestoreFromS3
    @DatabaseName = 'YourDatabase',
    @BackupType = 'FULL',
    @WithRecovery = 1;

-- Point-in-time restore
EXEC sp_RestoreFromS3
    @DatabaseName = 'YourDatabase',
    @BackupType = 'LOG',
    @RestoreDate = '20240130',
    @RestoreTime = '143000',
    @WithRecovery = 1;
```

## Security Considerations

- The system requires SQL Server Agent to be running
- `xp_cmdshell` must be enabled for S3 operations
- AWS credentials must be properly configured
- Appropriate SQL Server permissions are required for backup/restore operations

## Monitoring and Maintenance

- Check SQL Server Agent job history for backup status
- Monitor the SQL Server error log for backup/restore operations
- Regularly verify backup integrity
- Monitor S3 storage usage and costs
- Review and maintain backup retention policies

## Error Handling

The system includes comprehensive error handling:
- Detailed error logging
- Validation of input parameters
- Verification of backup/restore operations
- Cleanup of temporary local files
- Transaction log management

## Prerequisites

- SQL Server 2016 or later
- AWS CLI installed and configured
- Appropriate SQL Server permissions
- Sufficient disk space for local staging
- Network access to Amazon S3
- `xp_cmdshell` enabled

## Recovery Models

- Full backups work with all recovery models
- Differential backups work with all recovery models
- Transaction log backups require FULL recovery model
- Databases in SIMPLE recovery model are automatically skipped for log backups

## Troubleshooting

1. **Backup Failures**
   - Check SQL Server error logs
   - Verify AWS CLI configuration
   - Ensure sufficient disk space
   - Check network connectivity to S3

2. **Restore Failures**
   - Verify backup file existence in S3
   - Check local disk space for staging
   - Verify database status and locks
   - Review SQL Server permissions

## Support and Maintenance

For issues or modifications:
1. Check SQL Server error logs
2. Review job history in SQL Server Agent
3. Verify AWS S3 bucket permissions
4. Test AWS CLI connectivity
5. Monitor local disk space usage
