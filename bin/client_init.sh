#!/bin/bash

set -ex

# We need to hardcode the config dir variable
config="/pod-gw-config"

# Load main settings
cat /default_config/settings.sh
. /default_config/settings.sh
cat /${config}/settings.sh
. /${config}/settings.sh

# Derived settings
K8S_DNS_IP="$(cut -d ' ' -f 1 <<< "$K8S_DNS_IPS")"
GATEWAY_IP="$(dig +short "$GATEWAY_NAME" "@${K8S_DNS_IP}")"
NAT_ENTRY="$(grep "^$(hostname) " /config/nat.conf || true)"
VXLAN_GATEWAY_IP="${VXLAN_IP_NETWORK}.1"

# Check if this is first run (no vxlan0 interface)
if ! ip link show vxlan0 &>/dev/null; then
  # First time setup - set routing rule to the k8s DNS server
  K8S_GW_IP=$(/sbin/ip route | awk '/default/ { print $3 }')
  for local_cidr in $NOT_ROUTED_TO_GATEWAY_CIDRS; do
    # command might fail if rule already set
    ip route add "$local_cidr" via "$K8S_GW_IP" || /bin/true
  done

  # Delete default GW to prevent outgoing traffic to leave this docker
  echo "Deleting existing default GWs"
  ip route del 0/0 || /bin/true

  # We don't support IPv6 at the moment, so delete default route to prevent leaking traffic.
  echo "Deleting existing default IPv6 route to prevent leakage"
  ip route -6 del default || /bin/true

  # After this point nothing should be reachable -> check
  if ping -c 1 -W 1000 8.8.8.8; then
    echo "WE SHOULD NOT BE ABLE TO PING -> EXIT"
    exit 255
  fi

  # Make sure there is correct route for gateway
  if [ -n "$K8S_GW_IP" ]; then
    ip route add "$GATEWAY_IP" via "$K8S_GW_IP"
  fi

  # Create tunnel NIC
  ip link add vxlan0 type vxlan id "$VXLAN_ID" group 239.1.1.1 dev eth0 dstport 0 || true
  bridge fdb append to 00:00:00:00:00:00 dst "$GATEWAY_IP" dev vxlan0
  ip link set up dev vxlan0
  if [[ -n "$VPN_INTERFACE_MTU" ]]; then
    ETH0_INTERFACE_MTU=$(cat /sys/class/net/eth0/mtu)
    VXLAN0_INTERFACE_MAX_MTU=$((ETH0_INTERFACE_MTU-50))
    #Ex: if tun0 = 1500 and max mtu is 1450
    if [ ${VPN_INTERFACE_MTU} >= ${VXLAN0_INTERFACE_MAX_MTU} ];then
      ip link set mtu "${VXLAN0_INTERFACE_MAX_MTU}" dev vxlan0
    #Ex: if wg0 = 1420 and max mtu is 1450
    else
      ip link set mtu "${VPN_INTERFACE_MTU}" dev vxlan0
    fi
  fi
else
  # vxlan0 already exists - check if it has an IP address in the correct subnet
  if ip addr show dev vxlan0 | grep -q "inet ${VXLAN_IP_NETWORK}"; then
    echo "vxlan0 already has an IP address in the correct subnet"

    # Ensure default route exists
    if ! ip route show | grep -q "default via $VXLAN_GATEWAY_IP"; then
      echo "Adding default route via $VXLAN_GATEWAY_IP"
      route add default gw "$VXLAN_GATEWAY_IP" || true
    fi

    # Check we can connect to the gateway using the vxlan device
    if ping -c "${CONNECTION_RETRY_COUNT}" "$VXLAN_GATEWAY_IP"; then
      echo "Gateway already reachable, no changes needed"
      exit 0
    fi

    echo "Gateway not reachable, reconfiguring vxlan0"
  fi

  # Kill any existing udhcpc client for vxlan0
  if [ -f /var/run/udhcpc.vxlan0.pid ]; then
    kill $(cat /var/run/udhcpc.vxlan0.pid) 2>/dev/null || true
  fi
  pkill -f "udhcpc -i vxlan0" || true
fi

# For debugging reasons print some info
ip addr
ip route

# Configure IP and default GW through the gateway docker
if [[ -z "$NAT_ENTRY" ]]; then
  echo "Get dynamic IP"

  # Clean any existing leases or state
  rm -f /var/run/udhcpc.vxlan0.pid

  # Run udhcpc in daemon mode (-b) to automatically handle lease renewals
  echo "Running udhcpc to get IP address for vxlan0"
  udhcpc -i vxlan0 -b -q -p /var/run/udhcpc.vxlan0.pid

  # Verify we got an IP
  if ! ip addr show dev vxlan0 | grep -q "inet "; then
    echo "ERROR: Failed to get IP address for vxlan0"
    exit 1
  fi
else
  IP=$(cut -d' ' -f2 <<< "$NAT_ENTRY")
  VXLAN_IP="${VXLAN_IP_NETWORK}.${IP}"
  echo "Use fixed IP $VXLAN_IP"
  ip addr add "${VXLAN_IP}/24" dev vxlan0 || true
  route add default gw "$VXLAN_GATEWAY_IP" || true
fi

# For debugging reasons print some info
ip addr
ip route

# Check we can connect to the gateway using the vxlan device
ping -c "${CONNECTION_RETRY_COUNT}" "$VXLAN_GATEWAY_IP"

echo "Gateway ready and reachable"