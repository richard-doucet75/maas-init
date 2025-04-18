echo "==============================="
echo "🌐 Enabling DHCP on default VLAN"
echo "==============================="

echo "Getting Fabric, Subnet, and VLAN IDs..."
FABRICS_JSON=$(maas admin fabrics read)
SUBNETS_JSON=$(maas admin subnets read)

echo "$FABRICS_JSON" | jq .
echo "$SUBNETS_JSON" | jq .

FABRIC_ID=$(echo "$FABRICS_JSON" | jq -r '.[0].id // empty')
SUBNET_ID=$(echo "$SUBNETS_JSON" | jq -r '.[0].id // empty')

if [[ -z "$FABRIC_ID" || -z "$SUBNET_ID" ]]; then
    echo "❌ No fabrics or subnets were returned from MAAS. You may need to wait for a discovered network, or manually import a subnet."
    exit 1
fi

VLAN_ID=$(maas admin subnet read "$SUBNET_ID" | jq -r '.vlan.id')
VLAN_TAG=$(maas admin vlan read "$FABRIC_ID" "$VLAN_ID" | jq -r '.vid')

echo "FABRIC_ID: $FABRIC_ID"
echo "SUBNET_ID: $SUBNET_ID"
echo "VLAN_ID: $VLAN_ID"
echo "VLAN_TAG (VID): $VLAN_TAG"
