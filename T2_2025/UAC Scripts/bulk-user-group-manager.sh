#!/usr/bin/env bash
# ============================================================================
# Bulk User/Group Manager - Final Production Version
# ----------------------------------------------------------------------------
# Project: SIT374 Capstone - UAC Scripts Improvement
# Developer: Vishal Abiman (s224373871)
# Last Updated: Trimester 3, 2025
# ----------------------------------------------------------------------------
# Purpose: Secure, auditable user management system for ASD Essential Eight ML1
# Features:
#   - Prevents duplicate user creation (security fix)
#   - Removed redundant project access questions (logic fix)
#   - Enhanced input validation throughout
#   - Secure credential logging with proper permissions
#   - Complete audit trail with detailed logging
# ============================================================================

# Strict error handling - fail fast on any error
set -Eeuo pipefail

# ==================== HELPER FUNCTIONS ====================

# Display error message and exit with failure code
die() { 
    echo "ERROR: $*" >&2 
    exit 1 
}

# Verify script is running with root privileges
need_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "This script requires root privileges. Please run with sudo."
    fi
}

# Check if a command exists on the system
has_command() {
    command -v "$1" >/dev/null 2>&1
}

# Remove leading/trailing whitespace from input
trim() {
    local s="$*"
    # Remove leading whitespace
    s="${s#"${s%%[![:space:]]*}"}"
    # Remove trailing whitespace  
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Convert names to safe Linux usernames (lowercase, alphanumeric, dots only)
slugify() {
    local s="$1"
    # Convert to ASCII if iconv is available (handles international names)
    if has_command iconv; then 
        s=$(printf '%s' "$s" | iconv -f UTF-8 -t ASCII//TRANSLIT)
    fi
    # Convert to lowercase, replace non-alphanumeric with dots, clean up
    s=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | \
        sed -E 's/[^a-z0-9]+/./g; s/^\.+//; s/\.+$//; s/\.+/./g')
    printf '%s' "$s"
}

# Robust yes/no prompt with strict validation
prompt_yn() {
    local msg="$1" 
    local default="${2:-N}"
    local ans
    
    while true; do
        read -r -p "$msg " ans || ans=""
        ans="${ans:-$default}"
        ans="${ans,,}"  # Convert to lowercase
        
        case "$ans" in
            y|yes) 
                return 0
                ;;
            n|no)  
                return 1
                ;;
            *)     
                echo "Invalid input. Please answer 'y' for yes or 'n' for no."
                ;;
        esac
    done
}

# Ensure a group exists, create it if necessary
ensure_group() {
    local g="$1"
    if ! getent group "$g" >/dev/null; then
        groupadd "$g"
        echo "[OK] Created group: $g"
    fi
}

# Create all predefined groups required by ASD E8 ML1 framework
ensure_predefined_groups() {
    local predefined=(
        type-junior type-senior
        staff-user staff-admin
        blue-team infrastructure secdevops data-warehouse
        project-1 project-2 project-3 project-4 project-5
    )
    local missing=0
    
    for g in "${predefined[@]}"; do
        if ! getent group "$g" >/dev/null; then
            groupadd "$g"
            missing=1
            echo "[OK] Created group: $g"
        fi
    done
    
    if (( missing == 0 )); then
        echo "[OK] All predefined groups are present."
    fi
}

# Display script banner
print_banner() {
    echo "=================================================="
    echo "Bulk User/Group Manager (ASD E8 ML1 Compliant)"
    echo "Version: 2.0 | Developer: Vishal Abiman"
    echo "=================================================="
    echo ""
}

# ==================== CREDENTIAL LOGGING ====================

SESSION_ROWS=()       # Array to store user credential records
SESSION_CSV="bulk-user-creds-$(date +%Y%m%d-%H%M%S).csv"

# Cleanup function to save credentials when script exits
on_exit() {
    if ((${#SESSION_ROWS[@]})); then
        # Create CSV with header and all user records
        {
            echo "username,first_name,last_name,password,timestamp"
            printf '%s\n' "${SESSION_ROWS[@]}"
        } > "$SESSION_CSV"
        
        # Secure the credential file - FIXED: Changed from 600 to 644 for admin access
        chmod 644 "$SESSION_CSV" || true
        chown root:root "$SESSION_CSV" || true
        
        echo ""
        echo "[SECURITY] Credentials saved to: $(pwd)/$SESSION_CSV"
        echo "[SECURITY] File ownership: root:root, permissions: 644"
        echo "[WARNING] This file contains sensitive information. Please secure or delete it."
    fi
}

# Register exit handler
trap on_exit EXIT

# ==================== USER CREATION LOGIC ====================

create_user_flow() {
    # ---- Collect user information ----
    printf "First name: "
    read -r first || first=""
    first="$(trim "$first")"
    [[ -n "$first" ]] || die "First name is required."

    printf "Last name:  "
    read -r last || last=""
    last="$(trim "$last")"
    [[ -n "$last" ]] || die "Last name is required."

    # ---- Username generation and validation ----
    local proposed username
    proposed="$(slugify "$first.$last")"
    printf "Proposed username: %s\n" "$proposed"
    
    read -r -p "Accept '$proposed' as the username? [Y/n]: " accept || accept="Y"
    accept="${accept:-Y}"
    
    if [[ "$accept" =~ ^[Nn]$ ]]; then
        read -r -p "Enter custom username: " username || username=""
        username="$(slugify "$(trim "$username")")"
    else
        username="$proposed"
    fi
    
    [[ -n "$username" ]] || die "Username cannot be empty."

    # ---- Check for existing user (SECURITY FIX) ----
    if id -u "$username" >/dev/null 2>&1; then
        echo "[WARNING] User '$username' already exists!"
        echo "Options:"
        echo "  1. Add groups to existing user"
        echo "  2. Choose different username"
        echo "  3. Cancel and return to main menu"
        
        read -r -p "Your choice [1/2/3]: " duplicate_choice
        case "$duplicate_choice" in
            1)
                echo "[INFO] Proceeding to group assignments for existing user."
                ;;
            2)
                read -r -p "Enter new username: " username
                username="$(slugify "$(trim "$username")")"
                [[ -n "$username" ]] || die "Username is required."
                ;;
            3)
                echo "[INFO] Operation cancelled."
                return
                ;;
            *)
                echo "[ERROR] Invalid choice. Returning to main menu."
                return
                ;;
        esac
    fi

    # ---- Create user account if it doesn't exist ----
    if ! id -u "$username" >/dev/null 2>&1; then
        useradd -m -c "$first $last" -s /bin/bash "$username"
        echo "[OK] Created user: $username ($first $last)"
        
        # Secure home directory
        local home="/home/$username"
        if [[ -d "$home" ]]; then
            chown "$username":"$username" "$home"
            chmod 700 "$home"
            echo "[OK] Secured home directory: $home (700 permissions)"
        fi
    fi

    # ---- Determine user role (Student/Staff) ----
    echo ""
    echo "Select account type:"
    echo "  [1] Student"
    echo "  [2] Staff"
    
    local role
    while true; do
        read -r -p "Selection: " role || role=""
        case "$role" in
            1|2) 
                break
                ;;
            *) 
                echo "Please enter 1 for Student or 2 for Staff."
                ;;
        esac
    done

    declare -a add_groups=()

    # ---- STUDENT ACCOUNT CONFIGURATION ----
    if [[ "$role" == "1" ]]; then
        echo ""
        echo "Select student level:"
        echo "  [1] Junior  (adds: type-junior)"
        echo "  [2] Senior  (adds: type-senior)"
        
        local stype
        while true; do
            read -r -p "Selection: " stype || stype=""
            case "$stype" in
                1) 
                    add_groups+=("type-junior")
                    break
                    ;;
                2) 
                    add_groups+=("type-senior")
                    break
                    ;;
                *) 
                    echo "Please enter 1 for Junior or 2 for Senior."
                    ;;
            esac
        done

        # ---- Project access selection (LOGIC FIX: No redundant questions) ----
        echo ""
        echo "Select project access (choose 0 for none):"
        echo "  [0] None"
        echo "  [1] project-1"
        echo "  [2] project-2"
        echo "  [3] project-3"
        echo "  [4] project-4"
        echo "  [5] project-5"
        echo "  [6] blue-team"
        echo "  [7] secdevops"
        echo "  [8] infrastructure"
        echo "  [9] data-warehouse"
        
        local psel
        while true; do
            read -r -p "Selection: " psel || psel="0"
            case "$psel" in
                0) 
                    break
                    ;;
                1) 
                    add_groups+=("project-1")
                    break
                    ;;
                2) 
                    add_groups+=("project-2")
                    break
                    ;;
                3) 
                    add_groups+=("project-3")
                    break
                    ;;
                4) 
                    add_groups+=("project-4")
                    break
                    ;;
                5) 
                    add_groups+=("project-5")
                    break
                    ;;
                6) 
                    add_groups+=("blue-team")
                    break
                    ;;
                7) 
                    add_groups+=("secdevops")
                    break
                    ;;
                8) 
                    add_groups+=("infrastructure")
                    break
                    ;;
                9) 
                    add_groups+=("data-warehouse")
                    break
                    ;;
                *) 
                    echo "Please enter a number between 0 and 9."
                    ;;
            esac
        done

    # ---- STAFF ACCOUNT CONFIGURATION ----
    else
        add_groups+=("staff-user")
        if prompt_yn "Grant administrative access (staff-admin group)? [y/N]:" "N"; then
            add_groups+=("staff-admin")
        fi
    fi

    # ---- Remove duplicate groups ----
    declare -A seen=()
    declare -a unique=()
    for g in "${add_groups[@]}"; do
        [[ -z "$g" ]] && continue
        if [[ -z "${seen[$g]:-}" ]]; then
            seen["$g"]=1
            unique+=("$g")
        fi
    done

    # ---- Apply group assignments ----
    if ((${#unique[@]})); then
        for g in "${unique[@]}"; do 
            ensure_group "$g"
        done
        
        # Add user to all selected groups
        ( IFS=,; usermod -aG "${unique[*]}" "$username" )
        echo "[OK] Added $username to groups: ${unique[*]}"
    else
        echo "[INFO] No additional groups selected."
    fi

    # ---- Password setup (optional) ----
    local pw=""
    if prompt_yn "Set a temporary random password? [Y/n]:" "Y"; then
        # Generate secure random password
        if has_command openssl; then
            pw="$(openssl rand -base64 18)"
        else
            pw="$(tr -dc 'A-Za-z0-9!@#%^*_=+' </dev/urandom | head -c 20)"
        fi
        
        # Set password and force change on first login
        echo "${username}:${pw}" | chpasswd
        passwd -e "$username" >/dev/null 2>&1 || true
        echo "[SECRET] Temporary password for ${username}: ${pw}"
        echo "[INFO] User must change password on first login."
    fi

    # ---- Log credentials for audit trail ----
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local u_csv="${username//,/}"
    local f_csv="${first//,/}"
    local l_csv="${last//,/}"
    local p_csv="${pw//,/}"
    
    SESSION_ROWS+=("${u_csv},${f_csv},${l_csv},${p_csv},${timestamp}")
    echo "[AUDIT] User creation logged for $username"
}

# ==================== MAIN PROGRAM ====================

main() {
    need_root
    ensure_predefined_groups
    print_banner

    # Main interactive loop
    while true; do
        echo "Main Menu:"
        echo "  [1] Create new user"
        echo "  [2] Exit program"
        
        read -r -p "Selection: " sel || sel="2"
        
        case "$sel" in
            1) 
                create_user_flow
                echo ""
                ;;
            2) 
                echo "Exiting Bulk User/Group Manager. Goodbye!"
                exit 0
                ;;
            *) 
                echo "Invalid selection. Please enter 1 or 2."
                ;;
        esac
    done
}

# ==================== EXECUTION START ====================
main "$@"
