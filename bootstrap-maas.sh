#!/bin/bash

set -e

# --- Optional clean start ---
read -p "⚠️  Run clean.sh to wipe MAAS, PostgreSQL, and Nginx first? [y/N]: " CLEAN
if [[ "$CLEAN" =~ ^[Yy]$ ]]; then
  ./clean.sh
  read -p "🔁 Reboot now? [y/N]: " REBOOT
  [[ "$REBOOT" =~ ^[Yy]$ ]] && sudo reboot
fi

# --- Step 0: Load or generate configuration ---
if [[ -f .env ]]; then
  read -p "📄 Found existing .env configuration. Use it? [Y/n]: " USE_EXISTING
  if [[ "$USE_EXISTING" =~ ^[Nn]$ ]]; then
    rm -f .env
    ./configure.sh
  else
    echo "✅ Using existing .env file."
  fi
else
  echo "⚙️ No .env found — launching interactive configuration..."
  ./configure.sh
fi

set -a
source .env
set +a

# --- Step 1: Install MAAS ---
echo "📦 Running install.sh..."
./install.sh

# --- Step 2: Login to MAAS CLI ---
echo "🔐 Logging in..."
./login.sh

# --- Step 3: Finalize MAAS config ---
echo "⚙️ Finalizing configuration..."
./finalize.sh

# --- Step 4: Remove legacy DHCP snippets (optional) ---
echo "🧹 Cleaning DHCP snippets..."
./remove-snippets.sh || echo "⚠️ DHCP cleanup skipped or failed."

# --- Step 5: Configure DHCP and networking ---
echo "🌐 Configuring network and DHCP..."
./dhcp_setup.sh

# --- Step 6: Set up reverse proxy ---
echo "🔁 Setting up Nginx reverse proxy..."
./proxy.sh

echo "✅ MAAS bootstrap complete. Access it at: http://$MAAS_IP"
