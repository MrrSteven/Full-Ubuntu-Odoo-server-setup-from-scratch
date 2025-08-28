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
# 10. Includes a 'status' mode to check the health of the services.
# =================================================================================================

# --- Script Execution Settings ---
# -e: Exit immediately if a command exits with a non-zero status.
# -u: Treat unset variables as an error when substituting.
# -o pipefail: The return value of a pipeline is the status of the last command to exit with a non-zero status.
set -euo pipefail

# --- Formatting Variables ---
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# --- Logging Functions ---
log_success() { echo -e "${GREEN}✅  $1${NC}"; }
log_error() { echo -e "${RED}❌  $1${NC}"; } # Simplified for status checks
log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  WARNING: $1${NC}"; }

# --- Error Trap ---
# This function will be executed when any command fails before the script exits.
on_error() {
    # Don't show the error if we are exiting cleanly from status mode
    if [[ "${BASH_COMMAND}" != "exit 0" ]]; then
        log_error "Script failed on line $LINENO. Aborting."
    fi
}
trap 'on_error $LINENO' ERR

# --- Status Check Feature ---

# State variables for the final summary
DOCKER_STATUS="FAIL"
POSTGRES_STATUS="FAIL"
ODOO_STATUS="FAIL"

check_docker_component() {
    echo -e "\n${BLUE}--- Component: Docker ---${NC}"
    # Assume PASS until a check fails
    DOCKER_STATUS="PASS"

    # Check Service Status
    if sudo systemctl is-active --quiet docker; then
        log_success "Docker service is active and running."
    else
        log_error "Docker service is NOT running."
        DOCKER_STATUS="FAIL"
    fi

    # Display System Logs
    echo "  -> Last 20 Docker Service Logs (journalctl):"
    sudo journalctl -u docker.service -n 20 --no-pager
}

check_postgres_component() {
    echo -e "\n${BLUE}--- Component: PostgreSQL ---${NC}"
    local container_name="$DB_CONTAINER_NAME"
    # Assume PASS until a check fails
    POSTGRES_STATUS="PASS"

    # Check Container Existence
    if ! sudo docker ps -a --filter "name=^/${container_name}$" --format '{{.Names}}' | grep -q .; then
        log_error "PostgreSQL container ('${container_name}') does not exist."
        POSTGRES_STATUS="FAIL"
        return
    else
        log_success "PostgreSQL container ('${container_name}') exists."
    fi

    # Check Container Status
    local status
    status=$(sudo docker ps --filter "name=^/${container_name}$" --format '{{.Status}}' || true)
    if [[ "$status" == "Up"* ]]; then
        log_success "PostgreSQL container ('${container_name}') is running."
    else
        log_error "PostgreSQL container ('${container_name}') is NOT running. (Status: ${status:-'Not running or does not exist'})"
        POSTGRES_STATUS="FAIL"
    fi

    # Check Service Readiness (only if container is running)
    if [[ "$status" == "Up"* ]]; then
        # Guard with `|| true` in case container logs are empty or it exits
        local logs
        logs=$(sudo docker logs "$container_name" --tail 50 2>&1 || true)
        if echo "$logs" | grep -q "database system is ready to accept connections"; then
            log_success "PostgreSQL service is ready to accept connections."
        else
            log_error "PostgreSQL service is not yet ready."
            POSTGRES_STATUS="FAIL"
        fi
    fi

    # Display Container Logs (Error Focused)
    echo "  -> Health Check for ${container_name} Logs:"
    local all_logs
    all_logs=$(sudo docker logs "$container_name" --tail 100 2>&1 || true)
    local error_logs
    error_logs=$(echo "$all_logs" | grep -iE "ERROR|FATAL|PANIC" || true)
    if [ -n "$error_logs" ]; then
        log_warning "Found lines with potential error keywords in '${container_name}':"
        echo "$error_logs" | sed -E "s/(ERROR|FATAL|PANIC)/${RED}\1${NC}/gi"
        POSTGRES_STATUS="FAIL" # Finding critical errors is a failure
    else
        log_success "No recent critical errors found in '${container_name}' logs."
        echo "    Last 10 log lines:"
        echo "$all_logs" | tail -n 10 | sed 's/^/    /'
    fi
}

check_odoo_component() {
    echo -e "\n${BLUE}--- Component: Odoo ---${NC}"
    local container_name="$ODOO_CONTAINER_NAME"
    # Assume PASS until a check fails
    ODOO_STATUS="PASS"

    # Check Container Existence
    if ! sudo docker ps -a --filter "name=^/${container_name}$" --format '{{.Names}}' | grep -q .; then
        log_error "Odoo container ('${container_name}') does not exist."
        ODOO_STATUS="FAIL"
        return
    else
        log_success "Odoo container ('${container_name}') exists."
    fi

    # Check Container Status
    local status
    status=$(sudo docker ps --filter "name=^/${container_name}$" --format '{{.Status}}' || true)
    if [[ "$status" == "Up"* ]]; then
        log_success "Odoo container ('${container_name}') is running."
    else
        log_error "Odoo container ('${container_name}') is NOT running. (Status: ${status:-'Not running or does not exist'})"
        ODOO_STATUS="FAIL"
    fi

    # Check Service Readiness (only if container is running)
    if [[ "$status" == "Up"* ]]; then
        local logs
        logs=$(sudo docker logs "$container_name" --tail 50 2>&1 || true)
        if echo "$logs" | grep -q "werkzeug: Running on http://0.0.0.0:8069/"; then
            log_success "Odoo HTTP service is running and bound to port 8069."
        else
            log_error "Odoo HTTP service has not started yet."
            ODOO_STATUS="FAIL"
        fi
    fi

    # Display Container Logs (Error Focused)
    echo "  -> Health Check for ${container_name} Logs:"
    local all_logs
    all_logs=$(sudo docker logs "$container_name" --tail 100 2>&1 || true)
    local error_logs
    error_logs=$(echo "$all_logs" | grep -iE "ERROR|WARNING|FAIL|CRITICAL" || true)
    if [ -n "$error_logs" ]; then
        log_warning "Found lines with potential error keywords in '${container_name}':"
        echo "$error_logs" | sed -E "s/(ERROR|WARNING|FAIL|CRITICAL)/${RED}\1${NC}/gi"
        # A warning might not be a hard fail, but an error is.
        if echo "$error_logs" | grep -qiE "ERROR|FAIL|CRITICAL"; then
            ODOO_STATUS="FAIL"
        fi
    else
        log_success "No recent errors or warnings found in '${container_name}' logs."
        echo "    Last 10 log lines:"
        echo "$all_logs" | tail -n 10 | sed 's/^/    /'
    fi
}

print_summary_report() {
    echo -e "\n${BLUE}--- Final Summary ---${NC}"

    print_status_line() {
        local component=$1
        local status=$2
        local color
        if [ "$status" == "PASS" ]; then
            color=$GREEN
        else
            color=$RED
        fi
        printf "%-15s: ${color}%s${NC}\n" "$component" "$status"
    }

    print_status_line "Docker" "$DOCKER_STATUS"
    print_status_line "PostgreSQL" "$POSTGRES_STATUS"
    print_status_line "Odoo" "$ODOO_STATUS"
}

run_status_check() {
    log_info "Running in Status Check mode..."

    if [ ! -f "setup.conf" ]; then
        log_error "Configuration file 'setup.conf' not found. Cannot check status."
        log_info "Please run the script without arguments first to create the configuration."
        exit 1
    fi
    # shellcheck source=/dev/null
    source "setup.conf"

    check_docker_component
    check_postgres_component
    check_odoo_component
    print_summary_report
}

# --- Original Setup Functions ---

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
        DB_PASSWORD=$(openssl rand -base64 16)
        ODOO_MASTER_PASSWORD=$(openssl rand -base64 16)
        BASE_PATH_DEFAULT="$HOME/odoo-data"

        cat > "$CONFIG_FILE" << EOF
# --- Configuration Variables ---
ODOO_VERSION="18.0"
ODOO_CONTAINER_NAME="odoo"
DB_CONTAINER_NAME="db"
DB_USER="odoo"
DB_PASSWORD="${DB_PASSWORD}"
ODOO_MASTER_PASSWORD="${ODOO_MASTER_PASSWORD}"
ODOO_PORT="8069"
ODOO_NETWORK="odoo-net"

# --- Paths ---
BASE_PATH="${BASE_PATH_DEFAULT}"
ODOO_ADDONS_PATH="${BASE_PATH_DEFAULT}/addons"
ODOO_CONFIG_PATH="${BASE_PATH_DEFAULT}/config"
DB_DATA_PATH="${BASE_PATH_DEFAULT}/postgres"
BACKUP_PATH="${BASE_PATH_DEFAULT}/backups"
EOF
        log_success "New 'setup.conf' created with secure, random passwords."
        chmod 600 "$CONFIG_FILE"
        log_success "Set permissions for '$CONFIG_FILE' to 600 (read/write for owner only)."
        log_warning "Please review 'setup.conf' and store the passwords in a safe place."
    fi

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

        cat >> ~/.bashrc << EOF
# Odoo Backup Function
# Generated by Odoo setup script
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
    # Argument parsing for status mode
    if [[ "$#" -gt 0 && ( "$1" == "--status" || "$1" == "status" ) ]]; then
        run_status_check
        exit 0
    fi

    # Default setup logic
    log_info "Starting Odoo Setup..."
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

# Run the main function with all passed arguments
main "$@"
