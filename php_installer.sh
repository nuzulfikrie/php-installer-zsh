#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get current user and home directory BEFORE any root operations
if [ "$EUID" -eq 0 ]; then
    if [ -n "$SUDO_USER" ]; then
        CURRENT_USER="$SUDO_USER"
    else
        CURRENT_USER=$(logname 2>/dev/null || echo "${SUDO_USER:-${USER}}")
    fi
else
    CURRENT_USER="$USER"
fi

CURRENT_USER_HOME=$(eval echo ~"$CURRENT_USER")

if [ -z "$CURRENT_USER" ] || [ ! -d "$CURRENT_USER_HOME" ]; then
    echo "Error: Could not determine current user or home directory"
    exit 1
fi

# Detect which shell rc file to write to (bash vs zsh), instead of assuming zsh
if [ -n "$ZSH_VERSION" ] || [ -f "$CURRENT_USER_HOME/.zshrc" ]; then
    SHELL_RC="$CURRENT_USER_HOME/.zshrc"
else
    SHELL_RC="$CURRENT_USER_HOME/.bashrc"
fi

log() {
    local level=$1
    local message=$2
    local color=$NC
    case $level in
        "INFO") color=$BLUE ;;
        "SUCCESS") color=$GREEN ;;
        "WARNING") color=$YELLOW ;;
        "ERROR") color=$RED ;;
    esac
    echo -e "${color}[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message${NC}"
}

set -e
trap 'last_command=$current_command; current_command=$BASH_COMMAND' DEBUG
trap 'if [ $? -ne 0 ]; then log "ERROR" "Command failed: $last_command"; fi' EXIT

needs_sudo() {
    local cmd=$1
    case $cmd in
        apt|apt-get|dpkg|systemctl|update-alternatives|add-apt-repository|mysql_secure_installation)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

run_cmd() {
    local cmd=$1
    shift
    if needs_sudo "$cmd"; then
        if [ "$EUID" -ne 0 ]; then
            log "WARNING" "Command '$cmd' requires sudo privileges"
            return 1
        fi
    fi
    "$cmd" "$@"
}

# ---- Configurable options ----
PHP_VERSIONS=("7.4" "8.0" "8.1" "8.2" "8.3" "8.4" "8.5")
PHP_EXTENSIONS=("cli" "fpm" "mysql" "xml" "curl" "gd" "mbstring" "zip" "intl" "bcmath" "readline" "soap" "redis" "memcached" "xdebug")

# Set to "yes"/"no" to control whether MariaDB gets installed and secured
INSTALL_MARIADB="${INSTALL_MARIADB:-yes}"
RUN_MYSQL_SECURE_INSTALL="${RUN_MYSQL_SECURE_INSTALL:-no}" # requires interactive input, off by default

SYSTEM_PACKAGES=(
    "unzip" "git" "curl" "zip" "libzip-dev" "libpng-dev"
    "libonig-dev" "libxml2-dev" "libicu-dev" "software-properties-common"
    "libmemcached-dev" "libssl-dev" "libcurl4-openssl-dev"
)

backup_config() {
    local config_file=$1
    if [ -f "$config_file" ]; then
        local backup_file="${config_file}.bak.$(date +%Y%m%d_%H%M%S)"
        log "INFO" "Backing up $config_file to $backup_file"
        cp "$config_file" "$backup_file"
    fi
}

if [ "$EUID" -ne 0 ]; then
    log "ERROR" "This script must be run as root or with sudo"
    log "INFO" "Please run: sudo $0"
    exit 1
fi

log "INFO" "Updating system packages..."
run_cmd apt update
run_cmd apt install -y "${SYSTEM_PACKAGES[@]}" || {
    log "ERROR" "Failed to install system dependencies"
    exit 1
}

# ---- PHP repository setup ----
# The ondrej/php PPA is being merged into packages.sury.org/php and, per its own
# notice, only reliably serves Jammy (22.04) and Noble (24.04) going forward.
# Anything newer (e.g. Resolute) 404s on the PPA, so use sury.org's repo directly
# for those, falling back to Noble packages as a last resort if the exact
# codename isn't published there yet either.
UBUNTU_CODENAME=$(lsb_release -sc 2>/dev/null || . /etc/os-release && echo "$VERSION_CODENAME")
PPA_SUPPORTED_CODENAMES=("jammy" "noble")

is_ppa_supported() {
    local codename=$1
    for c in "${PPA_SUPPORTED_CODENAMES[@]}"; do
        [ "$c" = "$codename" ] && return 0
    done
    return 1
}

add_sury_repo() {
    local codename=$1
    log "INFO" "Adding packages.sury.org repository for $codename..."
    run_cmd apt install -y apt-transport-https lsb-release ca-certificates curl
    run_cmd curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg
    echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $codename main" | run_cmd tee /etc/apt/sources.list.d/php.list > /dev/null
}

if ! grep -q "ondrej/php\|packages.sury.org" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
    if is_ppa_supported "$UBUNTU_CODENAME"; then
        log "INFO" "Adding PHP PPA (ondrej/php) for $UBUNTU_CODENAME..."
        run_cmd add-apt-repository -y ppa:ondrej/php
        run_cmd apt update
    else
        log "WARNING" "Ubuntu '$UBUNTU_CODENAME' is not (yet) covered by ondrej/php PPA — using packages.sury.org instead"
        add_sury_repo "$UBUNTU_CODENAME"
        if ! run_cmd apt update; then
            log "WARNING" "sury.org has no '$UBUNTU_CODENAME' packages yet — falling back to 'noble' packages (may be slightly behind, but installable on newer Ubuntu bases)"
            rm -f /etc/apt/sources.list.d/php.list
            add_sury_repo "noble"
            run_cmd apt update
        fi
    fi
fi

install_composer() {
    if ! command -v composer &> /dev/null; then
        log "INFO" "Installing Composer..."
        run_cmd curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
        run_cmd chown "$CURRENT_USER":"$CURRENT_USER" /usr/local/bin/composer
        run_cmd chmod +x /usr/local/bin/composer
        su - "$CURRENT_USER" -c "composer config -g disable-tls true"
        su - "$CURRENT_USER" -c "composer config -g secure-http false"
    else
        log "SUCCESS" "Composer already installed"
    fi
}

install_php_versions() {
    for version in "${PHP_VERSIONS[@]}"; do
        log "INFO" "Installing PHP $version..."
        packages=("php$version")
        for ext in "${PHP_EXTENSIONS[@]}"; do
            packages+=("php$version-$ext")
        done
        run_cmd apt install -y "${packages[@]}" || {
            log "ERROR" "Failed to install PHP $version"
            continue
        }

        backup_config "/etc/php/$version/cli/php.ini"
        backup_config "/etc/php/$version/fpm/php.ini"

        for ini in "/etc/php/$version/cli/php.ini" "/etc/php/$version/fpm/php.ini"; do
            if [ -f "$ini" ]; then
                sed -i 's/memory_limit = .*/memory_limit = 512M/' "$ini"
                sed -i 's/upload_max_filesize = .*/upload_max_filesize = 64M/' "$ini"
                sed -i 's/post_max_size = .*/post_max_size = 64M/' "$ini"
            fi
        done

        if [ -d "/etc/php/$version/fpm/pool.d" ]; then
            run_cmd chown -R "$CURRENT_USER":"$CURRENT_USER" "/etc/php/$version/fpm/pool.d"
        fi

        if systemctl is-active --quiet "php$version-fpm"; then
            run_cmd systemctl restart "php$version-fpm"
        fi
    done
}

configure_alternatives() {
    log "INFO" "Configuring update-alternatives..."
    run_cmd update-alternatives --remove-all php 2>/dev/null || true

    for version in "${PHP_VERSIONS[@]}"; do
        priority=$(echo "$version" | tr -d '.')
        php_path="/usr/bin/php$version"
        if [[ -f "$php_path" ]]; then
            run_cmd update-alternatives --install /usr/bin/php php "$php_path" "$priority"
        fi
    done
}

install_laravel() {
    if ! command -v laravel &> /dev/null; then
        log "INFO" "Installing Laravel installer..."
        su - "$CURRENT_USER" -c "composer global require laravel/installer"
        if ! grep -q 'composer/vendor/bin' "$SHELL_RC" 2>/dev/null; then
            echo 'export PATH="$HOME/.config/composer/vendor/bin:$PATH"' >> "$SHELL_RC"
        fi
    fi
}

install_symfony() {
    if ! command -v symfony &> /dev/null; then
        log "INFO" "Installing Symfony CLI..."
        local temp_dir=$(mktemp -d)
        cd "$temp_dir"

        run_cmd curl -sS https://get.symfony.com/cli/installer -o symfony_installer
        run_cmd chmod +x symfony_installer
        run_cmd ./symfony_installer --install-dir="$CURRENT_USER_HOME/.local/bin"

        cd - > /dev/null
        rm -rf "$temp_dir"

        run_cmd chown "$CURRENT_USER":"$CURRENT_USER" "$CURRENT_USER_HOME/.local/bin/symfony"
        run_cmd chmod +x "$CURRENT_USER_HOME/.local/bin/symfony"

        if ! grep -q '.local/bin' "$SHELL_RC" 2>/dev/null; then
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"
        fi

        log "SUCCESS" "Symfony CLI installed successfully"
    else
        log "SUCCESS" "Symfony CLI already installed"
    fi
}

# ---- NEW: MariaDB installation ----
install_mariadb() {
    if [ "$INSTALL_MARIADB" != "yes" ]; then
        log "INFO" "Skipping MariaDB installation (INSTALL_MARIADB=$INSTALL_MARIADB)"
        return
    fi

    if command -v mariadb &> /dev/null || command -v mysql &> /dev/null; then
        log "SUCCESS" "MariaDB/MySQL client already installed"
    else
        log "INFO" "Installing MariaDB server and client..."
        run_cmd apt install -y mariadb-server mariadb-client || {
            log "ERROR" "Failed to install MariaDB"
            return 1
        }
    fi

    # Make sure it's enabled and running
    run_cmd systemctl enable mariadb
    run_cmd systemctl start mariadb

    if systemctl is-active --quiet mariadb; then
        log "SUCCESS" "MariaDB service is running"
    else
        log "ERROR" "MariaDB service failed to start"
        return 1
    fi

    # Install php-mysql / mysqlnd bindings for every installed PHP version (already
    # covered by PHP_EXTENSIONS above, but double check here in case versions were
    # added/removed independently of the PHP loop)
    for version in "${PHP_VERSIONS[@]}"; do
        if command -v "php$version" &> /dev/null; then
            dpkg -s "php$version-mysql" &> /dev/null || run_cmd apt install -y "php$version-mysql" || true
        fi
    done

    if [ "$RUN_MYSQL_SECURE_INSTALL" = "yes" ]; then
        log "INFO" "Running mysql_secure_installation (interactive)..."
        run_cmd mysql_secure_installation
    else
        log "INFO" "Skipping mysql_secure_installation. Run 'sudo mysql_secure_installation' manually to harden the install (set root password, remove anonymous users, disable remote root login, remove test DB)."
    fi

    log "INFO" "MariaDB version: $(mariadb --version 2>/dev/null || mysql --version)"
}

add_shell_functions() {
    log "INFO" "Adding shell functions to $SHELL_RC..."

    local temp_file=$(mktemp)

    cat <<'EOF' > "$temp_file"

# PHP / MariaDB Helper Functions
# ------------------------------

needs_sudo() {
    local cmd=$1
    case $cmd in
        apt|apt-get|dpkg|systemctl|update-alternatives|add-apt-repository|mysql_secure_installation)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

run_cmd() {
    local cmd=$1
    shift
    if needs_sudo "$cmd"; then
        sudo "$cmd" "$@"
    else
        "$cmd" "$@"
    fi
}

function php_switch() {
    if [ -z "$1" ]; then
        echo "Usage: php_switch <version> (e.g. 8.2)"
        return 1
    fi
    run_cmd update-alternatives --set php /usr/bin/php$1 && php -v
}

function php_project() {
    case "$1" in
        laravel)
            laravel new my-laravel-app
            ;;
        cakephp)
            composer create-project --prefer-dist cakephp/app my-cake-app
            ;;
        symfony)
            symfony new my-symfony-app --webapp
            ;;
        *)
            echo "Usage: php_project <laravel|cakephp|symfony>"
            return 1
            ;;
    esac
}

function php_service() {
    local action=$1
    local version=$2
    if [ -z "$action" ] || [ -z "$version" ]; then
        echo "Usage: php_service <start|stop|restart|status> <version>"
        return 1
    fi
    run_cmd systemctl $action php$version-fpm
}

function php_extension() {
    local action=$1
    local version=$2
    local extension=$3
    if [ -z "$action" ] || [ -z "$version" ] || [ -z "$extension" ]; then
        echo "Usage: php_extension <install|remove> <version> <extension>"
        return 1
    fi
    run_cmd apt $action php$version-$extension
    run_cmd systemctl restart php$version-fpm
}

# MariaDB helper functions
function db_service() {
    local action=$1
    if [ -z "$action" ]; then
        echo "Usage: db_service <start|stop|restart|status>"
        return 1
    fi
    run_cmd systemctl $action mariadb
}

function db_shell() {
    local user=${1:-root}
    mariadb -u "$user" -p
}

function db_create() {
    local dbname=$1
    if [ -z "$dbname" ]; then
        echo "Usage: db_create <database_name>"
        return 1
    fi
    mariadb -u root -p -e "CREATE DATABASE IF NOT EXISTS \`$dbname\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
}

function db_list() {
    mariadb -u root -p -e "SHOW DATABASES;"
}

autoload -Uz php_switch php_project php_service php_extension db_service db_shell db_create db_list
EOF

    if [ -f "$SHELL_RC" ]; then
        cp "$SHELL_RC" "$SHELL_RC.bak"
    fi

    if ! grep -q "# PHP / MariaDB Helper Functions" "$SHELL_RC" 2>/dev/null; then
        cat "$temp_file" >> "$SHELL_RC"
        log "SUCCESS" "Added PHP/MariaDB helper functions to $SHELL_RC"
    else
        log "INFO" "Helper functions already exist in $SHELL_RC"
    fi

    rm "$temp_file"

    run_cmd chown "$CURRENT_USER":"$CURRENT_USER" "$SHELL_RC"

    if grep -q "function php_switch()" "$SHELL_RC"; then
        log "SUCCESS" "Helper functions verified in $SHELL_RC"
        rm -f "$SHELL_RC.bak"
    else
        log "ERROR" "Failed to add helper functions to $SHELL_RC"
        if [ -f "$SHELL_RC.bak" ]; then
            mv "$SHELL_RC.bak" "$SHELL_RC"
            log "INFO" "Restored $SHELL_RC from backup"
        fi
        exit 1
    fi
}

main() {
    log "INFO" "Starting PHP + MariaDB installation for user: $CURRENT_USER..."

    install_composer
    install_php_versions
    configure_alternatives
    install_laravel
    install_symfony
    install_mariadb
    add_shell_functions

    log "SUCCESS" "Installation completed successfully!"
    log "INFO" "Please run the following commands to complete the setup:"
    log "INFO" "  1. source $SHELL_RC"
    log "INFO" "  2. php_switch 8.2 (or your preferred version)"
    log "INFO" "  3. sudo mysql_secure_installation (if not already run)"
    log "INFO" ""
    log "INFO" "Available commands:"
    log "INFO" "  php_switch <version>"
    log "INFO" "  php_project <laravel|cakephp|symfony>"
    log "INFO" "  php_service <start|stop|restart|status> <version>"
    log "INFO" "  php_extension <install|remove> <version> <extension>"
    log "INFO" "  db_service <start|stop|restart|status>"
    log "INFO" "  db_shell [user]"
    log "INFO" "  db_create <database_name>"
    log "INFO" "  db_list"
}

main
