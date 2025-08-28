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

# --- Script Execution Settings ---
# -e: Exit immediately if a command exits with a non-zero status.
# -u: Treat unset variables as an error when substituting.
# -o pipefail: The return value of a pipeline is the status of the last command to exit with a non-zero status.
set -euo pipefail

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

# --- Function Definitions ---

check_prerequisites() {
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
}

load_config() {
    log_info "Loading configuration..."
    CONFIG_FILE="setup.conf"

    if [ ! -f "$CONFIG_FILE" ]; then
        log_info "Configuration file not found. Creating default 'setup.conf'."
        # Generate secure random passwords
        DB_PASSWORD=$(openssl rand -base64 16)
        ODOO_MASTER_PASSWORD=$(openssl rand -base64 16)
        # Define default paths using an absolute path to the user's home directory
        BASE_PATH_DEFAULT="$HOME/odoo-data"

        cat > "$CONFIG_FILE" << EOF
# --- Configuration Variables ---
# Feel free to change these values to match your requirements.

ODOO_VERSION="16.0"                 # The version of Odoo to install.
ODOO_CONTAINER_NAME="odoo"          # The name for the Odoo Docker container.
DB_CONTAINER_NAME="db"              # The name for the PostgreSQL Docker container.
DB_USER="odoo"                      # The PostgreSQL user for Odoo.
DB_PASSWORD="${DB_PASSWORD}"  # IMPORTANT: This was a securely generated password.
ODOO_MASTER_PASSWORD="${ODOO_MASTER_PASSWORD}" # IMPORTANT: This was a securely generated master password.
ODOO_PORT="8069"                    # The port on which Odoo will be accessible.
ODOO_NETWORK="odoo-net"             # The name for the dedicated Docker network.

# --- Paths ---
# These paths are absolute and should not contain variables like \$HOME or ~.
BASE_PATH="${BASE_PATH_DEFAULT}"
ODOO_ADDONS_PATH="${BASE_PATH_DEFAULT}/addons"
ODOO_CONFIG_PATH="${BASE_PATH_DEFAULT}/config"
DB_DATA_PATH="${BASE_PATH_DEFAULT}/postgres"
BACKUP_PATH="${BASE_PATH_DEFAULT}/backups"
EOF
        log_success "New 'setup.conf' created with secure, random passwords."
        # Secure the config file, as it contains passwords.
        chmod 600 "$CONFIG_FILE"
        log_success "Set permissions for '$CONFIG_FILE' to 600 (read/write for owner only)."
        log_warning "Please review 'setup.conf' and store the passwords in a safe place."
    fi

    # Source the configuration file safely. It now contains absolute paths.
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    log_success "Configuration loaded from $CONFIG_FILE"
}

install_docker() {
    log_info "Handling Docker installation..."
    if ! command -v docker &> /dev/null; then
        log_info "Docker not found, installing..."
        sudo apt-get update
        sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io
    else
        log_info "Docker is already installed."
    fi

    if ! sudo systemctl is-active --quiet docker; then
        log_error "Docker service is not running. Please start it with 'sudo systemctl start docker'."
        exit 1
    fi
    log_success "Docker is installed and service is active."
}

add_user_to_docker_group() {
    log_info "Checking Docker group permissions..."
    if ! getent group docker | grep -q "\b${USER}\b"; then
        log_info "Adding current user to the 'docker' group..."
        sudo usermod -aG docker "${USER}"
        log_warning "You must log out and log back in for group changes to take effect."
    else
        log_info "User is already in the docker group."
    fi
    log_success "User permissions for Docker are set."
}

create_directories() {
    log_info "Creating and securing data directories..."
    mkdir -p "$ODOO_ADDONS_PATH" "$ODOO_CONFIG_PATH" "$DB_DATA_PATH" "$BACKUP_PATH"
    chmod 700 "$ODOO_ADDONS_PATH" "$ODOO_CONFIG_PATH" "$DB_DATA_PATH" "$BACKUP_PATH"
    log_success "Data directories created and secured."
}

create_odoo_config() {
    log_info "Checking for odoo.conf file..."
    local ODOO_CONFIG_FILE="$ODOO_CONFIG_PATH/odoo.conf"
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
}

create_docker_network() {
    log_info "Setting up Docker network..."
    if ! docker network ls | grep -q "$ODOO_NETWORK"; then
        log_info "Creating Docker network: $ODOO_NETWORK"
        docker network create "$ODOO_NETWORK"
    else
        log_info "Docker network '$ODOO_NETWORK' already exists."
    fi
    log_success "Docker network is ready."
}

start_container() {
    local container_name="$1"
    shift

    # The `^/` and `$` are used to ensure an exact match on the container name.
    if [ "$(docker ps -q -f name=^/"${container_name}"$)" ]; then
        log_info "${container_name} container is already running."
        return
    fi

    if [ "$(docker ps -aq -f name=^/"${container_name}"$)" ]; then
        log_info "Found stopped ${container_name} container. Starting it..."
        docker start "${container_name}"
    else
        log_info "Starting new ${container_name} container..."
        docker run -d --name "${container_name}" "$@"
    fi
    log_success "${container_name} container is running."
}

start_postgres_container() {
    log_info "Checking PostgreSQL container..."
    start_container "$DB_CONTAINER_NAME" \
        -e POSTGRES_USER="$DB_USER" \
        -e POSTGRES_PASSWORD="$DB_PASSWORD" \
        -e POSTGRES_DB=postgres \
        --network "$ODOO_NETWORK" \
        --restart=always \
        -v "$DB_DATA_PATH:/var/lib/postgresql/data" \
        postgres:15
}

start_odoo_container() {
    log_info "Checking Odoo container..."
    local ODOO_CONFIG_FILE="$ODOO_CONFIG_PATH/odoo.conf"

    start_container "$ODOO_CONTAINER_NAME" \
        -p "$ODOO_PORT:8069" \
        --network "$ODOO_NETWORK" \
        --restart=always \
        -v "$ODOO_ADDONS_PATH:/mnt/extra-addons" \
        -v "$ODOO_CONFIG_FILE:/etc/odoo/odoo.conf" \
        "odoo:$ODOO_VERSION"
}

configure_backup_function() {
    log_info "Configuring backup helper function..."
    if ! grep -q "backup_odoo_db" ~/.bashrc; then
        log_info "Adding 'backup_odoo_db' command to your .bashrc for easy backups."

        # The variables are now absolute and safe to embed directly
        cat >> ~/.bashrc << EOF

# Odoo Backup Function
# Generated by Odoo setup script
# Note: The configuration values below are set when this function is created.
# If you change them in setup.conf, you will need to re-run this setup script
# or manually update this function in your ~/.bashrc file.
backup_odoo_db() {
    local TIMESTAMP=\$(date +%Y%m%d_%H%M%S)
    local BACKUP_FILE="${BACKUP_PATH}/dump_\${TIMESTAMP}.sql"
    local DB_CONTAINER="${DB_CONTAINER_NAME}"
    local DB_USER_BACKUP="${DB_USER}"

    echo "Backing up Odoo database to \${BACKUP_FILE}.gz..."
    if ! docker exec "\${DB_CONTAINER}" pg_dumpall -U "\${DB_USER_BACKUP}" | gzip > "\${BACKUP_FILE}.gz"; then
        echo "Backup failed. Please check if the container is running and paths are correct."
    else
        echo "Backup complete!"
    fi
}
EOF
        log_warning "Please run 'source ~/.bashrc' or open a new terminal to use the new backup command."
    fi
    log_success "Backup helper function configured."
}

print_final_instructions() {
    local ODOO_CONFIG_FILE="$ODOO_CONFIG_PATH/odoo.conf"
    local ip_address
    ip_address=$(hostname -I | awk '{print $1}')

    echo ""
    echo "============================================================"
    echo "🎉 Odoo, Docker, and PostgreSQL setup is complete! 🎉"
    echo "============================================================"
    echo ""
    echo "You can access your Odoo instance at: http://${ip_address}:$ODOO_PORT"
    echo ""
    echo "A configuration file 'setup.conf' has been created."
    echo "Your custom addons folder is at: $ODOO_ADDONS_PATH"
    echo "Your Odoo config file is at: $ODOO_CONFIG_FILE"
    echo ""
    echo "To backup your database, run the command: backup_odoo_db"
    echo "============================================================"
}


# --- Main Execution ---
main() {
    check_prerequisites
    load_config
    install_docker
    add_user_to_docker_group
    create_directories
    create_odoo_config
    create_docker_network
    start_postgres_container
    start_odoo_container
    configure_backup_function
    print_final_instructions
}

# Run the main function
main
