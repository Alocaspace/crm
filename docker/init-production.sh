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

# --- Install Supervisor and Nginx ---
echo "📦 Installing Supervisor and Nginx..."
apt update && apt install -y supervisor nginx

# --- Generate Supervisor config ---
echo "⚙️ Setting up Supervisor..."
bench setup supervisor

# Replace 127.0.0.1 with 0.0.0.0 so Gunicorn listens on all interfaces
sed -i 's/127\.0\.0\.1:8000/0.0.0.0:8000/g' /home/frappe/frappe-bench/config/supervisor.conf
cp /home/frappe/frappe-bench/config/supervisor.conf /etc/supervisor/conf.d/frappe-bench.conf

# Remove redis programs (external Redis is used)
sed -i '/\[program:frappe-bench-redis-/,/^$/d' /etc/supervisor/conf.d/frappe-bench.conf || true
sed -i '/\[group:frappe-bench-redis\]/,/^$/d' /etc/supervisor/conf.d/frappe-bench.conf || true

# --- Generate Nginx config ---
echo "🌐 Setting up Nginx..."
bench setup nginx

# Enable the Frappe nginx site
cp /home/frappe/frappe-bench/config/nginx.conf /etc/nginx/conf.d/frappe-bench.conf

# Restart services
service nginx restart || true
supervisorctl reread || true
supervisorctl update || true
supervisorctl restart all || true

echo "✅ Frappe production environment is ready (Nginx + Supervisor running)."

# --- Start Supervisor in foreground ---
echo "🚀 Starting Supervisor (keeps container alive)..."
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
