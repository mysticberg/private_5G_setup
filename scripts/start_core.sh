#!/bin/bash
# start_core.sh
# Purpose: Configure and start Open5GS Control Plane Services on Host
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "======================================================"
echo "   Starting Open5GS 5G Core Control Plane"
echo "======================================================"

# Check if 10.200.1.1 exists (required for AMF NGAP and SMF PFCP)
if ! ip addr show veth-ran-host 2>/dev/null | grep -q "10.200.1.1"; then
    echo "[-] Error: Interface 'veth-ran-host' with IP 10.200.1.1 not found!"
    echo "    Please run './scripts/1_setup_network.sh' before starting the Core."
    exit 1
fi

# Stop and disable host-level UPF (UPFs run inside namespaces)
echo "[1/4] Stopping host systemd UPF daemon..."
sudo systemctl stop open5gs-upfd 2>/dev/null || true
sudo systemctl disable open5gs-upfd 2>/dev/null || true

# Backup existing configs if not backed up
echo "[2/4] Syncing Open5GS configurations..."
if [ ! -f /etc/open5gs/amf.yaml.bak ]; then
    sudo cp /etc/open5gs/amf.yaml /etc/open5gs/amf.yaml.bak 2>/dev/null || true
fi
if [ ! -f /etc/open5gs/smf.yaml.bak ]; then
    sudo cp /etc/open5gs/smf.yaml /etc/open5gs/smf.yaml.bak 2>/dev/null || true
fi

# Deploy tuned configurations
sudo cp "$PROJECT_ROOT/configs/open5gs/amf.yaml" /etc/open5gs/amf.yaml
sudo cp "$PROJECT_ROOT/configs/open5gs/smf.yaml" /etc/open5gs/smf.yaml
sudo cp "$PROJECT_ROOT/configs/open5gs/upf_internet.yaml" /etc/open5gs/upf_internet.yaml
sudo cp "$PROJECT_ROOT/configs/open5gs/upf_mec.yaml" /etc/open5gs/upf_mec.yaml

# Restart 5G Core control plane NFs
echo "[3/4] Restarting Control Plane NFs..."
sudo systemctl restart open5gs-nrfd
sudo systemctl restart open5gs-scpd
sudo systemctl restart open5gs-amfd
sudo systemctl restart open5gs-smfd
sudo systemctl restart open5gs-ausfd
sudo systemctl restart open5gs-udmd
sudo systemctl restart open5gs-udrd
sudo systemctl restart open5gs-pcfd
sudo systemctl restart open5gs-nssfd
sudo systemctl restart open5gs-bsfd

sleep 2

# Verify AMF and SMF status
echo "[4/4] Verifying Control Plane service status..."
AMF_STATUS=$(systemctl is-active open5gs-amfd)
SMF_STATUS=$(systemctl is-active open5gs-smfd)

echo " - AMF daemon status: $AMF_STATUS"
echo " - SMF daemon status: $SMF_STATUS"

if [ "$AMF_STATUS" != "active" ]; then
    echo "[-] WARNING: AMF failed to start cleanly. Checking log:"
    sudo tail -n 10 /var/log/open5gs/amf.log
fi

if [ "$SMF_STATUS" != "active" ]; then
    echo "[-] WARNING: SMF failed to start cleanly. Checking log:"
    sudo tail -n 10 /var/log/open5gs/smf.log
fi

if [ "$AMF_STATUS" = "active" ] && [ "$SMF_STATUS" = "active" ]; then
    echo "======================================================"
    echo " [+] Open5GS Core Control Plane is RUNNING successfully"
    echo "     AMF NGAP listening on: 10.200.1.1:38412"
    echo "     SMF PFCP listening on: 10.200.1.1:8805"
    echo "======================================================"
fi
