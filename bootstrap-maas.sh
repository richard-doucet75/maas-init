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
echo "🌐 Enabling DHCP on subnet"
echo "==============================="

echo "🔐 Verifying MAAS login and API access..."

# Get API key from sudo context
API_KEY=$(sudo maas apikey --username admin 2>/dev/null)
if [[ -z "$API_KEY" ]]; then
  echo "❌ Failed to retrieve MAAS API key from sudo context."
  exit 1
fi

# Clean up any existing local login
maas logout admin 2>/dev/null || true
rm -f ~/.maas.cli 2>/dev/null || true

# Log in to MAAS as regular user
maas login admin "http://localhost:5240/MAAS/api/2.0/" "$API_KEY"

# Confirm MAAS CLI login works
if ! maas admin users read >/dev/null 2>&1; then
  echo "❌ MAAS CLI login appears invalid after login attempt."
  exit 1
fi

# Determine default gateway
DEFAULT_GATEWAY=$(ip route | grep default | awk '{print $3}')
if [[ -z "$DEFAULT_GATEWAY" ]]; then
  echo "❌ Could not detect default gateway."
  exit 1
fi
echo "✅ Detected default gateway: $DEFAULT_GATEWAY"

# Calculate base CIDR
BASE_CIDR=$(echo "$MAAS_IP" | awk -F. '{printf "%s.%s.%s.0/24", $1, $2, $3}')
echo "→ Will create subnet: $BASE_CIDR"

# Look for existing subnet
SUBNET_ID=$(maas admin subnets read | jq -r --arg CIDR "$BASE_CIDR" '.[] | select(.cidr == $CIDR) | .id')

if [[ -z "$SUBNET_ID" ]]; then
  echo "⚠️ No existing subnet found for $BASE_CIDR. Creating it..."

  # Create or get fabric
  FABRIC_ID=$(maas admin fabrics read | jq -r '.[0].id // empty')
  if [[ -z "$FABRIC_ID" ]]; then
    echo "⚠️ No existing fabric found. Creating 'bootstrap-fabric'..."
    FABRIC_CREATE=$(maas admin fabrics create name="bootstrap-fabric")
    FABRIC_ID=$(echo "$FABRIC_CREATE" | jq -r '.id')
    echo "✅ Created new fabric 'bootstrap-fabric' with ID $FABRIC_ID"
  fi

  # Create or get VLAN
  VLAN_INFO=$(maas admin vlans read "$FABRIC_ID")
  VLAN_JSON=$(echo "$VLAN_INFO" | jq -r --arg vid "$VLAN_ID" '.[] | select(.vid == ($vid | tonumber))')
  VLAN_ID_INTERNAL=$(echo "$VLAN_JSON" | jq -r .id)

  if [[ -z "$VLAN_ID_INTERNAL" || "$VLAN_ID_INTERNAL" == "null" ]]; then
    echo "⚠️ VLAN ID $VLAN_ID not found on fabric $FABRIC_ID. Creating it..."
    VLAN_CREATE=$(maas admin vlans create "$FABRIC_ID" name="untagged-$VLAN_ID" vid="$VLAN_ID" mtu=1500)
    VLAN_ID_INTERNAL=$(echo "$VLAN_CREATE" | jq -r '.id')
    echo "✅ Created VLAN $VLAN_ID with internal ID $VLAN_ID_INTERNAL"
  fi

  echo "🌐 Using MAAS API to create subnet $BASE_CIDR"
  MAAS_URL="http://localhost:5240/MAAS"
  SUBNET_CREATE=$(curl -s -H "Authorization: OAuth $API_KEY" \
    -H "Accept: application/json" \
    -X POST "$MAAS_URL/api/2.0/subnets/" \
    --data-urlencode "cidr=$BASE_CIDR" \
    --data-urlencode "gateway_ip=$DEFAULT_GATEWAY" \
    --data-urlencode "dns_servers=10.0.0.10 10.0.0.11" \
    --data-urlencode "vlan=$VLAN_ID_INTERNAL")

  SUBNET_ID=$(echo "$SUBNET_CREATE" | jq -r '.id')
  if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "null" ]]; then
    echo "❌ Failed to create subnet via MAAS API:"
    echo "$SUBNET_CREATE"
    exit 1
  else
    echo "✅ Subnet $BASE_CIDR created with ID $SUBNET_ID"
  fi
else
  echo "✅ Found existing subnet $BASE_CIDR with ID $SUBNET_ID"
fi

# Reserve DHCP dynamic range
echo "🔧 Reserving DHCP range: 10.0.40.100 - 10.0.40.200"
maas admin ipranges create type=dynamic start_ip=10.0.40.100 end_ip=10.0.40.200 subnet="$SUBNET_ID" comment="DHCP range"

# Enable DHCP on the VLAN
RACK_ID=$(maas admin rack-controllers read | jq -r '.[0].system_id')
echo "🔧 Enabling DHCP on VLAN $VLAN_ID_INTERNAL with primary rack: $RACK_ID"
maas admin vlan update "$FABRIC_ID" "$VLAN_ID" dhcp_on=true primary_rack="$RACK_ID"

echo "==============================="
echo "✅ DHCP is now active on subnet: $BASE_CIDR"
echo "==============================="


