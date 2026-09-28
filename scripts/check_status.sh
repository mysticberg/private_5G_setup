#!/bin/bash
# check_status.sh
# Purpose: Comprehensive diagnostic status check for 5G multi-namespace setup

echo "======================================================"
echo "          5G SYSTEM STATUS DIAGNOSTICS"
echo "======================================================"

# 1. Namespaces Check
echo "[1] Network Namespaces:"
for ns in ueran-ns upf1-ns upf2-ns mec-app-ns; do
    if ip netns list | grep -q "$ns"; then
        echo "  [✓] $ns: EXISTS"
    else
        echo "  [✗] $ns: NOT FOUND"
    fi
done

echo ""
# 2. Virtual Link & Routing Check
echo "[2] Virtual Link Connectivity:"
check_ping() {
    local target=$1
    local name=$2
    if ping -c 1 -W 1 "$target" >/dev/null 2>&1; then
        echo "  [✓] Host -> $name ($target): OK"
    else
        echo "  [✗] Host -> $name ($target): UNREACHABLE"
    fi
}

check_ping 10.200.1.2 "ueran-ns (veth-ran-ns)"
check_ping 10.200.3.2 "upf1-ns (veth-upf1-ns)"
check_ping 10.200.4.2 "upf2-ns (veth-upf2-ns)"

echo ""
# 3. USRP X310 Radio Link Check
echo "[3] USRP Radio Interface (eno1):"
if sudo ip -n ueran-ns link show eno1 >/dev/null 2>&1; then
    echo "  [✓] eno1 is present inside ueran-ns"
    if sudo ip netns exec ueran-ns ping -c 1 -W 2 192.168.10.2 >/dev/null 2>&1; then
        echo "  [✓] USRP X310 (192.168.10.2) is REACHABLE from ueran-ns"
    else
        echo "  [✗] USRP X310 (192.168.10.2) is NOT responding to ping"
    fi
elif ip link show eno1 >/dev/null 2>&1; then
    echo "  [!] eno1 is currently in Host root namespace (not isolated into ueran-ns)"
    if ping -c 1 -W 2 192.168.10.2 >/dev/null 2>&1; then
        echo "  [✓] USRP X310 (192.168.10.2) is REACHABLE from Host"
    else
        echo "  [✗] USRP X310 (192.168.10.2) is NOT responding"
    fi
else
    echo "  [✗] eno1 interface not detected"
fi

echo ""
# 4. Open5GS Control Plane Services Check
echo "[4] Open5GS Control Plane (Host):"
for svc in open5gs-nrfd open5gs-amfd open5gs-smfd; do
    status=$(systemctl is-active "$svc" 2>/dev/null || echo "not-found")
    if [ "$status" = "active" ]; then
        echo "  [✓] $svc: ACTIVE (running)"
    else
        echo "  [✗] $svc: $status"
    fi
done

# Check Host UPF daemon (should be INACTIVE/DISABLED)
host_upf=$(systemctl is-active open5gs-upfd 2>/dev/null || echo "inactive")
if [ "$host_upf" = "active" ]; then
    echo "  [!] WARNING: Host open5gs-upfd is ACTIVE (May conflict with namespace UPFs)"
else
    echo "  [✓] Host open5gs-upfd is INACTIVE (Correct for multi-namespace mode)"
fi

echo ""
# 5. Namespaced UPF Daemons Check
echo "[5] Data Plane UPF Daemons (Namespaces):"
if sudo ip netns exec upf1-ns pgrep -f "upf_internet.yaml" >/dev/null 2>&1; then
    echo "  [✓] UPF1 (Internet) is RUNNING in upf1-ns (PID: $(sudo ip netns exec upf1-ns pgrep -f upf_internet.yaml))"
else
    echo "  [✗] UPF1 is NOT running in upf1-ns"
fi

if sudo ip netns exec upf2-ns pgrep -f "upf_mec.yaml" >/dev/null 2>&1; then
    echo "  [✓] UPF2 (MEC) is RUNNING in upf2-ns (PID: $(sudo ip netns exec upf2-ns pgrep -f upf_mec.yaml))"
else
    echo "  [✗] UPF2 is NOT running in upf2-ns"
fi

echo ""
# 6. srsRAN gNodeB Process Check
echo "[6] srsRAN gNodeB:"
if sudo ip netns exec ueran-ns pgrep -f "gnb" >/dev/null 2>&1; then
    echo "  [✓] gNodeB is RUNNING in ueran-ns (PID: $(sudo ip netns exec ueran-ns pgrep -f gnb))"
else
    echo "  [✗] gNodeB is NOT running"
fi

echo "======================================================"
