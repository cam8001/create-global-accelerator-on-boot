#!/bin/bash

# update-dns.sh - Standalone DNS management script
# Part of Global Accelerator Automation project
# 
# This script provides CLI access to DNS management functions using the modular
# dns-manager.sh component. It can create, update, or delete CNAME records in Route 53.

set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source required modules
source "${SCRIPT_DIR}/accelerator-utils.sh"
source "${SCRIPT_DIR}/dns-manager.sh"

# Script configuration
SCRIPT_NAME="update-dns"
VERSION="1.0.0"

# Default values
DEFAULT_TTL=300
ACTION=""
HOSTED_ZONE_ID=""
RECORD_NAME=""
TARGET_DNS=""
TTL=""

# Function to display usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS] ACTION

DNS Management Script for Route 53 CNAME Records

ACTIONS:
    create      Create or update a CNAME record
    delete      Delete a CNAME record
    validate    Validate DNS parameters without making changes

OPTIONS:
    -z, --hosted-zone-id ID     Route 53 hosted zone ID (required)
    -r, --record-name NAME      DNS record name/subdomain (required for create/delete)
    -t, --target-dns DNS        Target DNS name for CNAME (required for create)
    -l, --ttl SECONDS          TTL for DNS record (default: $DEFAULT_TTL)
    -h, --help                 Show this help message
    -v, --version              Show version information

ENVIRONMENT VARIABLES:
    HOSTED_ZONE_ID             Route 53 hosted zone ID
    RECORD_NAME                DNS record name
    TARGET_DNS                 Target DNS name for CNAME
    DNS_RECORD_TTL             TTL for DNS records

EXAMPLES:
    # Create a CNAME record
    $0 create --hosted-zone-id Z1234567890ABC --record-name app.example.com --target-dns my-accelerator-123.awsglobalaccelerator.com

    # Create with custom TTL
    $0 create -z Z1234567890ABC -r app.example.com -t my-service.amazonaws.com -l 600

    # Delete a CNAME record
    $0 delete --hosted-zone-id Z1234567890ABC --record-name app.example.com

    # Validate parameters
    $0 validate --hosted-zone-id Z1234567890ABC --record-name app.example.com

    # Using environment variables
    export HOSTED_ZONE_ID="Z1234567890ABC"
    export RECORD_NAME="app.example.com"
    export TARGET_DNS="my-accelerator-123.awsglobalaccelerator.com"
    $0 create

EXIT CODES:
    0    Success
    1    General error
    2    Invalid arguments
    3    DNS operation failed
    4    Validation failed

EOF
}

# Function to display version information
version() {
    echo "$SCRIPT_NAME version $VERSION"
    echo "Part of Global Accelerator Automation project"
}

# Function to parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -z|--hosted-zone-id)
                HOSTED_ZONE_ID="$2"
                shift 2
                ;;
            -r|--record-name)
                RECORD_NAME="$2"
                shift 2
                ;;
            -t|--target-dns)
                TARGET_DNS="$2"
                shift 2
                ;;
            -l|--ttl)
                TTL="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -v|--version)
                version
                exit 0
                ;;
            create|delete|validate)
                if [[ -n "$ACTION" ]]; then
                    log_error "Multiple actions specified. Only one action is allowed."
                    exit 2
                fi
                ACTION="$1"
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 2
                ;;
        esac
    done
}

# Function to load environment variables
load_environment() {
    # Load from environment if not set via command line
    [[ -z "$HOSTED_ZONE_ID" ]] && HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-}"
    [[ -z "$RECORD_NAME" ]] && RECORD_NAME="${RECORD_NAME:-}"
    [[ -z "$TARGET_DNS" ]] && TARGET_DNS="${TARGET_DNS:-}"
    [[ -z "$TTL" ]] && TTL="${DNS_RECORD_TTL:-$DEFAULT_TTL}"
}

# Function to validate required parameters
validate_parameters() {
    local errors=0

    if [[ -z "$ACTION" ]]; then
        log_error "No action specified. Use 'create', 'delete', or 'validate'."
        errors=1
    fi

    if [[ -z "$HOSTED_ZONE_ID" ]]; then
        log_error "Hosted zone ID is required. Use --hosted-zone-id or set HOSTED_ZONE_ID environment variable."
        errors=1
    fi

    case "$ACTION" in
        create)
            if [[ -z "$RECORD_NAME" ]]; then
                log_error "Record name is required for create action. Use --record-name or set RECORD_NAME environment variable."
                errors=1
            fi
            if [[ -z "$TARGET_DNS" ]]; then
                log_error "Target DNS is required for create action. Use --target-dns or set TARGET_DNS environment variable."
                errors=1
            fi
            if ! [[ "$TTL" =~ ^[0-9]+$ ]] || [[ "$TTL" -lt 60 ]] || [[ "$TTL" -gt 86400 ]]; then
                log_error "TTL must be a number between 60 and 86400 seconds."
                errors=1
            fi
            ;;
        delete)
            if [[ -z "$RECORD_NAME" ]]; then
                log_error "Record name is required for delete action. Use --record-name or set RECORD_NAME environment variable."
                errors=1
            fi
            ;;
        validate)
            # For validate, we only need hosted zone ID and record name
            if [[ -z "$RECORD_NAME" ]]; then
                log_error "Record name is required for validate action. Use --record-name or set RECORD_NAME environment variable."
                errors=1
            fi
            ;;
    esac

    if [[ $errors -gt 0 ]]; then
        echo
        usage
        exit 2
    fi
}

# Function to perform DNS create operation
perform_create() {
    log_info "Creating CNAME record: $RECORD_NAME -> $TARGET_DNS (TTL: $TTL)"
    
    if dns_create_cname_record "$HOSTED_ZONE_ID" "$RECORD_NAME" "$TARGET_DNS" "$TTL"; then
        log_info "Successfully created/updated CNAME record"
        
        # Store record information for future cleanup
        if dns_store_record_info "$HOSTED_ZONE_ID" "$RECORD_NAME"; then
            log_info "DNS record information stored for future cleanup"
        else
            log_warning "Failed to store DNS record information - manual cleanup may be required"
        fi
        
        return 0
    else
        log_error "Failed to create CNAME record"
        return 3
    fi
}

# Function to perform DNS delete operation
perform_delete() {
    log_info "Deleting CNAME record: $RECORD_NAME"
    
    if dns_delete_cname_record "$HOSTED_ZONE_ID" "$RECORD_NAME"; then
        log_info "Successfully deleted CNAME record"
        
        # Clean up stored record information
        if dns_cleanup_record_info; then
            log_info "Cleaned up stored DNS record information"
        else
            log_warning "Failed to clean up stored DNS record information"
        fi
        
        return 0
    else
        log_error "Failed to delete CNAME record"
        return 3
    fi
}

# Function to perform DNS validation
perform_validate() {
    log_info "Validating DNS parameters"
    log_info "Hosted Zone ID: $HOSTED_ZONE_ID"
    log_info "Record Name: $RECORD_NAME"
    
    if dns_validate_parameters "$HOSTED_ZONE_ID" "$RECORD_NAME"; then
        log_info "DNS parameters are valid"
        return 0
    else
        log_error "DNS parameter validation failed"
        return 4
    fi
}

# Function to display operation summary
display_summary() {
    log_info "=== DNS Operation Summary ==="
    log_info "Action: $ACTION"
    log_info "Hosted Zone ID: $HOSTED_ZONE_ID"
    log_info "Record Name: $RECORD_NAME"
    
    case "$ACTION" in
        create)
            log_info "Target DNS: $TARGET_DNS"
            log_info "TTL: $TTL seconds"
            ;;
        delete)
            log_info "Operation: Delete CNAME record"
            ;;
        validate)
            log_info "Operation: Validate parameters only"
            ;;
    esac
    log_info "=========================="
}

# Main execution function
main() {
    log_info "Starting DNS management script (version $VERSION)"
    
    # Parse command line arguments
    parse_arguments "$@"
    
    # Load environment variables
    load_environment
    
    # Validate parameters
    validate_parameters
    
    # Display operation summary
    display_summary
    
    # Perform the requested action
    case "$ACTION" in
        create)
            perform_create
            ;;
        delete)
            perform_delete
            ;;
        validate)
            perform_validate
            ;;
        *)
            log_error "Invalid action: $ACTION"
            exit 2
            ;;
    esac
    
    log_info "DNS operation completed successfully"
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
