#!/bin/bash

set -xe

set -a
source .env
set +a

PROFILE="$MAAS_PROFILE"

# Verify CLI profile is logged in
if [[ -z "$PROFILE" ]]; then
  echo "❌ No MAAS CLI profile is logged in. Run: maas login <profile> <URL> <API_KEY>"
  exit 1
fi

# Create fabric if it doesn't exist
FABRIC_ID=$(maas $PROFILE fabrics read | jq -r --arg name "$FABRIC_NAME" '.[] | select(.name == $name) | .id')
if [[ -z "$FABRIC_ID" ]]; then
  FABRIC_ID=$(maas $PROFILE fabrics create name="$FABRIC_NAME" | jq -r '.id')
fi

# Create VLAN if it doesn't exist
VLAN_ID=$(maas $PROFILE vlans read "$FABRIC_ID" | jq -r --arg vid "$VLAN_NUMBER" '.[] | select(.vid == ($vid | tonumber)) | .id')
if [[ -z "$VLAN_ID" ]]; then
  VLAN_ID=$(maas $PROFILE vlan update "$FABRIC_ID" 0 name="vlan$VLAN_NUMBER" vid=$VLAN_NUMBER mtu=1500 | jq -r '.id')
fi

# Create subnet
SUBNET_ID=$(maas $PROFILE subnets read | jq -r --arg cidr "$SUBNET_CIDR" '.[] | select(.cidr == $cidr) | .id')
if [[ -z "$SUBNET_ID" ]]; then
  SUBNET_ID=$(maas $PROFILE subnets create \
    cidr=$SUBNET_CIDR \
    gateway_ip=$GATEWAY \
    dns_servers="$DNS_SERVERS" \
    vlan=$VLAN_ID | jq -r '.id')
fi

# Reserve service IPs
maas $PROFILE ipranges create type=reserved start_ip=$RESERVED_START end_ip=$RESERVED_END subnet=$SUBNET_ID comment="Reserved"

# Create DHCP range
maas $PROFILE ipranges create type=dynamic start_ip=$DHCP_START end_ip=$DHCP_END subnet=$SUBNET_ID comment="DHCP range"

# Get rack controller ID
RACK_ID=$(maas $PROFILE rack-controllers read | jq -r '.[0].system_id')

# Move rack interface to VLAN (assumes eth0)
INTERFACE_ID=$(maas $PROFILE interfaces read $RACK_ID | jq -r '.[] | select(.name=="eth0") | .id')
if [[ -n "$INTERFACE_ID" ]]; then
  maas $PROFILE interface update $RACK_ID $INTERFACE_ID vlan=$VLAN_ID
else
  echo "❌ Could not determine interface ID for eth0"
  exit 1
fi

# Enable DHCP
maas $PROFILE vlan update "$FABRIC_ID" "$VLAN_NUMBER" dhcp_on=true primary_rack=$RACK_ID

echo "✅ DHCP enabled on VLAN $VLAN_NUMBER for subnet $SUBNET_CIDR"
