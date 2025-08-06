#!/bin/bash

# Example usage of the modular DNS and Global Accelerator components
# This demonstrates how to use the modules independently for custom workflows
# and how the main scripts now work with separated concerns

set -e

# Source the modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/accelerator-utils.sh"
source "$SCRIPT_DIR/dns-manager.sh"
source "$SCRIPT_DIR/accelerator-manager.sh"

# Example configuration - UPDATE THESE VALUES
HOSTED_ZONE_ID="Z1234567890ABC"  # Replace with your hosted zone ID
RECORD_NAME="test.example.com"   # Replace with your domain
AWS_REGION="us-east-1"           # Replace with your region

log "=== Example 1: Using Main Scripts (Recommended Approach) ==="

# The main scripts now have separated responsibilities:
# - create-accelerator.sh: Only creates Global Accelerator
# - update-dns.sh: Only manages DNS records

log "Step 1: Create Global Accelerator only"
log "Command: ./create-accelerator.sh --region $AWS_REGION"
log "(This creates the accelerator and outputs the DNS name for manual use)"

log "Step 2: Create DNS record pointing to the accelerator"
log "Command: ./update-dns.sh --hosted-zone-id $HOSTED_ZONE_ID --record-name $RECORD_NAME --target-dns <accelerator-dns>"
log "Or use: ./update-dns.sh --hosted-zone-id $HOSTED_ZONE_ID --record-name $RECORD_NAME --use-accelerator"

log "Step 3: Clean up when done"
log "Command: ./destroy-accelerator.sh  # Only removes Global Accelerator"
log "Command: ./update-dns.sh --hosted-zone-id $HOSTED_ZONE_ID --record-name $RECORD_NAME --delete  # Removes DNS record"

log "=== Example 2: Using Modules Directly ==="

# Validate DNS parameters first
if dns_validate_parameters "$HOSTED_ZONE_ID" "$RECORD_NAME"; then
    log "DNS parameters are valid"
else
    log "DNS parameters are invalid - update the configuration above"
    exit 1
fi

# Get current instance metadata (only works on EC2)
if ga_get_instance_metadata; then
    log "Successfully retrieved instance metadata:"
    log "  Instance ID: $INSTANCE_ID"
    log "  Primary ENI: $PRIMARY_ENI_ID"
    
    # Example: Create just a Global Accelerator
    log "Example: Creating Global Accelerator only..."
    # ACCELERATOR_ARN=$(ga_create_accelerator "example-accelerator")
    # log "Created accelerator: $ACCELERATOR_ARN"
    
    # Example: Create complete accelerator setup
    log "Example: Creating complete Global Accelerator setup..."
    # ACCELERATOR_ARN=$(ga_create_complete_setup "example-accelerator" "$AWS_REGION")
    # ACCELERATOR_DNS=$(ga_get_dns_name "$ACCELERATOR_ARN")
    # log "Accelerator DNS: $ACCELERATOR_DNS"
    
else
    log "Not running on EC2 instance - skipping accelerator creation examples"
fi

# Example: Create DNS record pointing to existing service
log "Example: Creating DNS record for existing service..."
# dns_create_cname_record "$HOSTED_ZONE_ID" "$RECORD_NAME" "existing-service.amazonaws.com"

log "=== Example 3: Loading and Managing Existing Resources ==="

# Load stored accelerator ARN if it exists
if ga_load_accelerator_arn; then
    log "Found stored accelerator: $STORED_ACCELERATOR_ARN"
    
    # Get its DNS name
    ACCELERATOR_DNS=$(ga_get_dns_name "$STORED_ACCELERATOR_ARN")
    log "Accelerator DNS: $ACCELERATOR_DNS"
    
    # Example: Create DNS record pointing to this accelerator
    log "Example: Creating DNS record for stored accelerator..."
    # dns_create_cname_record "$HOSTED_ZONE_ID" "$RECORD_NAME" "$ACCELERATOR_DNS"
    
else
    log "No stored accelerator found"
fi

# Load stored DNS record info if it exists
if dns_load_record_info; then
    log "Found stored DNS record: $DNS_RECORD_NAME in zone $DNS_HOSTED_ZONE_ID"
    
    # Example: Delete the stored DNS record
    log "Example: Deleting stored DNS record..."
    # dns_delete_cname_record "$DNS_HOSTED_ZONE_ID" "$DNS_RECORD_NAME"
    
else
    log "No stored DNS record found"
fi

log "=== Example 4: Custom Workflows ==="

# Workflow 1: Create accelerator with custom configuration, then DNS
create_custom_accelerator_workflow() {
    local accelerator_name="$1"
    local endpoint_region="$2"
    local hosted_zone_id="$3"
    local record_name="$4"
    
    log "Custom Workflow 1: Accelerator + DNS with custom settings"
    
    # Get instance metadata
    if ! ga_get_instance_metadata; then
        log "ERROR: Must run on EC2 instance"
        return 1
    fi
    
    # Create accelerator with custom settings
    local accelerator_arn
    accelerator_arn=$(ga_create_accelerator "$accelerator_name" "DUAL_STACK")
    
    # Create listener with HTTPS
    local listener_arn
    listener_arn=$(ga_create_listener "$accelerator_arn" "TCP" "443")
    
    # Create endpoint group with custom health check
    ga_create_endpoint_group "$listener_arn" "$endpoint_region" "$PRIMARY_ENI_ID" "443" "/api/health"
    
    # Get DNS name and create record with custom TTL
    local accelerator_dns
    accelerator_dns=$(ga_get_dns_name "$accelerator_arn")
    dns_create_cname_record "$hosted_zone_id" "$record_name" "$accelerator_dns" 600
    
    log "Custom accelerator setup completed:"
    log "  Accelerator: $accelerator_arn"
    log "  DNS: $record_name -> $accelerator_dns"
    log "  Configuration: HTTPS (443) with dual-stack IP"
}

# Workflow 2: DNS-only management for existing services
manage_dns_only() {
    local hosted_zone_id="$1"
    local record_name="$2"
    local target_service="$3"
    
    log "Custom Workflow 2: DNS-only management"
    
    # Create DNS record for existing service
    dns_create_cname_record "$hosted_zone_id" "$record_name" "$target_service"
    
    log "DNS record created: $record_name -> $target_service"
}

# Workflow 3: Complete cleanup
cleanup_all_resources() {
    log "Custom Workflow 3: Complete cleanup"
    
    # Clean up Global Accelerator if exists
    if ga_load_accelerator_arn; then
        log "Cleaning up accelerator: $STORED_ACCELERATOR_ARN"
        ga_delete_accelerator "$STORED_ACCELERATOR_ARN"
        ga_cleanup_accelerator_arn
    fi
    
    # Clean up DNS record if exists
    if dns_load_record_info; then
        log "Cleaning up DNS record: $DNS_RECORD_NAME"
        dns_delete_cname_record "$DNS_HOSTED_ZONE_ID" "$DNS_RECORD_NAME"
        dns_cleanup_record_info
    fi
    
    log "Complete cleanup finished"
}

# Uncomment to run specific workflows:
# create_custom_accelerator_workflow "custom-accelerator" "$AWS_REGION" "$HOSTED_ZONE_ID" "$RECORD_NAME"
# manage_dns_only "$HOSTED_ZONE_ID" "api.$RECORD_NAME" "existing-api.amazonaws.com"
# cleanup_all_resources

log "=== Example 5: Integration with Main Scripts ==="

log "The main scripts can now be used in sequence:"
log ""
log "# Create Global Accelerator"
log "./create-accelerator.sh --region $AWS_REGION --accelerator-name my-app --port 443"
log ""
log "# Create DNS record using the accelerator's DNS name"
log "./update-dns.sh --hosted-zone-id $HOSTED_ZONE_ID --record-name $RECORD_NAME --use-accelerator"
log ""
log "# Or create DNS record with custom target"
log "./update-dns.sh --hosted-zone-id $HOSTED_ZONE_ID --record-name api.$RECORD_NAME --target-dns some-other-service.com"
log ""
log "# Clean up Global Accelerator"
log "./destroy-accelerator.sh --force"
log ""
log "# Clean up DNS records"
log "./update-dns.sh --hosted-zone-id $HOSTED_ZONE_ID --record-name $RECORD_NAME --delete"

log "=== Summary ==="
log "The modular architecture now supports:"
log "1. Separated Global Accelerator and DNS management"
log "2. Independent use of each component"
log "3. Custom workflows using module functions directly"
log "4. Main scripts with focused responsibilities"
log "5. Flexible resource management and cleanup"
log ""
log "Check the individual module files (dns-manager.sh, accelerator-manager.sh) for all available functions."
