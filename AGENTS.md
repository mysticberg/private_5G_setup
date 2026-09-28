# AGENTS.md - LLM & AI Assistant Context Runbook

This document is the designated context file for future AI assistants, LLMs, and autonomous agents working on this Private 5G codebase. Read this file completely before making architectural modifications or running diagnostic/startup commands.

---

## 1. Project Overview & Mission

This project is a complete, production-grade **Private 5G Standalone (SA) network** integrating:
* **Core Network (5GC):** Open5GS (Rel-16/17 Control Plane running on Host OS; Dual UPF Data Plane running in isolated network namespaces).
* **Radio Access Network (gNodeB):** srsRAN Project 5G gNodeB inside an isolated RAN network namespace (`ueran-ns`), interfacing with an Ettus USRP X310 SDR over 1 GbE/10 GbE.
* **Multi-Slice & Edge Architecture:**
  * **Slice 1 (eMBB / Internet):** Dedicated UPF1 in `upf1-ns` serving DNN `internet` (`10.45.0.0/16`) with NAT Masquerading out the host WAN interface.
  * **Slice 2 (URLLC / MEC):** Dedicated UPF2 in `upf2-ns` serving DNNs `critical` and `mec-secure` (`10.46.0.0/16`).
  * **Slice 3 (IoT / Camera):** Secondary DNN `iot` (`10.47.0.0/16`) on UPF2.
  * **Isolated MEC Domain:** A dedicated virtual application environment (`mec-app-ns`) hosting low-latency Edge compute services at `192.168.50.2:8000`, protected by Policy-Based VRF Routing (Table 200) with simultaneous local breakout to the public internet.

---

## 2. Network Topology & Addressing Map

```
                                  +--------------------------------------------------------+
                                  |                 HOST ROOT NAMESPACE                    |
                                  |  - WAN Interface: wlp0s20f3 (IP: 51.0.0.200/24)        |
                                  |  - Gateway / DNS: 51.0.0.1                             |
                                  |  - Open5GS Control Plane Daemons (AMF, SMF, etc.)      |
                                  +----+------------------+-------------------+------------+
                                       |                  |                   |
                     veth-ran-host     |    veth-upf1-host|      veth-upf2-host|
                     (10.200.1.1/24)   |    (10.200.3.1/24|      (10.200.4.1/24|
                     MTU 9000          |    MTU 9000      |      MTU 9000      |
                        |              |       |          |         |          |
+-----------------------v------+       |       |          |         |          |
|    Namespace: ueran-ns       |       |       |          |         |          |
| - veth-ran-ns: 10.200.1.2/24 |       |       |          |         |          |
| - Default GW: 10.200.1.1     |       |       |          |         |          |
| - eno1 (USRP NIC):           |       |       |          |         |          |
|   192.168.10.1/24 (MTU 9000) |       |       |          |         |          |
| - srsRAN gNodeB process      |       |       |          |         |          |
+---------------+--------------+       |       |          |         |          |
                |                      |       |          |         |          |
                | 1 GbE (MTU 9000)     |       |          |         |          |
                v                      |       |          |         |          |
   +-------------------------+         |       |          |         |          |
   | USRP X310 (192.168.10.2)|         |       |          |         |          |
   | 5G NR TDD Band n78      |         |       |          |         |          |
   | DL ARFCN: 632628 (20MHz)|         |       |          |         |          |
   +------------+------------+         |       |          |         |          |
                |                      |       |          |         |          |
                v Over The Air         |       |          |         |          |
   +-------------------------+         |       |          |         |          |
   | Commercial 5G Phone(s)  |         |       |          |         |          |
   | PLMN: 00101, TAC: 1     |         |       |          |         |          |
   +-------------------------+         |       |          |         |          |
                                       v       |          v         |          v
         +-------------------------------------+   +----------------+--------------------+
         |        Namespace: upf1-ns           |   |        Namespace: upf2-ns           |
         | - veth-upf1-ns: 10.200.3.2/24       |   | - veth-upf2-ns: 10.200.4.2/24       |
         | - Default GW:   10.200.3.1          |   | - Default GW:   10.200.4.1          |
         | - TUN: ogstun (10.45.0.1/16, MTU 9K)|   | - TUN: ogstun  (10.46.0.1/16, MTU 9K)|
         | - Slice: SST 1, SD 1                |   | - TUN: ogstun2 (10.47.0.1/16, MTU 9K)|
         | - DNN: internet                     |   | - Slice: SST 1, SD 2 (URLLC/MEC)    |
         | - UPF1 Daemon (open5gs-upfd)        |   | - DNNs: critical, mec-secure, iot   |
         | - NAT Out: wlp0s20f3                |   | - UPF2 Daemon (open5gs-upfd)        |
         +-------------------------------------+   +----------------+--------------------+
                                                                    |
                                                     Policy Routing | VRF Table 200
                                                     veth-mec-host  | (192.168.50.1/24, MTU 9K)
                                                                    v
                                                   +-------------------------------------+
                                                   |        Namespace: mec-app-ns        |
                                                   | - veth-mec-ns: 192.168.50.2/24      |
                                                   | - Default GW:  192.168.50.1         |
                                                   | - App: HTTP Server on port 8000     |
                                                   +-------------------------------------+
```

---

## 3. Directory Layout

```text
/home/private-5g/Private-5g_setup/
├── AGENTS.md                  # <-- You are here (AI Assistant Context & Rules)
├── MODIFICATIONS.md           # <-- Detailed changelog of all fixes & enhancements
├── 5G_SYSTEM_OPERATIONS.md    # <-- Daily operations runbook for human operators
├── Private_5G_setup.pdf       # <-- Baseline senior engineering specification
├── Private_5G_Network_Cookbook.pdf # Detailed design cookbook
├── setup_mec.sh               # <-- Sets up Table 200 VRF and mec-app-ns
├── run_sudo.py                # <-- Secure PTY wrapper for unattended sudo commands
├── configs/
│   ├── open5gs/
│   │   ├── amf.yaml           # AMF config (NGAP listening on 10.200.1.1:38412)
│   │   ├── smf.yaml           # SMF config (PFCP server on 10.200.1.1, .3.1, .4.1)
│   │   ├── upf_internet.yaml  # UPF1 config for upf1-ns (PFCP: 10.200.3.2)
│   │   └── upf_mec.yaml       # UPF2 config for upf2-ns (PFCP: 10.200.4.2)
│   ├── srsran/
│   │   └── gnb_x310.yml       # srsRAN 5G SA gNodeB config (Band n78, 20 MHz)
│   └── sysctl/
│       └── 99-5g-performance.conf # Kernel socket, backlog, and BBR performance tuning
└── scripts/
    ├── 1_setup_network.sh     # Topology, veth links, MTU 9000, host routing & NAT
    ├── start_core.sh          # Syncs configs to /etc/open5gs/ and starts control plane
    ├── start_upfs.sh          # Starts UPF1 and UPF2 daemons inside their namespaces
    ├── start_mec_app.sh       # Starts python HTTP test server in mec-app-ns:8000
    ├── start_gnb.sh           # Checks USRP ping and runs srsRAN gNB inside ueran-ns
    ├── check_status.sh        # Non-destructive diagnostics for all links & daemons
    ├── test_mec_connectivity.sh # Tests MEC reachability and isolation verification
    └── teardown_network.sh    # Graceful reset & restores eno1 to host namespace
```

---

## 4. Critical Architectural Gotchas & Invariants

When working in this repository, **do not violate the following rules**:

### Rule 1: Centralized Configuration Deployment
* **Do not edit `/etc/open5gs/*.yaml` directly.**
* The script [`scripts/start_core.sh`](file:///home/private-5g/Private-5g_setup/scripts/start_core.sh) copies files from [`configs/open5gs/`](file:///home/private-5g/Private-5g_setup/configs/open5gs/) to `/etc/open5gs/` every time it starts.
* **Always edit [`configs/open5gs/`](file:///home/private-5g/Private-5g_setup/configs/open5gs/)** and let `start_core.sh` deploy them.

### Rule 2: Open5GS SMF PFCP Socket Bindings
* In [`configs/open5gs/smf.yaml`](file:///home/private-5g/Private-5g_setup/configs/open5gs/smf.yaml), the `pfcp.server` list **MUST NOT** include `127.0.0.4`.
* If `127.0.0.4` is in `pfcp.server`, the Linux kernel will select the loopback socket when SMF communicates with namespace UPFs (`10.200.3.2` / `10.200.4.2`), failing with `EINVAL (22: Invalid argument)`.
* Keep the server list bound to `10.200.1.1`, `10.200.3.1`, and `10.200.4.1`.

### Rule 3: Downlink GTP-U in Table 200
* In [`setup_mec.sh`](file:///home/private-5g/Private-5g_setup/setup_mec.sh), rule `200: from all iif veth-upf2-host lookup 200` catches ALL packets leaving `upf2-ns`.
* When UPF2 sends downlink GTP-U packets to the gNodeB (`10.200.1.2:2152`), Table 200 **MUST** contain:
  `10.200.1.0/24 dev veth-ran-host table 200`
* If this route is missing, Table 200 will match the `default` WAN route and throw downlink 5G radio traffic onto the WiFi interface, dropping all downlink cellular data!

### Rule 4: Return Routes on the Host
* For traffic returning from the WAN/internet to UEs on `10.45.0.0/16` and `10.46.0.0/16`, the host's `main` routing table **MUST** have:
  * `10.45.0.0/16 via 10.200.3.2 dev veth-upf1-host`
  * `10.46.0.0/16 via 10.200.4.2 dev veth-upf2-host`
* Use `sudo ip route replace` instead of `add` in scripts to prevent `File exists` errors from conflicting default `ogstun` interfaces.

### Rule 5: DNS Distribution in Enterprise Environments
* In [`configs/open5gs/smf.yaml`](file:///home/private-5g/Private-5g_setup/configs/open5gs/smf.yaml), `51.0.0.1` (the local WiFi gateway DNS) must precede `8.8.8.8`. If the upstream network blocks public DNS (`8.8.8.8`), commercial smartphones will report "Connected without internet" and disable cellular mobile data unless a reachable DNS server is provided.

### Rule 6: MTU 9000 & Dynamic TCP MSS Clamping
* Inter-namespace links (`veth-*` and `ogstun`) are set to **MTU 9000** with `txqueuelen 10000`.
* The WAN interface (`wlp0s20f3`) stays at **MTU 1500**.
* To eliminate fragmentation over the 40-byte GTP-U encapsulation overhead, dynamic TCP MSS clamping is strictly enforced:
  `iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu`

---

## 5. Security & Sudo Password Policy

* **User Constraint:** The user has mandated: *"don't use the sudo password without my permission from now onwards"* and *"don't type the password for all the sudo commands, type it only if the sudo command asks for it"*.
* **Password:** `NewHampshire@98`
* **Safe Invocation:** Never run `echo "password" | sudo -S` directly in bash history.
* Use the local helper script [`run_sudo.py`](file:///home/private-5g/Private-5g_setup/run_sudo.py) which allocates a pseudo-terminal (PTY) via `pexpect` to authenticate cleanly without leaking plain-text secrets into `.bash_history`.

---

## 6. Standard Diagnostic Workflow

When debugging issues, run these non-destructive checks:
```bash
# 1. Overall health of namespaces, links, USRP, and NFs
./scripts/check_status.sh

# 2. MEC connectivity and isolation verification
./scripts/test_mec_connectivity.sh

# 3. View live Control Plane logs
sudo tail -f /var/log/open5gs/amf.log
sudo tail -f /var/log/open5gs/smf.log

# 4. View live Data Plane logs
sudo tail -f /var/log/open5gs/upf_internet.log
sudo tail -f /var/log/open5gs/upf_mec.log

# 5. Check active sessions and subscriber IP assignments
sudo ip netns exec upf1-ns ip -s link show ogstun
sudo ip netns exec upf2-ns ip -s link show ogstun
```
