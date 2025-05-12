#!/bin/bash

set -xe

# --- Full MAAS and PostgreSQL Cleanup Script ---

# Stop MAAS and PostgreSQL
sudo snap remove --purge maas || true
sudo systemctl stop postgresql || true
sudo pg_dropcluster --stop 16 main || true

# Remove MAAS-related data and config
sudo rm -rf /var/snap/maas || true
sudo rm -rf /etc/maas || true
sudo rm -rf /var/lib/maas || true
sudo rm -rf ~/.maas || true

# Remove PostgreSQL completely
sudo apt-get purge --yes 'postgresql*' libpq5 postgresql-client-common postgresql-common || true
sudo rm -rf /etc/postgresql /var/lib/postgresql /var/log/postgresql || true

# Clean up extra packages and config
sudo apt-get autoremove --yes || true
sudo apt-get clean || true

# Remove nginx if installed
sudo apt-get purge --yes nginx nginx-common || true
sudo rm -rf /etc/nginx /var/log/nginx /var/www/html || true

# Reset network cleanup (optional and dangerous, comment unless needed)
# sudo rm -rf /etc/netplan/*

# Done
echo "✅ MAAS and PostgreSQL fully removed. System cleaned."

