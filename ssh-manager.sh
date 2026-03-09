#!/bin/bash
# SSH Manager - Bandwidth Quota System for Ubuntu 24.04
# Version: 2.0.0

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'
BOLD='\033[1m'

# Configuration
CONFIG_DIR="/etc/ssh-manager"
PIDFILE="/var/run/ssh-manager.pid"
LOGFILE="/var/log/ssh-manager.log"
CHECK_INTERVAL=3

# Create config directory if not exists
mkdir -p "$CONFIG_DIR" 2>/dev/null

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Error: Please run as root${NC}"
        exit 1
    fi
}

# Convert human readable to bytes
to_bytes() {
    local val="$1"
    local unit=$(echo "$val" | sed 's/[0-9.]//g' | tr '[:lower:]' '[:upper:]')
    local num=$(echo "$val" | sed 's/[A-Za-z]//g')
    
    case "$unit" in
        "G") echo $(($num * 1024 * 1024 * 1024)) ;;
        "M") echo $(($num * 1024 * 1024)) ;;
        "K") echo $(($num * 1024)) ;;
        "B") echo "$num" ;;
        "") echo "$num" ;;
        *) echo "0" ;;
    esac
}

# Convert bytes to human readable
to_human() {
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

# Setup iptables
setup_iptables() {
    # Create chains
    iptables -N SSH_MANAGER_IN 2>/dev/null
    iptables -N SSH_MANAGER_OUT 2>/dev/null
    
    # Insert jumps if not present
    if ! iptables -C INPUT -j SSH_MANAGER_IN 2>/dev/null; then
        iptables -I INPUT 1 -j SSH_MANAGER_IN
    fi
    if ! iptables -C OUTPUT -j SSH_MANAGER_OUT 2>/dev/null; then
        iptables -I OUTPUT 1 -j SSH_MANAGER_OUT
    fi
}

# Add new user
add_user() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║        ADD NEW USER                ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════╝${NC}\n"
    
    read -p "$(echo -e ${GREEN}Username: ${NC})" username
    
    # Validate username
    if [ -z "$username" ]; then
        echo -e "${RED}Error: Username cannot be empty${NC}"
        return
    fi
    
    if id "$username" &>/dev/null; then
        echo -e "${RED}Error: User '$username' already exists${NC}"
        return
    fi
    
    read -p "$(echo -e ${GREEN}Quota (e.g., 1G, 500M): ${NC})" quota_str
    
    # Validate quota
    quota_bytes=$(to_bytes "$quota_str")
    if [ "$quota_bytes" -eq 0 ]; then
        echo -e "${RED}Error: Invalid quota format${NC}"
        return
    fi
    
    # Create user
    useradd -m -s /bin/bash "$username"
    echo -e "${GREEN}✓ User created${NC}"
    
    # Set password
    passwd "$username"
    
    # Get UID
    uid=$(id -u "$username")
    
    # Add iptables rules
    iptables -A SSH_MANAGER_IN -m owner --uid-owner "$uid" -j RETURN
    iptables -A SSH_MANAGER_OUT -m owner --uid-owner "$uid" -j RETURN
    
    # Save user data
    cat > "$CONFIG_DIR/$username" <<EOF
QUOTA=$quota_bytes
USED=0
LAST_IN=0
LAST_OUT=0
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
EOF
    
    echo -e "\n${GREEN}✓ User '$username' added successfully${NC}"
    echo -e "  Quota: ${YELLOW}$quota_str${NC}"
}

# Delete user
delete_user() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║        DELETE USER                 ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════╝${NC}\n"
    
    # List users
    local users=()
    for file in "$CONFIG_DIR"/*; do
        if [ -f "$file" ]; then
            users+=($(basename "$file"))
        fi
    done
    
    if [ ${#users[@]} -eq 0 ]; then
        echo -e "${YELLOW}No users found${NC}"
        return
    fi
    
    echo -e "${GREEN}Available users:${NC}"
    for i in "${!users[@]}"; do
        echo "  $((i+1)). ${users[$i]}"
    done
    
    echo ""
    read -p "$(echo -e ${GREEN}Select user number: ${NC})" choice
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#users[@]} ]; then
        username="${users[$((choice-1))]}"
        
        read -p "$(echo -e ${RED}Delete user '$username'? (y/N): ${NC})" confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            # Get UID
            uid=$(id -u "$username" 2>/dev/null)
            
            # Remove iptables rules
            if [ -n "$uid" ]; then
                iptables -D SSH_MANAGER_IN -m owner --uid-owner "$uid" -j RETURN 2>/dev/null
                iptables -D SSH_MANAGER_OUT -m owner --uid-owner "$uid" -j RETURN 2>/dev/null
            fi
            
            # Delete user
            userdel -r "$username" 2>/dev/null
            
            # Remove config
            rm -f "$CONFIG_DIR/$username"
            
            echo -e "${GREEN}✓ User '$username' deleted${NC}"
            
            # Log action
            echo "$(date): Deleted user $username" >> "$LOGFILE"
        fi
    else
        echo -e "${RED}Invalid selection${NC}"
    fi
}

# List users
list_users() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║        USER USAGE REPORT           ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════╝${NC}\n"
    
    local total_quota=0
    local total_used=0
    local user_count=0
    
    printf "${WHITE}%-15s %-10s %-10s %-8s %s${NC}\n" "USERNAME" "QUOTA" "USED" "USAGE" "STATUS"
    echo -e "${DIM}─────────────────────────────────────────────────────────────${NC}"
    
    for file in "$CONFIG_DIR"/*; do
        if [ ! -f "$file" ]; then
            continue
        fi
        
        username=$(basename "$file")
        
        # Check if user exists
        if ! id "$username" &>/dev/null; then
            rm -f "$file"
            continue
        fi
        
        # Read user data
        source "$file"
        
        quota_hr=$(to_human "$QUOTA")
        used_hr=$(to_human "$USED")
        
        if [ "$QUOTA" -gt 0 ]; then
            percent=$((USED * 100 / QUOTA))
        else
            percent=0
        fi
        
        # Color based on usage
        if [ "$percent" -ge 90 ]; then
            color="$RED"
            status="CRITICAL"
        elif [ "$percent" -ge 60 ]; then
            color="$YELLOW"
            status="WARNING"
        else
            color="$GREEN"
            status="OK"
        fi
        
        printf "${WHITE}%-15s${NC} ${color}%-10s${NC} ${color}%-10s${NC} ${color}%3d%%${NC}    %s\n" \
               "$username" "$quota_hr" "$used_hr" "$percent" "$status"
        
        total_quota=$((total_quota + QUOTA))
        total_used=$((total_used + USED))
        user_count=$((user_count + 1))
    done
    
    if [ "$user_count" -eq 0 ]; then
        echo -e "${YELLOW}No users found${NC}"
    else
        echo -e "${DIM}─────────────────────────────────────────────────────────────${NC}"
        total_percent=$((total_used * 100 / total_quota))
        printf "${WHITE}%-15s %-10s %-10s %3d%%${NC}\n" \
               "TOTAL" "$(to_human $total_quota)" "$(to_human $total_used)" "$total_percent"
    fi
    
    # Monitor status
    echo -e "\n${CYAN}Monitor:${NC} $(monitor_status)"
}

# Check monitor status
monitor_status() {
    if [ -f "$PIDFILE" ]; then
        pid=$(cat "$PIDFILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "${GREEN}● Running (PID: $pid)${NC}"
            return 0
        fi
    fi
    echo -e "${RED}● Stopped${NC}"
    return 1
}

# Start monitor
start_monitor() {
    if [ -f "$PIDFILE" ]; then
        pid=$(cat "$PIDFILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "${YELLOW}Monitor already running (PID: $pid)${NC}"
            return
        fi
    fi
    
    # Start monitor in background
    nohup "$0" monitor >/dev/null 2>&1 &
    echo $! > "$PIDFILE"
    echo -e "${GREEN}✓ Monitor started (PID: $!)${NC}"
    echo "$(date): Monitor started" >> "$LOGFILE"
}

# Stop monitor
stop_monitor() {
    if [ -f "$PIDFILE" ]; then
        pid=$(cat "$PIDFILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            rm -f "$PIDFILE"
            echo -e "${GREEN}✓ Monitor stopped${NC}"
            echo "$(date): Monitor stopped" >> "$LOGFILE"
        else
            rm -f "$PIDFILE"
            echo -e "${YELLOW}Monitor was not running${NC}"
        fi
    else
        echo -e "${YELLOW}Monitor is not running${NC}"
    fi
}

# Monitor loop
monitor_loop() {
    while true; do
        for file in "$CONFIG_DIR"/*; do
            [ -f "$file" ] || continue
            
            username=$(basename "$file")
            
            # Skip if user doesn't exist
            if ! id "$username" &>/dev/null; then
                rm -f "$file"
                continue
            fi
            
            # Load user data
            source "$file"
            
            uid=$(id -u "$username")
            
            # Get current counters
            current_in=$(iptables -L SSH_MANAGER_IN -v -n -x 2>/dev/null | grep "owner UID match $uid" | awk '{print $2}')
            current_out=$(iptables -L SSH_MANAGER_OUT -v -n -x 2>/dev/null | grep "owner UID match $uid" | awk '{print $2}')
            
            current_in=${current_in:-0}
            current_out=${current_out:-0}
            
            # Calculate delta
            delta_in=$((current_in - LAST_IN))
            delta_out=$((current_out - LAST_OUT))
            
            [ "$delta_in" -lt 0 ] && delta_in=0
            [ "$delta_out" -lt 0 ] && delta_out=0
            
            # Update usage
            USED=$((USED + delta_in + delta_out))
            LAST_IN=$current_in
            LAST_OUT=$current_out
            
            # Save updated data
            cat > "$file" <<EOF
QUOTA=$QUOTA
USED=$USED
LAST_IN=$LAST_IN
LAST_OUT=$LAST_OUT
CREATED=$CREATED
EOF
            
            # Check quota
            if [ "$USED" -ge "$QUOTA" ] && [ "$QUOTA" -gt 0 ]; then
                echo "$(date): User $username exceeded quota ($(to_human $USED) >= $(to_human $QUOTA))" >> "$LOGFILE"
                
                # Delete user
                uid=$(id -u "$username" 2>/dev/null)
                if [ -n "$uid" ]; then
                    iptables -D SSH_MANAGER_IN -m owner --uid-owner "$uid" -j RETURN 2>/dev/null
                    iptables -D SSH_MANAGER_OUT -m owner --uid-owner "$uid" -j RETURN 2>/dev/null
                fi
                userdel -r "$username" 2>/dev/null
                rm -f "$file"
            fi
        done
        sleep "$CHECK_INTERVAL"
    done
}

# Show menu
show_menu() {
    while true; do
        clear
        echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║     SSH MANAGER - UBUNTU 24       ║${NC}"
        echo -e "${CYAN}╠════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║${NC}  ${GREEN}1.${NC} ➕  Add User                ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${RED}2.${NC} 🗑️  Delete User             ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${BLUE}3.${NC} 📋  List Users              ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${GREEN}4.${NC} ▶️  Start Monitor           ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${YELLOW}5.${NC} ⏹️  Stop Monitor            ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${PURPLE}6.${NC} 🔄  Reset Stats             ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${WHITE}7.${NC} 🚪  Exit                   ${CYAN}║${NC}"
        echo -e "${CYAN}╚════════════════════════════════════╝${NC}"
        
        echo -e "\n${CYAN}Monitor:${NC} $(monitor_status)"
        echo ""
        
        read -p "$(echo -e ${GREEN}Choose option [1-7]: ${NC})" choice
        
        case $choice in
            1) add_user ;;
            2) delete_user ;;
            3) list_users ;;
            4) start_monitor ;;
            5) stop_monitor ;;
            6) reset_stats ;;
            7) 
                echo -e "\n${GREEN}Goodbye!${NC}"
                exit 0 
                ;;
            *)
                echo -e "${RED}Invalid option${NC}"
                sleep 1
                ;;
        esac
        
        if [ "$choice" != "3" ]; then
            echo ""
            read -p "$(echo -e ${DIM}Press Enter to continue...${NC})"
        else
            echo ""
            read -p "$(echo -e ${DIM}Press Enter to continue...${NC})"
        fi
    done
}

# Reset stats
reset_stats() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║        RESET STATISTICS            ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════╝${NC}\n"
    
    read -p "$(echo -e ${RED}Reset ALL user statistics? (y/N): ${NC})" confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        for file in "$CONFIG_DIR"/*; do
            if [ -f "$file" ]; then
                username=$(basename "$file")
                if id "$username" &>/dev/null; then
                    # Reset counters
                    cat > "$file" <<EOF
QUOTA=$(grep QUOTA "$file" | cut -d= -f2)
USED=0
LAST_IN=0
LAST_OUT=0
CREATED=$(grep CREATED "$file" | cut -d= -f2)
EOF
                    echo -e "${GREEN}✓ Reset $username${NC}"
                fi
            fi
        done
        echo -e "\n${GREEN}✓ All statistics reset${NC}"
    fi
}

# Main execution
check_root
setup_iptables

# Handle command line arguments
if [ "$1" = "monitor" ]; then
    monitor_loop
elif [ "$1" = "status" ]; then
    monitor_status
else
    show_menu
fi
