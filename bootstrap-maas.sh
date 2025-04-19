#!/bin/bash

set -e

# Prompt for user input
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

read -p "Enter VLAN ID to enable DHCP on (default: 0): " VLAN_ID
VLAN_ID=${VLAN_ID:-0}

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
sudo nginx -t && sudo systemctl restart nginx

echo "==============================="
echo "👤 Creating MAAS admin user"
echo "==============================="
sudo maas createadmin --username admin --password "$MAAS_PASSWORD" --email admin@maas.com

echo "==============================="
echo "🔑 Logging into MAAS as CLI profile 'admin'"
echo "==============================="

# Get API key using sudo (admin was created under root context)
API_KEY=$(sudo maas apikey --username admin 2>/dev/null)

if [[ -z "$API_KEY" ]]; then
  echo "❌ Failed to retrieve API key for MAAS admin user from sudo context."
  exit 1
fi

echo "Retrieved MAAS API key from root context."

# Always remove the profile to avoid any prompts
maas logout admin 2>/dev/null || true
rm -f ~/.maas.cli || true  # Older versions may cache prompts here

# Login cleanly with the API key
maas login admin "http://localhost:5240/MAAS/api/2.0/" "$API_KEY"

echo "==============================="
echo "🌐 Enabling DHCP on subnet"
echo "==============================="

echo "🔐 Verifying MAAS login and API access..."
# Try to run a simple query that only works if logged in
if ! maas admin users read >/dev/null 2>&1; then
  echo "❌ MAAS CLI login appears invalid. Could not read users."
  exit 1
fi

# Attempt to find an existing subnet that matches the MAAS IP
SUBNET_ID=$(maas admin subnets read 2>/dev/null | jq -r --arg MAAS_IP "$MAAS_IP" '
  .[] | select(.cidr != null and ($MAAS_IP | startswith(.cidr | split("/")[0]))) | .id' | head -n1)

if [[ -z "$SUBNET_ID" ]]; then
  echo "⚠️ No matching subnet found for $MAAS_IP. Attempting to create one..."

  BASE_CIDR=$(echo "$MAAS_IP" | awk -F. '{printf "%s.%s.%s.0/24", $1, $2, $3}')
  echo "→ Will create subnet: $BASE_CIDR"

  # Grab the first fabric ID MAAS gives us
FABRIC_ID=$(maas admin fabrics read | jq -r '.[0].id')

if [[ -z "$FABRIC_ID" ]]; then
  echo "❌ No fabric found. MAAS might not be fully initialized."
  exit 1
fi

echo "✅ Using existing fabric with ID $FABRIC_ID"
  # Check if VLAN exists or create it
  
  VLAN_EXISTS=$(maas admin vlan read "$FABRIC_ID" "$VLAN_ID" 2>/dev/null || echo "")
  if [[ -z "$VLAN_EXISTS" ]]; then
    echo "⚠️ VLAN ID $VLAN_ID not found on fabric $FABRIC_NAME. Creating it..."
    VLAN_CREATE_JSON=$(maas admin vlan create fabric=$FABRIC_ID vid=$VLAN_ID name="untagged-$VLAN_ID" mtu=1500 dhcp_on=false primary_rack="" 2>&1)
    if echo "$VLAN_CREATE_JSON" | jq -e .id >/dev/null 2>&1; then
      echo "✅ VLAN $VLAN_ID created on fabric $FABRIC_NAME"
    else
      echo "❌ Failed to create VLAN $VLAN_ID. MAAS response:"
      echo "$VLAN_CREATE_JSON"
      exit 1
    fi
  else
    echo "✅ Found existing VLAN $VLAN_ID on fabric $FABRIC_NAME"
  fi

  # Create the subnet
  SUBNET_CREATE_JSON=$(maas admin subnet create \
    cidr="$BASE_CIDR" \
    gateway_ip="$MAAS_IP" \
    dns_servers="10.0.0.10 10.0.0.11" \
    vlan="$VLAN_ID" 2>&1)

  if echo "$SUBNET_CREATE_JSON" | jq -e .id >/dev/null 2>&1; then
    SUBNET_ID=$(echo "$SUBNET_CREATE_JSON" | jq -r '.id')
    echo "✅ Subnet $BASE_CIDR registered with ID $SUBNET_ID"
  else
    echo "❌ Failed to create subnet $BASE_CIDR. MAAS response:"
    echo "$SUBNET_CREATE_JSON"
    exit 1
  fi
else
  echo "✅ Found existing subnet for $MAAS_IP (ID: $SUBNET_ID)"
  FABRIC_ID=$(maas admin subnet read "$SUBNET_ID" | jq -r '.vlan.fabric_id')
fi

echo "🔧 Configuring DHCP on VLAN $VLAN_ID (Fabric ID: $FABRIC_ID)..."

# Enable DHCP on the VLAN
maas admin vlan update "$FABRIC_ID" "$VLAN_ID" dhcp_on=true

# Update subnet configuration
maas admin subnet update "$SUBNET_ID" \
    gateway_ip="${MAAS_IP}" \
    dns_servers="10.0.0.10 10.0.0.11" \
    allow_proxy=true \
    active_discovery=true \
    boot_file="pxelinux.0" \
    next_server="${MAAS_IP}"
   
echo "==============================="
echo "✅ MAAS has been successfully set up!"
echo "    Access it at: $MAAS_URL"
echo "==============================="
