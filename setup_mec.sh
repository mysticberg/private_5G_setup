#!/bin/bash
# 4_setup_mec_isolated.sh
# Purpose: Setup MEC with STRICT Routing Isolation (VRF-style)
# Auto-cleans all previous configurations before starting.

# --- Configuration ---
MEC_NS="mec-app-ns"
MEC_SUBNET="192.168.50.0/24"
MEC_IP="192.168.50.2"
HOST_MEC_IP="192.168.50.1"

# Interface Names
VETH_HOST="veth-mec-host"
VETH_NS="veth-mec-ns"
VETH_UPF2="veth-upf2-host" # MUST match the interface name in 2_launch_upfs.sh

# Routing Table IDs
RT_ID=200
RT_PREF_UPF=200
RT_PREF_MEC=201

echo "========================================================"
echo "   initializing MEC setup with VRF Isolation"
echo "========================================================"

# --- 1. AGGRESSIVE CLEANUP ---
echo "[1/6] Cleaning up previous configurations..."

# Remove namespace (automatically kills processes inside it)
sudo ip netns del $MEC_NS 2>/dev/null

# Remove veth interface from Host if it lingers
sudo ip link del $VETH_HOST 2>/dev/null

# Remove Policy Routing Rules (Suppress errors if they don't exist)
sudo ip rule del pref $RT_PREF_UPF 2>/dev/null
sudo ip rule del pref $RT_PREF_MEC 2>/dev/null

# Flush the Custom Routing Table (200)
sudo ip route flush table $RT_ID 2>/dev/null

# Remove any stray iptables rules from previous attempts (Optional but good hygiene)
sudo iptables -D FORWARD -s 10.45.0.0/16 -d $MEC_SUBNET -j DROP 2>/dev/null

echo "      Cleanup complete."

# --- 2. CREATE INFRASTRUCTURE ---
echo "[2/6] Creating Namespace and Links..."

# Create Namespace
sudo ip netns add $MEC_NS

# Create Veth Pair
sudo ip link add $VETH_HOST type veth peer name $VETH_NS

# Move peer to namespace
sudo ip link set $VETH_NS netns $MEC_NS

# --- 3. CONFIGURE HOST SIDE (The VRF Gateway) ---
echo "[3/6] Configuring Host Interface..."

# Assign IP to Host side
sudo ip addr add $HOST_MEC_IP/24 dev $VETH_HOST
sudo ip link set $VETH_HOST mtu 9000 txqueuelen 10000 up

# --- 4. CONFIGURE MEC SIDE (The App) ---
echo "[4/6] Configuring MEC Application Server..."

# Assign IP inside namespace
sudo ip netns exec $MEC_NS ip addr add $MEC_IP/24 dev $VETH_NS
sudo ip netns exec $MEC_NS ip link set $VETH_NS mtu 9000 txqueuelen 10000 up
sudo ip netns exec $MEC_NS ip link set lo up

# Default Gateway for MEC is the Host
sudo ip netns exec $MEC_NS ip route add default via $HOST_MEC_IP

# --- 5. ENFORCE ROUTING ISOLATION (The "Magic") ---
echo "[5/6] Applying Routing Isolation (VRF)..."

# A. REMOVE the automatic route from the Main table
#    This makes the MEC invisible to the OS and UPF1.
sudo ip route del $MEC_SUBNET dev $VETH_HOST table main

# B. ADD the route to the Custom Table (200)
sudo ip route add $MEC_SUBNET dev $VETH_HOST table $RT_ID

# C. ADD return path for UPF2 (URLLC) to Table 200
#    Traffic going back to 10.46.x.x must go to UPF2 Gateway (10.200.4.2)
sudo ip route add 10.46.0.0/16 via 10.200.4.2 dev $VETH_UPF2 table $RT_ID

# D. ADD Policy Rules
#    "If traffic comes from UPF2 interface -> Use Table 200"
sudo ip rule add iif $VETH_UPF2 table $RT_ID pref $RT_PREF_UPF

#    "If traffic comes from MEC interface -> Use Table 200"
sudo ip rule add iif $VETH_HOST table $RT_ID pref $RT_PREF_MEC

# E. ADD Internet Breakout to Table 200 (Enables simultaneous MEC + Public Internet)
WAN_GW=$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -n 1)
WAN_IF=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n 1)
if [ -z "$WAN_IF" ]; then WAN_IF="wlp0s20f3"; fi
if [ -n "$WAN_GW" ]; then
    sudo ip route replace default via "$WAN_GW" dev "$WAN_IF" table $RT_ID
fi

# Ensure Core 5G RAN and UPF interconnects exist in Table 200 (Required for downlink GTP-U to gNodeB)
sudo ip route replace 10.200.1.0/24 dev veth-ran-host table $RT_ID
sudo ip route replace 10.200.3.0/24 dev veth-upf1-host table $RT_ID
sudo ip route replace 10.200.4.0/24 dev veth-upf2-host table $RT_ID

# Enable Host NAT MASQUERADE for 10.46.0.0/16
sudo iptables -t nat -D POSTROUTING -s 10.46.0.0/16 -o "$WAN_IF" -j MASQUERADE 2>/dev/null || true
sudo iptables -t nat -A POSTROUTING -s 10.46.0.0/16 -o "$WAN_IF" -j MASQUERADE

# --- 6. FINAL CHECK ---
echo "========================================================"
echo "   SETUP COMPLETE"
echo "========================================================"
echo "MEC Namespace: $MEC_NS"
echo "MEC IP:        $MEC_IP"
echo "Isolated in:   Table $RT_ID"
echo ""
echo "VERIFICATION:"
echo "1. Ping from Host/UPF1 (Should FAIL/Unreachable):"
echo "   ping $MEC_IP"
echo ""
echo "2. Ping from UPF2/URLLC UE (Should PASS):"
echo "   (From UE terminal): ping $MEC_IP"
echo "========================================================"
