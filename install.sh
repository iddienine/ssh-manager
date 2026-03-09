#!/bin/bash
# SSH Manager Installer for Ubuntu 24.04

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "╔════════════════════════════════════╗"
echo "║    SSH MANAGER - UBUNTU 24.04     ║"
echo "║         INSTALLATION SCRIPT        ║"
echo "╚════════════════════════════════════╝"
echo ""

# Check Ubuntu version
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$VERSION_ID" != "24.04" ]]; then
        echo -e "${YELLOW}Warning: This script is optimized for Ubuntu 24.04${NC}"
        echo -e "Your version: $VERSION_ID"
        echo ""
    fi
fi

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Please run as root${NC}"
    exit 1
fi

# Install required packages
echo -e "${GREEN}📦 Installing required packages...${NC}"
apt update
apt install -y iptables curl

# Download main script
echo -e "${GREEN}📥 Downloading SSH Manager...${NC}"
curl -sSL https://raw.githubusercontent.com/iddienine/ssh-manager/main/ssh-manager -o /usr/local/bin/ssh-manager

# Make executable
chmod +x /usr/local/bin/ssh-manager

# Create config directory
mkdir -p /etc/ssh-manager

# Create log file
touch /var/log/ssh-manager.log
chmod 644 /var/log/ssh-manager.log

# Add alias
echo -e "${GREEN}🔧 Adding 'menu' command...${NC}"
if ! grep -q "alias menu=" /root/.bashrc 2>/dev/null; then
    echo "alias menu='sudo /usr/local/bin/ssh-manager'" >> /root/.bashrc
fi

# Add to bashrc for auto-display
if ! grep -q "/usr/local/bin/ssh-manager" /root/.bashrc 2>/dev/null; then
    echo "/usr/local/bin/ssh-manager" >> /root/.bashrc
fi

# Setup iptables
echo -e "${GREEN}🛡️  Configuring iptables...${NC}"
/usr/local/bin/ssh-manager 2>/dev/null &

# Create systemd service (optional)
cat > /etc/systemd/system/ssh-manager.service <<EOF
[Unit]
Description=SSH Manager Monitor
After=network.target

[Service]
Type=forking
ExecStart=/usr/local/bin/ssh-manager monitor
PIDFile=/var/run/ssh-manager.pid
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

# Done
echo ""
echo -e "${GREEN}╔════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     INSTALLATION COMPLETE!         ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════╝${NC}"
echo ""
echo -e "📝 ${WHITE}Commands:${NC}"
echo -e "   ${GREEN}menu${NC}         - Open interactive manager"
echo -e "   ${GREEN}sudo ssh-manager${NC} - Show menu"
echo -e "   ${GREEN}sudo ssh-manager monitor${NC} - Start monitor"
echo ""
echo -e "📁 ${WHITE}Locations:${NC}"
echo -e "   Script: ${CYAN}/usr/local/bin/ssh-manager${NC}"
echo -e "   Config: ${CYAN}/etc/ssh-manager/${NC}"
echo -e "   Logs:   ${CYAN}/var/log/ssh-manager.log${NC}"
echo ""
echo -e "🎯 ${YELLOW}Type 'menu' to get started!${NC}"
echo ""

# Reload bashrc
source /root/.bashrc 2>/dev/null || true
