#!/bin/bash

# =================================================================================================
# Production-Ready Script for setting up Docker, PostgreSQL, and Odoo on Ubuntu
# =================================================================================================
# This script automates the following tasks:
# 1.  Checks for prerequisites (Ubuntu version, Docker service).
# 2.  Installs Docker and Docker Compose.
# 3.  Creates configuration files (`setup.conf`, `.env`, `docker-compose.yml`).
# 4.  Adds the current user to the 'docker' group.
# 5.  Creates necessary directories with secure permissions.
# 6.  Starts PostgreSQL and Odoo services using Docker Compose.
# 7.  Provides a function for easy database backups.
# 8.  Includes a 'status' mode to check the health of the services.
# =================================================================================================

# --- Script Execution Settings ---
set -euo pipefail

# --- Formatting Variables ---
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# --- Logging Functions ---
log_success() { echo -e "${GREEN}✅  $1${NC}"; }
log_error() { echo -e "${RED}❌  $1${NC}"; }
log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  WARNING: $1${NC}"; }

# --- Error Trap ---
on_error() {
    if [[ "${BASH_COMMAND}" != "exit 0" ]]; then
        log_error "Script failed on line $LINENO. Aborting."
    fi
}
trap 'on_error $LINENO' ERR

# --- Global Variables ---
COMPOSE_CMD=""

# --- Helper Functions ---
find_compose_command() {
    if [ -n "$COMPOSE_CMD" ]; then
        return
    fi
    if docker compose version &>/dev/null; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_CMD="docker-compose"
    else
        log_error "Cannot find a working Docker Compose command."
        exit 1
    fi
}

# --- Status Check Feature ---
DOCKER_STATUS="FAIL"
POSTGRES_STATUS="FAIL"
ODOO_STATUS="FAIL"

check_docker_component() {
    echo -e "\n${BLUE}--- Component: Docker Service ---${NC}"
    DOCKER_STATUS="PASS"
    if sudo systemctl is-active --quiet docker; then
        log_success "Docker service is active and running."
    else
        log_error "Docker service is NOT running."
        DOCKER_STATUS="FAIL"
    fi
    echo "  -> Last 20 Docker Service Logs:"
    sudo journalctl -u docker.service -n 20 --no-pager
}

check_compose_service_component() {
    local service_name=$1
    local readiness_check_string=$2
    local error_keywords=$3
    local component_name=$4
    local status_var_name=$5

    echo -e "\n${BLUE}--- Component: ${component_name} ---${NC}"
    declare -g "${status_var_name}=PASS"

    local status
    status=$($COMPOSE_CMD ps -q "$service_name" 2>/dev/null || echo "")
    if [ -z "$status" ]; then
        log_error "${component_name} service ('${service_name}') is not running or does not exist."
        declare -g "${status_var_name}=FAIL"
        return
    else
        log_success "${component_name} service ('${service_name}') is running."
    fi

    local logs
    logs=$($COMPOSE_CMD logs --tail 50 "$service_name" 2>&1 || true)
    if echo "$logs" | grep -q -E "$readiness_check_string"; then
        log_success "${component_name} service appears to be ready."
    else
        log_error "${component_name} service does not appear to be ready yet."
        declare -g "${status_var_name}=FAIL"
    fi

    echo "  -> Health Check for ${service_name} Logs:"
    local all_logs
    all_logs=$($COMPOSE_CMD logs --tail 100 "$service_name" 2>&1 || true)
    local error_logs
    error_logs=$(echo "$all_logs" | grep -iE "$error_keywords" || true)
    if [ -n "$error_logs" ]; then
        log_warning "Found lines with potential error keywords in '${service_name}':"
        echo "$error_logs" | sed -E "s/($error_keywords)/${RED}\1${NC}/gi"
        declare -g "${status_var_name}=FAIL"
    else
        log_success "No recent critical errors found in '${service_name}' logs."
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
        if [ "$status" == "PASS" ]; then color=$GREEN; else color=$RED; fi
        printf "%-15s: ${color}%s${NC}\n" "$component" "$status"
    }
    print_status_line "Docker" "$DOCKER_STATUS"
    print_status_line "PostgreSQL" "$POSTGRES_STATUS"
    print_status_line "Odoo" "$ODOO_STATUS"
}

run_status_check() {
    log_info "Running in Status Check mode..."
    find_compose_command
    if [ ! -f "docker-compose.yml" ]; then
        log_error "docker-compose.yml not found. Cannot check status."
        log_info "Please run the script without arguments first to create the configuration."
        exit 1
    fi
    check_docker_component
    check_compose_service_component "db" "database system is ready to accept connections" "ERROR|FATAL|PANIC" "PostgreSQL" "POSTGRES_STATUS"
    check_compose_service_component "odoo" "werkzeug: Running on http://0.0.0.0:8069/" "ERROR|WARNING|FAIL|CRITICAL" "Odoo" "ODOO_STATUS"
    print_summary_report
}

# --- Setup Functions ---

check_prerequisites() {
    log_info "Running prerequisite checks..."
    if ! grep -q "Ubuntu" /etc/os-release; then
        log_error "This script is intended for Ubuntu only."
        exit 1
    fi
    TOTAL_MEM=$(free -g | awk '/^Mem:/{print $2}')
    if [ "$TOTAL_MEM" -lt "2" ]; then
        log_warning "Less than 2GB of RAM detected."
    fi
    log_success "Prerequisite checks passed."
}

install_docker() {
    log_info "Handling Docker installation..."
    if ! command -v docker &>/dev/null; then
        log_info "Docker not found, installing..."
        sudo apt-get update
        sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io
    else
        log_info "Docker is already installed."
    fi
    if ! sudo systemctl is-active --quiet docker; then
        log_error "Docker service is not running."
        exit 1
    fi
    log_success "Docker is installed and service is active."
}

install_docker_compose() {
    log_info "Checking for Docker Compose..."
    find_compose_command
    if [ "$COMPOSE_CMD" == "docker compose" ]; then
        log_success "Docker Compose plugin is already installed."
        return
    fi
    if [ "$COMPOSE_CMD" == "docker-compose" ]; then
        log_success "Legacy docker-compose is installed."
        log_warning "Consider upgrading to the plugin."
        return
    fi
    log_info "Docker Compose not found. Installing the plugin..."
    sudo apt-get update
    sudo apt-get install -y docker-compose-plugin
    find_compose_command
    if [ "$COMPOSE_CMD" == "docker compose" ]; then
        log_success "Plugin installed successfully."
    else
        log_error "Failed to install plugin."
        exit 1
    fi
}

add_user_to_docker_group() {
    log_info "Checking Docker group permissions..."
    if ! getent group docker | grep -q "\b${USER}\b"; then
        log_info "Adding current user to 'docker' group..."
        sudo usermod -aG docker "${USER}"
        log_warning "You must log out and log back in for group changes to take effect."
    else
        log_info "User is already in the docker group."
    fi
    log_success "User permissions for Docker are set."
}

load_config() {
    log_info "Loading configuration..."
    CONFIG_FILE="setup.conf"
    if [ ! -f "$CONFIG_FILE" ]; then
        log_info "Configuration file not found. Creating default 'setup.conf'."
        DB_PASSWORD=$(openssl rand -base64 16)
        ODOO_MASTER_PASSWORD=$(openssl rand -base64 16)
        BASE_PATH_DEFAULT="$HOME/odoo-data"
        cat >"$CONFIG_FILE" <<EOF
ODOO_VERSION="18.0"
ODOO_CONTAINER_NAME="odoo_service"
DB_CONTAINER_NAME="db_service"
DB_USER="odoo"
DB_PASSWORD="${DB_PASSWORD}"
ODOO_MASTER_PASSWORD="${ODOO_MASTER_PASSWORD}"
ODOO_PORT="8069"
ODOO_NETWORK="odoo-net"
ODOO_CONFIG_FILE_PATH="${BASE_PATH_DEFAULT}/config/odoo.conf"
BASE_PATH="${BASE_PATH_DEFAULT}"
ODOO_ADDONS_PATH="${BASE_PATH_DEFAULT}/addons"
ODOO_CONFIG_PATH="${BASE_PATH_DEFAULT}/config"
DB_DATA_PATH="${BASE_PATH_DEFAULT}/postgres"
BACKUP_PATH="${BASE_PATH_DEFAULT}/backups"
EOF
        log_success "New 'setup.conf' created."
        chmod 600 "$CONFIG_FILE"
        log_success "Set permissions for '$CONFIG_FILE' to 600."
        log_warning "Please store passwords securely."
    fi
    source "$CONFIG_FILE"
    log_success "Configuration loaded from $CONFIG_FILE"
}

create_directories() {
    log_info "Creating and securing data directories..."
    mkdir -p "$ODOO_ADDONS_PATH" "$ODOO_CONFIG_PATH" "$DB_DATA_PATH" "$BACKUP_PATH"
    log_info "Updating addons folder ownership for container access..."
    sudo chown -R 101:101 "$ODOO_ADDONS_PATH"
    chmod 700 "$ODOO_ADDONS_PATH" "$ODOO_CONFIG_PATH" "$DB_DATA_PATH" "$BACKUP_PATH"
    log_success "Data directories created and secured."
}

create_odoo_config() {
    log_info "Checking for odoo.conf file..."
    if [ ! -f "$ODOO_CONFIG_FILE_PATH" ]; then
        log_info "Creating default odoo.conf file..."
        cat >"$ODOO_CONFIG_FILE_PATH" <<EOF
[options]
admin_passwd = ${ODOO_MASTER_PASSWORD}
db_host = db
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

create_docker_compose_file() {
    log_info "Creating docker-compose.yml file..."
    cat >docker-compose.yml <<EOF
version: '3.8'
services:
  db:
    image: postgres:15
    container_name: \${DB_CONTAINER_NAME}
    environment:
      - POSTGRES_USER=\${DB_USER}
      - POSTGRES_PASSWORD=\${DB_PASSWORD}
      - POSTGRES_DB=postgres
    restart: always
    volumes:
      - \${DB_DATA_PATH}:/var/lib/postgresql/data
    networks:
      - odoo-net
  odoo:
    image: odoo:\${ODOO_VERSION}
    container_name: \${ODOO_CONTAINER_NAME}
    depends_on:
      - db
    ports:
      - "\${ODOO_PORT}:8069"
    volumes:
      - \${ODOO_ADDONS_PATH}:/mnt/extra-addons
      - \${ODOO_CONFIG_FILE_PATH}:/etc/odoo/odoo.conf
    restart: always
    networks:
      - odoo-net
networks:
  odoo-net:
    name: \${ODOO_NETWORK}
EOF
    log_success "docker-compose.yml file created."
}

create_env_file() {
    log_info "Creating .env file from setup.conf..."
    if [ ! -f "setup.conf" ]; then
        log_error "setup.conf not found."
        exit 1
    fi
    grep -v -E '^\s*#|^\s*$' setup.conf | sed -e 's/"//g' >.env
    log_success ".env file created successfully."
}

start_services() {
    log_info "Starting services with Docker Compose..."
    find_compose_command
    $COMPOSE_CMD up -d
    log_success "Services started successfully."
}

configure_backup_function() {
    log_info "Configuring backup helper function..."
    if ! grep -q "backup_odoo_db" ~/.bashrc; then
        log_info "Adding 'backup_odoo_db' command to your .bashrc..."
        cat >>~/.bashrc <<EOF
backup_odoo_db() {
    local TIMESTAMP=\$(date +%Y%m%d_%H%M%S)
    if [ -f .env ]; then source .env; fi
    local BACKUP_FILE="\${BACKUP_PATH:-\$HOME/odoo-data/backups}/dump_\${TIMESTAMP}.sql"
    local DB_CONTAINER="\${DB_CONTAINER_NAME:-db_service}"
    local DB_USER_BACKUP="\${DB_USER:-odoo}"
    echo "Backing up Odoo database to \${BACKUP_FILE}.gz..."
    if ! docker exec "\${DB_CONTAINER}" pg_dumpall -U "\${DB_USER_BACKUP}" | gzip >"\${BACKUP_FILE}.gz"; then
        echo "Backup failed."; else echo "Backup complete!"; fi
}
EOF
        log_warning "Please run 'source ~/.bashrc' or open a new terminal to use the new backup command."
    fi
    log_success "Backup helper function configured."
}

print_final_instructions() {
    local ip_address
    ip_address=$(hostname -I | awk '{print $1}')
    echo ""
    echo "============================================================"
    echo "🎉 Odoo setup via Docker Compose is complete! 🎉"
    echo "============================================================"
    echo ""
    echo "You can access your Odoo instance at: http://${ip_address}:${ODOO_PORT}"
    echo ""
    echo "Your configuration is in 'setup.conf', '.env', and 'docker-compose.yml'."
    echo ""
    echo "Useful commands:"
    find_compose_command
    echo "  - To check service status: ${COMPOSE_CMD} ps"
    echo "  - To view logs: ${COMPOSE_CMD} logs -f odoo_service"
    echo "  - To stop services: ${COMPOSE_CMD} down"
    echo "  - To backup your database: backup_odoo_db (run 'source ~/.bashrc' first)"
    echo "============================================================"
}

# --- Main Execution ---
main() {
    if [[ "$#" -gt 0 && ( "$1" == "--status" || "$1" == "status" ) ]]; then
        run_status_check
        exit 0
    fi
    log_info "Starting Odoo Setup..."
    check_prerequisites
    install_docker
    install_docker_compose
    add_user_to_docker_group
    load_config
    create_directories
    create_odoo_config
    create_docker_compose_file
    create_env_file
    start_services
    configure_backup_function
    print_final_instructions
}

main "$@"
