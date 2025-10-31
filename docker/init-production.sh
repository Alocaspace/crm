#!/bin/bash
set -e

echo "🔧 Installing Bench CLI..."
pip install frappe-bench

cd /home/frappe

# ==============================================================
# 🚀 Initialize or reuse Bench
# ==============================================================
if [ -d "frappe-bench" ]; then
    echo "⚙️ Bench already exists, skipping init."
else
    echo "🚀 Creating new Frappe bench..."
    bench init --skip-redis-config-generation frappe-bench --version version-15
fi

cd frappe-bench

# ==============================================================
# 🔌 Connect to external MariaDB & Redis
# ==============================================================
bench set-mariadb-host mariadb
bench set-redis-cache-host redis://redis:6379
bench set-redis-queue-host redis://redis:6379
bench set-redis-socketio-host redis://redis:6379

# Remove dev processes from Procfile
sed -i '/redis/d' ./Procfile || true
sed -i '/watch/d' ./Procfile || true

# ==============================================================
# 📦 Get your app
# ==============================================================
if [ ! -d "apps/crm" ]; then
    echo "📥 Fetching CRM app..."
    bench get-app crm https://github.com/Alocaspace/crm.git --branch main
fi

# ==============================================================
# 🌐 Create site if missing
# ==============================================================
if [ ! -d "sites/crm.duiverse.com" ]; then
    echo "🌍 Creating site crm.duiverse.com..."
    bench new-site crm.duiverse.com \
        --force \
        --mariadb-root-password 123 \
        --admin-password admin \
        --no-mariadb-socket
    bench --site crm.duiverse.com install-app crm
fi

# ==============================================================
# ⚙️ Base Config
# ==============================================================
bench --site crm.duiverse.com set-config developer_mode 0
bench --site crm.duiverse.com set-config mute_emails 1
bench --site crm.duiverse.com set-config server_script_enabled 1
# Use http for local enviroment
#bench --site crm.duiverse.com set-config host_name "http://crm.duiverse.com"
bench --site crm.duiverse.com set-config host_name "https://crm.duiverse.com"
bench --site crm.duiverse.com set-config allow_hosts '["crm.duiverse.com", "localhost", "127.0.0.1"]'
bench --site crm.duiverse.com clear-cache
bench use crm.duiverse.com

# ==============================================================
# 🎨 Build & Link Assets
# ==============================================================
echo "🎨 Building production assets..."
set +e
bench build --production || bench build
set -e

echo "🧩 Ensuring /sites/assets folder is populated..."
mkdir -p /home/frappe/frappe-bench/sites/assets
bench setup assets || true
bench clear-cache || true

chown -R frappe:frappe /home/frappe/frappe-bench/sites
chmod -R 755 /home/frappe/frappe-bench/sites/assets

# ==============================================================
# 🌐 Setup Nginx + Supervisor
# ==============================================================
echo "📦 Installing Nginx and Supervisor..."
apt update && apt install -y nginx supervisor

# Supervisor setup
echo "⚙️ Configuring Supervisor..."
bench setup supervisor

# Change Gunicorn port to 8001 so Nginx can front it
sed -i 's/127\.0\.0\.1:8000/127.0.0.1:8001/g' /home/frappe/frappe-bench/config/supervisor.conf

# Make sure SocketIO runs on 9000 and listens on all interfaces
sed -i 's/node socketio.js$/node socketio.js --port 9000/' /home/frappe/frappe-bench/config/supervisor.conf

cp /home/frappe/frappe-bench/config/supervisor.conf /etc/supervisor/conf.d/frappe-bench.conf

# Remove redis workers (external redis used)
sed -i '/\[program:frappe-bench-redis-/,/^$/d' /etc/supervisor/conf.d/frappe-bench.conf || true
sed -i '/\[group:frappe-bench-redis\]/,/^$/d' /etc/supervisor/conf.d/frappe-bench.conf || true

# ==============================================================
# 🧩 Setup Nginx
# ==============================================================
echo "🌐 Generating and patching Nginx config..."
bench setup nginx

NGINX_CONF="/home/frappe/frappe-bench/config/nginx.conf"

# Force Nginx to listen on port 8000
sed -i 's/listen 80;/listen 8000;/' "$NGINX_CONF"

# Make sure it proxies Gunicorn correctly (running on 8001)
sed -i 's|proxy_pass http://127.0.0.1:8000;|proxy_pass http://127.0.0.1:8001;|' "$NGINX_CONF"

# Ensure static assets are served directly by Nginx
if ! grep -q "alias /home/frappe/frappe-bench/sites/assets;" "$NGINX_CONF"; then
    sed -i '/location \/assets {/a\    alias /home/frappe/frappe-bench/sites/assets;' "$NGINX_CONF"
fi

# Copy config to Nginx conf.d
cp "$NGINX_CONF" /etc/nginx/conf.d/frappe-bench.conf

# --------------------------------------------------------------
# ✅ Fix for missing "main" log format
# --------------------------------------------------------------
if ! grep -q "log_format main" /etc/nginx/nginx.conf; then
    echo "🧩 Adding missing 'main' log format to nginx.conf..."
    sed -i '/http {/a\    log_format main '\''$remote_addr - $remote_user [$time_local] "$request" '\''\n                      '\''$status $body_bytes_sent "$http_referer" '\''\n                      '\''"$http_user_agent" "$http_x_forwarded_for"'\'';' /etc/nginx/nginx.conf
fi

if grep -q "main" /etc/nginx/conf.d/frappe-bench.conf; then
    echo "🧹 Verifying 'main' log format references..."
    sed -i 's/ main;$/;/' /etc/nginx/conf.d/frappe-bench.conf
fi

# 🔧 Ensure upstream uses correct Gunicorn port (8001)
if grep -q "127.0.0.1:8000" /etc/nginx/conf.d/frappe-bench.conf; then
    echo "🔄 Fixing Nginx upstream to point to port 8001..."
    sed -i 's/127\.0\.0\.1:8000/127.0.0.1:8001/g' /etc/nginx/conf.d/frappe-bench.conf
fi

# ==============================================================
# 🚀 Start Services
# ==============================================================
echo "🔁 Restarting services..."

mkdir -p /var/run/supervisor
chown -R root:root /var/run/supervisor

nginx -t && service nginx restart

echo "✅ Frappe production (Nginx + Supervisor + SocketIO) ready."
echo "🌍 App: http://localhost:8000"
echo "⚡ SocketIO: ws://localhost:9000"

# ==============================================================
# 🚀 Keep Container Running
# ==============================================================
echo "🚀 Starting Supervisor in foreground..."
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
