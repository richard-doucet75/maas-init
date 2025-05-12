#!/bin/bash

set -e

set -a
source .env
set +a

PROFILE="$MAAS_PROFILE"

# Verify CLI profile is logged in
if [[ -z "$PROFILE" ]]; then
  echo "❌ No MAAS CLI profile is logged in."
  exit 1
fi

# Read and delete all DHCP snippet IDs
SNIPPET_IDS=$(maas "$PROFILE" dhcpsnippets read | jq -r '.[].id')

for ID in $SNIPPET_IDS; do
  echo "🧹 Deleting DHCP snippet ID: $ID"
  maas "$PROFILE" dhcpsnippet delete "$ID"
done

echo "✅ All DHCP snippets removed."
