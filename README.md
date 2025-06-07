# PHP Installer Script

This script automates the installation and configuration of multiple PHP versions, Composer, Laravel, Symfony CLI, and useful PHP helper shell functions for a single user on Ubuntu (WSL2 compatible).

## Features

- Installs PHP 7.4, 8.0, 8.1, 8.2, 8.3 with common extensions
- Installs Composer globally for the current user
- Installs Laravel installer and Symfony CLI for the current user
- Adds helper shell functions to your `.zshrc`:
  - `php_switch <version>`: Switch PHP CLI version
  - `php_project <laravel|cakephp|symfony>`: Create new framework projects
  - `php_service <start|stop|restart|status> <version>`: Manage PHP-FPM services
  - `php_extension <install|remove> <version> <extension>`: Manage PHP extensions
- Ensures all user-specific tools and configs are installed in your home directory, not root
- Backs up `.zshrc` before modifying

## Requirements

- Ubuntu (tested on WSL2)
- `zsh` as your shell
- Run as root (with `sudo`)

## Usage

1. **Clone or copy the script to your machine:**
    ```sh
    cd ~/scripts
    ```

2. **Run the installer:**
    ```sh
    sudo ./php_installer.sh
    ```

3. **After installation, reload your shell:**
    ```sh
    source ~/.zshrc
    ```

4. **Use the helper functions:**
    ```sh
    php_switch 8.2
    php_project laravel
    php_service restart 8.2
    php_extension install 8.2 xdebug
    ```

## Notes

- The script will only modify the current user’s `.zshrc` and home directory.
- If you encounter issues, check the log output for errors.
- The script creates a backup of your `.zshrc` before making changes.

## Troubleshooting

- If the helper functions are not available, ensure you have sourced your `.zshrc`:
    ```sh
    source ~/.zshrc
    ```
- If you run the script as root without `sudo`, it may default to root’s home. Always use `sudo`.

## License

MIT

