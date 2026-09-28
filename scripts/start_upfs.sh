#!/bin/bash
# start_upfs.sh
# Purpose: Start UPF1 (Internet) in upf1-ns and UPF2 (MEC) in upf2-ns
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN=/usr/bin/open5gs-upfd
CNF="$PROJECT_ROOT/configs/open5gs"
LOG_DIR=/var/log/open5gs

# Verify namespaces exist
if ! ip netns list | grep -q "upf1-ns" || ! ip netns list | grep -q "upf2-ns"; then
    echo "[-] Error: UPF namespaces do not exist. Please run './scripts/1_setup_network.sh' first."
    exit 1
fi

# Ensure log directory exists
sudo mkdir -p "$LOG_DIR"

# Cleanly stop any existing UPF instances and discard job output
{
    sudo pkill -9 -x "open5gs-upfd" 2>/dev/null || true
    wait 2>/dev/null || true
} >/dev/null 2>&1
sleep 1

echo "======================================================"
echo "          Starting Data Plane UPF Daemons             "
echo "======================================================"

# --- 1. UPF1 (Internet) ---
echo "[1/2] Initializing UPF1 (Internet Slice) in 'upf1-ns'..."

# Enable IP forwarding and disable reverse-path filter
sudo ip netns exec upf1-ns sysctl -w net.ipv4.ip_forward=1 >/dev/null
sudo ip netns exec upf1-ns sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
sudo ip netns exec upf1-ns sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null

# Create TUN device 'ogstun' (10.45.0.1/16)
sudo ip netns exec upf1-ns ip tuntap add name ogstun mode tun 2>/dev/null || true
sudo ip netns exec upf1-ns ip addr add 10.45.0.1/16 dev ogstun 2>/dev/null || true
sudo ip netns exec upf1-ns ip link set ogstun mtu 9000 txqueuelen 10000 up
sudo ip netns exec upf1-ns ip route add 10.45.0.0/16 dev ogstun 2>/dev/null || true

# Launch UPF1
sudo ip netns exec upf1-ns nohup "$BIN" -c "$CNF/upf_internet.yaml" > "$LOG_DIR/upf_internet.log" 2>&1 &
sleep 1.5

UPF1_PID=$(sudo ip netns exec upf1-ns pgrep -o -f "upf_internet.yaml" 2>/dev/null | head -n 1 || true)
if [ -n "$UPF1_PID" ]; then
    echo "      -> UPF1 is ACTIVE [PID: $UPF1_PID]"
else
    echo "      -> [!] UPF1 failed to launch. Check $LOG_DIR/upf_internet.log"
fi

# --- 2. UPF2 (MEC) ---
echo "[2/2] Initializing UPF2 (MEC Slice) in 'upf2-ns'..."

# Enable IP forwarding and disable reverse-path filter
sudo ip netns exec upf2-ns sysctl -w net.ipv4.ip_forward=1 >/dev/null
sudo ip netns exec upf2-ns sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
sudo ip netns exec upf2-ns sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null

# Create TUN device 'ogstun' (10.46.0.1/16 - MEC DNN)
sudo ip netns exec upf2-ns ip tuntap add name ogstun mode tun 2>/dev/null || true
sudo ip netns exec upf2-ns ip addr add 10.46.0.1/16 dev ogstun 2>/dev/null || true
sudo ip netns exec upf2-ns ip link set ogstun mtu 9000 txqueuelen 10000 up
sudo ip netns exec upf2-ns ip route add 10.46.0.0/16 dev ogstun 2>/dev/null || true

# Create TUN device 'ogstun2' (10.47.0.1/16 - IoT / Camera DNN)
sudo ip netns exec upf2-ns ip tuntap add name ogstun2 mode tun 2>/dev/null || true
sudo ip netns exec upf2-ns ip addr add 10.47.0.1/16 dev ogstun2 2>/dev/null || true
sudo ip netns exec upf2-ns ip link set ogstun2 mtu 9000 txqueuelen 10000 up
sudo ip netns exec upf2-ns ip route add 10.47.0.0/16 dev ogstun2 2>/dev/null || true

# Launch UPF2
sudo ip netns exec upf2-ns nohup "$BIN" -c "$CNF/upf_mec.yaml" > "$LOG_DIR/upf_mec.log" 2>&1 &
sleep 1.5

UPF2_PID=$(sudo ip netns exec upf2-ns pgrep -o -f "upf_mec.yaml" 2>/dev/null | head -n 1 || true)
if [ -n "$UPF2_PID" ]; then
    echo "      -> UPF2 is ACTIVE [PID: $UPF2_PID]"
else
    echo "      -> [!] UPF2 failed to launch. Check $LOG_DIR/upf_mec.log"
fi

echo "======================================================"
echo "              UPF Data Plane Active                   "
echo "======================================================"
echo "  [✓] UPF1 (Internet | 10.45.0.0/16) : upf1-ns (PID: ${UPF1_PID:-none})"
echo "  [✓] UPF2 (MEC / IoT| 10.46.0.0/16) : upf2-ns (PID: ${UPF2_PID:-none})"
echo "  Log files:"
echo "    - $LOG_DIR/upf_internet.log"
echo "    - $LOG_DIR/upf_mec.log"
echo "======================================================"
