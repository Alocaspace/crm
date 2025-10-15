#!/bin/bash
set -e

echo "🔧 Installing Bench CLI..."
pip install frappe-bench

cd /home/frappe

if [ -d "frappe-bench" ]; then
    echo "⚙️ Bench already exists, skipping init."
else
    echo "🚀 Creating new Frappe bench..."
    bench init --skip-redis-config-generation frappe-bench --version version-15
fi

cd frappe-bench

# Configure DB and Redis hosts for container networking
bench set-mariadb-host mariadb
bench set-redis-cache-host redis://redis:6379
bench set-redis-queue-host redis://redis:6379
bench set-redis-socketio-host redis://redis:6379

# Clean out unnecessary dev processes
sed -i '/redis/d' ./Procfile || true
sed -i '/watch/d' ./Procfile || true

# Install your app if missing
if [ ! -d "apps/crm" ]; then
    bench get-app crm https://github.com/Alocaspace/crm.git --branch main
fi

# Create site if missing
if [ ! -d "sites/crm.localhost" ]; then
    bench new-site crm.localhost \
        --force \
        --mariadb-root-password 123 \
        --admin-password admin \
        --no-mariadb-socket
    bench --site crm.localhost install-app crm
fi

# Basic configs
bench --site crm.localhost set-config developer_mode 0
bench --site crm.localhost set-config mute_emails 1
bench --site crm.localhost set-config server_script_enabled 1
bench --site crm.localhost clear-cache
bench use crm.localhost

# --- Install and configure Supervisor ---
echo "📦 Installing Supervisor..."
apt update && apt install -y supervisor

echo "⚙️ Generating Supervisor config..."
bench setup supervisor

cp /home/frappe/frappe-bench/config/supervisor.conf /etc/supervisor/conf.d/frappe-bench.conf

# Remove redis programs and groups (external redis is used)
sed -i '/\[program:frappe-bench-redis-/,/^$/d' /etc/supervisor/conf.d/frappe-bench.conf || true
sed -i '/\[group:frappe-bench-redis\]/,/^$/d' /etc/supervisor/conf.d/frappe-bench.conf || true

# --- Start Supervisor in foreground ---
echo "🚀 Starting Frappe via Supervisor..."
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf

