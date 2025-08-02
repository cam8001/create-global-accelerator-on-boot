# Global Accelerator Automation

Automated scripts for creating and managing AWS Global Accelerator endpoints with Route 53 DNS updates on EC2 instances.

## Overview

This project provides automation scripts to:
- Create a Global Accelerator endpoint pointing to the current EC2 instance's ENI
- Update Route 53 DNS records to CNAME to the Global Accelerator
- Automatically destroy resources on shutdown
- Manage IAM service-linked roles with proper permissions

## Dependencies

- AWS CLI v2
- jq
- curl
- nginx (installed by setup script)
- Ubuntu Linux (modern EC2 instance)
- IMDSv2 enabled for credential retrieval

## Files

- `create-accelerator.sh` - Main script to create Global Accelerator and update DNS
- `destroy-accelerator.sh` - Script to clean up Global Accelerator resources
- `setup-iam-role.sh` - Script to create required IAM service-linked role
- `setup-health-check.sh` - Script to configure nginx health check endpoint

## Configuration

### Required Parameters

| Parameter | Environment Variable | Description |
|-----------|---------------------|-------------|
| `--hosted-zone-id` | `HOSTED_ZONE_ID` | Route 53 hosted zone ID |
| `--region` | `AWS_REGION` | AWS region for Global Accelerator |

### Optional Parameters

| Parameter | Environment Variable | Default | Description |
|-----------|---------------------|---------|-------------|
| `--record-name` | `RECORD_NAME` | `accelerator` | DNS record name (subdomain) |
| `--retry-attempts` | `RETRY_ATTEMPTS` | `3` | Number of retry attempts for AWS API calls |
| `--accelerator-name` | `ACCELERATOR_NAME` | `ec2-accelerator-{instance-id}` | Global Accelerator name |

## Setup

### 1. IAM Role Creation

```bash
sudo ./setup-iam-role.sh
```

This creates a service-linked role named `ec2-global-accelerator-r53-{unique-id}` with permissions for:
- Global Accelerator management
- Route 53 record updates
- EC2 ENI describe operations

The role name is stored in `/var/lib/accelerator-role-name` for reuse.

### 2. Health Check Endpoint

```bash
sudo ./setup-health-check.sh
```

This installs and configures nginx to serve a health check endpoint at `/health` that returns `200 OK`.

### 3. System Service Integration

#### Boot Script (systemd)
```bash
sudo cp create-accelerator.sh /usr/local/bin/
sudo systemctl enable accelerator-startup.service
```

#### Shutdown Script
```bash
sudo cp destroy-accelerator.sh /usr/local/bin/
sudo systemctl enable accelerator-shutdown.service
```

## Usage

### Manual Execution

#### Create Global Accelerator
```bash
# Using environment variables
export HOSTED_ZONE_ID="Z1234567890ABC"
export AWS_REGION="us-east-1"
./create-accelerator.sh

# Using parameters
./create-accelerator.sh --hosted-zone-id Z1234567890ABC --region us-east-1 --record-name myapp
```

#### Destroy Global Accelerator
```bash
./destroy-accelerator.sh
```

### Automatic Execution

The scripts are designed to run automatically:
- `create-accelerator.sh` on system boot
- `destroy-accelerator.sh` on system shutdown

## Script Behavior

### create-accelerator.sh

1. **IAM Role Check**: Verifies or creates required IAM role
2. **ENI Discovery**: Identifies current instance's primary ENI
3. **Global Accelerator Creation**: 
   - Creates accelerator with TCP listener on port 22
   - Configures endpoint group pointing to instance ENI
   - Sets health check to port 80, path `/health`
4. **DNS Update**: Creates/updates Route 53 CNAME record
5. **State Persistence**: Stores accelerator ARN for cleanup

### destroy-accelerator.sh

1. **State Recovery**: Reads stored accelerator ARN
2. **DNS Cleanup**: Removes Route 53 CNAME record
3. **Resource Deletion**: Deletes Global Accelerator
4. **State Cleanup**: Removes stored configuration

### Error Handling

- **Exponential Backoff**: AWS API calls retry with increasing delays
- **Logging**: All operations logged to stderr with timestamps
- **Graceful Failures**: Script continues where possible, reports specific failures
- **State Recovery**: Handles partial failures and cleanup scenarios

## File Locations

**When running as root:**
- `/var/lib/aws-global-accelerator-script/` - Script state directory
- `/var/lib/aws-global-accelerator-script/accelerator-arn` - Stores Global Accelerator ARN
- `/var/lib/aws-global-accelerator-script/role-name` - Stores IAM role name
- `/var/lib/aws-global-accelerator-script/accelerator-dns-record` - Stores DNS record details
- `/var/lib/aws-global-accelerator-script/accelerator.log` - Operation logs
- `/var/lib/aws-global-accelerator-script/README.txt` - Directory description

**When running as regular user:**
- `$HOME/.aws-global-accelerator-script/` - Script state directory
- Files stored in user's home directory with same structure

## Security Considerations

- Uses IMDSv2 for EC2 metadata access
- Minimal IAM permissions following least privilege
- No hardcoded credentials or sensitive data
- Secure temporary file handling

## Troubleshooting

### Common Issues

1. **IMDSv2 Not Enabled**
   ```bash
   aws ec2 modify-instance-metadata-options --instance-id i-1234567890abcdef0 --http-tokens required
   ```

2. **DNS Propagation**
   - Route 53 changes may take up to 60 seconds to propagate
   - Verify hosted zone ID is correct

3. **Permission Errors**
   - Ensure IAM role is properly attached to EC2 instance
   - Verify role has required permissions for Global Accelerator and Route 53

### Logs

Check operation logs:
```bash
# When running as root
sudo tail -f /var/lib/aws-global-accelerator-script/accelerator.log

# When running as regular user
tail -f ~/.aws-global-accelerator-script/accelerator.log
```

### Manual Cleanup

If automatic cleanup fails:
```bash
# List Global Accelerators
aws globalaccelerator list-accelerators

# Delete manually
aws globalaccelerator delete-accelerator --accelerator-arn arn:aws:globalaccelerator::123456789012:accelerator/abcd1234-abcd-1234-abcd-1234567890ab
```

## License

MIT License - see LICENSE file for details.