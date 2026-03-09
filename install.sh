#!/bin/bash
# SSH Manager Installation Script

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "🚀 Installing SSH Manager..."

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

# Download the main script
echo "📥 Downloading SSH Manager..."
curl -sSL https://raw.githubusercontent.com/iddienine/ssh-manager/main/ssh-quota-manager.sh -o /usr/local/bin/ssh-quota-manager

# Make it executable
chmod +x /usr/local/bin/ssh-quota-manager

# Add to .bashrc for auto-display
echo "🔧 Configuring auto-display..."
if ! grep -q "ssh-quota-manager" /root/.bashrc; then
    echo "/usr/local/bin/ssh-quota-manager" >> /root/.bashrc
fi

# Create config directory
mkdir -p /etc/ssh-quotas

# Setup iptables
echo "🛡️  Configuring iptables..."
/usr/local/bin/ssh-quota-manager 2>/dev/null || true

echo -e "${GREEN}✅ Installation complete!${NC}"
echo ""
echo "📝 Commands:"
echo "   menu     - Open interactive manager"
echo "   sudo ssh-quota-manager monitor - Start monitor daemon"
echo ""
echo "🎯 Type 'menu' to get started!"
