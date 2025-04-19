#!/bin/bash

set -xe

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

# Clean up previous MAAS and PostgreSQL state
sudo snap remove --purge maas || true
sudo rm -rf /var/snap/maas || true
sudo systemctl stop postgresql || true
sudo pg_dropcluster --stop 16 main || true
sudo apt-get purge --yes postgresql* libpq5 postgresql-client-common postgresql-common
sudo apt-get autoremove --yes
sudo rm -rf /etc/postgresql /var/lib/postgresql /var/log/postgresql

# Install PostgreSQL and nginx
sudo apt-get update
sudo apt-get install -y postgresql nginx
sudo systemctl enable --now postgresql

# Create MAAS DB and user
sudo -u postgres psql <<EOF
DROP DATABASE IF EXISTS maasdb;
DROP ROLE IF EXISTS maas;
CREATE ROLE maas WITH LOGIN PASSWORD '$PG_PASSWORD';
CREATE DATABASE maasdb WITH OWNER maas ENCODING 'UTF8';
EOF

# Install MAAS
sudo snap install maas

# Initialize MAAS
sudo maas init region+rack \
  --database-uri "postgres://maas:$PG_PASSWORD@localhost/maasdb" \
  --maas-url "$MAAS_URL"

# Wait for MAAS to be ready
for i in {1..30}; do
  if sudo ss -tulnp | grep -q ':5240'; then
    echo "MAAS is now listening on port 5240"
    break
  fi
  sleep 2
done

# Create MAAS admin
sudo maas createadmin --username admin --password "$MAAS_PASSWORD" --email admin@maas.com

# Retrieve API key
MAX_RETRIES=3
ATTEMPT=1
RETRY_DELAY=2
API_KEY=""

while [[ $ATTEMPT -le $MAX_RETRIES ]]; do
  API_KEY=$(sudo maas apikey --username admin 2>/dev/null)
  if [[ -n "$API_KEY" ]]; then
    echo "✅ Retrieved API key for user 'admin'."
    break
  fi
  echo "❌ Failed to retrieve API key (attempt $ATTEMPT). Retrying in $RETRY_DELAY seconds..."
  sleep $RETRY_DELAY
  ATTEMPT=$((ATTEMPT + 1))
  RETRY_DELAY=$((RETRY_DELAY * 2))
done

if [[ -z "$API_KEY" ]]; then
  echo "🚨 Could not retrieve MAAS API key after $MAX_RETRIES attempts. Exiting."
  exit 1
fi

# Clean and login
maas logout admin 2>/dev/null || true
rm -f ~/.maas.cli 2>/dev/null || true
maas login admin "http://localhost:5240/MAAS/api/2.0/" "$API_KEY"

# Verify login
if ! maas admin users read >/dev/null 2>&1; then
  echo "❌ MAAS CLI login failed after setting API key. Exiting."
  exit 1
fi

# Enable DHCP
DEFAULT_GATEWAY=$(ip route | grep default | awk '{print $3}')
BASE_CIDR=$(echo "$MAAS_IP" | awk -F. '{printf "%s.%s.%s.0/24", $1, $2, $3}')
SUBNET_ID=$(maas admin subnets read | jq -r --arg CIDR "$BASE_CIDR" '.[] | select(.cidr == $CIDR) | .id')

if [[ -z "$SUBNET_ID" ]]; then
  FABRIC_ID=$(maas admin fabrics read | jq -r '.[0].id // empty')
  if [[ -z "$FABRIC_ID" ]]; then
    FABRIC_CREATE=$(maas admin fabrics create name="bootstrap-fabric")
    FABRIC_ID=$(echo "$FABRIC_CREATE" | jq -r '.id')
  fi
  VLAN_JSON=$(maas admin vlans read "$FABRIC_ID" | jq -r --arg vid "$VLAN_ID" '.[] | select(.vid == ($vid | tonumber))')
  VLAN_ID_INTERNAL=$(echo "$VLAN_JSON" | jq -r .id)
  if [[ -z "$VLAN_ID_INTERNAL" || "$VLAN_ID_INTERNAL" == "null" ]]; then
    VLAN_CREATE=$(maas admin vlans create "$FABRIC_ID" name="untagged-$VLAN_ID" vid="$VLAN_ID" mtu=1500)
    VLAN_ID_INTERNAL=$(echo "$VLAN_CREATE" | jq -r '.id')
  fi
  SUBNET_CREATE=$(sudo curl -s -H "Authorization: OAuth $API_KEY" \
    -H "Accept: application/json" \
    -X POST "http://localhost:5240/MAAS/api/2.0/subnets/" \
    --data-urlencode "cidr=$BASE_CIDR" \
    --data-urlencode "gateway_ip=$DEFAULT_GATEWAY" \
    --data-urlencode "dns_servers=10.0.0.10 10.0.0.11" \
    --data-urlencode "vlan=$VLAN_ID_INTERNAL")
  SUBNET_ID=$(echo "$SUBNET_CREATE" | jq -r '.id')
  if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "null" ]]; then
    echo "❌ Failed to create subnet via API:"
    echo "$SUBNET_CREATE"
    exit 1
  fi
fi

# Reserve DHCP range and enable DHCP
maas admin ipranges create type=dynamic start_ip=10.0.40.100 end_ip=10.0.40.200 subnet="$SUBNET_ID" comment="Reserved dynamic range for DHCP"
RACK_ID=$(maas admin rack-controllers read | jq -r '.[0].system_id')
maas admin vlan update "$FABRIC_ID" "$VLAN_ID" dhcp_on=true primary_rack="$RACK_ID"

echo "✅ DHCP is now active on subnet: $BASE_CIDR"
