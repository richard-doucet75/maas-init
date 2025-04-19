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

# Create fabric
FABRIC_ID=$(maas admin fabrics create name="k8s-fabric" | jq -r '.id')

# Create VLAN 40 on the new fabric (overwrite existing if needed)
maas admin vlan update "$FABRIC_ID" 0 name="home-lab" mtu=1500 vid=40

# Create subnet 10.0.40.0/24 on VLAN 40
VLAN_ID=$(maas admin vlans read "$FABRIC_ID" | jq -r '.[] | select(.vid == 40) | .id')
maas admin subnets create \
  cidr=10.0.40.0/24 \
  gateway_ip=10.0.40.1 \
  dns_servers="10.0.0.10 10.0.0.11" \
  vlan=40
