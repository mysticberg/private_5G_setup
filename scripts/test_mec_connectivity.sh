#!/bin/bash
# test_mec_connectivity.sh
# Purpose: Test and verify MEC connectivity and routing isolation
set -e

MEC_IP="192.168.50.2"

echo "======================================================"
echo "          MEC CONNECTIVITY & ISOLATION TEST           "
echo "======================================================"

# 1. Check Namespaces
if ! ip netns list | grep -q "mec-app-ns" || ! ip netns list | grep -q "upf2-ns"; then
    echo "[-] Error: 'mec-app-ns' or 'upf2-ns' does not exist."
    echo "    Please run './scripts/1_setup_network.sh' and './setup_mec.sh' first."
    exit 1
fi

# 2. Test Authorized Access from UPF2 (MEC Slice)
echo "[1] Testing Authorized Access from 'upf2-ns'..."
if sudo ip netns exec upf2-ns ping -c 2 -W 1 "$MEC_IP" >/dev/null 2>&1; then
    echo "  [✓] Ping from upf2-ns (10.200.4.2 -> $MEC_IP): SUCCESS"
else
    echo "  [✗] Ping from upf2-ns failed."
fi

# Test with UE subnet IP (10.46.0.1) as source address
if sudo ip netns exec upf2-ns ping -I 10.46.0.1 -c 2 -W 1 "$MEC_IP" >/dev/null 2>&1; then
    echo "  [✓] Ping from upf2-ns with UE source IP (10.46.0.1 -> $MEC_IP): SUCCESS"
else
    echo "  [!] Ping with source 10.46.0.1 failed (Check Table 200 return path)."
fi

# Test HTTP Service if running
if sudo ip netns exec upf2-ns curl -s -m 2 "http://$MEC_IP:8000/" >/dev/null 2>&1; then
    echo "  [✓] HTTP service on http://$MEC_IP:8000/ is REACHABLE from upf2-ns"
else
    echo "  [!] HTTP port 8000 is not responding (Start python3 -m http.server 8000 inside mec-app-ns to test)."
fi

echo ""
# 3. Test Security Isolation (Unauthorized Domains Must Be Blocked)
echo "[2] Verifying Routing Isolation (VRF Table 200)..."

# Test from Host (Should FAIL)
if ping -c 1 -W 1 "$MEC_IP" >/dev/null 2>&1; then
    echo "  [✗] Host -> MEC: ACCESSIBLE (Isolation leak! Table main still has route)"
else
    echo "  [✓] Host -> MEC: BLOCKED / UNREACHABLE (Correct Isolation)"
fi

# Test from ueran-ns (gNB Namespace) (Should FAIL)
if sudo ip netns exec ueran-ns ping -c 1 -W 1 "$MEC_IP" >/dev/null 2>&1; then
    echo "  [✗] ueran-ns -> MEC: ACCESSIBLE (Isolation leak!)"
else
    echo "  [✓] ueran-ns (gNodeB) -> MEC: BLOCKED / UNREACHABLE (Correct Isolation)"
fi

# Test from upf1-ns (Internet Slice) (Should FAIL)
if sudo ip netns exec upf1-ns ping -c 1 -W 1 "$MEC_IP" >/dev/null 2>&1; then
    echo "  [✗] upf1-ns (Internet) -> MEC: ACCESSIBLE (Cross-slice leak!)"
else
    echo "  [✓] upf1-ns (Internet Slice) -> MEC: BLOCKED / UNREACHABLE (Correct Isolation)"
fi

echo "======================================================"
echo "Summary & Architecture Notes:"
echo " 1. 'curl http://$MEC_IP:8000/' worked because upf2-ns routes via Table 200."
echo " 2. 'ping -I ogstun' fails because '-I <dev>' binds to the TUN socket,"
echo "    sending packets to the UPF GTP-U tunnel rather than the default gateway."
echo "    Use 'ping -c 2 $MEC_IP' or 'ping -I 10.46.0.1 $MEC_IP' instead."
echo " 3. 'ueran-ns' CANNOT reach MEC directly because ueran-ns is the gNodeB"
echo "    radio access network. Only UE traffic passing through UPF2 can reach MEC."
echo "======================================================"
