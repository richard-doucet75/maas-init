#!/bin/bash

set -e

echo "Enter PostgreSQL password:"
read -s PG_PASSWORD

echo "Enter MAAS admin password:"
read -s MAAS_PASSWORD

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

sudo snap stop maas || true
sudo rm -rf /var/snap/maas/common/maas

# Prevent missing bootloader dir crash
sudo mkdir -p /var/snap/maas/common/maas/image-storage/bootloaders
sudo chown root:root /var/snap/maas/common/maas/image-storage/bootloaders

echo
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

echo
echo "==============================="
echo "🚦 Initializing MAAS"
echo "==============================="

sudo maas init region+rack \
  --database-uri "postgres://maas:$PG_PASSWORD@localhost/maasdb" \
  --maas-url "$MAAS_URL"

echo
echo "==============================="
echo "👤 Creating MAAS admin user"
echo "==============================="

sudo maas createadmin --username admin --password "$MAAS_PASSWORD" --email admin@maas.com

echo
echo "==============================="
echo "✅ MAAS has been successfully set up!"
echo "==============================="
