#!/bin/bash
# Install WordPress on Ubuntu 22.04 server by cecep-91


# Check root privileges
check_root() {
  if [ "$(whoami)" != "root" ]; then
    echo "You do not have root privileges, run it with sudo or as root."
    exit 1
  fi
}


# Check internet connection
check_internet_connection() {
  local internet_connection
  internet_connection=$(ping -c 1 8.8.8.8 &> /dev/null && echo "true" || echo "false")

  if [[ "$internet_connection" == "false" ]]; then
    echo "No internet connection, try again later."
    exit 2
  fi
}

# Install required packages
install_packages() {
  local packages
  packages=(
    mariadb-server
    mariadb-client
    apache2
    php
    php-curl
    php-gd
    php-mbstring
    php-xml
    php-xmlrpc
    php-soap
    libapache2-mod-php
    php-mysql
    wget
    unzip
  )

  echo "Installing ${packages[*]}..."

  apt-get install "${packages[@]}" -y
}

# Set up LAMP stack
setup_lamp() {
    local root_password="$1"
    local database_name="$2"
    local db_username="$3"
    local db_password="$4"

    echo "Configuring LAMP stack..."

    # Start and enable Apache
    systemctl start apache2 &> /dev/null
    systemctl enable apache2 &> /dev/null

    # Configure MariaDB
    mysql --user="root" --password="$root_password" --execute="CREATE DATABASE ${database_name};" &> /dev/null
    mysql --user="root" --password="$root_password" --execute="CREATE USER '${db_username}'@'localhost' IDENTIFIED BY '${db_password}';" &> /dev/null
    mysql --user="root" --password="$root_password" --execute="GRANT ALL PRIVILEGES ON ${database_name}.* TO '${db_username}'@'localhost';" &> /dev/null
    mysql --user="root" --password="$root_password" --execute="FLUSH PRIVILEGES;" &> /dev/null
}

# Download and configure WordPress
download_and_configure_wordpress() {
  local today="$1"
  
  local wordpress_dir
  local backup_dir
  local tarball

  today=$(date +'%Y%m%d')
  tarball="/var/www/html/${today}/latest.tar.gz"
  wordpress_dir="/var/www/html/${today}/wordpress/"
  backup_dir="${wordpress_dir}../old_wordpress/"

  mkdir -p /var/www/html/"${today}"
  echo "Downloading WordPress..."
  
  if [ -f "$tarball" ]; then
    echo "Removing old file..."
    rm "$tarball"
  fi
  
  if [ -d "$wordpress_dir" ]; then
    echo "Existing WordPress files found, making a backup..."
    rm -R "$backup_dir" &>> /dev/null
    mv "$wordpress_dir" "$backup_dir"
  fi
  
  wget -q --show-progress -P "/var/www/html/${today}" "http://wordpress.org/latest.tar.gz"
  
  echo "Configuring WordPress..."
  tar -xvzf "$tarball" -C "/var/www/html/${today}/" >> /dev/null
  mv "${wordpress_dir}wp-config-sample.php" "${wordpress_dir}wp-config.php"
  
  configure_wordpress_db_settings "$wordpress_dir" "$2" "$3" "$4"
}

configure_wordpress_db_settings() {
  local wordpress_dir="$1"
  local database_name="$2"
  local db_username="$3"
  local db_password="$4"
  
  local db_name_line_number
  local db_user_line_number
  local db_password_line_number
  
  db_name_line_number=$(grep -n "DB_NAME" "${wordpress_dir}wp-config.php" | cut -d: -f1)
  db_user_line_number=$(grep -n "DB_USER" "${wordpress_dir}wp-config.php" | cut -d: -f1)
  db_password_line_number=$(grep -n "DB_PASSWORD" "${wordpress_dir}wp-config.php" | cut -d: -f1)
  
  sed -i "${db_name_line_number}s/define.*$/define( 'DB_NAME', '${database_name}' );/" "${wordpress_dir}wp-config.php"
  sed -i "${db_user_line_number}s/define.*$/define( 'DB_USER', '${db_username}' );/" "${wordpress_dir}wp-config.php"
  sed -i "${db_password_line_number}s/define.*$/define( 'DB_PASSWORD', '${db_password}' );/" "${wordpress_dir}wp-config.php"
  
  chown -R www-data:www-data "$wordpress_dir"
  chmod -R 775 "$wordpress_dir"
}

# Create Virtual Host for WordPress
create_virtual_host() {
  local today="$1"
  local server_name="$2"
  local wordpress_port="$3"
  
  local virtual_host_file
  local virtual_host_filename
  local alternate_virtual_host
  local wordpress_dir

  alternate_virtual_host=1
  wordpress_dir="/var/www/html/${today}/wordpress/"

  while [ -f "/etc/apache2/sites-available/wordpress${alternate_virtual_host}.conf" ]; do
    alternate_virtual_host=$((alternate_virtual_host + 1))
  done

  virtual_host_filename="wordpress${alternate_virtual_host}.conf"
  virtual_host_file="/etc/apache2/sites-available/${virtual_host_filename}"

  # Create Virtual Host configuration
  cat <<EOF > "$virtual_host_file"
<VirtualHost *:${wordpress_port}>
  ServerAdmin webmaster@${server_name}
  DocumentRoot ${wordpress_dir}
  ServerName ${server_name}

  <Directory ${wordpress_dir}>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
  </Directory>

  ErrorLog \${APACHE_LOG_DIR}/wordpress_error.log
  CustomLog \${APACHE_LOG_DIR}/wordpress_access.log combined
</VirtualHost>
EOF

  # Disable other sites and enable WordPress site
  for site in /etc/apache2/sites-enabled/*; do
    a2dissite "$(basename "$site")"
  done

  a2ensite "$virtual_host_filename"
  a2enmod rewrite
  systemctl restart apache2
}

### MAIN SCRIPT ###
main() {
  check_root
  check_internet_connection

  # Add Maria-DB repository
  curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | bash

  # Get mySQL root password
  local mysql_root_password
  while true; do
    read -r -p "Enter your Maria-DB's root password (Leave it blank if you haven't configured it before): " mysql_root_password

    mysql --user="root" --password="$mysql_root_password" --execute="SHOW DATABASES;" &>> /dev/null

    if ! dpkg -l | grep -E 'mysql-server|mariadb-server' &>> /dev/null; then
      skip_checking_mysql=1
      break
    else
      if ! mysql --user="root" --password="$mysql_root_password" --execute="SHOW DATABASES;" &>> /dev/null; then
        echo "Can't access Maria-DB server, check again your password."
        exit 5
      else
        break
      fi
    fi

  done

  # Get database name for Maria-DB user
  local database_name
  while true; do
    read -r -p "Database name for Wordpress: " database_name

    # Check null input
    if [ -z "$database_name" ]; then
      continue
    fi

    # Check duplicated database
    if [ -n "$skip_checking_mysql" ]; then
      break
    fi

    if mysql --user="root" --password="$mysql_root_password" --execute="USE $database_name;" &>> /dev/null; then
      echo "There is already database named '$database_name', enter something else."
    else
      break
    fi
  done

  # Get username for Maria-DB user
  local mysql_username
  while true; do
    read -r -p "Username Maria-DB for Wordpress: " mysql_username

    # Check null input
    if [ -z "$mysql_username" ]; then
      continue
    fi

    if [ -n "$skip_checking_mysql" ]; then
      break
    fi

    result=$(mysql --user="root" --password="$mysql_root_password" --execute="SELECT User FROM mysql.user WHERE User='$mysql_username';" 2>&1)
    if [[ "$result" == *"User"* ]]; then
      echo "There is already username named '$mysql_username', enter something else."
    else
      break
    fi
  done

  # Get password for Maria-DB user
  local mysql_password
  while true; do
    read -r -s -p "Maria-DB's password for user '$mysql_username': " mysql_password
    echo ""

    read -r -s -p "Confirm your password: " mysql_confirm_password
    echo ""

    if [ "$mysql_password" != "$mysql_confirm_password" ]; then
      echo "Your password is not matched. Try again ..."
    else
      break
    fi
  done

  # Get server name
  local server_name
  read -r -p "Server name: " server_name

  if [ -z "$server_name" ]; then
    server_name='localhost'
  fi

  # Get wordpress port
  local wordpress_port
  read -r -p "Wordpress port: " wordpress_port

  if [ -z "$wordpress_port" ]; then
    wordpress_port='80'
  fi

  local today
  today=$(date +'%Y%m%d')

  # Update the Ubuntu server
  apt update

  install_packages

  setup_lamp "$mysql_root_password" "$database_name" "$mysql_username" "$mysql_password"

  download_and_configure_wordpress "$today" "$database_name" "$mysql_username" "$mysql_password"

  create_virtual_host "$today" "$server_name" "$wordpress_port"

  # Let the user check the webserver
  echo "Installation finished. Visit the following IP in your web browser:"
  hostname --all-ip-addresses
  echo "Or your domain: $server_name"
}

main