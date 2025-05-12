#!/bin/bash
set -e

CONFIG_FILE="./.env"

prompt_with_default() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="$3"

  read -p "$prompt_text [$default_value]: " input
  input="${input:-$default_value}"
  echo "$var_name=\"$input\"" >> "$CONFIG_FILE"
}

if [[ -f "$CONFIG_FILE" ]]; then
  echo "✅ Existing config found in $CONFIG_FILE"
  echo "To reconfigure, delete the file or run: rm -f $CONFIG_FILE"
  exit 0
fi

echo "⚙️  Starting interactive configuration..."
> "$CONFIG_FILE"

prompt_with_default "MAAS_IP" "Enter the IP address of your MAAS server" "10.0.40.5"
prompt_with_default "FABRIC_NAME" "Enter fabric name for DHCP" "k8s-fabric"
prompt_with_default "SUBNET_CIDR" "Enter subnet CIDR" "10.0.40.0/24"
prompt_with_default "GATEWAY" "Enter subnet gateway" "10.0.40.1"
prompt_with_default "DNS_SERVERS" "Enter DNS servers (space-separated)" "8.8.8.8 8.8.4.4"
prompt_with_default "RESERVED_START" "Enter start of reserved IP range" "10.0.40.1"
prompt_with_default "RESERVED_END" "Enter end of reserved IP range" "10.0.40.30"
prompt_with_default "DHCP_START" "Enter start of DHCP range" "10.0.40.100"
prompt_with_default "DHCP_END" "Enter end of DHCP range" "10.0.40.200"
prompt_with_default "VLAN_NUMBER" "Enter VLAN number" "4"

# Derived values
echo "MAAS_URL=\"http://\$MAAS_IP:5240/MAAS\"" >> "$CONFIG_FILE"
echo "MAAS_API_URL=\"\$MAAS_URL/api/2.0/\"" >> "$CONFIG_FILE"
echo "MAAS_PROFILE=\"admin\"" >> "$CONFIG_FILE"

echo "✅ Config saved to $CONFIG_FILE"
