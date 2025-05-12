#!/bin/bash

set -e

set -a
source .env
set +a

PROFILE="$MAAS_PROFILE"

# Verify MAAS CLI profile is logged in
[[ -z "$PROFILE" ]] && echo "❌ MAAS CLI not logged in." && exit 1

# Set intro wizard and default config
maas $PROFILE maas set-config name=enable_analytics value=false
maas $PROFILE maas set-config name=boot_images_auto_import value=true
maas $PROFILE maas set-config name=upstream_dns value="$DNS_SERVERS"
maas $PROFILE maas set-config name=default_osystem value="ubuntu"
maas $PROFILE maas set-config name=default_distro_series value="noble"
maas $PROFILE maas set-config name=enable_third_party_drivers value=true
maas $PROFILE maas set-config name=kernel_opts value=""
maas $PROFILE maas set-config name=completed_intro value=true

# Make sure the admin user has an SSH key
KEY_EXISTS=$(maas $PROFILE sshkeys read | jq 'length')
if [[ "$KEY_EXISTS" -eq 0 ]]; then
  echo "🔐 No SSH key found. Generating..."
  ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -C "$USER@$(hostname)"
  PUB_KEY=$(cat ~/.ssh/id_rsa.pub)
  maas $PROFILE sshkeys create "key=$PUB_KEY"
fi

# Import boot resources
echo "📦 Importing boot resources..."
maas $PROFILE boot-resources import || true

echo "✅ All intro setup completed via CLI."
