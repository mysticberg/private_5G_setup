#!/bin/bash
# start_gnb.sh
# Purpose: Verify USRP connectivity and launch srsRAN gNodeB inside ueran-ns
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GNB_BIN=/usr/local/bin/gnb
GNB_CONFIG="$PROJECT_ROOT/configs/srsran/gnb_x310.yml"
OPT_DIR=/opt/srsRAN_gnb

echo "======================================================"
echo "   Launching srsRAN 5G gNodeB in 'ueran-ns'"
echo "======================================================"

# 1. Check if ueran-ns exists
if ! ip netns list | grep -q "ueran-ns"; then
    echo "[-] Error: Namespace 'ueran-ns' does not exist."
    echo "    Please run './scripts/1_setup_network.sh' first."
    exit 1
fi

# 2. Check if eno1 is inside ueran-ns
if ! sudo ip -n ueran-ns link show eno1 >/dev/null 2>&1; then
    echo "[-] Error: Interface 'eno1' is not inside 'ueran-ns'."
    echo "    Please run './scripts/1_setup_network.sh' to isolate the USRP interface."
    exit 1
fi

# 3. Check connectivity to USRP X310
echo "[1/3] Testing USRP X310 connectivity (192.168.10.2)..."
if sudo ip netns exec ueran-ns ping -c 2 -W 2 192.168.10.2 >/dev/null 2>&1; then
    echo " [+] USRP X310 is REACHABLE inside ueran-ns."
else
    echo " [-] WARNING: Cannot ping USRP X310 at 192.168.10.2."
    echo "     Please check Ethernet cabling and ensure the USRP is powered ON."
fi

# 4. Setup /opt/srsRAN_gnb config (per Private_5G_setup.pdf to bypass AppArmor)
echo "[2/3] Preparing gNodeB configuration..."
sudo mkdir -p "$OPT_DIR"
sudo cp "$GNB_CONFIG" "$OPT_DIR/gnb_config.yml"
if [ ! -f "$OPT_DIR/gnb" ] && [ -f "$GNB_BIN" ]; then
    sudo ln -sf "$GNB_BIN" "$OPT_DIR/gnb"
fi

# 5. Check AMF reachability
echo "[3/3] Testing AMF reachability (10.200.1.1:38412)..."
if sudo ip netns exec ueran-ns ping -c 1 -W 1 10.200.1.1 >/dev/null 2>&1; then
    echo " [+] Host AMF gateway (10.200.1.1) is REACHABLE from ueran-ns."
else
    echo " [-] WARNING: Cannot reach 10.200.1.1 from ueran-ns."
fi

echo "======================================================"
echo " Starting gNodeB process inside ueran-ns..."
echo " Config: $OPT_DIR/gnb_config.yml"
echo " Press Ctrl+C to stop gNodeB."
echo "======================================================"

sudo ip netns exec ueran-ns "$GNB_BIN" -c "$OPT_DIR/gnb_config.yml"
