*🥀ONE CLICK INSTALL⚡🟢*

# SSH Manager - Bandwidth Quota System for SlowDNS

![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)
![Bash](https://img.shields.io/badge/bash-5.0%2B-orange.svg)

A powerful SSH user management system with bandwidth quota monitoring and auto-deletion for SlowDNS tunneling. Perfect for managing multiple users with data limits.

## ✨ Features

- **User Management**: Create and delete SSH users easily
- **Bandwidth Quotas**: Set limits in MB or GB (e.g., 1G, 500M)
- **Real-time Monitoring**: Checks usage every 3 seconds
- **Auto-Deletion**: Automatically removes users when quota exceeded
- **Colorful Interface**: Easy-to-use menu with visual feedback
- **Login Banner**: Shows stats automatically when you SSH in
- **Persistent Storage**: Quota data saved in `/etc/ssh-quotas/`
- **Background Daemon**: Monitor runs as a service

## 📋 Requirements

- Linux VPS (Ubuntu/Debian/CentOS)
- Root access
- iptables with owner module
- bash 4.0+

## 🚀 Installation

### One-Line Install
```bash
curl -sSL https://raw.githubusercontent.com/iddienine/ssh-manager/main/install.sh | sudo bash
