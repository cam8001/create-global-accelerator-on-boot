#!/bin/bash

# Create Global Accelerator and update Route 53 DNS
set -e

# Default values
RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-3}"
# Use appropriate directories based on user privileges
if [[ $EUID -eq 0 ]]; then
    SCRIPT_DIR="/var/lib/aws-global-accelerator-script"
else
    SCRIPT_DIR="$HOME/.aws-global-accelerator-script"
fi

LOG_FILE="$SCRIPT_DIR/accelerator.log"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >&2
}

# Retry function with exponential backoff
retry_aws() {
    local cmd="$1"
    local attempt=1
    
    while [[ $attempt -le $RETRY_ATTEMPTS ]]; do
        if eval "$cmd"; then
            return 0
        fi
        
        if [[ $attempt -eq $RETRY_ATTEMPTS ]]; then
            log "ERROR: Command failed after $RETRY_ATTEMPTS attempts: $cmd"
            return 1
        fi
        
        local delay=$((2 ** attempt))
        log "Attempt $attempt failed, retrying in ${delay}s..."
        sleep $delay
        ((attempt++))
    done
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --hosted-zone-id)
            HOSTED_ZONE_ID="$2"
            shift 2
            ;;
        --region)
            AWS_REGION="$2"
            shift 2
            ;;
        --record-name)
            RECORD_NAME="$2"
            shift 2
            ;;
        --retry-attempts)
            RETRY_ATTEMPTS="$2"
            shift 2
            ;;
        --accelerator-name)
            ACCELERATOR_NAME="$2"
            shift 2
            ;;
        *)
            log "ERROR: Unknown parameter $1"
            exit 1
            ;;
    esac
done

# Validate required parameters
if [[ -z "$HOSTED_ZONE_ID" ]]; then
    log "ERROR: --hosted-zone-id or HOSTED_ZONE_ID environment variable required"
    exit 1
fi

if [[ -z "$AWS_REGION" ]]; then
    log "ERROR: --region or AWS_REGION environment variable required"
    exit 1
fi

if [[ -z "$RECORD_NAME" ]]; then
    log "ERROR: --record-name or RECORD_NAME environment variable required"
    exit 1
fi

log "Starting Global Accelerator creation..."

# Get instance metadata using IMDSv2
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" -s)
INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/instance-id)

# Set default accelerator name
ACCELERATOR_NAME="${ACCELERATOR_NAME:-ec2-accelerator-$INSTANCE_ID}"

log "Instance ID: $INSTANCE_ID"
log "Accelerator Name: $ACCELERATOR_NAME"

# Get primary ENI
ENI_ID=$(retry_aws "aws ec2 describe-instances --instance-ids $INSTANCE_ID --query 'Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId' --output text --no-cli-pager")

if [[ "$ENI_ID" == "None" || -z "$ENI_ID" ]]; then
    log "ERROR: Could not find primary ENI for instance $INSTANCE_ID"
    exit 1
fi

log "Primary ENI: $ENI_ID"

# Create Global Accelerator
log "Creating Global Accelerator..."
ACCELERATOR_ARN=$(retry_aws "aws globalaccelerator create-accelerator --name '$ACCELERATOR_NAME' --ip-address-type IPV4 --enabled --query 'Accelerator.AcceleratorArn' --output text --no-cli-pager")

if [[ -z "$ACCELERATOR_ARN" ]]; then
    log "ERROR: Failed to create Global Accelerator"
    exit 1
fi

log "Created Global Accelerator: $ACCELERATOR_ARN"

# Create script directory and description
mkdir -p "$SCRIPT_DIR"
echo "Files created by AWS Global Accelerator automation scripts for managing accelerator endpoints and Route 53 DNS records." > "$SCRIPT_DIR/README.txt"

# Store accelerator ARN
echo "$ACCELERATOR_ARN" > "$SCRIPT_DIR/accelerator-arn"

# Wait for accelerator to be deployed
log "Waiting for accelerator deployment..."
retry_aws "aws globalaccelerator describe-accelerator --accelerator-arn '$ACCELERATOR_ARN' --query 'Accelerator.Status' --output text --no-cli-pager | grep -q 'DEPLOYED'"

# Create listener
log "Creating TCP listener on port 22..."
LISTENER_ARN=$(retry_aws "aws globalaccelerator create-listener --accelerator-arn '$ACCELERATOR_ARN' --protocol TCP --port-ranges FromPort=22,ToPort=22 --query 'Listener.ListenerArn' --output text --no-cli-pager")

# Create endpoint group
log "Creating endpoint group..."
ENDPOINT_GROUP_ARN=$(retry_aws "aws globalaccelerator create-endpoint-group --listener-arn '$LISTENER_ARN' --endpoint-group-region '$AWS_REGION' --endpoints EndpointId='$ENI_ID',Weight=100 --health-check-port 80 --health-check-path '/health' --query 'EndpointGroup.EndpointGroupArn' --output text --no-cli-pager")

# Get accelerator DNS name
ACCELERATOR_DNS=$(retry_aws "aws globalaccelerator describe-accelerator --accelerator-arn '$ACCELERATOR_ARN' --query 'Accelerator.DnsName' --output text --no-cli-pager")

log "Accelerator DNS: $ACCELERATOR_DNS"

# Update Route 53 record
log "Updating Route 53 CNAME record..."
CHANGE_BATCH=$(cat <<EOF
{
    "Changes": [
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "$RECORD_NAME",
                "Type": "CNAME",
                "TTL": 300,
                "ResourceRecords": [
                    {
                        "Value": "$ACCELERATOR_DNS"
                    }
                ]
            }
        }
    ]
}
EOF
)

CHANGE_ID=$(retry_aws "aws route53 change-resource-record-sets --hosted-zone-id '$HOSTED_ZONE_ID' --change-batch '$CHANGE_BATCH' --query 'ChangeInfo.Id' --output text --no-cli-pager")

# Store DNS record info
echo "$HOSTED_ZONE_ID:$RECORD_NAME" > "$SCRIPT_DIR/accelerator-dns-record"

log "Route 53 change submitted: $CHANGE_ID"
log "Global Accelerator setup completed successfully"
log "DNS record: $RECORD_NAME -> $ACCELERATOR_DNS"