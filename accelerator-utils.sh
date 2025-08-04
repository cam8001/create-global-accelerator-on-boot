#!/bin/bash

# Shared utility functions for Global Accelerator scripts

# Use appropriate directories based on user privileges
if [[ $EUID -eq 0 ]]; then
    SCRIPT_OUTPUT_DIR="/var/lib/aws-global-accelerator-script"
else
    SCRIPT_OUTPUT_DIR="$HOME/.aws-global-accelerator-script"
fi

LOG_FILE="$SCRIPT_OUTPUT_DIR/accelerator.log"

# Logging function
log() {
    mkdir -p "$SCRIPT_OUTPUT_DIR"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >&2
}

# Retry function with exponential backoff
retry_aws() {
    local cmd="$1"
    # Use parameter 2, fallback to RETRY_ATTEMPTS env var, or default to 3
    local max_attempts="${2:-${RETRY_ATTEMPTS:-3}}"
    # Use parameter 3 or default to 2 seconds for initial delay
    local initial_delay="${3:-2}"
    # Use parameter 4 or default error message
    local error_msg="${4:-Command failed}"
    # Track current attempt number starting from 1
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if eval "$cmd"; then
            return 0
        fi
        
        if [[ $attempt -eq $max_attempts ]]; then
            log "ERROR: $error_msg after $max_attempts attempts: $cmd"
            return 1
        fi
        
        local delay=$((initial_delay * (2 ** (attempt - 1))))
        log "Attempt $attempt failed, retrying in ${delay}s..."
        sleep $delay
        ((attempt++))
    done
}

# Retry function specifically for describe-accelerator with longer timeouts
retry_describe_accelerator() {
    local cmd="$1"
    retry_aws "$cmd" 5 30 "Accelerator deployment check failed"
}