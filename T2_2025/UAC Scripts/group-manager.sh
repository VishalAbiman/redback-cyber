#!/usr/bin/env bash
# ============================================================================
# Group Manager - Final Production Version
# ----------------------------------------------------------------------------
# Project: SIT374 Capstone - UAC Scripts Improvement  
# Developer: Vishal Abiman (s224373871)
# Last Updated: Trimester 3, 2025
# ----------------------------------------------------------------------------
# Purpose: Manage Linux groups, shared directories, and sudo privileges
# Features:
#   - Enhanced input validation for all prompts
#   - Proper group and shared directory management
#   - Sudo privilege assignment with visudo validation
#   - Comprehensive error handling and logging
# ============================================================================

set -Eeuo pipefail

# ==================== CONFIGURATION ====================

# Base directory for group shared folders
BASE_DIR="/srv/groups"

# Default groups required by ASD E8 ML1 framework
DEFAULT_GROUPS=(
    staff-admin
    staff-user
    type-junior
    type-senior
    blue-team
    infrastructure
    secdevops
    data-warehouse
    project-1
    project-2
    project-3
    project-4
    project-5
)

# Common system commands for sudo privilege assignment
CANDIDATE_NAMES=(
    systemctl
    service
    journalctl
    tail
    less
    cat
    dmesg
    ip
    ss
    ufw
    docker
    podman
)

# Sudoers configuration
SUDOERS_DIR="/etc/sudoers.d"
SUDOERS_PREFIX="grp-"
REQUIRE_PASSWORD_DEFAULT=1  # 1=require password, 0=NOPASSWD

# ==================== UTILITY FUNCTIONS ====================

log()  { printf "%s\n" "$*"; }
ok()   { printf "[OK] %s\n" "$*"; }
warn() { printf "[WARN] %s\n" "$*"; }
err()  { printf "[ERROR] %s\n" "$*" 1>&2; }

# Verify root privileges
need_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        err "This script requires root privileges. Please run with sudo."
        exit 1
    fi
}

# Check for required system utilities
need_bins() {
    local missing=()
    local req=(getent groupadd gpasswd visudo install mkdir chmod chgrp)
    
    for b in "${req[@]}"; do
        command -v "$b" >/dev/null 2>&1 || missing+=("$b")
    done
    
    if ((${#missing[@]})); then
        err "Missing required system utilities: ${missing[*]}"
        exit 1
    fi
}

# Remove whitespace from string
trim() {
    local s="$*"
    s="${s##+([[:space:]])}"
    s="${s%%+([[:space:]])}"
    printf '%s' "$s"
}

# Wait for user to press Enter
press_enter() { 
    read -r -p $'Press Enter to continue… ' _ || true 
}

# Robust yes/no prompt with validation
prompt_yn_secure() {
    local msg="$1"
    local default="${2:-N}"
    local ans
    
    while true; do
        read -r -p "$msg " ans || ans=""
        ans="${ans:-$default}"
        ans="${ans,,}"
        
        case "$ans" in
            y|yes) 
                echo "y"
                return 0
                ;;
            n|no)  
                echo "n"
                return 1
                ;;
            *)     
                echo "Invalid input. Please answer y or n."
                ;;
        esac
    done
}

# ==================== GROUP MANAGEMENT ====================

# Create base directory if it doesn't exist
ensure_base_dir() {
    if [[ ! -d "$BASE_DIR" ]]; then
        mkdir -p "$BASE_DIR"
        chmod 0755 "$BASE_DIR"
        ok "Created base directory: $BASE_DIR"
    fi
}

# Validate group name format
valid_group_name() {
    # POSIX group naming rules: start with letter/underscore, then alnum/underscore/hyphen
    [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]]
}

# Create group if it doesn't exist
ensure_group() {
    local grp="$1"
    if getent group "$grp" >/dev/null; then
        ok "Group already exists: $grp"
    else
        groupadd "$grp"
        ok "Created new group: $grp"
    fi
}

# Create and secure shared directory for a group
ensure_shared_dir() {
    local grp="${1:-}"
    if [[ -z "$grp" ]]; then 
        err "Missing group name for shared directory"
        return 1
    fi
    
    local dir="$BASE_DIR/$grp"
    
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        ok "Created shared directory: $dir"
    fi
    
    # Set group ownership and permissions
    chgrp "$grp" "$dir"
    chmod 2770 "$dir"  # setgid + rwx for owner and group
    
    # Set ACLs if available
    if command -v setfacl >/dev/null 2>&1; then
        setfacl -d -m g:"$grp":rwx "$dir" || true
        setfacl -m g:"$grp":rwx "$dir" || true
    fi
    
    ok "Secured directory: $dir (root:$grp, 2770)"
}

# Find full path of a command
resolve_cmd() {
    local p
    p=$(command -v -- "$1" 2>/dev/null || true)
    [[ -n "$p" ]] && printf '%s' "$p"
}

# Build list of available commands from candidates
build_candidates() {
    CANDIDATE_CMDS=()
    local p
    
    for n in "${CANDIDATE_NAMES[@]}"; do
        p=$(resolve_cmd "$n" || true)
        if [[ -n "$p" ]]; then
            CANDIDATE_CMDS+=("$p")
        fi
    done
}

# ==================== SUDOERS MANAGEMENT ====================

# Generate summary of sudoers line for confirmation
summary_sudoers_line() {
    local grp="$1"
    shift
    local cmds=("$@")
    local npfx=""
    
    (( REQUIRE_PASSWORD_DEFAULT == 0 )) && npfx="NOPASSWD: "
    
    local line="%${grp} ALL=(root) ${npfx}"
    local first=1
    
    for c in "${cmds[@]}"; do
        if (( first )); then 
            line+="$c"
            first=0
        else 
            line+=", $c"
        fi
    done
    
    printf '%s\n' "$line"
}

# Create and install sudoers file with validation
install_sudoers_file() {
    local grp="$1"
    shift
    local cmds=("$@")
    local tmp
    tmp=$(mktemp)
    
    local npfx=""
    (( REQUIRE_PASSWORD_DEFAULT == 0 )) && npfx="NOPASSWD: "

    # Create sudoers snippet
    {
        printf '%s\n' "# Managed by E8 ML1 Group Manager"
        printf '%s\n' "# Grant limited commands to group: $grp"
        printf '%%%s ALL=(root) %s' "$grp" "$npfx"
        
        local first=1
        for c in "${cmds[@]}"; do
            if (( first )); then 
                printf '%s' "$c"
                first=0
            else 
                printf ', %s' "$c"
            fi
        done
        printf '\n'
    } >"$tmp"

    # Validate syntax with visudo
    local visout
    if ! visout=$(visudo -cf "$tmp" 2>&1); then
        err "Sudoers syntax validation failed:"
        printf '\n----- Validation Error -----\n%s\n' "$visout"
        printf '\n----- Proposed Snippet -----\n'
        nl -ba "$tmp" 1>&2 || true
        rm -f "$tmp"
        return 1
    fi

    # Backup existing file if present
    local dest="$SUDOERS_DIR/${SUDOERS_PREFIX}${grp}"
    local backup="${dest}.bak.$(date +%Y%m%d-%H%M%S)"
    
    if [[ -f "$dest" ]]; then
        cp -a "$dest" "$backup"
        ok "Backed up existing sudoers file to: $backup"
    fi

    # Install new sudoers file
    install -m 0440 "$tmp" "$dest"
    rm -f "$tmp"

    # Final validation of complete sudoers configuration
    if ! visudo -cf /etc/sudoers >/dev/null 2>&1; then
        err "Global sudoers validation failed after installation"
        # Rollback to backup
        [[ -f "$backup" ]] && install -m 0440 "$backup" "$dest" || rm -f "$dest"
        return 1
    fi

    ok "Sudoers updated successfully: $dest"
}

# Ensure staff-admin has full sudo privileges
ensure_staff_admin_full_sudo() {
    local grp="staff-admin"
    
    if ! getent group "$grp" >/dev/null; then
        warn "Staff-admin group doesn't exist. Creating it now."
        ensure_group "$grp"
    fi
    
    local dest="$SUDOERS_DIR/${SUDOERS_PREFIX}${grp}"
    
    # Check if full privileges already exist
    if [[ -f "$dest" ]] && grep -qE '^%staff-admin\s+ALL=\(ALL(:ALL)?\)\s+ALL\s*$' "$dest"; then
        ok "Staff-admin already has full administrative privileges"
        return 0
    fi
    
    # Create full sudo privileges snippet
    local tmp
    tmp=$(mktemp)
    {
        echo "# Managed by E8 ML1 Group Manager"
        echo "# Full administrative privileges for staff-admin"
        echo "%staff-admin ALL=(ALL:ALL) ALL"
    } >"$tmp"
    
    # Validate before installation
    if ! visudo -cf "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        err "Failed to validate staff-admin sudoers snippet"
        return 1
    fi
    
    # Install the snippet
    install -m 0440 "$tmp" "$dest"
    rm -f "$tmp"
    
    if visudo -cf /etc/sudoers >/dev/null 2>&1; then
        ok "Granted full administrative privileges to staff-admin group"
    else
        err "Global validation failed after staff-admin update"
        return 1
    fi
}

# ==================== WORKFLOW FUNCTIONS ====================

# Check and create default groups and directories
check_defaults_flow() {
    ensure_base_dir

    local missing=()
    local g
    
    # Check for missing default groups
    for g in "${DEFAULT_GROUPS[@]}"; do
        if getent group "$g" >/dev/null 2>&1; then
            ok "Group present: $g"
        else
            warn "Missing default group: $g"
            missing+=("$g")
        fi
    done

    # Offer to create missing groups
    if ((${#missing[@]})); then
        log "\nMissing default groups detected:"
        printf '  - %s\n' "${missing[@]}"
        
        if prompt_yn_secure "Create missing groups now? [Y/n]:" "Y"; then
            for g in "${missing[@]}"; do
                ensure_group "$g"
            done
        else
            warn "Skipped creation of missing groups"
        fi
    fi

    # Create shared directories for all default groups
    for g in "${DEFAULT_GROUPS[@]}"; do
        if getent group "$g" >/dev/null 2>&1; then
            ensure_shared_dir "$g"
        fi
    done

    # Ensure staff-admin has full sudo
    ensure_staff_admin_full_sudo

    # Audit existing sudoers files
    shopt -s nullglob
    local f base grp
    local others=()
    
    for f in "$SUDOERS_DIR"/"${SUDOERS_PREFIX}"*; do
        base=$(basename -- "$f")
        grp="${base#${SUDOERS_PREFIX}}"
        if [[ -n "$grp" && "$grp" != "staff-admin" ]]; then
            others+=("$grp ($f)")
        fi
    done
    shopt -u nullglob

    if ((${#others[@]})); then
        warn "Found sudoers files for non-staff-admin groups:"
        printf '  - %s\n' "${others[@]}"
    fi
}

# Create a new custom group
create_new_group_flow() {
    read -r -p "Enter new group name: " grp
    grp=$(trim "$grp")
    
    if [[ -z "$grp" ]]; then 
        err "No group name provided"
        return 1
    fi
    
    if ! valid_group_name "$grp"; then 
        err "Invalid group name: $grp (must start with letter/underscore, contain only a-z, 0-9, _, -)"
        return 1
    fi
    
    ensure_group "$grp"
    ensure_shared_dir "$grp"
}

# Modify sudo privileges for a group
modify_privs_flow() {
    read -r -p "Enter group to modify: " grp
    grp=$(trim "$grp")
    
    if [[ -z "$grp" ]]; then 
        err "No group specified"
        return 1
    fi
    
    if ! getent group "$grp" >/dev/null; then 
        err "Group does not exist: $grp"
        return 1
    fi

    # Select input method
    log "\nChoose command selection method:"
    log "  [1] Enter commands manually (comma-separated)"
    log "  [2] Select from predefined command list"
    
    read -r -p "Selection [1/2]: " mode
    mode=${mode:-1}

    local selected=()
    
    if [[ "$mode" == "1" ]]; then
        cat <<'TIP'
Enter absolute command paths, comma-separated.
Examples: /bin/systemctl, /usr/bin/journalctl
If you enter command names, the script will attempt to resolve full paths.
TIP
        
        read -r -p "Commands: " line
        IFS=',' read -r -a raw <<<"$line"
        
        for item in "${raw[@]}"; do
            local t
            t=$(trim "$item")
            [[ -z "$t" ]] && continue
            
            # Resolve command name to full path if needed
            if [[ "$t" != /* ]]; then
                local r
                r=$(resolve_cmd "$t" || true)
                if [[ -n "$r" ]]; then 
                    t="$r"
                else 
                    warn "Could not resolve command: '$t' - skipping"
                    continue
                fi
            fi
            selected+=("$t")
        done
        
    else
        # Use predefined command list
        build_candidates
        
        if ((${#CANDIDATE_CMDS[@]} == 0)); then
            err "No predefined commands found on this system"
            return 1
        fi
        
        log "\nAvailable system commands:"
        local i=1
        for c in "${CANDIDATE_CMDS[@]}"; do 
            printf "  %2d) %s\n" "$i" "$c"
            ((i++))
        done
        
        read -r -p $'Enter command numbers (comma-separated): ' picks
        IFS=',' read -r -a nums <<<"$picks"
        
        for n in "${nums[@]}"; do
            n=$(trim "$n")
            [[ -z "$n" ]] && continue
            
            if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#CANDIDATE_CMDS[@]} )); then
                selected+=("${CANDIDATE_CMDS[$((n-1))]}")
            else
                warn "Skipping invalid selection: $n"
            fi
        done
    fi

    if ((${#selected[@]} == 0)); then 
        err "No valid commands selected"
        return 1
    fi

    # Password requirement setting
    if prompt_yn_secure "Require password when using sudo? [Y/n]:" "Y"; then
        REQUIRE_PASSWORD_DEFAULT=1
    else
        REQUIRE_PASSWORD_DEFAULT=0
    fi

    # Show summary and confirm
    log "\nReady to grant the following sudo privileges:"
    summary_sudoers_line "$grp" "${selected[@]}"
    
    if prompt_yn_secure "Proceed with these changes? [y/N]:" "N"; then
        install_sudoers_file "$grp" "${selected[@]}"
    else
        warn "Operation cancelled by user"
        return 1
    fi
}

# ==================== MAIN MENU ====================

menu() {
    while true; do
        cat <<MENU

==========================================
        E8 ML1 Group Manager
        Version 2.0
==========================================
Main Menu:
  [1] Check & configure defaults (groups, directories, sudo)
  [2] Create new custom group
  [3] Modify group sudo privileges
  [4] Exit program

==========================================
MENU
        
        read -r -p "Enter selection: " sel
        
        case "${sel:-1}" in
            1) 
                if ! check_defaults_flow; then 
                    warn "Defaults check encountered issues"
                fi
                press_enter
                ;;
            2) 
                if ! create_new_group_flow; then 
                    warn "Group creation failed"
                fi
                press_enter
                ;;
            3) 
                if ! modify_privs_flow; then 
                    warn "Privilege modification failed"
                fi
                press_enter
                ;;
            4) 
                echo "Exiting Group Manager. Goodbye!"
                exit 0
                ;;
            *) 
                warn "Invalid selection. Please enter 1-4."
                ;;
        esac
    done
}

# ==================== MAIN EXECUTION ====================

main() {
    need_root
    need_bins
    
    echo ""
    echo "=========================================="
    echo "    E8 ML1 Group Manager - Initializing"
    echo "=========================================="
    echo ""
    
    menu
}

main "$@"
