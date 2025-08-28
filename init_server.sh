#!/bin/bash

# =================================================================================
# Initial Server Setup & Security Script
#
# Author: Lungani Langa
# Repository: https://github.com/MrrSteven/Full-Ubuntu-Odoo-server-setup-from-scratch/
# Description: A first-run script for new Ubuntu servers. It updates the system,
#              creates a new sudo user, sets up SSH key auth, and secures SSH.
# =================================================================================

# --- Colors for better output ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Helper Functions ---
log() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

error() {
    # This function now includes a visual failure indicator.
    echo -e "${RED}[ERROR] ❌ $1${NC}" >&2
    exit 1
}

# --- Check Up ---
# --- Script Start ---
# 1. Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
  error "This script must be run as root. Please use 'sudo'."
fi

# 2. Check for Internet Connectivity
log "Checking for internet connection..."
if ! ping -c 1 8.8.8.8 &> /dev/null; then
  error "No internet connection. Please check your network settings."
fi
log "✅ Internet connection is active."

# 3. Update System Packages
log "Updating system packages. This may take a few minutes..."
apt-get update > /dev/null || error "Failed to update package lists."
apt-get upgrade -y > /dev/null || error "Failed to upgrade packages."
log "✅ System updated successfully."

# 4. Create a New User
log "Creating a new user account..."
read -p "Enter the username for the new user: " NEW_USER
if id "$NEW_USER" &>/dev/null; then
    warn "User '$NEW_USER' already exists. Skipping creation."
else
    adduser --gecos "" "$NEW_USER" || error "Failed to create new user."
    usermod -aG sudo "$NEW_USER" || error "Failed to add user to sudo group."
    log "✅ User '$NEW_USER' created and added to the sudo group."
fi

# 5. Set up SSH Key Authentication
log "Setting up SSH key for the new user..."
# Create the .ssh directory and authorized_keys file
mkdir -p /home/$NEW_USER/.ssh
touch /home/$NEW_USER/.ssh/authorized_keys

# Prompt for the public key
echo "Please paste your SSH public key (it usually starts with 'ssh-rsa' or 'ecdsa-sha2-nistp256'):"
read -p "> " PUBLIC_KEY

# Add the key and set correct permissions
echo "$PUBLIC_KEY" >> /home/$NEW_USER/.ssh/authorized_keys || error "Failed to write SSH key to authorized_keys."
chown -R $NEW_USER:$NEW_USER /home/$NEW_USER/.ssh || error "Failed to set ownership of .ssh directory."
chmod 700 /home/$NEW_USER/.ssh
chmod 600 /home/$NEW_USER/.ssh/authorized_keys || error "Failed to set permissions on authorized_keys."
log "✅ SSH key added for user '$NEW_USER'."

# 6. Secure the SSH Daemon
log "Securing the SSH server..."
# Disable root login
sed -i 's/^#?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
# Disable password authentication
sed -i 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
# Restart SSH to apply changes
systemctl restart sshd || error "Failed to restart SSH service. Please check the configuration."
log "✅ SSH server secured (root login and password auth disabled)."

# 7. Configure Firewall (UFW)
log "Setting up a basic firewall (UFW)..."
ufw allow OpenSSH > /dev/null || error "Failed to add UFW rule for OpenSSH."
ufw --force enable > /dev/null || error "Failed to enable UFW firewall."
log "✅ Firewall enabled and configured to allow SSH."

# --- Final Instructions ---
echo
warn "========================================================================"
warn "IMPORTANT: Your server is now secured."
warn "Before you close this terminal, please open a NEW terminal window and"
warn "test that you can log in with your new user:"
warn ""
warn "ssh ${NEW_USER}@$(hostname -I | awk '{print $1}')"
warn ""
warn "If you cannot log in, DO NOT close this root session."
warn "========================================================================"
echo
log "========================================================================"
log "🎉 Initial server setup is complete!"
log "✅ User '${NEW_USER}' created."
log "✅ SSH secured with your key."
log "✅ Firewall is active."
log "========================================================================"
