#!/bin/bash
# 1_setup_network.sh
# Purpose: Initialize Network Namespace Architecture for Private 5G Setup
# Namespaces: ueran-ns (gNB + USRP X310), upf1-ns (Internet), upf2-ns (MEC)
set -e

# Detect external WAN interface for NAT
WAN_IF=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n 1)
if [ -z "$WAN_IF" ]; then
    WAN_IF="wlp0s20f3"
fi
echo "[+] Detected WAN interface for NAT: $WAN_IF"

echo "[1/5] Cleaning up existing namespaces and virtual interfaces..."
# Safely return eno1 to default namespace if it is currently inside ueran-ns
if sudo ip -n ueran-ns link show eno1 >/dev/null 2>&1; then
    echo "  -> Returning eno1 to root namespace..."
    sudo ip -n ueran-ns link set eno1 netns 1 2>/dev/null || true
fi

# Clean previous namespaces
sudo ip netns del ueran-ns 2>/dev/null || true
sudo ip netns del upf1-ns 2>/dev/null || true
sudo ip netns del upf2-ns 2>/dev/null || true

# Remove lingering host veths if any
sudo ip link del veth-ran-host 2>/dev/null || true
sudo ip link del veth-upf1-host 2>/dev/null || true
sudo ip link del veth-upf2-host 2>/dev/null || true

echo "[2/5] Setting up RAN Namespace 'ueran-ns' (10.200.1.x)..."
sudo ip netns add ueran-ns
sudo ip link add veth-ran-host type veth peer name veth-ran-ns
sudo ip link set veth-ran-ns netns ueran-ns

# Host side
sudo ip addr add 10.200.1.1/24 dev veth-ran-host
sudo ip link set veth-ran-host mtu 9000 txqueuelen 10000 up

# Namespace side
sudo ip netns exec ueran-ns ip addr add 10.200.1.2/24 dev veth-ran-ns
sudo ip netns exec ueran-ns ip link set veth-ran-ns mtu 9000 txqueuelen 10000 up
sudo ip netns exec ueran-ns ip link set lo up
sudo ip netns exec ueran-ns ip route add default via 10.200.1.1

# Move USRP X310 physical interface (eno1) into ueran-ns
if ip link show eno1 >/dev/null 2>&1; then
    echo "  -> Isolating physical interface 'eno1' into 'ueran-ns'..."
    sudo ip link set eno1 netns ueran-ns
    sudo ip netns exec ueran-ns ip addr add 192.168.10.1/24 dev eno1
    sudo ip netns exec ueran-ns ip link set eno1 up
    sudo ip netns exec ueran-ns ip link set eno1 mtu 9000
    echo "  -> 'eno1' configured inside ueran-ns with IP 192.168.10.1/24 (MTU 9000)."
else
    echo "  -> WARNING: Interface 'eno1' not found on host."
fi

echo "[3/5] Setting up UPF1 Namespace 'upf1-ns' (Internet: 10.200.3.x)..."
sudo ip netns add upf1-ns
sudo ip link add veth-upf1-host type veth peer name veth-upf1-ns
sudo ip link set veth-upf1-ns netns upf1-ns

# Host side
sudo ip addr add 10.200.3.1/24 dev veth-upf1-host
sudo ip link set veth-upf1-host mtu 9000 txqueuelen 10000 up

# Namespace side
sudo ip netns exec upf1-ns ip addr add 10.200.3.2/24 dev veth-upf1-ns
sudo ip netns exec upf1-ns ip link set veth-upf1-ns mtu 9000 txqueuelen 10000 up
sudo ip netns exec upf1-ns ip link set lo up
sudo ip netns exec upf1-ns ip route add default via 10.200.3.1

echo "[4/5] Setting up UPF2 Namespace 'upf2-ns' (MEC: 10.200.4.x)..."
sudo ip netns add upf2-ns
sudo ip link add veth-upf2-host type veth peer name veth-upf2-ns
sudo ip link set veth-upf2-ns netns upf2-ns

# Host side
sudo ip addr add 10.200.4.1/24 dev veth-upf2-host
sudo ip link set veth-upf2-host mtu 9000 txqueuelen 10000 up

# Namespace side
sudo ip netns exec upf2-ns ip addr add 10.200.4.2/24 dev veth-upf2-ns
sudo ip netns exec upf2-ns ip link set veth-upf2-ns mtu 9000 txqueuelen 10000 up
sudo ip netns exec upf2-ns ip link set lo up
sudo ip netns exec upf2-ns ip route add default via 10.200.4.1

echo "[5/5] Configuring Host Routing, Checksum offloads, and NAT..."
# Disable checksum offloading on veth pairs to prevent packet drops
sudo ethtool -K veth-ran-host rx off tx off 2>/dev/null || true
sudo ip netns exec ueran-ns ethtool -K veth-ran-ns rx off tx off 2>/dev/null || true
sudo ethtool -K veth-upf1-host rx off tx off 2>/dev/null || true
sudo ip netns exec upf1-ns ethtool -K veth-upf1-ns rx off tx off 2>/dev/null || true
sudo ethtool -K veth-upf2-host rx off tx off 2>/dev/null || true
sudo ip netns exec upf2-ns ethtool -K veth-upf2-ns rx off tx off 2>/dev/null || true

# Add Host routes to UE subnets via corresponding UPFs
sudo ip route replace 10.45.0.0/16 via 10.200.3.2 dev veth-upf1-host
sudo ip route replace 10.46.0.0/16 via 10.200.4.2 dev veth-upf2-host
sudo ip route replace 10.47.0.0/16 via 10.200.4.2 dev veth-upf2-host

# Enable IP forwarding and NAT MASQUERADE on Host
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null

# Clean old NAT rules before adding new ones
sudo iptables -t nat -D POSTROUTING -s 10.200.1.0/24 -o "$WAN_IF" -j MASQUERADE 2>/dev/null || true
sudo iptables -t nat -D POSTROUTING -s 10.200.3.0/24 -o "$WAN_IF" -j MASQUERADE 2>/dev/null || true
sudo iptables -t nat -D POSTROUTING -s 10.200.4.0/24 -o "$WAN_IF" -j MASQUERADE 2>/dev/null || true
sudo iptables -t nat -D POSTROUTING -s 10.45.0.0/16 -o "$WAN_IF" -j MASQUERADE 2>/dev/null || true
sudo iptables -t nat -D POSTROUTING -s 10.46.0.0/16 -o "$WAN_IF" -j MASQUERADE 2>/dev/null || true
sudo iptables -t nat -A POSTROUTING -s 10.200.1.0/24 -o "$WAN_IF" -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -s 10.200.3.0/24 -o "$WAN_IF" -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -s 10.200.4.0/24 -o "$WAN_IF" -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -s 10.45.0.0/16 -o "$WAN_IF" -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -s 10.46.0.0/16 -o "$WAN_IF" -j MASQUERADE

# Apply 5G high-performance kernel tuning if configuration exists
if [ -f "$PROJECT_ROOT/configs/sysctl/99-5g-performance.conf" ]; then
    sudo cp "$PROJECT_ROOT/configs/sysctl/99-5g-performance.conf" /etc/sysctl.d/99-5g-performance.conf 2>/dev/null || true
    sudo sysctl -p /etc/sysctl.d/99-5g-performance.conf >/dev/null 2>&1 || true
fi

# Clamp TCP MSS to prevent packet fragmentation over GTP-U tunnels
sudo iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
sudo iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

echo "========================================================"
echo "   5G Network Namespaces Successfully Configured"
echo "========================================================"
echo " - ueran-ns:  10.200.1.2 (Host: 10.200.1.1) + eno1 (192.168.10.1)"
echo " - upf1-ns:   10.200.3.2 (Host: 10.200.3.1)"
echo " - upf2-ns:   10.200.4.2 (Host: 10.200.4.1)"
echo " - Host NAT:  Traffic via $WAN_IF"
echo "========================================================"
