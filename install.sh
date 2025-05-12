#!/bin/bash

set -xe

set -a
source .env
set +a

# Prompt for sensitive values
read -s -p "Enter PostgreSQL password: " PG_PASSWORD
echo
read -s -p "Enter MAAS admin password: " MAAS_PASSWORD
echo

# --- Install Dependencies ---
sudo apt update
sudo apt install -y postgresql

# --- Setup PostgreSQL for MAAS ---
sudo -u postgres psql <<EOF
DROP DATABASE IF EXISTS maasdb;
DROP ROLE IF EXISTS maas;
CREATE ROLE maas WITH LOGIN PASSWORD '$PG_PASSWORD';
CREATE DATABASE maasdb WITH OWNER maas ENCODING 'UTF8';
EOF

# --- Install MAAS Snap ---
sudo snap install maas

# --- Initialize both Region and Rack ---
sudo maas init region+rack \
  --database-uri "postgres://maas:$PG_PASSWORD@localhost/maasdb" \
  --maas-url "$MAAS_URL"

# --- Create MAAS admin user ---
sudo maas createadmin --username "$MAAS_PROFILE" --password "$MAAS_PASSWORD" --email admin@example.com

# --- Wait for MAAS API to respond ---
echo "⏳ Waiting for MAAS API to become responsive..."
for i in {1..3}; do
  if curl -s --head "$MAAS_URL/api/2.0/" | grep -q "200 OK"; then
    echo "✅ MAAS API is responsive."
    break
  fi
  echo "⏳ Attempt $i failed. Retrying in 5s..."
  sleep 5
done

echo "✅ MAAS installed and running at $MAAS_URL"
