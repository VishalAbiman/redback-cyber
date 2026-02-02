#!/usr/bin/env bash
# ============================================================================
# Start of Trimester Cleanup - Final Production Version  
# ----------------------------------------------------------------------------
# Project: SIT374 Capstone - UAC Scripts Improvement
# Developer: Vishal Abiman (s224373871)
# Last Updated: Trimester 2, 2025
# ----------------------------------------------------------------------------
# Purpose: Automated user account cleanup for academic environments
# Features:
#   - FIXED: Critical syntax error in array_minus function
#   - Enhanced error handling and validation
#   - Comprehensive logging for audit trails
#   - Safe dry-run mode by default
#   - Interactive user confirmation steps
# ============================================================================

set -Euo pipefail

readonly SCRIPT_VERSION="2.0"

# ==================== CONFIGURATION ====================

# User group definitions
JUNIOR_GROUP=${JUNIOR_GROUP:-"type-junior"}
SENIOR_GROUP=${SENIOR_GROUP:-"type-senior"}
STAFF_USER_GROUP=${STAFF_USER_GROUP:-"staff-user"}
STAFF_ADMIN_GROUP=${STAFF_ADMIN_GROUP:-"staff-admin"}

# System users to ignore (comma-separated)
IGNORE_USERS=${IGNORE_USERS:-"root,ubuntu"}

# Logging configuration
LOG_DIR=${LOG_DIR:-"/var/log/e8ml1"}
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/start_of_tri_cleanup_$(date +%Y%m%d_%H%M%S).log"

# ==================== RUNTIME FLAGS ====================

APPLY=0           # 0=dry-run, 1=apply changes
ASSUME_YES=0      # 0=ask for confirmation, 1=auto-confirm
DEBUG=0           # 0=normal, 1=debug mode

# Terminal IO configuration (safe for sudo)
TTY_IN="/dev/tty"
TTY_OUT="/dev/tty"
[[ -r "$TTY_IN" ]] || TTY_IN="/proc/self/fd/0"
[[ -w "$TTY_OUT" ]] || TTY_OUT="/proc/self/fd/1"

# ==================== UTILITY FUNCTIONS ====================

# Log message to both console and log file
log() { 
    echo "$(date +%F' '%T) | $*" | tee -a "$LOG_FILE" 
}

# Error message with logging
err() { 
    echo "ERROR: $*" >&2 
    log "ERROR: $*" 
}

# Require root privileges
require_root() { 
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then 
        err "This script requires root privileges. Please run with sudo."
        exit 
