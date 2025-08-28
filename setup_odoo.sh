#!/bin/bash

# =================================================================================================
# Production-Ready Script for setting up Docker, PostgreSQL, and Odoo on Ubuntu
# =================================================================================================
# This script automates the following tasks:
# 1.  Checks for prerequisites (Ubuntu version, Docker service).
# 2.  Sources configuration from an external file (setup.conf).
# 3.  Updates packages and installs Docker.
# 4.  Adds the current user to the 'docker' group.
# 5.  Creates a dedicated Docker network for better container communication.
# 6.  Creates necessary directories with secure permissions.
# 7.  Creates a custom odoo.conf file for better configuration management.
# 8.  Starts PostgreSQL and Odoo containers on the dedicated network.
# 9.  Provides a function for easy database backups.
# =================================================================================================

# --- Script Execution ---

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Logging Functions ---
log_success() { echo "✅  $1"; }
log_error() { echo "❌  ERROR: $1" >&2; }
log_info() { echo "ℹ️  $1"; }
log_warning() { echo "⚠️  WARNING: $1"; }

# --- Error Trap ---
# This function will be executed when any command fails before the script exits.
on_error() {
    log_error "Script failed on line $1. Aborting."
}
trap 'on_error $LINENO' ERR


# --- 1. Prerequisite Checks ---
log_info "Running prerequisite checks..."
if ! grep -q "Ubuntu" /etc/os-release; then
    log_error "This script is intended for Ubuntu only."
    exit 1
fi

TOTAL_MEM=$(free -g | awk '/^Mem:/{print $2}')
if [ "$TOTAL_MEM" -lt "2" ]; then
    log_warning "Less than 2GB of RAM detected. Odoo may run slowly."
fi
log_success "Prerequisite checks passed."


# --- 2. Centralized Configuration ---
log_info "Loading configuration..."
CONFIG_FILE="setup.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    log_info "Configuration file not found. Creating default 'setup.conf'."
    cat > "$CONFIG_FILE" << EOF
# --- Configuration Variables ---
# Feel free to change these values to match your requirements.

ODOO_VERSION="16.0"                 # The version of Odoo to install.
ODOO_CONTAINER_NAME="odoo"          # The name for the Odoo Docker container.
DB_CONTAINER_NAME="db"              # The name for the PostgreSQL Docker container.
DB_USER="odoo"                      # The PostgreSQL user for Odoo.
DB_PASSWORD="your_strong_password"  # IMPORTANT: Change this to a secure password.
ODOO_MASTER_PASSWORD="your_master_password" # IMPORTANT: Change this to a secure master password for Odoo.
ODOO_PORT="8069"                    # The port on which Odoo will be accessible.
ODOO_NETWORK="odoo-net"             # The name for the dedicated Docker network.

# --- Paths ---
# These paths will be created in your home directory.
BASE_PATH="\$HOME/odoo-data"
ODOO_ADDONS_PATH="\$BASE_PATH/addons"
ODOO_CONFIG_PATH="\$BASE_PATH/config"
DB_DATA_PATH="\$BASE_PATH/postgres"
BACKUP_PATH="\$BASE_PATH/backups"
EOF
fi

eval "$(cat $CONFIG_FILE | sed 's/=\$/=/' | sed 's/=/="/' | sed 's/$/"/')"
log_success "Configuration loaded from $CONFIG_FILE"


# --- 3. System Update and Docker Installation ---
log_info "Handling Docker installation..."
sudo apt-get update > /dev/null 2>&1
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common > /dev/null 2>&1

if ! [ -x "$(command -v docker)" ]; then
    log_info "Docker not found, installing..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update > /dev/null 2>&1
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io > /dev/null 2>&1
else
    log_info "Docker is already installed."
fi

if ! sudo systemctl is-active --quiet docker; then
    log_error "Docker service is not running. Please start it with 'sudo systemctl start docker'."
    exit 1
fi
log_success "Docker is installed and service is active."


# --- 4. Add User to Docker Group ---
log_info "Checking Docker group permissions..."
if ! getent group docker | grep -q "\b${USER}\b"; then
    log_info "Adding current user to the 'docker' group..."
    sudo usermod -aG docker ${USER}
    log_warning "You must log out and log back in for group changes to take effect."
else
    log_info "User is already in the docker group."
fi
log_success "User permissions for Docker are set."


# --- 5. Create Directories and Permissions ---
log_info "Creating and securing data directories..."
mkdir -p "$ODOO_ADDONS_PATH" "$ODOO_CONFIG_PATH" "$DB_DATA_PATH" "$BACKUP_PATH"
chmod 700 "$ODOO_ADDONS_PATH" "$ODOO_CONFIG_PATH" "$DB_DATA_PATH" "$BACKUP_PATH"
log_success "Data directories created and secured."


# --- 6. Create Custom odoo.conf ---
log_info "Checking for odoo.conf file..."
ODOO_CONFIG_FILE="$ODOO_CONFIG_PATH/odoo.conf"
if [ ! -f "$ODOO_CONFIG_FILE" ]; then
    log_info "Creating default odoo.conf file..."
    cat > "$ODOO_CONFIG_FILE" << EOF
[options]
admin_passwd = ${ODOO_MASTER_PASSWORD}
db_host = ${DB_CONTAINER_NAME}
db_port = 5432
db_user = ${DB_USER}
db_password = ${DB_PASSWORD}
addons_path = /mnt/extra-addons
EOF
else
    log_info "odoo.conf file already exists."
fi
log_success "Custom odoo.conf is in place."


# --- 7. Create Docker Network ---
log_info "Setting up Docker network..."
if ! docker network ls | grep -q "$ODOO_NETWORK"; then
    log_info "Creating Docker network: $ODOO_NETWORK"
    docker network create "$ODOO_NETWORK" > /dev/null
else
    log_info "Docker network '$ODOO_NETWORK' already exists."
fi
log_success "Docker network is ready."


# --- 8. Start PostgreSQL Container ---
log_info "Checking PostgreSQL container..."
if [ ! "$(docker ps -q -f name=$DB_CONTAINER_NAME)" ]; then
    if [ "$(docker ps -aq -f status=exited -f name=$DB_CONTAINER_NAME)" ]; then
        docker rm $DB_CONTAINER_NAME > /dev/null
    fi
    log_info "Starting PostgreSQL container..."
    docker run -d \
        -e POSTGRES_USER=$DB_USER \
        -e POSTGRES_PASSWORD=$DB_PASSWORD \
        -e POSTGRES_DB=postgres \
        --name $DB_CONTAINER_NAME \
        --network "$ODOO_NETWORK" \
        --restart=always \
        -v "$DB_DATA_PATH:/var/lib/postgresql/data" \
        postgres:15 > /dev/null
else
    log_info "PostgreSQL container is already running."
fi
log_success "PostgreSQL container is running."


# --- 9. Start Odoo Container ---
log_info "Checking Odoo container..."
if [ ! "$(docker ps -q -f name=$ODOO_CONTAINER_NAME)" ]; then
    if [ "$(docker ps -aq -f status=exited -f name=$ODOO_CONTAINER_NAME)" ]; then
        docker rm $ODOO_CONTAINER_NAME > /dev/null
    fi
    log_info "Starting Odoo container..."
    docker run -d \
        -p $ODOO_PORT:8069 \
        --name $ODOO_CONTAINER_NAME \
        --network "$ODOO_NETWORK" \
        --restart=always \
        -v "$ODOO_ADDONS_PATH:/mnt/extra-addons" \
        -v "$ODOO_CONFIG_FILE:/etc/odoo/odoo.conf" \
        odoo:$ODOO_VERSION > /dev/null
else
    log_info "Odoo container is already running."
fi
log_success "Odoo container is running."


# --- 10. Backup Function ---
log_info "Configuring backup helper function..."
if ! grep -q "backup_odoo_db" ~/.bashrc; then
    log_info "Adding 'backup_odoo_db' command to your .bashrc for easy backups."
    cat >> ~/.bashrc << EOF

# Odoo Backup Function
backup_odoo_db() {
    TIMESTAMP=\$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="$BACKUP_PATH/dump_\${TIMESTAMP}.sql"
    echo "Backing up Odoo database to \${BACKUP_FILE}.gz..."
    docker exec "$DB_CONTAINER_NAME" pg_dumpall -U "$DB_USER" | gzip > "\${BACKUP_FILE}.gz"
    echo "Backup complete!"
}
EOF
    log_warning "Please run 'source ~/.bashrc' or open a new terminal to use the new backup command."
fi
log_success "Backup helper function configured."


# --- Final Instructions ---
echo ""
echo "============================================================"
echo "🎉 Odoo, Docker, and PostgreSQL setup is complete! 🎉"
echo "============================================================"
echo ""
echo "You can access your Odoo instance at: http://$(hostname -I | awk '{print $1'}):$ODOO_PORT"
echo ""
echo "A configuration file 'setup.conf' has been created."
echo "Your custom addons folder is at: $ODOO_ADDONS_PATH"
echo "Your Odoo config file is at: $ODOO_CONFIG_FILE"
echo ""
echo "To backup your database, run the command: backup_odoo_db"
echo "============================================================"

