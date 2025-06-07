#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get current user and home directory BEFORE any root operations
if [ "$EUID" -eq 0 ]; then
    # If running as root, get the original user from SUDO_USER
    if [ -n "$SUDO_USER" ]; then
        CURRENT_USER="$SUDO_USER"
    else
        # If not running with sudo, get the user who invoked sudo
        CURRENT_USER=$(logname 2>/dev/null || echo "${SUDO_USER:-${USER}}")
    fi
else
    CURRENT_USER="$USER"
fi

# Get the home directory for the current user
CURRENT_USER_HOME=$(eval echo ~$CURRENT_USER)

# Verify we have a valid user and home directory
if [ -z "$CURRENT_USER" ] || [ ! -d "$CURRENT_USER_HOME" ]; then
    echo "Error: Could not determine current user or home directory"
    exit 1
fi

# Logging function
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

# Error handling
set -e
trap 'last_command=$current_command; current_command=$BASH_COMMAND' DEBUG
trap 'if [ $? -ne 0 ]; then log "ERROR" "Command failed: $last_command"; exit 1; fi' EXIT

# Check if command needs sudo
needs_sudo() {
    local cmd=$1
    case $cmd in
        apt|apt-get|dpkg|systemctl|update-alternatives|add-apt-repository)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Run command with sudo if needed
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

# Define PHP versions and common extensions
PHP_VERSIONS=("7.4" "8.0" "8.1" "8.2" "8.3")
PHP_EXTENSIONS=("cli" "fpm" "mysql" "xml" "curl" "gd" "mbstring" "zip" "intl" "bcmath" "readline" "soap" "redis" "memcached" "xdebug")

# System dependencies
SYSTEM_PACKAGES=(
    "unzip" "git" "curl" "zip" "libzip-dev" "libpng-dev"
    "libonig-dev" "libxml2-dev" "libicu-dev" "software-properties-common"
    "libmemcached-dev" "libssl-dev" "libcurl4-openssl-dev"
)

# Backup function
backup_config() {
    local config_file=$1
    if [ -f "$config_file" ]; then
        local backup_file="${config_file}.bak.$(date +%Y%m%d_%H%M%S)"
        log "INFO" "Backing up $config_file to $backup_file"
        cp "$config_file" "$backup_file"
    fi
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log "ERROR" "This script must be run as root or with sudo"
    log "INFO" "Please run: sudo $0"
    exit 1
fi

# System update and dependency installation
log "INFO" "Updating system packages..."
run_cmd apt update
run_cmd apt install -y "${SYSTEM_PACKAGES[@]}" || {
    log "ERROR" "Failed to install system dependencies"
    exit 1
}

# Add PHP PPA
if ! grep -q "ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
    log "INFO" "Adding PHP PPA..."
    run_cmd add-apt-repository -y ppa:ondrej/php
    run_cmd apt update
fi

# Install Composer
install_composer() {
    if ! command -v composer &> /dev/null; then
        log "INFO" "Installing Composer..."
        # Install composer for current user
        run_cmd curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
        # Set proper permissions
        run_cmd chown $CURRENT_USER:$CURRENT_USER /usr/local/bin/composer
        run_cmd chmod +x /usr/local/bin/composer
        # Configure composer for current user
        su - $CURRENT_USER -c "composer config -g disable-tls true"
        su - $CURRENT_USER -c "composer config -g secure-http false"
    else
        log "SUCCESS" "Composer already installed"
    fi
}

# Install PHP versions with extensions
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

        # Configure PHP
        backup_config "/etc/php/$version/cli/php.ini"
        backup_config "/etc/php/$version/fpm/php.ini"

        # Set common PHP settings
        sed -i 's/memory_limit = .*/memory_limit = 512M/' "/etc/php/$version/cli/php.ini"
        sed -i 's/upload_max_filesize = .*/upload_max_filesize = 64M/' "/etc/php/$version/cli/php.ini"
        sed -i 's/post_max_size = .*/post_max_size = 64M/' "/etc/php/$version/cli/php.ini"

        # Set proper permissions for PHP-FPM
        if [ -d "/etc/php/$version/fpm/pool.d" ]; then
            run_cmd chown -R $CURRENT_USER:$CURRENT_USER "/etc/php/$version/fpm/pool.d"
        fi

        # Restart PHP-FPM if installed
        if systemctl is-active --quiet "php$version-fpm"; then
            run_cmd systemctl restart "php$version-fpm"
        fi
    done
}

# Configure update-alternatives
configure_alternatives() {
    log "INFO" "Configuring update-alternatives..."
    run_cmd update-alternatives --remove-all php 2>/dev/null || true

    for version in "${PHP_VERSIONS[@]}"; do
        priority=$(echo $version | tr -d '.')
        php_path="/usr/bin/php$version"
        if [[ -f "$php_path" ]]; then
            run_cmd update-alternatives --install /usr/bin/php php "$php_path" "$priority"
        fi
    done
}

# Install Laravel installer
install_laravel() {
    if ! command -v laravel &> /dev/null; then
        log "INFO" "Installing Laravel installer..."
        su - $CURRENT_USER -c "composer global require laravel/installer"
        # Add composer bin to PATH for current user
        if ! grep -q 'composer/vendor/bin' "$CURRENT_USER_HOME/.zshrc"; then
            echo 'export PATH="$HOME/.config/composer/vendor/bin:$PATH"' >> "$CURRENT_USER_HOME/.zshrc"
        fi
    fi
}

# Install Symfony CLI
install_symfony() {
    if ! command -v symfony &> /dev/null; then
        log "INFO" "Installing Symfony CLI..."

        # Create temporary directory for installation
        local temp_dir=$(mktemp -d)
        cd "$temp_dir"

        # Download and install Symfony CLI
        run_cmd curl -sS https://get.symfony.com/cli/installer -o symfony_installer
        run_cmd chmod +x symfony_installer
        run_cmd ./symfony_installer --install-dir="$CURRENT_USER_HOME/.local/bin"

        # Clean up
        cd - > /dev/null
        rm -rf "$temp_dir"

        # Set proper permissions
        run_cmd chown $CURRENT_USER:$CURRENT_USER "$CURRENT_USER_HOME/.local/bin/symfony"
        run_cmd chmod +x "$CURRENT_USER_HOME/.local/bin/symfony"

        # Add to PATH if not already present
        if ! grep -q '.local/bin' "$CURRENT_USER_HOME/.zshrc"; then
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$CURRENT_USER_HOME/.zshrc"
        fi

        log "SUCCESS" "Symfony CLI installed successfully"
    else
        log "SUCCESS" "Symfony CLI already installed"
    fi
}

# Add helper functions to .zshrc
add_shell_functions() {
    log "INFO" "Adding shell functions to $CURRENT_USER_HOME/.zshrc..."

    # Create a temporary file for the new content
    local temp_file=$(mktemp)

    # Add the functions to the temporary file
    cat <<'EOF' > "$temp_file"

# PHP Helper Functions
# -------------------

# Check if command needs sudo
needs_sudo() {
    local cmd=$1
    case $cmd in
        apt|apt-get|dpkg|systemctl|update-alternatives|add-apt-repository)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Run command with sudo if needed
run_cmd() {
    local cmd=$1
    shift
    if needs_sudo "$cmd"; then
        sudo "$cmd" "$@"
    else
        "$cmd" "$@"
    fi
}

# PHP version switcher
function php_switch() {
    if [ -z "$1" ]; then
        echo "Usage: php_switch <version> (e.g. 8.2)"
        return 1
    fi
    run_cmd update-alternatives --set php /usr/bin/php$1 && php -v
}

# Create PHP framework project
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

# PHP service management
function php_service() {
    local action=$1
    local version=$2

    if [ -z "$action" ] || [ -z "$version" ]; then
        echo "Usage: php_service <start|stop|restart|status> <version>"
        return 1
    fi

    run_cmd systemctl $action php$version-fpm
}

# PHP extension management
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

# Make functions available
autoload -Uz php_switch php_project php_service php_extension
EOF

    # Backup existing .zshrc
    if [ -f "$CURRENT_USER_HOME/.zshrc" ]; then
        cp "$CURRENT_USER_HOME/.zshrc" "$CURRENT_USER_HOME/.zshrc.bak"
    fi

    # Append the new content to .zshrc if it doesn't already exist
    if ! grep -q "# PHP Helper Functions" "$CURRENT_USER_HOME/.zshrc"; then
        cat "$temp_file" >> "$CURRENT_USER_HOME/.zshrc"
        log "SUCCESS" "Added PHP helper functions to .zshrc"
    else
        log "INFO" "PHP helper functions already exist in .zshrc"
    fi

    # Clean up
    rm "$temp_file"

    # Set proper ownership of .zshrc
    run_cmd chown $CURRENT_USER:$CURRENT_USER "$CURRENT_USER_HOME/.zshrc"

    # Verify the functions were added
    if grep -q "function php_switch()" "$CURRENT_USER_HOME/.zshrc"; then
        log "SUCCESS" "PHP helper functions verified in .zshrc"
    else
        log "ERROR" "Failed to add PHP helper functions to .zshrc"
        # Restore backup if verification fails
        if [ -f "$CURRENT_USER_HOME/.zshrc.bak" ]; then
            mv "$CURRENT_USER_HOME/.zshrc.bak" "$CURRENT_USER_HOME/.zshrc"
            log "INFO" "Restored .zshrc from backup"
        fi
        exit 1
    fi

    # Remove backup if everything is successful
    rm -f "$CURRENT_USER_HOME/.zshrc.bak"
}

# Main execution
main() {
    log "INFO" "Starting PHP installation for user: $CURRENT_USER..."

    install_composer
    install_php_versions
    configure_alternatives
    install_laravel
    install_symfony
    add_shell_functions

    log "SUCCESS" "PHP installation completed successfully!"
    log "INFO" "Please run the following commands to complete the setup:"
    log "INFO" "  1. source ~/.zshrc"
    log "INFO" "  2. php_switch 8.2 (or your preferred version)"
    log "INFO" ""
    log "INFO" "Available commands:"
    log "INFO" "  php_switch <version>"
    log "INFO" "  php_project <laravel|cakephp|symfony>"
    log "INFO" "  php_service <start|stop|restart|status> <version>"
    log "INFO" "  php_extension <install|remove> <version> <extension>"
}

# Run main function
main

