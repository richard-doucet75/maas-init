#!/bin/bash

set -e

set -a
source .env
set +a

# Logout only if profile exists
if maas list | grep -q "^$MAAS_PROFILE"; then
  maas logout "$MAAS_PROFILE"
fi

# Log in fresh
API_KEY=$(sudo maas apikey --username "$MAAS_PROFILE")
maas login "$MAAS_PROFILE" "$MAAS_API_URL" "$API_KEY"

echo "✅ MAAS CLI is now forcibly logged in as '$MAAS_PROFILE'"
