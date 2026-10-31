#!/bin/bash
# =============================================================================
# Flux-N6 & Private 5G: Physical MEC Setup with VRF Routing Isolation (Table 200)
# =============================================================================
# Purpose:
#   Replaces the internal 'mec-app-ns' virtual namespace with a dedicated
#   physical Ethernet interface / bridge (br-mec -> 192.168.50.1/24) isolated
#   inside VRF Routing Table 200 so an external physical MEC host (192.168.50.76
#   / 192.168.50.2) connects via USB-to-Ethernet adapter or Ethernet switch.
#
# Usage:
#   sudo ./setup_mec.sh [ETH_IFACE]
#     - If ETH_IFACE is provided (e.g., enx00e04c680001), bridges that NIC.
#     - Otherwise, auto-detects any secondary Ethernet adapter (enx*, enp*, eth*).
#     - If only 'eno1' exists (connected to an Ethernet switch shared with USRP),
#       automatically creates an isolated macvlan interface 'eno1-mec' on 'eno1'
#       and bridges it into 'br-mec' (Table 200).
# =============================================================================

set -u

# --- Configuration ---
MEC_NS="mec-app-ns"
BR_MEC="br-mec"
MEC_SUBNET="192.168.50.0/24"
HOST_MEC_IP="192.168.50.1"
MEC_PRIMARY_IP="192.168.50.76"
MEC_ALIAS_IP="192.168.50.2"

VETH_HOST="veth-mec-host"
VETH_UPF2="veth-upf2-host"
MACVLAN_MEC="eno1-mec"

# Routing Table IDs
RT_ID=200
RT_PREF_UPF=200
RT_PREF_MEC=201
RT_PREF_GW=202

DNSMASQ_CONF="/tmp/fluxn6-mec-dnsmasq.conf"
DNSMASQ_PID="/tmp/fluxn6-mec-dnsmasq.pid"

USER_IFACE="${1:-}"

echo "========================================================"
echo "   Initializing Physical MEC Host Setup (VRF Table $RT_ID)"
echo "========================================================"

# --- 1. AGGRESSIVE CLEANUP OF OLD NAMESPACE & BRIDGES ---
echo "[1/6] Cleaning up legacy mec-app-ns and previous MEC state..."

if [ -f "$DNSMASQ_PID" ]; then
    sudo kill "$(cat "$DNSMASQ_PID" 2>/dev/null)" 2>/dev/null || true
    sudo rm -f "$DNSMASQ_PID"
fi
sudo pkill -f "dnsmasq.*$DNSMASQ_CONF" 2>/dev/null || true

# Remove old namespace so MEC is strictly external
sudo ip netns del "$MEC_NS" 2>/dev/null || true
sudo ip link del "$VETH_HOST" 2>/dev/null || true
sudo ip link del "$MACVLAN_MEC" 2>/dev/null || true
sudo ip -n ueran-ns link del "$MACVLAN_MEC" 2>/dev/null || true

sudo ip link set "$BR_MEC" down 2>/dev/null || true
sudo ip link del "$BR_MEC" 2>/dev/null || true

sudo ip rule del pref "$RT_PREF_UPF" 2>/dev/null || true
sudo ip rule del pref "$RT_PREF_MEC" 2>/dev/null || true
sudo ip rule del pref "$RT_PREF_GW" 2>/dev/null || true
sudo ip route flush table "$RT_ID" 2>/dev/null || true

echo "  -> Legacy namespace '$MEC_NS' removed. Host cleaned."

# --- 2. DETECT OR CREATE PHYSICAL ETHERNET INTERFACE FOR MEC ---
echo "[2/6] Detecting Ethernet interface for separate physical MEC device..."

WAN_IF=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n 1)
if [ -z "$WAN_IF" ]; then
    WAN_IF="wlp0s20f3"
fi

MEC_PHYS_IF=""

if [ -n "$USER_IFACE" ]; then
    if ip link show "$USER_IFACE" >/dev/null 2>&1; then
        MEC_PHYS_IF="$USER_IFACE"
        echo "  -> Using user-specified Ethernet interface: $MEC_PHYS_IF"
    else
        echo "  [!] Specified interface '$USER_IFACE' not found on host."
        exit 1
    fi
else
    # Auto-detect USB-to-Ethernet or secondary PCIe Ethernet adapter on host
    for candidate in $(ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1); do
        case "$candidate" in
            lo|ogstun*|veth-*|br-*|"$WAN_IF"|eno1|docker*|virbr*|flannel*)
                continue
                ;;
            enx*|enp*|eth*|ens*|eno*)
                MEC_PHYS_IF="$candidate"
                echo "  -> Auto-detected dedicated Ethernet adapter: $MEC_PHYS_IF"
                break
                ;;
        esac
    done
fi

# If no secondary USB-to-Ethernet dongle is present, check if eno1 is in ueran-ns
# (or host) and create an L2 macvlan sub-interface for Ethernet switch sharing.
if [ -z "$MEC_PHYS_IF" ]; then
    if sudo ip -n ueran-ns link show eno1 >/dev/null 2>&1; then
        echo "  -> No standalone USB-Ethernet detected; creating switch-ready macvlan '$MACVLAN_MEC' on 'eno1' (from ueran-ns)..."
        sudo ip -n ueran-ns link add "$MACVLAN_MEC" link eno1 type macvlan mode bridge
        sudo ip -n ueran-ns link set "$MACVLAN_MEC" netns 1
        MEC_PHYS_IF="$MACVLAN_MEC"
    elif ip link show eno1 >/dev/null 2>&1; then
        echo "  -> Creating switch-ready macvlan '$MACVLAN_MEC' on host 'eno1'..."
        sudo ip link add "$MACVLAN_MEC" link eno1 type macvlan mode bridge
        MEC_PHYS_IF="$MACVLAN_MEC"
    else
        echo "  -> WARNING: No physical Ethernet port detected yet. Creating '$BR_MEC' ready for hotplug."
    fi
fi

# --- 3. CONFIGURE HOST BRIDGE (br-mec) ---
echo "[3/6] Creating MEC gateway bridge '$BR_MEC' ($HOST_MEC_IP/24)..."

sudo ip link add name "$BR_MEC" type bridge
sudo ip addr add "$HOST_MEC_IP/24" dev "$BR_MEC"
sudo ip link set "$BR_MEC" mtu 1500 txqueuelen 10000 up

if [ -n "$MEC_PHYS_IF" ]; then
    # Detach from NetworkManager if managed so NM doesn't wipe bridge binding
    if command -v nmcli >/dev/null 2>&1; then
        sudo nmcli device set "$MEC_PHYS_IF" managed no 2>/dev/null || true
    fi
    sudo ip addr flush dev "$MEC_PHYS_IF" 2>/dev/null || true
    sudo ip link set "$MEC_PHYS_IF" mtu 1500 2>/dev/null || true
    sudo ip link set "$MEC_PHYS_IF" master "$BR_MEC"
    sudo ip link set "$MEC_PHYS_IF" up
    echo "  -> Attached physical interface '$MEC_PHYS_IF' to bridge '$BR_MEC'."
fi

# --- 4. DISABLE RPF & ENABLE FORWARDING ---
echo "[4/6] Configuring kernel sysctl forwarding and disabling RPF for VRF..."

sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
sudo sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
sudo sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null
sudo sysctl -w "net.ipv4.conf.$BR_MEC.rp_filter=0" >/dev/null 2>&1 || true
sudo sysctl -w "net.ipv4.conf.$VETH_UPF2.rp_filter=0" >/dev/null 2>&1 || true
if [ -n "$MEC_PHYS_IF" ]; then
    sudo sysctl -w "net.ipv4.conf.$MEC_PHYS_IF.rp_filter=0" >/dev/null 2>&1 || true
fi

sudo iptables -D FORWARD -i "$BR_MEC" -j ACCEPT 2>/dev/null || true
sudo iptables -D FORWARD -o "$BR_MEC" -j ACCEPT 2>/dev/null || true
sudo iptables -D INPUT -i "$BR_MEC" -j ACCEPT 2>/dev/null || true
sudo iptables -D OUTPUT -o "$BR_MEC" -j ACCEPT 2>/dev/null || true
sudo iptables -I FORWARD -i "$BR_MEC" -j ACCEPT
sudo iptables -I FORWARD -o "$BR_MEC" -j ACCEPT
sudo iptables -I INPUT -i "$BR_MEC" -j ACCEPT
sudo iptables -I OUTPUT -o "$BR_MEC" -j ACCEPT

# --- 5. ENFORCE VRF ROUTING ISOLATION (TABLE 200) ---
echo "[5/6] Enforcing VRF Policy Routing in Table $RT_ID..."

# A. Remove automatic 192.168.50.0/24 route from main table (hides MEC from host & UPF1)
sudo ip route del "$MEC_SUBNET" dev "$BR_MEC" table main 2>/dev/null || true

# B. Add MEC subnet route into Table 200
sudo ip route replace "$MEC_SUBNET" dev "$BR_MEC" table "$RT_ID"

# C. Add return paths for UPF2 UE subnets & Reverse SPA VIPs into Table 200
#    - 10.46.0.0/16: Forward MEC UEs (ogstun)
#    - 10.47.0.0/16: IoT UEs & Reverse SPA Controller 10.47.0.1 (ogstun2)
#    - 10.100.0.0/16: Reverse SPA Virtual IPs (DNAT translated inside upf2-ns)
sudo ip route replace 10.46.0.0/16 via 10.200.4.2 dev "$VETH_UPF2" table "$RT_ID"
sudo ip route replace 10.47.0.0/16 via 10.200.4.2 dev "$VETH_UPF2" table "$RT_ID"
sudo ip route replace 10.100.0.0/16 via 10.200.4.2 dev "$VETH_UPF2" table "$RT_ID"

# D. Preserve Core 5G RAN and UPF interconnects in Table 200 (prevents GTP-U downlink blackhole)
sudo ip route replace 10.200.1.0/24 dev veth-ran-host table "$RT_ID" 2>/dev/null || true
sudo ip route replace 10.200.3.0/24 dev veth-upf1-host table "$RT_ID" 2>/dev/null || true
sudo ip route replace 10.200.4.0/24 dev veth-upf2-host table "$RT_ID" 2>/dev/null || true

# E. Add WAN Internet Breakout to Table 200 (Hybrid Local Breakout)
WAN_GW=$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -n 1)
if [ -n "$WAN_GW" ]; then
    sudo ip route replace default via "$WAN_GW" dev "$WAN_IF" table "$RT_ID"
fi

# F. Bind Policy Routing Rules to Table 200
#    - pref 200: Packets arriving from UPF2 (veth-upf2-host)
#    - pref 201: Packets arriving from physical MEC bridge (br-mec)
#    - pref 202: Locally generated gateway replies sourced from 192.168.50.1
#                (Without pref 202, ICMP Echo Replies from 192.168.50.1 have iif=lo,
#                 miss prefs 200/201, and fall through to table main's default Wi-Fi route!)
sudo ip rule add iif "$VETH_UPF2" table "$RT_ID" pref "$RT_PREF_UPF"
sudo ip rule add iif "$BR_MEC" table "$RT_ID" pref "$RT_PREF_MEC"
sudo ip rule add from "$HOST_MEC_IP/32" table "$RT_ID" pref "$RT_PREF_GW"
sudo ip route flush cache 2>/dev/null || true

# G. Ensure NAT Masquerade for 10.46.0.0/16 out WAN
sudo iptables -t nat -D POSTROUTING -s 10.46.0.0/16 -o "$WAN_IF" -j MASQUERADE 2>/dev/null || true
sudo iptables -t nat -A POSTROUTING -s 10.46.0.0/16 -o "$WAN_IF" -j MASQUERADE

# --- 6. OPTIONAL DHCP SERVER ON br-mec FOR PLUG-AND-PLAY PHYSICAL MEC ---
echo "[6/6] Starting DHCP + Classless Static Route Push on '$BR_MEC'..."
if command -v dnsmasq >/dev/null 2>&1; then
    cat <<EOF | sudo tee "$DNSMASQ_CONF" >/dev/null
interface=$BR_MEC
bind-interfaces
dhcp-range=192.168.50.50,192.168.50.150,255.255.255.0,12h
dhcp-option=3,$HOST_MEC_IP
dhcp-option=6,51.0.0.1,1.1.1.1
# RFC 3442 Classless Static Routes pushed to physical MEC host automatically:
# Routes 10.46.0.0/16, 10.47.0.0/16, and 10.100.0.0/16 via 192.168.50.1
dhcp-option=121,10.46.0.0/16,$HOST_MEC_IP,10.47.0.0/16,$HOST_MEC_IP,10.100.0.0/16,$HOST_MEC_IP
EOF
    sudo dnsmasq --conf-file="$DNSMASQ_CONF" --pid-file="$DNSMASQ_PID" 2>/dev/null || true
    echo "  -> dnsmasq active on $BR_MEC (DHCP + RFC3442 static routes for 10.46/16, 10.47/16, 10.100/16)."
else
    echo "  -> dnsmasq not installed; configure static IP ($MEC_PRIMARY_IP/24, GW $HOST_MEC_IP) on physical MEC."
fi

echo "========================================================"
echo "   PHYSICAL MEC GATEWAY SETUP COMPLETE"
echo "========================================================"
echo " - Mode              : External Physical MEC Device (No mec-app-ns)"
echo " - Host MEC Bridge   : $BR_MEC ($HOST_MEC_IP/24)"
echo " - Bridged NIC       : ${MEC_PHYS_IF:-<hotplug-ready>}"
echo " - Expected MEC IPs  : $MEC_PRIMARY_IP (and/or $MEC_ALIAS_IP)"
echo " - VRF Isolation     : Table $RT_ID (Isolated from Host & UPF1)"
echo " - Routed Subnets    : 10.46.0.0/16 (UE), 10.47.0.0/16 (IoT), 10.100.0.0/16 (VIP)"
if ping -I "$HOST_MEC_IP" -c 2 -W 1 "$MEC_PRIMARY_IP" >/dev/null 2>&1; then
    echo " - Link Verification : [OK] Physical MEC ($MEC_PRIMARY_IP) replied to $HOST_MEC_IP!"
else
    echo " - Link Verification : [WAITING] Run setup_on_mec_device.sh on the MEC PC to bring up $MEC_PRIMARY_IP"
fi
echo "========================================================"
echo "Next on the Separate Physical MEC Machine:"
echo "  Run: sudo bash setup_on_mec_device.sh <ETHERNET_IFACE>"
echo "========================================================"
