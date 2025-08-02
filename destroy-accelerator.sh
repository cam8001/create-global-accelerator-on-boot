#!/bin/bash

# Destroy Global Accelerator and cleanup Route 53 DNS
set -e

# Source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/accelerator-utils.sh"

# Use appropriate directories based on user privileges
if [[ $EUID -eq 0 ]]; then
    SCRIPT_OUTPUT_DIR="/var/lib/aws-global-accelerator-script"
else
    SCRIPT_OUTPUT_DIR="$HOME/.aws-global-accelerator-script"
fi

LOG_FILE="$SCRIPT_OUTPUT_DIR/accelerator.log"
RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-3}"

# Logging function
log() {
    mkdir -p "$SCRIPT_OUTPUT_DIR"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >&2
}



log "Starting Global Accelerator cleanup..."

# Check if accelerator ARN exists
if [[ ! -f "$SCRIPT_OUTPUT_DIR/accelerator-arn" ]]; then
    log "No accelerator ARN found, nothing to cleanup"
    exit 0
fi

ACCELERATOR_ARN=$(cat "$SCRIPT_OUTPUT_DIR/accelerator-arn")

if [[ -z "$ACCELERATOR_ARN" ]]; then
    log "Empty accelerator ARN, nothing to cleanup"
    exit 0
fi

log "Cleaning up accelerator: $ACCELERATOR_ARN"

# Check if DNS record info exists
if [[ -f "$SCRIPT_OUTPUT_DIR/accelerator-dns-record" ]]; then
    DNS_INFO=$(cat "$SCRIPT_OUTPUT_DIR/accelerator-dns-record")
    HOSTED_ZONE_ID="${DNS_INFO%:*}"
    RECORD_NAME="${DNS_INFO#*:}"
    
    if [[ -n "$HOSTED_ZONE_ID" && -n "$RECORD_NAME" ]]; then
        log "Removing Route 53 CNAME record: $RECORD_NAME"
        
        # Get current record value
        CURRENT_VALUE=$(retry_aws "aws route53 list-resource-record-sets --hosted-zone-id '$HOSTED_ZONE_ID' --query \"ResourceRecordSets[?Name=='$RECORD_NAME.' && Type=='CNAME'].ResourceRecords[0].Value\" --output text --no-cli-pager" 2>/dev/null || echo "")
        
        if [[ -n "$CURRENT_VALUE" && "$CURRENT_VALUE" != "None" ]]; then
            CHANGE_BATCH=$(cat <<EOF
{
    "Changes": [
        {
            "Action": "DELETE",
            "ResourceRecordSet": {
                "Name": "$RECORD_NAME",
                "Type": "CNAME",
                "TTL": 300,
                "ResourceRecords": [
                    {
                        "Value": "$CURRENT_VALUE"
                    }
                ]
            }
        }
    ]
}
EOF
)
            
            if retry_aws "aws route53 change-resource-record-sets --hosted-zone-id '$HOSTED_ZONE_ID' --change-batch '$CHANGE_BATCH' --query 'ChangeInfo.Id' --output text --no-cli-pager"; then
                log "Route 53 record deleted successfully"
            else
                log "WARNING: Failed to delete Route 53 record"
            fi
        else
            log "Route 53 record not found or already deleted"
        fi
    fi
fi

# Check if accelerator exists before attempting deletion
if retry_describe_accelerator "aws globalaccelerator describe-accelerator --region us-west-2 --accelerator-arn '$ACCELERATOR_ARN' --no-cli-pager >/dev/null 2>&1"; then
    log "Disabling Global Accelerator..."
    if retry_aws "aws globalaccelerator update-accelerator --region us-west-2 --accelerator-arn '$ACCELERATOR_ARN' --enabled false --no-cli-pager"; then
        log "Accelerator disabled successfully"
        
        # Wait for accelerator to be disabled
        log "Waiting for accelerator to be disabled..."
        retry_describe_accelerator "aws globalaccelerator describe-accelerator --region us-west-2 --accelerator-arn '$ACCELERATOR_ARN' --query 'Accelerator.Status' --output text --no-cli-pager | grep -q 'DEPLOYED'"
        
        log "Deleting Global Accelerator..."
        if retry_aws "aws globalaccelerator delete-accelerator --region us-west-2 --accelerator-arn '$ACCELERATOR_ARN' --no-cli-pager"; then
            log "Global Accelerator deleted successfully"
        else
            log "ERROR: Failed to delete Global Accelerator"
        fi
    else
        log "ERROR: Failed to disable Global Accelerator"
    fi
else
    log "Global Accelerator not found or already deleted"
fi

# Cleanup state files
rm -f "$SCRIPT_OUTPUT_DIR/accelerator-arn"
rm -f "$SCRIPT_OUTPUT_DIR/accelerator-dns-record"

log "Global Accelerator cleanup completed"