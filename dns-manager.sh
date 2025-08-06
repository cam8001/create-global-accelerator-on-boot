#!/bin/bash

# DNS Manager - Route 53 operations for Global Accelerator automation
# Handles CNAME record creation, updates, and deletion for accelerator endpoints

set -e

# Source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/accelerator-utils.sh"

# DNS Manager Configuration
DNS_RECORD_TTL="${DNS_RECORD_TTL:-300}"

#
# Create or update a CNAME record pointing to the Global Accelerator
#
# Parameters:
#   $1 - Hosted Zone ID
#   $2 - Record Name (FQDN)
#   $3 - Target DNS Name (Global Accelerator DNS)
#   $4 - Optional TTL (defaults to DNS_RECORD_TTL)
#
dns_create_cname_record() {
    local hosted_zone_id="$1"
    local record_name="$2"
    local target_dns="$3"
    local ttl="${4:-$DNS_RECORD_TTL}"
    
    if [[ -z "$hosted_zone_id" || -z "$record_name" || -z "$target_dns" ]]; then
        log "ERROR: dns_create_cname_record requires hosted_zone_id, record_name, and target_dns"
        return 1
    fi
    
    log "Creating/updating CNAME record: $record_name -> $target_dns"
    
    # Create change batch JSON
    local change_batch=$(cat <<EOF
{
    "Changes": [
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "$record_name",
                "Type": "CNAME",
                "TTL": $ttl,
                "ResourceRecords": [
                    {
                        "Value": "$target_dns"
                    }
                ]
            }
        }
    ]
}
EOF
)
    
    # Submit the change
    local change_id
    change_id=$(retry_aws "aws route53 change-resource-record-sets --hosted-zone-id '$hosted_zone_id' --change-batch '$change_batch' --query 'ChangeInfo.Id' --output text --no-cli-pager")
    
    if [[ -n "$change_id" ]]; then
        log "Route 53 change submitted: $change_id"
        
        # Store DNS record info for cleanup
        dns_store_record_info "$hosted_zone_id" "$record_name"
        
        return 0
    else
        log "ERROR: Failed to create/update CNAME record"
        return 1
    fi
}

#
# Delete a CNAME record
#
# Parameters:
#   $1 - Hosted Zone ID
#   $2 - Record Name (FQDN)
#
dns_delete_cname_record() {
    local hosted_zone_id="$1"
    local record_name="$2"
    
    if [[ -z "$hosted_zone_id" || -z "$record_name" ]]; then
        log "ERROR: dns_delete_cname_record requires hosted_zone_id and record_name"
        return 1
    fi
    
    log "Deleting CNAME record: $record_name"
    
    # Get current record details to ensure accurate deletion
    local record_details
    record_details=$(retry_aws "aws route53 list-resource-record-sets --hosted-zone-id '$hosted_zone_id' --query \"ResourceRecordSets[?Name=='$record_name.' && Type=='CNAME'] | [0]\" --output json --no-cli-pager" 2>/dev/null || echo "{}")
    
    if [[ "$record_details" == "{}" || "$record_details" == "null" ]]; then
        log "CNAME record not found or already deleted: $record_name"
        return 0
    fi
    
    # Extract current values for accurate deletion
    local current_value
    local current_ttl
    current_value=$(echo "$record_details" | jq -r '.ResourceRecords[0].Value // empty')
    current_ttl=$(echo "$record_details" | jq -r '.TTL // 300')
    
    if [[ -z "$current_value" ]]; then
        log "WARNING: Could not determine current CNAME value for $record_name"
        return 1
    fi
    
    # Create delete change batch
    local change_batch=$(cat <<EOF
{
    "Changes": [
        {
            "Action": "DELETE",
            "ResourceRecordSet": {
                "Name": "$record_name",
                "Type": "CNAME",
                "TTL": $current_ttl,
                "ResourceRecords": [
                    {
                        "Value": "$current_value"
                    }
                ]
            }
        }
    ]
}
EOF
)
    
    # Submit the deletion
    if retry_aws "aws route53 change-resource-record-sets --hosted-zone-id '$hosted_zone_id' --change-batch '$change_batch' --query 'ChangeInfo.Id' --output text --no-cli-pager"; then
        log "CNAME record deleted successfully: $record_name"
        return 0
    else
        log "WARNING: Failed to delete CNAME record: $record_name"
        return 1
    fi
}

#
# Store DNS record information for later cleanup
#
# Parameters:
#   $1 - Hosted Zone ID
#   $2 - Record Name
#
dns_store_record_info() {
    local hosted_zone_id="$1"
    local record_name="$2"
    
    mkdir -p "$SCRIPT_OUTPUT_DIR"
    echo "$hosted_zone_id:$record_name" > "$SCRIPT_OUTPUT_DIR/accelerator-dns-record"
    log "Stored DNS record info: $hosted_zone_id:$record_name"
}

#
# Load stored DNS record information
#
# Returns: Sets global variables DNS_HOSTED_ZONE_ID and DNS_RECORD_NAME
#
dns_load_record_info() {
    DNS_HOSTED_ZONE_ID=""
    DNS_RECORD_NAME=""
    
    if [[ ! -f "$SCRIPT_OUTPUT_DIR/accelerator-dns-record" ]]; then
        log "No stored DNS record information found"
        return 1
    fi
    
    local dns_info
    dns_info=$(cat "$SCRIPT_OUTPUT_DIR/accelerator-dns-record")
    
    if [[ -z "$dns_info" ]]; then
        log "Empty DNS record information"
        return 1
    fi
    
    DNS_HOSTED_ZONE_ID="${dns_info%:*}"
    DNS_RECORD_NAME="${dns_info#*:}"
    
    if [[ -z "$DNS_HOSTED_ZONE_ID" || -z "$DNS_RECORD_NAME" ]]; then
        log "Invalid DNS record information format: $dns_info"
        return 1
    fi
    
    log "Loaded DNS record info: Zone=$DNS_HOSTED_ZONE_ID, Record=$DNS_RECORD_NAME"
    return 0
}

#
# Clean up stored DNS record information
#
dns_cleanup_record_info() {
    if [[ -f "$SCRIPT_OUTPUT_DIR/accelerator-dns-record" ]]; then
        rm -f "$SCRIPT_OUTPUT_DIR/accelerator-dns-record"
        log "Cleaned up DNS record information"
    fi
}

#
# Validate DNS parameters
#
# Parameters:
#   $1 - Hosted Zone ID
#   $2 - Record Name
#
dns_validate_parameters() {
    local hosted_zone_id="$1"
    local record_name="$2"
    
    # Validate hosted zone ID format (basic check)
    if [[ ! "$hosted_zone_id" =~ ^Z[A-Z0-9]{10,32}$ ]]; then
        log "ERROR: Invalid hosted zone ID format: $hosted_zone_id"
        return 1
    fi
    
    # Validate record name format (basic FQDN check)
    if [[ ! "$record_name" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        log "ERROR: Invalid record name format: $record_name"
        return 1
    fi
    
    log "DNS parameters validated successfully"
    return 0
}

# Export functions for use by other scripts
export -f dns_create_cname_record
export -f dns_delete_cname_record
export -f dns_store_record_info
export -f dns_load_record_info
export -f dns_cleanup_record_info
export -f dns_validate_parameters
