#!/bin/bash
# SSH Quota Manager – Colorful version with auto-display on login

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color
BOLD='\033[1m'
DIM='\033[2m'

CONFIG_DIR="/etc/ssh-quotas"
PIDFILE="/var/run/ssh-quota-monitor.pid"
CHAIN_IN="QUOTA_INPUT"
CHAIN_OUT="QUOTA_OUTPUT"
LOGFILE="/var/log/ssh-quota-monitor.log"

# Function to print colored output
print_color() {
    echo -e "${2}${1}${NC}"
}

# Function to print banners
print_banner() {
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${WHITE}               SSH QUOTA MANAGER - SlowDNS                ${CYAN}║${NC}"
    echo -e "${CYAN}║${DIM}         Bandwidth Monitoring & Auto-Deletion System       ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Function to print progress bar
print_progress() {
    local used=$1
    local quota=$2
    local width=30
    local percent=$((used * 100 / quota))
    local filled=$((percent * width / 100))
    local empty=$((width - filled))
    
    printf "${WHITE}[${NC}"
    if [ "$percent" -ge 90 ]; then
        printf "${RED}"
    elif [ "$percent" -ge 60 ]; then
        printf "${YELLOW}"
    else
        printf "${GREEN}"
    fi
    printf "%0.s#" $(seq 1 $filled)
    printf "${DIM}%0.s-" $(seq 1 $empty)
    printf "${WHITE}] ${NC}%3d%%" $percent
}

# Ensure we are root
if [ "$EUID" -ne 0 ]; then
    print_color "❌ Please run as root" "$RED"
    exit 1
fi

# Create config directory
mkdir -p "$CONFIG_DIR"

# ----------------------------------------------------------------------
# iptables setup – create chains and insert jumps
setup_iptables() {
    # Create custom chains (ignore error if they already exist)
    iptables -N "$CHAIN_IN" 2>/dev/null
    iptables -N "$CHAIN_OUT" 2>/dev/null

    # Insert jumps at the top of INPUT/OUTPUT if not present
    if ! iptables -C INPUT -j "$CHAIN_IN" 2>/dev/null; then
        iptables -I INPUT 1 -j "$CHAIN_IN"
        print_color "✓ Added INPUT chain jump" "$GREEN" >> "$LOGFILE"
    fi
    if ! iptables -C OUTPUT -j "$CHAIN_OUT" 2>/dev/null; then
        iptables -I OUTPUT 1 -j "$CHAIN_OUT"
        print_color "✓ Added OUTPUT chain jump" "$GREEN" >> "$LOGFILE"
    fi
}

# ----------------------------------------------------------------------
# Convert human readable size to bytes (e.g., 1G, 500M, 200K)
human_to_bytes() {
    local val="$1"
    local unit="${val: -1}"
    local num="${val%?}"
    case $unit in
        G|g) echo $((num * 1024 * 1024 * 1024)) ;;
        M|m) echo $((num * 1024 * 1024)) ;;
        K|k) echo $((num * 1024)) ;;
        *)   echo "$val" ;;
    esac
}

# Convert bytes to human readable
bytes_to_human() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ]; then
        echo "$((bytes / 1073741824))G"
    elif [ "$bytes" -ge 1048576 ]; then
        echo "$((bytes / 1048576))M"
    elif [ "$bytes" -ge 1024 ]; then
        echo "$((bytes / 1024))K"
    else
        echo "${bytes}B"
    fi
}

# ----------------------------------------------------------------------
# Check monitor status
check_monitor_status() {
    if [ -f "$PIDFILE" ]; then
        pid=$(cat "$PIDFILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "${GREEN}● Running${NC} (PID: $pid)"
            return 0
        else
            rm -f "$PIDFILE"
            echo -e "${RED}● Stopped${NC} (stale PID file)"
            return 1
        fi
    else
        echo -e "${RED}● Stopped${NC}"
        return 1
    fi
}

# ----------------------------------------------------------------------
# Add a new user with quota
add_user() {
    print_color "\n➤ ADD NEW USER" "$BOLD$BLUE"
    echo -e "${DIM}──────────────────────────────${NC}"
    
    read -p "$(echo -e ${CYAN}Enter username: ${NC})" username
    if id "$username" &>/dev/null; then
        print_color "❌ User '$username' already exists." "$RED"
        return
    fi

    read -p "$(echo -e ${CYAN}Enter quota (e.g., 1G, 500M): ${NC})" quota_str
    quota_bytes=$(human_to_bytes "$quota_str")
    if [ -z "$quota_bytes" ] || [ "$quota_bytes" -eq 0 ]; then
        print_color "❌ Invalid quota." "$RED"
        return
    fi

    # Create system user
    useradd -m -s /bin/bash "$username"
    print_color "✓ User created" "$GREEN"
    
    passwd "$username"
    uid=$(id -u "$username")

    # Add iptables counting rules
    iptables -A "$CHAIN_IN" -m owner --uid-owner "$uid" -j RETURN
    iptables -A "$CHAIN_OUT" -m owner --uid-owner "$uid" -j RETURN

    # Store quota and initial counters
    cat > "$CONFIG_DIR/$username" <<EOF
quota=$quota_bytes
used=0
last_in=0
last_out=0
EOF

    print_color "✓ User $username added with quota $(bytes_to_human "$quota_bytes")" "$GREEN"
}

# ----------------------------------------------------------------------
# Delete a user (interactive)
delete_user() {
    print_color "\n➤ DELETE USER" "$BOLD$RED"
    echo -e "${DIM}──────────────────────────────${NC}"
    
    # Show list of users
    list_users_simple
    
    read -p "$(echo -e ${CYAN}Enter username to delete: ${NC})" username
    if ! id "$username" &>/dev/null; then
        print_color "❌ User does not exist." "$RED"
        return
    fi

    read -p "$(echo -e ${RED}Are you sure? (y/N): ${NC})" confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        delete_user_force "$username"
        print_color "✓ User $username deleted." "$GREEN"
    else
        print_color "✗ Deletion cancelled." "$YELLOW"
    fi
}

# Force delete a user (no prompts)
delete_user_force() {
    local username="$1"
    local uid
    uid=$(id -u "$username" 2>/dev/null)
    if [ -n "$uid" ]; then
        # Remove iptables rules
        iptables -D "$CHAIN_IN" -m owner --uid-owner "$uid" -j RETURN 2>/dev/null
        iptables -D "$CHAIN_OUT" -m owner --uid-owner "$uid" -j RETURN 2>/dev/null
        # Delete user and home
        userdel -r "$username" 2>/dev/null
        print_color "  ↳ Removed iptables rules" "$DIM" >> "$LOGFILE"
    fi
    # Remove quota file
    rm -f "$CONFIG_DIR/$username"
    echo "$(date): User $username deleted (quota exceeded or manual)" >> "$LOGFILE"
}

# ----------------------------------------------------------------------
# Simple user list for delete prompt
list_users_simple() {
    echo -e "\n${CYAN}Current users:${NC}"
    for file in "$CONFIG_DIR"/*; do
        [ -f "$file" ] || continue
        username=$(basename "$file")
        if id "$username" &>/dev/null; then
            echo -e "  ${WHITE}•${NC} ${YELLOW}$username${NC}"
        fi
    done
    echo ""
}

# ----------------------------------------------------------------------
# List all users with quota and usage (detailed)
list_users() {
    print_color "\n➤ USER USAGE REPORT" "$BOLD$PURPLE"
    echo -e "${DIM}──────────────────────────────${NC}"
    
    # Table header
    printf "${WHITE}%-15s %-10s %-10s %-35s${NC}\n" "Username" "Quota" "Used" "Usage"
    echo -e "${DIM}────────────────────────────────────────────────────────────────${NC}"
    
    total_users=0
    total_quota=0
    total_used=0
    
    for file in "$CONFIG_DIR"/*; do
        [ -f "$file" ] || continue
        username=$(basename "$file")
        
        if ! id "$username" &>/dev/null; then
            rm -f "$file"
            continue
        fi
        
        # shellcheck source=/dev/null
        source "$file"
        
        quota_hr=$(bytes_to_human "$quota")
        used_hr=$(bytes_to_human "$used")
        
        if [ "$quota" -gt 0 ]; then
            percent=$((used * 100 / quota))
        else
            percent=0
        fi
        
        # Choose color based on usage percentage
        if [ "$percent" -ge 90 ]; then
            color="$RED"
        elif [ "$percent" -ge 60 ]; then
            color="$YELLOW"
        else
            color="$GREEN"
        fi
        
        printf "${WHITE}%-15s${NC} ${color}%-10s${NC} ${color}%-10s${NC} " "$username" "$quota_hr" "$used_hr"
        print_progress "$used" "$quota"
        echo ""
        
        total_users=$((total_users + 1))
        total_quota=$((total_quota + quota))
        total_used=$((total_used + used))
    done
    
    echo -e "${DIM}────────────────────────────────────────────────────────────────${NC}"
    
    # Summary
    if [ "$total_users" -gt 0 ]; then
        total_percent=$((total_used * 100 / total_quota))
        printf "${WHITE}%-15s %-10s %-10s${NC} " "TOTAL" "$(bytes_to_human $total_quota)" "$(bytes_to_human $total_used)"
        print_progress "$total_used" "$total_quota"
        echo -e "\n"
    else
        print_color "No users found." "$YELLOW"
    fi
    
    # Monitor status
    echo -ne "${CYAN}Monitor:${NC} "
    check_monitor_status
    echo ""
}

# ----------------------------------------------------------------------
# Monitor loop
monitor_loop() {
    print_color "Monitor started (PID $$)" "$GREEN" >> "$LOGFILE"
    print_color "Logging to $LOGFILE" "$DIM" >> "$LOGFILE"
    
    while true; do
        for file in "$CONFIG_DIR"/*; do
            [ -f "$file" ] || continue
            username=$(basename "$file")
            
            if ! id "$username" &>/dev/null; then
                rm -f "$file"
                continue
            fi

            # shellcheck source=/dev/null
            source "$file"
            uid=$(id -u "$username")

            # Get current byte counts from iptables
            current_in=$(iptables -L "$CHAIN_IN" -v -n -x | grep "owner UID match $uid" | awk '{print $2}')
            current_out=$(iptables -L "$CHAIN_OUT" -v -n -x | grep "owner UID match $uid" | awk '{print $2}')
            current_in=${current_in:-0}
            current_out=${current_out:-0}

            # Calculate delta
            delta_in=$((current_in - last_in))
            delta_out=$((current_out - last_out))
            [ "$delta_in" -lt 0 ] && delta_in=0
            [ "$delta_out" -lt 0 ] && delta_out=0

            used=$((used + delta_in + delta_out))
            last_in=$current_in
            last_out=$current_out

            # Save updated counters
            cat > "$file" <<EOF
quota=$quota
used=$used
last_in=$last_in
last_out=$last_out
EOF

            # Enforce quota
            if [ "$used" -ge "$quota" ]; then
                print_color "$(date): ⚠ User $username exceeded quota ($(bytes_to_human $used) >= $(bytes_to_human $quota)). Deleting." "$RED" >> "$LOGFILE"
                delete_user_force "$username"
            fi
        done
        sleep 3
    done
}

# ----------------------------------------------------------------------
# Start monitor daemon
start_monitor() {
    print_color "\n➤ STARTING MONITOR" "$BOLD$GREEN"
    echo -e "${DIM}──────────────────────────────${NC}"
    
    if [ -f "$PIDFILE" ]; then
        pid=$(cat "$PIDFILE")
        if kill -0 "$pid" 2>/dev/null; then
            print_color "✓ Monitor already running (PID $pid)" "$GREEN"
            return
        else
            rm -f "$PIDFILE"
        fi
    fi

    # Launch monitor in background
    nohup "$0" monitor >> "$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    print_color "✓ Monitor started with PID $!" "$GREEN"
    print_color "  Log: $LOGFILE" "$DIM"
}

# ----------------------------------------------------------------------
# Stop monitor daemon
stop_monitor() {
    print_color "\n➤ STOPPING MONITOR" "$BOLD$YELLOW"
    echo -e "${DIM}──────────────────────────────${NC}"
    
    if [ -f "$PIDFILE" ]; then
        pid=$(cat "$PIDFILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            rm -f "$PIDFILE"
            print_color "✓ Monitor stopped." "$GREEN"
        else
            print_color "✗ Monitor not running." "$YELLOW"
            rm -f "$PIDFILE"
        fi
    else
        print_color "✗ No PID file found." "$YELLOW"
    fi
}

# ----------------------------------------------------------------------
# Show quick stats (for login banner)
show_quick_stats() {
    local user_count=0
    local active_monitor="No"
    
    for file in "$CONFIG_DIR"/*; do
        [ -f "$file" ] && user_count=$((user_count + 1))
    done
    
    if [ -f "$PIDFILE" ]; then
        pid=$(cat "$PIDFILE")
        kill -0 "$pid" 2>/dev/null && active_monitor="Yes"
    fi
    
    echo -e "${CYAN}📊 Quick Stats${NC}"
    echo -e "  ${WHITE}•${NC} Users: ${GREEN}$user_count${NC}"
    echo -e "  ${WHITE}•${NC} Monitor: $(if [ "$active_monitor" = "Yes" ]; then echo -e "${GREEN}● Active${NC}"; else echo -e "${RED}○ Inactive${NC}"; fi)"
    echo -e "  ${WHITE}•${NC} Log: ${DIM}$LOGFILE${NC}"
    echo -e "  ${WHITE}•${NC} Type ${BOLD}${CYAN}menu${NC} to open manager"
}

# ----------------------------------------------------------------------
# Interactive menu
show_menu() {
    clear
    print_banner
    
    # Monitor status
    echo -ne "${CYAN}Monitor Status:${NC} "
    check_monitor_status
    echo ""
    
    # Menu options with colors
    echo -e "${WHITE}╔════════════════════════════════════════╗${NC}"
    echo -e "${WHITE}║           ${BOLD}MAIN MENU${NC}${WHITE}                ║${NC}"
    echo -e "${WHITE}╠════════════════════════════════════════╣${NC}"
    echo -e "${WHITE}║${NC}  ${GREEN}1)${NC} ➕ Add user                     ${WHITE}║${NC}"
    echo -e "${WHITE}║${NC}  ${RED}2)${NC} 🗑️  Delete user                  ${WHITE}║${NC}"
    echo -e "${WHITE}║${NC}  ${BLUE}3)${NC} 📋 List users                   ${WHITE}║${NC}"
    echo -e "${WHITE}║${NC}  ${GREEN}4)${NC} ▶️  Start monitor                ${WHITE}║${NC}"
    echo -e "${WHITE}║${NC}  ${YELLOW}5)${NC} ⏹️  Stop monitor                 ${WHITE}║${NC}"
    echo -e "${WHITE}║${NC}  ${PURPLE}6)${NC} 🚪 Exit                        ${WHITE}║${NC}"
    echo -e "${WHITE}╚════════════════════════════════════════╝${NC}"
    
    echo ""
    read -p "$(echo -e ${CYAN}Choose option [1-6]: ${NC})" opt
    
    case $opt in
        1) add_user ;;
        2) delete_user ;;
        3) list_users ;;
        4) start_monitor ;;
        5) stop_monitor ;;
        6) 
            print_color "\n👋 Goodbye!" "$CYAN"
            exit 0 
            ;;
        *) 
            print_color "❌ Invalid option" "$RED"
            sleep 1 
            ;;
    esac
    
    echo ""
    read -p "$(echo -e ${DIM}Press Enter to continue...${NC})"
    show_menu
}

# ----------------------------------------------------------------------
# Show login banner (when script is sourced in .bashrc)
show_login_banner() {
    clear
    print_banner
    show_quick_stats
    echo -e "\n${DIM}Type 'menu' to open the manager or 'monitor' for background mode${NC}"
    echo ""
}

# ----------------------------------------------------------------------
# Main execution
setup_iptables

# If script is called with "monitor" argument, run monitor loop
if [ "$1" = "monitor" ]; then
    monitor_loop
# If script is sourced (for .bashrc), show login banner
elif [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    show_login_banner
# Otherwise run interactive menu
else
    # Check if we're in interactive shell
    if [ -t 0 ]; then
        show_menu
    else
        # Called non-interactively, just show banner
        show_login_banner
    fi
fi
