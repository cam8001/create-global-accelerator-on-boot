#!/bin/bash

# Create Global Accelerator endpoint
# Focuses only on Global Accelerator management, no DNS operations
set -e

# Source shared utilities and modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/accelerator-utils.sh"
source "$SCRIPT_DIR/accelerator-manager.sh"

# Default values
RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-3}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --region)
            AWS_REGION="$2"
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
        --ip-address-type)
            GA_IP_ADDRESS_TYPE="$2"
            shift 2
            ;;
        --protocol)
            GA_PROTOCOL="$2"
            shift 2
            ;;
        --port)
            GA_PORT="$2"
            shift 2
            ;;
        --health-check-port)
            GA_HEALTH_CHECK_PORT="$2"
            shift 2
            ;;
        --health-check-path)
            GA_HEALTH_CHECK_PATH="$2"
            shift 2
            ;;
        *)
            log "ERROR: Unknown parameter $1"
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --region REGION                AWS region where EC2 instance is located (required)"
            echo "  --accelerator-name NAME        Name for the Global Accelerator (optional)"
            echo "  --ip-address-type TYPE         IP address type: IPV4 or DUAL_STACK (default: IPV4)"
            echo "  --protocol PROTOCOL            Listener protocol: TCP or UDP (default: TCP)"
            echo "  --port PORT                    Listener port (default: 22)"
            echo "  --health-check-port PORT       Health check port (default: 80)"
            echo "  --health-check-path PATH       Health check path (default: /health)"
            echo "  --retry-attempts COUNT         Number of retry attempts (default: 3)"
            exit 1
            ;;
    esac
done

# Validate required parameters
if [[ -z "$AWS_REGION" ]]; then
    log "ERROR: --region or AWS_REGION environment variable required"
    log "This specifies the AWS region where your target EC2 instance is located"
    exit 1
fi

log "Starting Global Accelerator creation..."

# Get instance metadata
if ! ga_get_instance_metadata; then
    log "ERROR: Failed to get EC2 instance metadata"
    log "Ensure this script is running on an EC2 instance with IMDSv2 enabled"
    exit 1
fi

# Set default accelerator name if not provided
ACCELERATOR_NAME="${ACCELERATOR_NAME:-ec2-accelerator-$INSTANCE_ID}"

log "Configuration:"
log "  Instance ID: $INSTANCE_ID"
log "  Primary ENI: $PRIMARY_ENI_ID"
log "  Accelerator Name: $ACCELERATOR_NAME"
log "  Endpoint Region: $AWS_REGION"
log "  IP Address Type: ${GA_IP_ADDRESS_TYPE:-IPV4}"
log "  Protocol: ${GA_PROTOCOL:-TCP}"
log "  Port: ${GA_PORT:-22}"
log "  Health Check Port: ${GA_HEALTH_CHECK_PORT:-80}"
log "  Health Check Path: ${GA_HEALTH_CHECK_PATH:-/health}"

# Create script directory and description
mkdir -p "$SCRIPT_OUTPUT_DIR"
echo "Files created by AWS Global Accelerator automation scripts for managing accelerator endpoints." > "$SCRIPT_OUTPUT_DIR/README.txt"

# Check if accelerator already exists
if ga_load_accelerator_arn; then
    log "WARNING: Found existing accelerator ARN: $STORED_ACCELERATOR_ARN"
    log "Use destroy-accelerator.sh first to clean up existing resources"
    exit 1
fi

# Create complete Global Accelerator setup
log "Creating Global Accelerator infrastructure..."
ACCELERATOR_ARN=$(ga_create_complete_setup "$ACCELERATOR_NAME" "$AWS_REGION" "$PRIMARY_ENI_ID")

if [[ $? -ne 0 || -z "$ACCELERATOR_ARN" ]]; then
    log "ERROR: Failed to create Global Accelerator setup"
    exit 1
fi

# Get accelerator DNS name
ACCELERATOR_DNS=$(ga_get_dns_name "$ACCELERATOR_ARN")

if [[ $? -ne 0 || -z "$ACCELERATOR_DNS" ]]; then
    log "ERROR: Failed to get accelerator DNS name"
    exit 1
fi

log "Global Accelerator created successfully:"
log "  ARN: $ACCELERATOR_ARN"
log "  DNS Name: $ACCELERATOR_DNS"
log "  Status: Provisioning (may take 2-3 minutes to become active)"

log "Global Accelerator setup completed successfully"
log "Your service will be accessible via: $ACCELERATOR_DNS"
log ""
log "Next steps:"
log "1. Wait 2-3 minutes for the accelerator to become active"
log "2. Test connectivity: ssh user@$ACCELERATOR_DNS (if using SSH)"
log "3. Use destroy-accelerator.sh to clean up when no longer needed"
