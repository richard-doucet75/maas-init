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
echo "📆 Installing PostgreSQL"
echo "==============================="

sudo apt-get update
sudo apt-get install -y postgresql

echo
echo "==============================="
echo "📱 Ensuring PostgreSQL is running"
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
echo "🗓 Installing MAAS"
echo "==============================="

sudo snap install maas

echo
echo "==============================="
echo "🪟 Wiping MAAS Snap state to ensure clean init"
echo "==============================="

sudo rm -rf /var/snap/maas/common/* || true

echo "==============================="
echo "🚦 Initializing MAAS"
echo "==============================="

sudo maas init region+rack \
    --database-uri "postgres://maas:$PG_PASSWORD@localhost/maasdb" \
    --maas-url "$MAAS_URL"

echo "==============================="
echo "📅 Waiting for MAAS API to become available on port 5240"
echo "==============================="

for i in {1..30}; do
    if curl -sSf http://localhost:5240/MAAS/ >/dev/null; then
        echo "✅ MAAS API is up!"
        break
    else
        echo "⏳ Still waiting for MAAS API... (\$i/30)"
        sleep 2
    fi

done

echo "==============================="
echo "👤 Creating MAAS admin user"
echo "==============================="

sudo maas createadmin --username admin --password "$MAAS_PASSWORD" --email admin@maas.com

echo "==============================="
echo "✅ MAAS has been successfully set up!"
echo "    Access it at: $MAAS_URL"
echo "==============================="
