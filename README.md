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

### Main Scripts
- `create-accelerator.sh` - Create Global Accelerator endpoint (Global Accelerator functions only)
- `destroy-accelerator.sh` - Clean up Global Accelerator resources (Global Accelerator functions only)
- `update-dns.sh` - Manage Route 53 DNS records independently
- `setup-iam-role.sh` - Script to create required IAM service-linked role
- `setup-health-check.sh` - Script to configure nginx health check endpoint

### Modular Components
- `accelerator-utils.sh` - Shared utility functions (logging, retry logic)
- `dns-manager.sh` - Route 53 DNS management functions
- `accelerator-manager.sh` - Global Accelerator lifecycle management functions
- `example-usage.sh` - Example script demonstrating modular usage

### Modular Architecture

The scripts have been refactored into reusable modules for better maintainability and code reuse:

#### DNS Manager (`dns-manager.sh`)
Handles all Route 53 DNS operations:
- `dns_create_cname_record(hosted_zone_id, record_name, target_dns, [ttl])` - Create/update CNAME records
- `dns_delete_cname_record(hosted_zone_id, record_name)` - Delete CNAME records
- `dns_validate_parameters(hosted_zone_id, record_name)` - Validate DNS parameters
- `dns_store_record_info(hosted_zone_id, record_name)` - Store DNS record info for cleanup
- `dns_load_record_info()` - Load stored DNS record info (sets DNS_HOSTED_ZONE_ID and DNS_RECORD_NAME)
- `dns_cleanup_record_info()` - Clean up stored DNS record information

#### Global Accelerator Manager (`accelerator-manager.sh`)
Handles all Global Accelerator operations:
- `ga_get_instance_metadata()` - Retrieve EC2 instance metadata (sets INSTANCE_ID and PRIMARY_ENI_ID)
- `ga_create_accelerator(accelerator_name, [ip_address_type])` - Create Global Accelerator
- `ga_create_listener(accelerator_arn, [protocol], [port])` - Create TCP/UDP listeners
- `ga_create_endpoint_group(listener_arn, endpoint_region, eni_id, [health_check_port], [health_check_path])` - Create endpoint groups
- `ga_get_dns_name(accelerator_arn)` - Get accelerator DNS name
- `ga_delete_accelerator(accelerator_arn)` - Disable and delete accelerator
- `ga_create_complete_setup(accelerator_name, endpoint_region, [eni_id])` - Create full accelerator setup
- `ga_store_accelerator_arn(accelerator_arn)` - Store accelerator ARN for cleanup
- `ga_load_accelerator_arn()` - Load stored accelerator ARN (sets STORED_ACCELERATOR_ARN)
- `ga_cleanup_accelerator_arn()` - Clean up stored accelerator ARN

#### Configuration Variables

**DNS Manager:**
- `DNS_RECORD_TTL` - Default TTL for DNS records (default: 300)

**Global Accelerator Manager:**
- `GA_REGION` - Global Accelerator API region (default: us-west-2)
- `GA_IP_ADDRESS_TYPE` - IP address type (default: IPV4)
- `GA_PROTOCOL` - Listener protocol (default: TCP)
- `GA_PORT` - Listener port (default: 22)
- `GA_HEALTH_CHECK_PORT` - Health check port (default: 80)
- `GA_HEALTH_CHECK_PATH` - Health check path (default: /health)

#### Usage Examples

```bash
# Source the modules
source ./dns-manager.sh
source ./accelerator-manager.sh

# Example 1: Create just a DNS record pointing to an existing service
dns_create_cname_record "Z123456789" "app.example.com" "existing-service.amazonaws.com"

# Example 2: Create just a Global Accelerator
ACCELERATOR_ARN=$(ga_create_complete_setup "my-app" "us-east-1")

# Example 3: Get accelerator DNS and update Route 53
ACCELERATOR_DNS=$(ga_get_dns_name "$ACCELERATOR_ARN")
dns_create_cname_record "Z123456789" "app.example.com" "$ACCELERATOR_DNS"

# Example 4: Custom workflow with different TTL
ga_get_instance_metadata
ACCELERATOR_ARN=$(ga_create_accelerator "custom-accelerator")
LISTENER_ARN=$(ga_create_listener "$ACCELERATOR_ARN" "TCP" "443")
ga_create_endpoint_group "$LISTENER_ARN" "us-east-1" "$PRIMARY_ENI_ID"
ACCELERATOR_DNS=$(ga_get_dns_name "$ACCELERATOR_ARN")
dns_create_cname_record "Z123456789" "secure.example.com" "$ACCELERATOR_DNS" 600

# Example 5: Load and cleanup existing resources
if ga_load_accelerator_arn; then
    ga_delete_accelerator "$STORED_ACCELERATOR_ARN"
fi

if dns_load_record_info; then
    dns_delete_cname_record "$DNS_HOSTED_ZONE_ID" "$DNS_RECORD_NAME"
fi
```

#### Benefits of Modular Design

- **Reusability**: Use individual functions for custom workflows
- **Maintainability**: Clear separation of concerns between DNS and Global Accelerator operations
- **Testability**: Each module can be tested independently
- **Flexibility**: Mix and match functions for different use cases
- **Error Handling**: Consistent error handling and logging across all modules
- **State Management**: Built-in state persistence for cleanup operations

## Configuration

### Required Parameters

#### create-accelerator.sh
| Parameter | Environment Variable | Description |
|-----------|---------------------|-------------|
| `--region` | `AWS_REGION` | AWS region where your EC2 instance is located (for endpoint group) |

#### update-dns.sh (for DNS management)
| Parameter | Environment Variable | Description |
|-----------|---------------------|-------------|
| `--hosted-zone-id` | `HOSTED_ZONE_ID` | Route 53 hosted zone ID |
| `--record-name` | `RECORD_NAME` | DNS record name (subdomain) |

**Note**: Global Accelerator API calls are made to the global endpoint (us-west-2), but the `--region` parameter specifies where your EC2 instance endpoints are located.

### Optional Parameters

#### create-accelerator.sh
| Parameter | Environment Variable | Default | Description |
|-----------|---------------------|---------|-------------|
| `--retry-attempts` | `RETRY_ATTEMPTS` | `3` | Number of retry attempts for AWS API calls |
| `--accelerator-name` | `ACCELERATOR_NAME` | `ec2-accelerator-{instance-id}` | Global Accelerator name |
| `--ip-address-type` | `GA_IP_ADDRESS_TYPE` | `IPV4` | IP address type (IPV4 or DUAL_STACK) |
| `--protocol` | `GA_PROTOCOL` | `TCP` | Listener protocol (TCP or UDP) |
| `--port` | `GA_PORT` | `22` | Listener port |
| `--health-check-port` | `GA_HEALTH_CHECK_PORT` | `80` | Health check port |
| `--health-check-path` | `GA_HEALTH_CHECK_PATH` | `/health` | Health check path |

## Setup

### 1. IAM Role Creation

```bash
sudo ./setup-iam-role.sh
```

This creates a service-linked role named `ec2-global-accelerator-r53-{unique-id}` with permissions for:
- Global Accelerator management
- Route 53 record updates (limited to specific hosted zone and subdomain)
- EC2 ENI describe operations

The role name is stored in `/var/lib/accelerator-role-name` for reuse.

**IMPORTANT**: The IAM policy contains example values that must be updated before use:
- Replace `Z1234567890ABC` with your actual hosted zone ID
- Replace `myapp.example.com` with your actual subdomain

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
export AWS_REGION="us-east-1"
./create-accelerator.sh

# Using parameters
./create-accelerator.sh --region us-east-1

# With custom configuration
./create-accelerator.sh --region us-east-1 --accelerator-name my-app --port 443 --protocol TCP
```

#### Destroy Global Accelerator
```bash
./destroy-accelerator.sh

# Skip confirmation prompt
./destroy-accelerator.sh --force
```

#### Manage DNS Separately
```bash
# Create DNS record pointing to existing Global Accelerator
./update-dns.sh --hosted-zone-id Z1234567890ABC --record-name myapp.example.com --target-dns a1234567890abcdef.awsglobalaccelerator.com

# Delete DNS record
./update-dns.sh --hosted-zone-id Z1234567890ABC --record-name myapp.example.com --delete
```

### Automatic Execution

The scripts are designed to run automatically:
- `create-accelerator.sh` on system boot
- `destroy-accelerator.sh` on system shutdown

## Script Behavior

### create-accelerator.sh

1. **ENI Discovery**: Identifies current instance's primary ENI
2. **Global Accelerator Creation**: 
   - Creates accelerator with configurable listener (default: TCP port 22)
   - Configures endpoint group pointing to instance ENI
   - Sets health check to configurable port/path (default: port 80, path `/health`)
3. **State Persistence**: Stores accelerator ARN for cleanup
4. **Output**: Provides Global Accelerator DNS name for manual DNS configuration

### destroy-accelerator.sh

1. **State Recovery**: Reads stored accelerator ARN
2. **Resource Deletion**: Disables and deletes Global Accelerator
3. **State Cleanup**: Removes stored configuration files

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
- `/var/lib/aws-global-accelerator-script/policy-name` - Stores IAM policy name
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