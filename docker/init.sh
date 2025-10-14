#!/bin/bash
set -e

if [ -d "/home/frappe/frappe-bench/apps/frappe" ]; then
    echo "Bench already exists, skipping init"
else
    echo "Creating new bench..."
fi

bench init --skip-redis-config-generation frappe-bench --version version-15

cd frappe-bench

# Use containers instead of localhost
bench set-mariadb-host mariadb
bench set-redis-cache-host redis://redis:6379
bench set-redis-queue-host redis://redis:6379
bench set-redis-socketio-host redis://redis:6379

# Remove redis, watch from Procfile
sed -i '/redis/d' ./Procfile
sed -i '/watch/d' ./Procfile

bench get-app crm https://github.com/Alocaspace/crm.git --branch main

bench new-site crm.localhost \
    --force \
    --mariadb-root-password 123 \
    --admin-password admin \
    --no-mariadb-socket

bench --site crm.localhost install-app crm
bench --site crm.localhost set-config developer_mode 1
bench --site crm.localhost set-config mute_emails 1
bench --site crm.localhost set-config server_script_enabled 1
bench --site crm.localhost clear-cache
bench use crm.localhost

echo "Setting up production environment..."

# --- Install system dependencies ---
echo "Installing Nginx and Supervisor..."
apt-get update -qq
apt-get install -y nginx supervisor

# --- Setup production mode ---
echo "Setting up Frappe production environment..."
sudo bench setup production frappe --yes

# --- Ensure supervisor and nginx services are running ---
sudo service supervisor start
sudo service nginx start

# --- Restart all managed processes ---
sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl restart all

echo "✅ Frappe is running in production mode."
