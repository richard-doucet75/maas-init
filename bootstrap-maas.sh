#!/bin/bash

set -e

read -s -p "Enter PostgreSQL password: " PG_PASSWORD
echo
read -s -p "Enter MAAS admin password: " MAAS_PASSWORD
echo

read -p "Enter MAAS URL (default: http://maas.jaded:5240/MAAS): " MAAS_URL
MAAS_URL=${MAAS_URL:-http://maas.jaded:5240/MAAS}

read -p "Enter IP address for MAAS server (leave blank to auto-detect): " MAAS_IP
if [[ -z "$MAAS_IP" ]]; then
    echo "Auto-detecting available IPs..."
    MAAS_IP=$(hostname -I | awk '{print $1}')
    echo "Detected IP address: $MAAS_IP"
fi

echo
echo "==============================="
echo "💣 Removing previous MAAS setup"
echo "==============================="

sudo snap remove --purge maas || true
sudo snap remove --purge maas-test-db || true

sudo systemctl stop postgresql || true
sudo pg_dropcluster --stop 16 main || true
sudo apt-get purge --yes postgresql* libpq5 postgresql-client-common postgresql-common
sudo apt-get autoremove --yes
sudo rm -rf /etc/postgresql /var/lib/postgresql /var/log/postgresql

echo
echo "==============================="
echo "📦 Installing PostgreSQL"
echo "==============================="

sudo apt-get update
sudo apt-get install -y postgresql

echo
echo "==============================="
echo "📡 Ensuring PostgreSQL is running"
echo "==============================="

sudo systemctl enable --now postgresql

echo
echo "==============================="
echo "🧑 Creating PostgreSQL user + DB for MAAS"
echo "==============================="

sudo -u postgres psql <<EOF
DROP DATABASE IF EXISTS maasdb;
DROP ROLE IF EXISTS maas;
CREATE ROLE maas WITH LOGIN PASSWORD '$PG_PASSWORD';
CREATE DATABASE maasdb WITH OWNER maas ENCODING 'UTF8';
EOF

echo
echo "==============================="
echo "📥 Installing MAAS"
echo "==============================="

sudo snap install maas

echo
echo "==============================="
echo "🧹 Wiping MAAS Snap state to ensure clean init"
echo "==============================="

sudo rm -rf /var/snap/maas/common/* || true

echo
echo "==============================="
echo "🔧 Creating custom embedded NGINX config"
echo "==============================="

CUSTOM_NGINX_DIR="/var/snap/maas/common/custom-nginx"
CUSTOM_NGINX_FILE="$CUSTOM_NGINX_DIR/custom.conf"
MAIN_NGINX_CONF="/var/snap/maas/current/http/nginx.conf"

sudo mkdir -p "$CUSTOM_NGINX_DIR"

sudo tee "$CUSTOM_NGINX_FILE" >/dev/null <<EOF
location /MAAS/ {
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
}
EOF

# Only inject include if not already present
if ! grep -q "custom-nginx" "$MAIN_NGINX_CONF"; then
    echo "Adding include to embedded nginx.conf"
    sudo sed -i '/http {/a \\n    include /var/snap/maas/common/custom-nginx/*.conf;' "$MAIN_NGINX_CONF"
fi

echo
echo "==============================="
echo "🚦 Initializing MAAS"
echo "==============================="

sudo maas init region+rack --database-uri "postgres://maas:$PG_PASSWORD@localhost/maasdb"

echo
echo "==============================="
echo "👤 Creating MAAS admin user"
echo "==============================="

sudo maas createadmin --username admin --password "$MAAS_PASSWORD" --email admin@maas.com

sudo snap restart maas

echo
echo "==============================="
echo "✅ MAAS has been successfully set up!"
echo "    Access it at: $MAAS_URL"
echo "==============================="
