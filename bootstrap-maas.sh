#!/bin/bash

set -e

read -s -p "Enter PostgreSQL password: " PG_PASSWORD
echo
read -s -p "Enter MAAS admin password: " MAAS_PASSWORD
echo

read -p "Enter MAAS URL (default: http://maas.jaded): " MAAS_URL
MAAS_URL=${MAAS_URL:-http://maas.jaded}

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
sudo rm -rf /var/snap/maas || true

sudo systemctl stop postgresql 2>/dev/null || true
sudo pg_dropcluster --stop 16 main || true
sudo apt-get purge --yes postgresql* libpq5 postgresql-client-common postgresql-common
sudo apt-get autoremove --yes
sudo rm -rf /etc/postgresql /var/lib/postgresql /var/log/postgresql

echo
echo "==============================="
echo "📱 Ensuring PostgreSQL is running"
echo "==============================="

sudo apt-get update
sudo apt-get install -y postgresql nginx

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
echo "🪱 Wiping MAAS Snap state to ensure clean init"
echo "==============================="

# Already wiped above, no-op here now

echo "==============================="
echo "🚦 Initializing MAAS"
echo "==============================="

sudo maas init region+rack \
    --database-uri "postgres://maas:$PG_PASSWORD@localhost/maasdb" \
    --maas-url "$MAAS_URL"

echo "Waiting for MAAS to start on port 5240..."
for i in {1..30}; do
    if sudo ss -tulnp | grep -q ':5240'; then
        echo "MAAS is now listening on port 5240"
        break
    fi
    sleep 2

done

echo "==============================="
echo "🌐 Configuring NGINX reverse proxy"
echo "==============================="

sudo tee /etc/nginx/sites-available/maas >/dev/null <<EOF
server {
    listen 80;
    server_name maas.jaded;

    location / {
        proxy_pass http://localhost:5240/;
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
sudo rm -f /etc/nginx/sites-enabled/default

echo "==============================="
echo "👤 Creating MAAS admin user"
echo "==============================="

sudo maas createadmin --username admin --password "$MAAS_PASSWORD" --email admin@maas.com

# DHCP Configuration Section
echo "==============================="
echo "🔑 Logging into MAAS as CLI profile 'admin'"
echo "==============================="

sudo maas apikey --username admin > /tmp/maas_api_key.txt
API_KEY=$(cat /tmp/maas_api_key.txt)

if [[ -z "$API_KEY" ]]; then
  echo "❌ Failed to retrieve API key for MAAS admin user. Exiting."
  exit 1
fi

echo "Retrieved MAAS API key."
maas logout admin 2>/dev/null || true
maas login admin "http://localhost:5240/MAAS/api/2.0/" "$API_KEY"

echo "==============================="
echo "🌐 Enabling DHCP on default VLAN"
echo "==============================="

echo "Getting Fabric, Subnet, and VLAN IDs..."
FABRICS_JSON=$(maas admin fabrics read)
SUBNETS_JSON=$(maas admin subnets read)

echo "$FABRICS_JSON" | jq .
echo "$SUBNETS_JSON" | jq .

FABRIC_ID=$(echo "$FABRICS_JSON" | jq -r '.[0].id // empty')
SUBNET_ID=$(echo "$SUBNETS_JSON" | jq -r '.[0].id // empty')

if [[ -z "$FABRIC_ID" || -z "$SUBNET_ID" ]]; then
    echo "❌ No fabrics or subnets were returned from MAAS. You may need to wait for a discovered network, or manually import a subnet."
    exit 1
fi

VLAN_ID=$(maas admin subnet read "$SUBNET_ID" | jq -r '.vlan.id')
VLAN_TAG=$(maas admin vlan read "$FABRIC_ID" "$VLAN_ID" | jq -r '.vid')

echo "FABRIC_ID: $FABRIC_ID"
echo "SUBNET_ID: $SUBNET_ID"
echo "VLAN_ID: $VLAN_ID"
echo "VLAN_TAG (VID): $VLAN_TAG"

echo "==============================="
echo "✅ MAAS has been successfully set up!"
echo "    Access it at: $MAAS_URL"
echo "==============================="
