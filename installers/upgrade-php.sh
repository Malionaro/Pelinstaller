#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Project 'Pelinstaller'                                                             #
#                                                                                    #
# Copyright (C) 2018 - 2024, Vilhelm Prytz, <vilhelm@prytznet.se>                    #
# Copyright (C) 2021 - 2026, Matthew Jacob, <git@matthew.network>                    #
#                                                                                    #
#   This program is free software: you can redistribute it and/or modify             #
#   it under the terms of the GNU General Public License as published by             #
#   the Free Software Foundation, either version 3 of the License, or                #
#   (at your option) any later version.                                              #
#                                                                                    #
#   This program is distributed in the hope that it will be useful,                  #
#   but WITHOUT ANY WARRANTY; without even the implied warranty of                   #
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the                    #
#   GNU General Public License for more details.                                     #
#                                                                                    #
#   You should have received a copy of the GNU General Public License                #
#   along with this program.  If not, see <https://www.gnu.org/licenses/>.           #
#                                                                                    #
# https://github.com/Malionaro/Pelinstaller/blob/Production/LICENSE.md               #
#                                                                                    #
# This script is not associated with the official Pelican Project.                   #
# https://github.com/Malionaro/Pelinstaller                                          #
#                                                                                    #
######################################################################################

# Check if script is loaded, load if not or fail otherwise.
fn_exists() { declare -F "$1" >/dev/null; }
if ! fn_exists lib_loaded; then
  # shellcheck source=lib/lib.sh
  source /tmp/lib.sh 2>/dev/null || source <(curl -fsSL "${GIT_REPO_URL:-https://raw.githubusercontent.com/Malionaro/Pelinstaller/Production}"/lib/lib.sh)
  ! fn_exists lib_loaded && echo "* ERROR: Could not load lib script" && exit 1
fi

export TARGET_PHP="${TARGET_PHP:-8.5}"

# ----------------- Helper Functions ----------------- #
setup_php_repo() {
  output "Setting up PHP repositories for $OS $OS_VER .."

  case "$OS" in
  ubuntu)
    install_packages "software-properties-common apt-transport-https ca-certificates gnupg"
    add-apt-repository universe -y
    if curl -fsSL "https://ppa.launchpadcontent.net/ondrej/php/ubuntu/dists/${UBUNTU_CODENAME}/Release" >/dev/null; then
      LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
    else
      warning "Ondrej PHP PPA does not support ${UBUNTU_CODENAME}; trying default repositories."
    fi
    update_repos
    ;;
  debian)
    install_packages "dirmngr ca-certificates apt-transport-https lsb-release"
    curl -fsSL -o /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
    echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/php.list
    update_repos
    ;;
  almalinux | rocky)
    install_packages "epel-release http://rpms.remirepo.net/enterprise/remi-release-$OS_VER_MAJOR.rpm"
    dnf module reset -y php || true
    dnf module enable -y php:remi-"$TARGET_PHP"
    ;;
  esac

  success "PHP repositories configured!"
}

install_php_packages() {
  output "Installing PHP $TARGET_PHP packages .."

  case "$OS" in
  debian | ubuntu)
    # Check if target PHP is available in repos
    if ! apt-cache show "php${TARGET_PHP}-fpm" >/dev/null 2>&1; then
      error "PHP ${TARGET_PHP} packages (php${TARGET_PHP}-fpm) are not available in the repositories for $OS $OS_VER."
      exit 1
    fi

    install_packages "php${TARGET_PHP} php${TARGET_PHP}-{cli,common,gd,intl,sqlite3,mysql,mbstring,bcmath,xml,fpm,curl,zip}"

    # Set default CLI php alternative if available
    if command -v update-alternatives >/dev/null 2>&1; then
      update-alternatives --set php /usr/bin/php"${TARGET_PHP}" 2>/dev/null || true
    fi
    ;;
  almalinux | rocky)
    install_packages "php php-{common,fpm,cli,json,intl,mysqlnd,mcrypt,gd,mbstring,pdo,zip,bcmath,dom,opcache,posix}"
    ;;
  esac

  success "PHP $TARGET_PHP packages installed!"
}

configure_php_fpm() {
  output "Configuring PHP-FPM service .."

  case "$OS" in
  debian | ubuntu)
    # Stop & disable older PHP-FPM services
    for old_ver in 7.4 8.0 8.1 8.2 8.3 8.4 8.5; do
      if [ "$old_ver" != "$TARGET_PHP" ]; then
        if systemctl is-active --quiet "php${old_ver}-fpm" 2>/dev/null; then
          output "Stopping older php${old_ver}-fpm service .."
          systemctl stop "php${old_ver}-fpm" || true
          systemctl disable "php${old_ver}-fpm" || true
        fi
      fi
    done

    systemctl enable "php${TARGET_PHP}-fpm"
    systemctl restart "php${TARGET_PHP}-fpm"
    ;;
  almalinux | rocky)
    systemctl enable php-fpm
    systemctl restart php-fpm
    ;;
  esac

  success "PHP-FPM service configured!"
}

update_nginx_config() {
  output "Updating Nginx configuration for PHP $TARGET_PHP .."

  case "$OS" in
  debian | ubuntu)
    local target_socket="/run/php/php${TARGET_PHP}-fpm.sock"

    for conf in /etc/nginx/sites-available/pelican.conf /etc/nginx/conf.d/pelican.conf; do
      if [ -f "$conf" ]; then
        output "Updating PHP socket in $conf .."
        sed -i -E "s@unix:/run/php/php[0-9.]+-fpm\.sock@unix:${target_socket}@g" "$conf"
        sed -i -E "s@unix:/var/run/php/php[0-9.]+-fpm\.sock@unix:${target_socket}@g" "$conf"
      fi
    done
    ;;
  almalinux | rocky)
    # On RHEL/Alma/Rocky, socket is unified via www-pelican.conf (/var/run/php-fpm/pelican.sock)
    output "Nginx uses unified php-fpm socket on $OS."
    ;;
  esac

  if nginx -t; then
    systemctl restart nginx
    success "Nginx reloaded successfully!"
  else
    warning "Nginx configuration test failed. Please check /etc/nginx/ configuration manually."
  fi
}

refresh_pelican() {
  output "Clearing and rebuilding Pelican caches .."

  if [ -d "/var/www/pelican" ]; then
    cd /var/www/pelican

    # Clear old caches
    php artisan optimize:clear || true
    php artisan view:clear || true
    php artisan config:clear || true
    php artisan route:clear || true

    # Fix file permissions
    case "$OS" in
    debian | ubuntu)
      chown -R www-data:www-data /var/www/pelican
      ;;
    almalinux | rocky)
      chown -R nginx:nginx /var/www/pelican
      ;;
    esac

    # Restart queue worker if present
    if systemctl is-active --quiet pelican-queue 2>/dev/null || systemctl is-enabled --quiet pelican-queue 2>/dev/null; then
      output "Restarting pelican-queue service .."
      systemctl restart pelican-queue || true
    fi

    success "Pelican cache and queue refreshed!"
  else
    warning "/var/www/pelican not found. Skipping artisan cache clear."
  fi
}

# ----------------- Main Execution ----------------- #
main() {
  welcome "panel"
  check_os_x86_64

  if [ ! -d "/var/www/pelican" ]; then
    warning "No Pelican panel installation found at /var/www/pelican."
    echo -e -n "* Do you still want to proceed with PHP upgrade? (y/N): "
    read -r CONFIRM_PROCEED || true
    if [[ ! "$CONFIRM_PROCEED" =~ [Yy] ]]; then
      error "Upgrade aborted."
      exit 1
    fi
  fi

  echo -n "* Target PHP version [$TARGET_PHP]: "
  read -r input_php || true
  [ -n "$input_php" ] && TARGET_PHP="$input_php"

  print_brake 62
  output "Upgrading PHP for Pelican Panel to PHP $TARGET_PHP on $OS $OS_VER"
  print_brake 62

  echo -e -n "* Continue with PHP upgrade? (y/N): "
  read -r CONFIRM || true
  if [[ ! "$CONFIRM" =~ [Yy] ]]; then
    error "Upgrade aborted."
    exit 1
  fi

  setup_php_repo
  install_php_packages
  configure_php_fpm
  update_nginx_config
  refresh_pelican

  print_brake 62
  success "PHP upgrade to $TARGET_PHP completed successfully!"
  output "Active CLI PHP version: $(php -v 2>/dev/null | head -n 1)"
  print_brake 62
}

main
