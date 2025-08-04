#!/bin/bash

# Destroy Global Accelerator and cleanup Route 53 DNS
set -e

# Source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/accelerator-utils.sh"

RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-3}"

# Check for required dependencies
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not installed. Please install jq and try again." >&2
    exit 1
fi

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

        # Get current record details (value and TTL)
        RECORD_DETAILS=$(retry_aws "aws route53 list-resource-record-sets --hosted-zone-id '$HOSTED_ZONE_ID' --query \"ResourceRecordSets[?Name=='$RECORD_NAME.' && Type=='CNAME'] | [0]\" --output json --no-cli-pager" 2>/dev/null || echo "{}")

        if [[ "$RECORD_DETAILS" != "{}" && "$RECORD_DETAILS" != "null" ]]; then
            CURRENT_VALUE=$(echo "$RECORD_DETAILS" | jq -r '.ResourceRecords[0].Value // empty')
            CURRENT_TTL=$(echo "$RECORD_DETAILS" | jq -r '.TTL // 300')

            if [[ -n "$CURRENT_VALUE" ]]; then
                CHANGE_BATCH=$(cat <<EOF
{
    "Changes": [
        {
            "Action": "DELETE",
            "ResourceRecordSet": {
                "Name": "$RECORD_NAME",
                "Type": "CNAME",
                "TTL": $CURRENT_TTL,
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
                log "Route 53 record value not found"
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
        retry_describe_accelerator "aws globalaccelerator describe-accelerator --region us-west-2 --accelerator-arn '$ACCELERATOR_ARN' --query 'Accelerator.Enabled' --output text --no-cli-pager | grep -q 'false'"

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
