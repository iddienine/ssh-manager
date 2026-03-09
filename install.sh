
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
curl -sSL https://raw.githubusercontent.com/iddienine/ssh-manager/main/ssh-manager -o /usr/local/bin/ssh-manager

# Make it executable
chmod +x /usr/local/bin/ssh-manager

# Add alias for easy access
echo "🔧 Adding 'menu' command..."
if ! grep -q "alias menu=" /root/.bashrc 2>/dev/null; then
    echo "alias menu='sudo /usr/local/bin/ssh-manager'" >> /root/.bashrc
fi

# Add to .bashrc for auto-display
echo "🔧 Configuring auto-display..."
if ! grep -q "ssh-manager" /root/.bashrc 2>/dev/null; then
    echo "/usr/local/bin/ssh-manager" >> /root/.bashrc
fi

# Create config directory
mkdir -p /etc/ssh-quotas

# Create log file
touch /var/log/ssh-quota-monitor.log 2>/dev/null

# Initial setup
echo "🛡️  Configuring iptables..."
/usr/local/bin/ssh-manager 2>/dev/null || true

echo -e "${GREEN}✅ Installation complete!${NC}"
echo ""
echo "📝 Commands:"
echo "   menu     - Open interactive manager"
echo "   sudo ssh-manager monitor - Start monitor daemon"
echo "   sudo ssh-manager - Show menu"
echo ""
echo "🎯 Type 'menu' to get started!"
