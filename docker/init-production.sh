#!/bin/bash
set -e

echo "🔧 Installing Bench CLI..."
pip install frappe-bench

cd /home/frappe

# --- Initialize or reuse bench ---
if [ -d "frappe-bench" ]; then
    echo "⚙️ Bench already exists, skipping init."
else
    echo "🚀 Creating new Frappe bench..."
    bench init --skip-redis-config-generation frappe-bench --version version-15
fi

cd frappe-bench

# --- Configure DB and Redis hosts for container networking ---
bench set-mariadb-host mariadb
bench set-redis-cache-host redis://redis:6379
bench set-redis-queue-host redis://redis:6379
bench set-redis-socketio-host redis://redis:6379

# --- Clean out unnecessary dev processes ---
sed -i '/redis/d' ./Procfile || true
sed -i '/watch/d' ./Procfile || true

# --- Get app if missing ---
if [ ! -d "apps/crm" ]; then
    echo "📦 Cloning CRM app..."
    bench get-app crm https://github.com/Alocaspace/crm.git --branch main
fi

# --- Create site if missing ---
if [ ! -d "sites/crm.duiverse.com" ]; then
    echo "🌐 Creating new site crm.duiverse.com..."
    bench new-site crm.duiverse.com \
        --force \
        --mariadb-root-password 123 \
        --admin-password admin \
        --no-mariadb-socket
    bench --site crm.duiverse.com install-app crm
fi

# --- Basic site configs ---
bench --site crm.duiverse.com set-config developer_mode 0
bench --site crm.duiverse.com set-config mute_emails 1
bench --site crm.duiverse.com set-config server_script_enabled 1
bench --site crm.duiverse.com set-config host_name "https://crm.duiverse.com"
bench --site crm.duiverse.com set-config allow_hosts '["crm.duiverse.com", "localhost", "form_crm_frappe"]'
bench --site crm.duiverse.com clear-cache
bench use crm.duiverse.com

# ==============================================================
# 🧠 Prevent OOM issues during asset build (Add Swap)
# ==============================================================
echo "🧠 Setting up temporary 2 GB swap to prevent OOM during yarn build..."
if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
fi
free -h

# ==============================================================
# 🎨 Build and link assets for production
# ==============================================================

echo "🎨 Building Frappe assets for production..."
set +e
bench build --production
if [ $? -ne 0 ]; then
    echo "⚠️ Production build failed (likely memory). Retrying with normal build..."
    bench build
fi
set -e

echo "🧩 Collecting static assets..."
bench setup assets
bench clear-cache

# ==============================================================
# 🌐 Install and configure Supervisor + Nginx
# ==============================================================

echo "📦 Installing Supervisor and Nginx..."
apt update && apt install -y supervisor nginx

echo "⚙️ Setting up Supervisor..."
bench setup supervisor

# Replace localhost binding
sed -i 's/127\.0\.0\.1:8000/0.0.0.0:8000/g' /home/frappe/frappe-bench/config/supervisor.conf
cp /home/frappe/frappe-bench/config/supervisor.conf /etc/supervisor/conf.d/frappe-bench.conf

# Remove internal redis definitions
sed -i '/\[program:frappe-bench-redis-/,/^$/d' /etc/supervisor/conf.d/frappe-bench.conf || true
sed -i '/\[group:frappe-bench-redis\]/,/^$/d' /etc/supervisor/conf.d/frappe-bench.conf || true

# --- Generate Nginx config ---
echo "🌐 Setting up Nginx..."
bench setup nginx
cp /home/frappe/frappe-bench/config/nginx.conf /etc/nginx/conf.d/frappe-bench.conf

# Ensure correct asset path and permissions
chown -R frappe:frappe /home/frappe/frappe-bench
chmod -R 755 /home/frappe/frappe-bench/sites/assets

# Restart services
service nginx restart || true
supervisorctl reread || true
supervisorctl update || true
supervisorctl restart all || true

echo "✅ Frappe production environment is ready (Nginx + Supervisor running)."

# --- Keep container alive with Supervisor ---
echo "🚀 Starting Supervisor (keeps container alive)..."
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
