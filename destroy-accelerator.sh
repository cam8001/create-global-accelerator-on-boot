#!/bin/bash

# Destroy Global Accelerator endpoint
# Focuses only on Global Accelerator cleanup, no DNS operations
set -e

# Source shared utilities and modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/accelerator-utils.sh"
source "$SCRIPT_DIR/accelerator-manager.sh"

RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-3}"

# Parse arguments for help
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Destroys the Global Accelerator created by create-accelerator.sh"
            echo ""
            echo "Options:"
            echo "  --help, -h                     Show this help message"
            echo "  --force                        Skip confirmation prompt"
            echo ""
            echo "This script will:"
            echo "1. Load the stored Global Accelerator ARN"
            echo "2. Disable and delete the Global Accelerator"
            echo "3. Clean up stored state files"
            exit 0
            ;;
        --force)
            FORCE_CLEANUP=true
            shift
            ;;
        *)
            log "ERROR: Unknown parameter $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Check for required dependencies
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not installed. Please install jq and try again." >&2
    exit 1
fi

log "Starting Global Accelerator cleanup..."

# Load stored accelerator ARN
if ! ga_load_accelerator_arn; then
    log "No accelerator ARN found in $SCRIPT_OUTPUT_DIR"
    log "Nothing to cleanup - no Global Accelerator resources found"
    exit 0
fi

log "Found stored accelerator: $STORED_ACCELERATOR_ARN"

# Get accelerator details for confirmation
ACCELERATOR_DNS=$(ga_get_dns_name "$STORED_ACCELERATOR_ARN" 2>/dev/null || echo "Unable to retrieve DNS name")

log "Accelerator details:"
log "  ARN: $STORED_ACCELERATOR_ARN"
log "  DNS Name: $ACCELERATOR_DNS"

# Confirmation prompt unless forced
if [[ "$FORCE_CLEANUP" != "true" ]]; then
    echo ""
    echo "WARNING: This will permanently delete the Global Accelerator and all its resources."
    echo "This action cannot be undone."
    echo ""
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Cleanup cancelled by user"
        exit 0
    fi
fi

# Delete the Global Accelerator
log "Disabling and deleting Global Accelerator: $STORED_ACCELERATOR_ARN"
log "This may take 2-3 minutes to complete..."

if ga_delete_accelerator "$STORED_ACCELERATOR_ARN"; then
    log "Global Accelerator cleanup completed successfully"
else
    log "ERROR: Failed to cleanup Global Accelerator"
    log "You may need to manually delete the accelerator using the AWS Console or CLI"
    log "ARN: $STORED_ACCELERATOR_ARN"
    exit 1
fi

# Clean up stored accelerator ARN
ga_cleanup_accelerator_arn

log "Global Accelerator cleanup completed successfully"
log "All resources have been removed and state files cleaned up"
