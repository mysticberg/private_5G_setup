#!/bin/bash
# teardown_network.sh
# Purpose: Safely tear down all namespaces, restore physical NICs, and flush routes.
set -e

# Reset terminal modes in case previous processes (like gNB or sudo) corrupted TTY state
stty sane < /dev/tty 2>/dev/null || stty sane 2>/dev/null || true

echo "========================================================"
echo "   Tearing down 5G Network Namespaces and Processes     "
echo "========================================================"

# 1. Terminate running data plane and RAN processes
echo "[1/5] Stopping gNodeB and UPF processes..."
sudo killall -q -9 gnb open5gs-upfd 2>/dev/null || true
sudo pkill -9 -x "gnb" 2>/dev/null || true
sudo pkill -9 -x "open5gs-upfd" 2>/dev/null || true
stty sane < /dev/tty 2>/dev/null || stty sane 2>/dev/null || true
echo "  -> Terminated active gNodeB and open5gs-upfd processes."

# 2. Safely restore physical NIC (eno1) back to host root namespace
echo "[2/5] Restoring physical interface 'eno1' to Host namespace..."
if sudo ip -n ueran-ns link show eno1 >/dev/null 2>&1; then
    sudo ip -n ueran-ns link set eno1 netns 1 2>/dev/null || true
    sudo ip addr flush dev eno1 2>/dev/null || true
    sudo ip addr add 192.168.10.1/24 dev eno1 2>/dev/null || true
    sudo ip link set eno1 up 2>/dev/null || true
    sudo ip link set eno1 mtu 9000 2>/dev/null || true
    echo "  -> Interface 'eno1' returned to Host namespace (192.168.10.1/24, MTU 9000)."
elif ip link show eno1 >/dev/null 2>&1; then
    sudo ip link set eno1 up 2>/dev/null || true
    sudo ip link set eno1 mtu 9000 2>/dev/null || true
    echo "  -> Interface 'eno1' already in Host namespace."
else
    echo "  -> Interface 'eno1' not present on system."
fi

# 3. Delete Network Namespaces
echo "[3/5] Deleting namespaces..."
sudo ip netns del ueran-ns 2>/dev/null || true
sudo ip netns del upf1-ns 2>/dev/null || true
sudo ip netns del upf2-ns 2>/dev/null || true
sudo ip netns del mec-app-ns 2>/dev/null || true
echo "  -> Removed namespaces: ueran-ns, upf1-ns, upf2-ns, mec-app-ns."

# 4. Remove Host Veth interfaces
echo "[4/5] Removing host-side virtual interfaces..."
sudo ip link del veth-ran-host 2>/dev/null || true
sudo ip link del veth-upf1-host 2>/dev/null || true
sudo ip link del veth-upf2-host 2>/dev/null || true
sudo ip link del veth-mec-host 2>/dev/null || true
echo "  -> Deleted virtual links: veth-ran-host, veth-upf1-host, veth-upf2-host, veth-mec-host."

# 5. Flush custom routing tables and rules
echo "[5/5] Flushing policy routing and cleanup..."
sudo ip rule del pref 200 2>/dev/null || true
sudo ip rule del pref 201 2>/dev/null || true
sudo ip route flush table 200 2>/dev/null || true
sudo ip route del 10.45.0.0/16 2>/dev/null || true
sudo ip route del 10.46.0.0/16 2>/dev/null || true
sudo ip route del 10.47.0.0/16 2>/dev/null || true
echo "  -> Flushed Policy Table 200 and host-level UE routes."

echo "========================================================"
echo "          5G System Teardown & Reset Complete           "
echo "========================================================"
echo " - Radio Interface : eno1 in Host (192.168.10.1, MTU 9000)"
echo " - Namespaces      : All namespaces deleted"
echo " - Virtual Links   : All veth pairs removed"
echo " - Policy Routing  : Table 200 and rules flushed"
echo " - Host State      : Restored to baseline"
echo "========================================================"

# Final terminal sanity check
stty sane < /dev/tty 2>/dev/null || stty sane 2>/dev/null || true

