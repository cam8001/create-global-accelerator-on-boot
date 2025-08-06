#!/bin/bash

# Global Accelerator Manager - AWS Global Accelerator operations
# Handles accelerator creation, configuration, and deletion

set -e

# Source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/accelerator-utils.sh"

# Global Accelerator Configuration
GA_REGION="us-west-2"  # Global Accelerator API region
GA_IP_ADDRESS_TYPE="${GA_IP_ADDRESS_TYPE:-IPV4}"
GA_PROTOCOL="${GA_PROTOCOL:-TCP}"
GA_PORT="${GA_PORT:-22}"
GA_HEALTH_CHECK_PORT="${GA_HEALTH_CHECK_PORT:-80}"
GA_HEALTH_CHECK_PATH="${GA_HEALTH_CHECK_PATH:-/health}"

#
# Get EC2 instance metadata using IMDSv2
#
# Returns: Sets global variables INSTANCE_ID and PRIMARY_ENI_ID
#
ga_get_instance_metadata() {
    log "Retrieving EC2 instance metadata..."
    
    # Get IMDSv2 token with 5 second timeout
    local token
    token=$(curl -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
        --max-time 10 \
        --connect-timeout 5 \
        -s)
    
    if [[ -z "$token" ]]; then
        log "ERROR: Failed to get IMDSv2 token (timeout or connection failed)"
        return 1
    fi
    
    # Get instance ID with 5 second timeout
    INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $token" \
        --max-time 10 \
        --connect-timeout 5 \
        -s http://169.254.169.254/latest/meta-data/instance-id)
    
    if [[ -z "$INSTANCE_ID" ]]; then
        log "ERROR: Failed to get instance ID (timeout or connection failed)"
        return 1
    fi
    
    log "Instance ID: $INSTANCE_ID"
    
    # Get primary ENI ID
    PRIMARY_ENI_ID=$(retry_aws "aws ec2 describe-instances --instance-ids $INSTANCE_ID --query 'Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId' --output text --no-cli-pager")
    
    if [[ "$PRIMARY_ENI_ID" == "None" || -z "$PRIMARY_ENI_ID" ]]; then
        log "ERROR: Could not find primary ENI for instance $INSTANCE_ID"
        return 1
    fi
    
    log "Primary ENI: $PRIMARY_ENI_ID"
    return 0
}

#
# Create a Global Accelerator
#
# Parameters:
#   $1 - Accelerator Name
#   $2 - Optional: IP Address Type (defaults to GA_IP_ADDRESS_TYPE)
#
ga_create_accelerator() {
    local accelerator_name="$1"
    local ip_address_type="${2:-$GA_IP_ADDRESS_TYPE}"
    
    if [[ -z "$accelerator_name" ]]; then
        log "ERROR: ga_create_accelerator requires accelerator_name"
        return 1
    fi
    
    log "Creating Global Accelerator: $accelerator_name"
    
    local accelerator_arn
    accelerator_arn=$(retry_aws "aws globalaccelerator create-accelerator --region $GA_REGION --name '$accelerator_name' --ip-address-type $ip_address_type --enabled --query 'Accelerator.AcceleratorArn' --output text --no-cli-pager")
    
    if [[ -z "$accelerator_arn" ]]; then
        log "ERROR: Failed to create Global Accelerator"
        return 1
    fi
    
    log "Created Global Accelerator: $accelerator_arn"
    
    # Store accelerator ARN
    ga_store_accelerator_arn "$accelerator_arn"
    
    # Wait for accelerator to be deployed
    log "Waiting for accelerator deployment..."
    retry_describe_accelerator "aws globalaccelerator describe-accelerator --region $GA_REGION --accelerator-arn '$accelerator_arn' --query 'Accelerator.Status' --output text --no-cli-pager | grep -q 'DEPLOYED'"
    
    log "Global Accelerator deployed successfully"
    echo "$accelerator_arn"
    return 0
}

#
# Create a listener for the Global Accelerator
#
# Parameters:
#   $1 - Accelerator ARN
#   $2 - Optional: Protocol (defaults to GA_PROTOCOL)
#   $3 - Optional: Port (defaults to GA_PORT)
#
ga_create_listener() {
    local accelerator_arn="$1"
    local protocol="${2:-$GA_PROTOCOL}"
    local port="${3:-$GA_PORT}"
    
    if [[ -z "$accelerator_arn" ]]; then
        log "ERROR: ga_create_listener requires accelerator_arn"
        return 1
    fi
    
    log "Creating $protocol listener on port $port..."
    
    local listener_arn
    listener_arn=$(retry_aws "aws globalaccelerator create-listener --region $GA_REGION --accelerator-arn '$accelerator_arn' --protocol $protocol --port-ranges FromPort=$port,ToPort=$port --query 'Listener.ListenerArn' --output text --no-cli-pager")
    
    if [[ -z "$listener_arn" ]]; then
        log "ERROR: Failed to create listener"
        return 1
    fi
    
    log "Created listener: $listener_arn"
    
    # Wait for listener to be ready
    log "Waiting for listener to be ready..."
    retry_aws "aws globalaccelerator describe-listener --region $GA_REGION --listener-arn '$listener_arn' --query 'Listener.ListenerArn' --output text --no-cli-pager >/dev/null"
    
    echo "$listener_arn"
    return 0
}

#
# Create an endpoint group for the listener
#
# Parameters:
#   $1 - Listener ARN
#   $2 - Endpoint Group Region (where the EC2 instance is located)
#   $3 - ENI ID
#   $4 - Optional: Health Check Port (defaults to GA_HEALTH_CHECK_PORT)
#   $5 - Optional: Health Check Path (defaults to GA_HEALTH_CHECK_PATH)
#
ga_create_endpoint_group() {
    local listener_arn="$1"
    local endpoint_region="$2"
    local eni_id="$3"
    local health_check_port="${4:-$GA_HEALTH_CHECK_PORT}"
    local health_check_path="${5:-$GA_HEALTH_CHECK_PATH}"
    
    if [[ -z "$listener_arn" || -z "$endpoint_region" || -z "$eni_id" ]]; then
        log "ERROR: ga_create_endpoint_group requires listener_arn, endpoint_region, and eni_id"
        return 1
    fi
    
    log "Creating endpoint group in region $endpoint_region for ENI $eni_id..."
    
    local endpoint_group_arn
    endpoint_group_arn=$(retry_aws "aws globalaccelerator create-endpoint-group --region $GA_REGION --listener-arn '$listener_arn' --endpoint-group-region '$endpoint_region' --endpoints EndpointId='$eni_id',Weight=100 --health-check-port $health_check_port --health-check-path '$health_check_path' --query 'EndpointGroup.EndpointGroupArn' --output text --no-cli-pager")
    
    if [[ -z "$endpoint_group_arn" ]]; then
        log "ERROR: Failed to create endpoint group"
        return 1
    fi
    
    log "Created endpoint group: $endpoint_group_arn"
    echo "$endpoint_group_arn"
    return 0
}

#
# Get the DNS name of a Global Accelerator
#
# Parameters:
#   $1 - Accelerator ARN
#
ga_get_dns_name() {
    local accelerator_arn="$1"
    
    if [[ -z "$accelerator_arn" ]]; then
        log "ERROR: ga_get_dns_name requires accelerator_arn"
        return 1
    fi
    
    local dns_name
    dns_name=$(retry_aws "aws globalaccelerator describe-accelerator --region $GA_REGION --accelerator-arn '$accelerator_arn' --query 'Accelerator.DnsName' --output text --no-cli-pager")
    
    if [[ -z "$dns_name" ]]; then
        log "ERROR: Failed to get accelerator DNS name"
        return 1
    fi
    
    log "Accelerator DNS name: $dns_name"
    echo "$dns_name"
    return 0
}

#
# Disable and delete a Global Accelerator
#
# Parameters:
#   $1 - Accelerator ARN
#
ga_delete_accelerator() {
    local accelerator_arn="$1"
    
    if [[ -z "$accelerator_arn" ]]; then
        log "ERROR: ga_delete_accelerator requires accelerator_arn"
        return 1
    fi
    
    log "Checking if accelerator exists: $accelerator_arn"
    
    # Check if accelerator exists
    if ! retry_describe_accelerator "aws globalaccelerator describe-accelerator --region $GA_REGION --accelerator-arn '$accelerator_arn' --no-cli-pager >/dev/null 2>&1"; then
        log "Global Accelerator not found or already deleted"
        return 0
    fi
    
    log "Disabling Global Accelerator..."
    if retry_aws "aws globalaccelerator update-accelerator --region $GA_REGION --accelerator-arn '$accelerator_arn' --enabled false --no-cli-pager"; then
        log "Accelerator disabled successfully"
        
        # Wait for accelerator to be disabled
        log "Waiting for accelerator to be disabled..."
        retry_describe_accelerator "aws globalaccelerator describe-accelerator --region $GA_REGION --accelerator-arn '$accelerator_arn' --query 'Accelerator.Enabled' --output text --no-cli-pager | grep -q 'false'"
        
        log "Deleting Global Accelerator..."
        if retry_aws "aws globalaccelerator delete-accelerator --region $GA_REGION --accelerator-arn '$accelerator_arn' --no-cli-pager"; then
            log "Global Accelerator deleted successfully"
            return 0
        else
            log "ERROR: Failed to delete Global Accelerator"
            return 1
        fi
    else
        log "ERROR: Failed to disable Global Accelerator"
        return 1
    fi
}

#
# Store accelerator ARN for later cleanup
#
# Parameters:
#   $1 - Accelerator ARN
#
ga_store_accelerator_arn() {
    local accelerator_arn="$1"
    
    mkdir -p "$SCRIPT_OUTPUT_DIR"
    echo "$accelerator_arn" > "$SCRIPT_OUTPUT_DIR/accelerator-arn"
    log "Stored accelerator ARN: $accelerator_arn"
}

#
# Load stored accelerator ARN
#
# Returns: Sets global variable STORED_ACCELERATOR_ARN
#
ga_load_accelerator_arn() {
    STORED_ACCELERATOR_ARN=""
    
    if [[ ! -f "$SCRIPT_OUTPUT_DIR/accelerator-arn" ]]; then
        log "No stored accelerator ARN found"
        return 1
    fi
    
    STORED_ACCELERATOR_ARN=$(cat "$SCRIPT_OUTPUT_DIR/accelerator-arn")
    
    if [[ -z "$STORED_ACCELERATOR_ARN" ]]; then
        log "Empty accelerator ARN"
        return 1
    fi
    
    log "Loaded accelerator ARN: $STORED_ACCELERATOR_ARN"
    return 0
}

#
# Clean up stored accelerator ARN
#
ga_cleanup_accelerator_arn() {
    if [[ -f "$SCRIPT_OUTPUT_DIR/accelerator-arn" ]]; then
        rm -f "$SCRIPT_OUTPUT_DIR/accelerator-arn"
        log "Cleaned up accelerator ARN"
    fi
}

#
# Create a complete Global Accelerator setup (accelerator + listener + endpoint group)
#
# Parameters:
#   $1 - Accelerator Name
#   $2 - Endpoint Region (where the EC2 instance is located)
#   $3 - Optional: ENI ID (if not provided, will auto-detect)
#
ga_create_complete_setup() {
    local accelerator_name="$1"
    local endpoint_region="$2"
    local eni_id="$3"
    
    if [[ -z "$accelerator_name" || -z "$endpoint_region" ]]; then
        log "ERROR: ga_create_complete_setup requires accelerator_name and endpoint_region"
        return 1
    fi
    
    # Get instance metadata if ENI not provided
    if [[ -z "$eni_id" ]]; then
        if ! ga_get_instance_metadata; then
            log "ERROR: Failed to get instance metadata"
            return 1
        fi
        eni_id="$PRIMARY_ENI_ID"
    fi
    
    # Create accelerator
    local accelerator_arn
    accelerator_arn=$(ga_create_accelerator "$accelerator_name")
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to create accelerator"
        return 1
    fi
    
    # Create listener
    local listener_arn
    listener_arn=$(ga_create_listener "$accelerator_arn")
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to create listener"
        return 1
    fi
    
    # Create endpoint group
    local endpoint_group_arn
    endpoint_group_arn=$(ga_create_endpoint_group "$listener_arn" "$endpoint_region" "$eni_id")
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to create endpoint group"
        return 1
    fi
    
    log "Complete Global Accelerator setup created successfully"
    echo "$accelerator_arn"
    return 0
}

# Export functions for use by other scripts
export -f ga_get_instance_metadata
export -f ga_create_accelerator
export -f ga_create_listener
export -f ga_create_endpoint_group
export -f ga_get_dns_name
export -f ga_delete_accelerator
export -f ga_store_accelerator_arn
export -f ga_load_accelerator_arn
export -f ga_cleanup_accelerator_arn
export -f ga_create_complete_setup
