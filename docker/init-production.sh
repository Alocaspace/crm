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
bench --site crm.duiverse.com set-config host_name "https://crm.duiverse.com"
bench --site crm.duiverse.com set-config allow_hosts '["crm.duiverse.com", "localhost", "form_crm_frappe"]'
bench --site crm.duiverse.com clear-cache
bench use crm.duiverse.com


# ==============================================================
# 🎨 Build & Link Assets
# ==============================================================
echo "🎨 Building production assets..."
set +e
bench build --production
if [ $? -ne 0 ]; then
    echo "⚠️ Production build failed (OOM or error). Retrying normal build..."
    bench build
fi
set -e

echo "🧩 Ensuring /sites/assets folder is populated..."
mkdir -p /home/frappe/frappe-bench/sites/assets
bench setup assets || true
bench clear-cache || true

echo "📦 Copying app assets to /sites/assets..."
cp -r /home/frappe/frappe-bench/apps/frappe/frappe/public/* /home/frappe/frappe-bench/sites/assets/ || true
if [ -d "/home/frappe/frappe-bench/apps/crm/crm/public" ]; then
  cp -r /home/frappe/frappe-bench/apps/crm/crm/public/* /home/frappe/frappe-bench/sites/assets/ || true
fi

chown -R frappe:frappe /home/frappe/frappe-bench/sites
chmod -R 755 /home/frappe/frappe-bench/sites/assets

echo "✅ Assets successfully built and linked!"

# ==============================================================
# 🌐 Setup Nginx + Supervisor
# ==============================================================
echo "📦 Installing Nginx and Supervisor..."
apt update && apt install -y nginx supervisor

echo "⚙️ Configuring Supervisor..."
bench setup supervisor
sed -i 's/127\.0\.0\.1:8000/0.0.0.0:8000/g' /home/frappe/frappe-bench/config/supervisor.conf
cp /home/frappe/frappe-bench/config/supervisor.conf /etc/supervisor/conf.d/frappe-bench.conf

# Remove redis workers (external redis used)
sed -i '/\[program:frappe-bench-redis-/,/^$/d' /etc/supervisor/conf.d/frappe-bench.conf || true
sed -i '/\[group:frappe-bench-redis\]/,/^$/d' /etc/supervisor/conf.d/frappe-bench.conf || true

echo "🌐 Configuring Nginx..."
bench setup nginx
cp /home/frappe/frappe-bench/config/nginx.conf /etc/nginx/conf.d/frappe-bench.conf

# Fix asset directory path for Nginx
sed -i 's|root\s*/home/frappe/frappe-bench/sites;|root /home/frappe/frappe-bench/sites;|' /etc/nginx/conf.d/frappe-bench.conf

# Restart services
service nginx restart || true
supervisorctl reread || true
supervisorctl update || true
supervisorctl restart all || true

echo "✅ Frappe production (Supervisor + Nginx + Assets) ready."

# ==============================================================
# 🚀 Keep Container Running
# ==============================================================
echo "🚀 Starting Supervisor in foreground..."
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
