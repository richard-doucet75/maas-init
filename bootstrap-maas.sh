#!/bin/bash

set -e

read -s -p "Enter PostgreSQL password: " PG_PASSWORD
echo
read -s -p "Enter MAAS admin password: " MAAS_PASSWORD
echo

read -p "Enter MAAS URL (default: http://maas.jaded/MAAS): " MAAS_URL
MAAS_URL=${MAAS_URL:-http://maas.jaded/MAAS}

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
echo "📦 Installing PostgreSQL + NGINX"
echo "==============================="

sudo apt-get update
sudo apt-get install -y postgresql nginx

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

echo "==============================="
echo "🚦 Initializing MAAS"
echo "==============================="

sudo maas init region+rack \
    --database-uri "postgres://maas:$PG_PASSWORD@localhost/maasdb" \
    --maas-url "$MAAS_URL"

echo "==============================="
echo "🌐 Configuring NGINX reverse proxy"
echo "==============================="

MAAS_PORT=5240

sudo tee /etc/nginx/sites-available/maas >/dev/null <<EOF
server {
    listen 80;
    server_name maas.jaded;

    location /MAAS/ {
        proxy_pass http://localhost:$MAAS_PORT/MAAS/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/maas /etc/nginx/sites-enabled/maas
sudo nginx -t && sudo systemctl reload nginx

echo "==============================="
echo "👤 Creating MAAS admin user"
echo "==============================="

sudo maas createadmin --username admin --password "$MAAS_PASSWORD" --email admin@maas.com

echo "==============================="
echo "✅ MAAS has been successfully set up!"
echo "    Access it at: $MAAS_URL"
echo "==============================="
