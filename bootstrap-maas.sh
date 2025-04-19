#!/bin/bash

set -xe

# Prompt for credentials
read -s -p "Enter PostgreSQL password: " PG_PASSWORD; echo
read -s -p "Enter MAAS admin password: " MAAS_PASSWORD; echo

# Prompt for optional values
read -p "Enter MAAS URL (default: http://maas.jaded): " MAAS_URL
MAAS_URL=${MAAS_URL:-http://maas.jaded}

read -p "Enter IP address for MAAS server (leave blank to auto-detect): " MAAS_IP
if [[ -z "$MAAS_IP" ]]; then
    MAAS_IP=$(hostname -I | awk '{print $1}')
    echo "Detected IP address: $MAAS_IP"
fi

read -p "Enter VLAN ID to enable DHCP on (default: 0): " VLAN_ID
VLAN_ID=${VLAN_ID:-0}

# Clean previous installs
sudo snap remove --purge maas || true
sudo rm -rf /var/snap/maas || true
sudo systemctl stop postgresql || true
sudo pg_dropcluster --stop 16 main || true
sudo apt-get purge --yes postgresql* libpq5 postgresql-client-common postgresql-common
sudo apt-get autoremove --yes
sudo rm -rf /etc/postgresql /var/lib/postgresql /var/log/postgresql

# Install dependencies
sudo apt-get update
sudo apt-get install -y postgresql nginx
sudo systemctl enable --now postgresql

# Setup PostgreSQL DB for MAAS
sudo -u postgres psql <<EOF
DROP DATABASE IF EXISTS maasdb;
DROP ROLE IF EXISTS maas;
CREATE ROLE maas WITH LOGIN PASSWORD '$PG_PASSWORD';
CREATE DATABASE maasdb WITH OWNER maas ENCODING 'UTF8';
EOF

# Install and initialize MAAS
sudo snap install maas
sudo maas init region+rack \
  --database-uri "postgres://maas:$PG_PASSWORD@localhost/maasdb" \
  --maas-url "$MAAS_URL"

# Wait for MAAS to start listening
until sudo ss -tulnp | grep -q ':5240'; do
    echo "Waiting for MAAS to start..."
    sleep 2
done

echo "MAAS is now listening on port 5240"

# Wait for MAAS API to become available
until curl -s -f http://localhost:5240/MAAS/api/2.0/version/ >/dev/null; do
    echo "Waiting for MAAS API to become available..."
    sleep 2
done

echo "✅ MAAS API is ready."

# Wait for full region controller API (e.g. subnets)
until curl -s -f http://localhost:5240/MAAS/api/2.0/ | jq '."subnets"' >/dev/null; do
    echo "Waiting for full MAAS API surface (e.g. subnets)..."
    sleep 2
done

echo "✅ Full MAAS API is available."

# Create admin
sudo maas createadmin --username admin --password "$MAAS_PASSWORD" --email admin@maas.com
API_KEY=$(sudo maas apikey --username admin)

# Login
maas logout admin 2>/dev/null || true
rm -f ~/.maas.cli 2>/dev/null || true
maas login admin "http://localhost:5240/MAAS/api/2.0/" "$API_KEY"

# Verify login
maas admin users read >/dev/null

# Enable DHCP
DEFAULT_GATEWAY=$(ip route | grep default | awk '{print $3}')
BASE_CIDR=$(echo "$MAAS_IP" | awk -F. '{printf "%s.%s.%s.0/24", $1, $2, $3}')
SUBNET_ID=$(maas admin subnets read | jq -r --arg CIDR "$BASE_CIDR" '.[] | select(.cidr == $CIDR) | .id')

if [[ -z "$SUBNET_ID" ]]; then
    FABRIC_ID=$(maas admin fabrics read | jq -r '.[0].id')

    if [[ -z "$FABRIC_ID" || "$FABRIC_ID" == "null" ]]; then
        echo "⚠️ No existing fabric found. Creating a new fabric..."
        FABRIC_ID=$(maas admin fabrics create name="bootstrap-fabric" | jq -r '.id')
        echo "✅ Created fabric with ID: $FABRIC_ID"
    fi

    VLAN_JSON=$(maas admin vlans read "$FABRIC_ID" | jq -r --arg vid "$VLAN_ID" '.[] | select(.vid == ($vid | tonumber))')
    VLAN_ID_INTERNAL=$(echo "$VLAN_JSON" | jq -r .id)

    if [[ -z "$VLAN_ID_INTERNAL" || "$VLAN_ID_INTERNAL" == "null" ]]; then
        VLAN_ID_INTERNAL=$(maas admin vlans create "$FABRIC_ID" name="untagged-$VLAN_ID" vid="$VLAN_ID" mtu=1500 | jq -r '.id')
    fi

    # Wait for rack controller to register
    RACK_ID=""
    while true; do
        RACK_ID=$(maas admin rack-controllers read | jq -r '.[0].system_id')
        if [[ -n "$RACK_ID" && "$RACK_ID" != "null" ]]; then
            break
        fi
        echo "Waiting for rack controller to register..."
        sleep 2
    done

    INTERFACE_ID=$(maas admin interfaces read "$RACK_ID" | jq -r '.[0].id')
    if [[ -n "$INTERFACE_ID" ]]; then
        maas admin interface update "$RACK_ID" "$INTERFACE_ID" vlan="$VLAN_ID_INTERNAL"
    fi

    SUBNET_CREATE=$(curl -s -H "Authorization: OAuth $API_KEY" \
        -H "Accept: application/json" \
        -X POST "http://localhost:5240/MAAS/api/2.0/subnets/" \
        --data-urlencode "cidr=$BASE_CIDR" \
        --data-urlencode "gateway_ip=$DEFAULT_GATEWAY" \
        --data-urlencode "dns_servers=10.0.0.10 10.0.0.11" \
        --data-urlencode "vlan=$VLAN_ID_INTERNAL")

    if echo "$SUBNET_CREATE" | grep -q "Forbidden"; then
        echo "❌ MAAS API call to create subnet was forbidden. Check authentication and permissions."
        echo "$SUBNET_CREATE"
        exit 1
    fi

    SUBNET_ID=$(echo "$SUBNET_CREATE" | jq -r '.id')
    if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "null" ]]; then
        echo "❌ Failed to create subnet via API:"
        echo "$SUBNET_CREATE"
        exit 1
    fi
fi

# Set DHCP range and enable DHCP
maas admin ipranges create type=dynamic start_ip=10.0.40.100 end_ip=10.0.40.200 subnet="$SUBNET_ID" comment="Reserved dynamic range for DHCP"
RACK_ID=$(maas admin rack-controllers read | jq -r '.[0].system_id')
maas admin vlan update "$FABRIC_ID" "$VLAN_ID" dhcp_on=true primary_rack="$RACK_ID"

echo "✅ DHCP is now active on subnet: $BASE_CIDR"
