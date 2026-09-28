# Project Engineering Ledger & Modifications History

This document logs all architectural changes, bug fixes, performance optimizations, and infrastructure contributions made to the **Private 5G Setup** repository.

---

## Modification Summary Index

1. [Multi-Namespace Architecture Isolation](#1-multi-namespace-architecture-isolation)
2. [PFCP Association & SMF Socket Collision (`EINVAL`)](#2-pfcp-association--smf-socket-collision-einval)
3. [Host Return Route Loss on UE Subnets](#3-host-return-route-loss-on-ue-subnets)
4. [Enterprise Firewall DNS Resolution Block](#4-enterprise-firewall-dns-resolution-block)
5. [MEC Slice Hybrid Local Breakout & Zero-Trust Isolation](#5-mec-slice-hybrid-local-breakout--zero-trust-isolation)
6. [Table 200 Downlink GTP-U Blackhole](#6-table-200-downlink-gtp-u-blackhole)
7. [MTU 9000 Jumbo Frames Across Virtual Links](#7-mtu-9000-jumbo-frames-across-virtual-links)
8. [Baremetal Performance Profile & TCP MSS Clamping](#8-baremetal-performance-profile--tcp-mss-clamping)
9. [Edge Computing Test Portal Service](#9-edge-computing-test-portal-service)
10. [Secure Automation & Credential Handling](#10-secure-automation--credential-handling)
11. [Operational Scripting & Output Standardization](#11-operational-scripting--output-standardization)
12. [PFCP Peer Mismatch & UPF Subnet NAT Resolution](#12-pfcp-peer-mismatch--upf-subnet-nat-resolution)

---

### 1. Multi-Namespace Architecture Isolation
* **Context:** The senior's initial setup had parts running baremetal or with conflicting interfaces. The objective was to isolate the gNodeB, UPFs, and MEC applications into dedicated network namespaces.
* **Modifications Made:**
  * Created `ueran-ns` (IP: `10.200.1.2`, Gateway: `10.200.1.1`). Moved physical interface `eno1` (USRP X310) into `ueran-ns` with IP `192.168.10.1/24` and MTU 9000.
  * Created `upf1-ns` (IP: `10.200.3.2`, Gateway: `10.200.3.1`) for the Internet Slice (DNN: `internet`, Subnet: `10.45.0.0/16`).
  * Created `upf2-ns` (IP: `10.200.4.2`, Gateway: `10.200.4.1`) for the MEC/Critical Slice (DNN: `critical` / `mec-secure`, Subnet: `10.46.0.0/16`) and IoT (DNN: `iot`, Subnet: `10.47.0.0/16`).
  * Created `mec-app-ns` (IP: `192.168.50.2`, Gateway: `192.168.50.1`) for edge application services.
* **Files Impacted:** [`scripts/1_setup_network.sh`](file:///home/private-5g/Private-5g_setup/scripts/1_setup_network.sh), [`setup_mec.sh`](file:///home/private-5g/Private-5g_setup/setup_mec.sh).

---

### 2. PFCP Association & SMF Socket Collision (`EINVAL`)
* **Problem:** Open5GS SMF failed to associate with UPF1 and UPF2 in their respective namespaces, throwing continuous errors:
  `ogs_sendto(10, ..., 10.200.3.2:8805) failed (22:Invalid argument)` and de-associating UPFs.
* **Root Cause:** In [`configs/open5gs/smf.yaml`](file:///home/private-5g/Private-5g_setup/configs/open5gs/smf.yaml), the PFCP server address list included `127.0.0.4`. The Linux kernel selected the socket bound to loopback when routing outbound UDP packets toward non-loopback IPs (`10.200.3.2` / `10.200.4.2`), triggering `EINVAL`.
* **Solution:**
  * Removed `127.0.0.4` from `smf.pfcp.server`.
  * Explicitly bound SMF PFCP listeners to the gateway endpoints `10.200.1.1`, `10.200.3.1`, and `10.200.4.1`.
  * Configured UPF1 client SMF target to `10.200.3.1` and UPF2 client SMF target to `10.200.4.1`.
* **Files Impacted:** [`configs/open5gs/smf.yaml`](file:///home/private-5g/Private-5g_setup/configs/open5gs/smf.yaml), [`configs/open5gs/upf_internet.yaml`](file:///home/private-5g/Private-5g_setup/configs/open5gs/upf_internet.yaml), [`configs/open5gs/upf_mec.yaml`](file:///home/private-5g/Private-5g_setup/configs/open5gs/upf_mec.yaml).

---

### 3. Host Return Route Loss on UE Subnets
* **Problem:** UEs connected to the `internet` APN were assigned IP `10.45.0.x` and could send outbound packets, but all return traffic was lost.
* **Root Cause:** The host routing table lacked `10.45.0.0/16 via 10.200.3.2 dev veth-upf1-host`. The host received return packets on `wlp0s20f3`, de-NAT'ed them, but having no route to `10.45.0.0/16`, looped them back out the default gateway. Additionally, standard `ip route add` failed silently when default systemd `ogstun` interfaces existed on boot.
* **Solution:**
  * Converted routing commands in [`scripts/1_setup_network.sh`](file:///home/private-5g/Private-5g_setup/scripts/1_setup_network.sh) to `ip route replace` to guarantee idempotent, clean route installation.
  * Ensured `10.45.0.0/16 via 10.200.3.2 dev veth-upf1-host` is always installed.
* **Files Impacted:** [`scripts/1_setup_network.sh`](file:///home/private-5g/Private-5g_setup/scripts/1_setup_network.sh).

---

### 4. Enterprise Firewall DNS Resolution Block
* **Problem:** Phone connected to 5G signal with valid IP, but showed "Connected without internet" and apps could not load any website.
* **Root Cause:** SMF pushed `8.8.8.8` and `8.8.4.4` to the UE. The campus/enterprise upstream firewall completely drops ICMP and UDP port 53 traffic to `8.8.8.8`. Android and iOS captive portal checks failed, disabling mobile data.
* **Solution:**
  * Detected upstream DNS server via `resolvectl status wlp0s20f3` (`51.0.0.1`).
  * Updated [`configs/open5gs/smf.yaml`](file:///home/private-5g/Private-5g_setup/configs/open5gs/smf.yaml) to distribute `51.0.0.1` as primary DNS ahead of public fallbacks.
  * Verified DNS query resolution directly from `ogstun` using `dig @51.0.0.1 google.com` (`142.250.67.174`).
* **Files Impacted:** [`configs/open5gs/smf.yaml`](file:///home/private-5g/Private-5g_setup/configs/open5gs/smf.yaml).

---

### 5. MEC Slice Hybrid Local Breakout & Zero-Trust Isolation
* **Problem:** The `mec-secure` APN was completely isolated to `192.168.50.0/24`, preventing users from browsing the internet or testing public speeds while connected to the MEC slice.
* **Root Cause:** Host VRF Table 200 had no default route to the outside world, and the host lacked a NAT MASQUERADE rule for `10.46.0.0/16`.
* **Solution:**
  * Added dynamic WAN breakout route: `ip route replace default via "$WAN_GW" dev "$WAN_IF" table 200`.
  * Added host NAT masquerading for `10.46.0.0/16` out `wlp0s20f3`.
  * Maintained zero-trust isolation: Host and UPF1 remain strictly blocked from accessing `192.168.50.2`.
* **Files Impacted:** [`setup_mec.sh`](file:///home/private-5g/Private-5g_setup/setup_mec.sh), [`scripts/1_setup_network.sh`](file:///home/private-5g/Private-5g_setup/scripts/1_setup_network.sh).

---

### 6. Table 200 Downlink GTP-U Blackhole
* **Problem:** After enabling internet breakout in Table 200, the UE on `mec-secure` could resolve DNS, but still could not receive web data or perform speed tests.
* **Root Cause:** 
  * Rule `200: from all iif veth-upf2-host lookup 200` captured all packets from `upf2-ns`.
  * When UPF2 received return packets from the internet, it encapsulated them into a downlink GTP-U packet destined for the gNodeB (`10.200.1.2:2152`).
  * Table 200 had no route for `10.200.1.0/24`. It matched the `default` route and sent the 5G radio frames to the WiFi router, dropping all downlink user data.
* **Solution:**
  * Injected inter-namespace RAN and UPF routes into Table 200:
    ```bash
    ip route replace 10.200.1.0/24 dev veth-ran-host table 200
    ip route replace 10.200.3.0/24 dev veth-upf1-host table 200
    ip route replace 10.200.4.0/24 dev veth-upf2-host table 200
    ```
  * Verified route resolution: `ip route get 10.200.1.2 from 10.200.4.2 iif veth-upf2-host` correctly outputs to `dev veth-ran-host table 200`.
* **Files Impacted:** [`setup_mec.sh`](file:///home/private-5g/Private-5g_setup/setup_mec.sh).

---

### 7. MTU 9000 Jumbo Frames Across Virtual Links
* **Problem:** Cross-namespace packet processing incurred MTU mismatch and fragmentation overhead when encapsulating 1500-byte IP frames into GTP-U (1540 bytes).
* **Solution:**
  * Configured **MTU 9000** and `txqueuelen 10000` on all virtual links:
    * `veth-ran-host` $\leftrightarrow$ `veth-ran-ns`
    * `veth-upf1-host` $\leftrightarrow$ `veth-upf1-ns`
    * `veth-upf2-host` $\leftrightarrow$ `veth-upf2-ns`
    * `veth-mec-host` $\leftrightarrow$ `veth-mec-ns`
    * `ogstun` in `upf1-ns` and `upf2-ns`
  * Increased SMF PDU session MTU in [`configs/open5gs/smf.yaml`](file:///home/private-5g/Private-5g_setup/configs/open5gs/smf.yaml) from 1400 to **1500**.
  * Kept physical WAN (`wlp0s20f3`) at 1500 per standard 802.11 WiFi constraints.
* **Files Impacted:** [`scripts/1_setup_network.sh`](file:///home/private-5g/Private-5g_setup/scripts/1_setup_network.sh), [`scripts/start_upfs.sh`](file:///home/private-5g/Private-5g_setup/scripts/start_upfs.sh), [`setup_mec.sh`](file:///home/private-5g/Private-5g_setup/setup_mec.sh), [`configs/open5gs/smf.yaml`](file:///home/private-5g/Private-5g_setup/configs/open5gs/smf.yaml).

---

### 8. Baremetal Performance Profile & TCP MSS Clamping
* **Problem:** Cellular data rate was initially constrained to ~6 Mbps. User previously achieved ~30 Mbps on baremetal using srsRAN performance tuning.
* **Solution:**
  * **TCP MSS Clamping:** Added iptables mangle rule `-j TCPMSS --clamp-mss-to-pmtu` in `scripts/1_setup_network.sh` to prevent packet fragmentation over the cellular GTP-U tunnel.
  * **Kernel Network Buffers:** Created [`configs/sysctl/99-5g-performance.conf`](file:///home/private-5g/Private-5g_setup/configs/sysctl/99-5g-performance.conf) and deployed to `/etc/sysctl.d/99-5g-performance.conf`:
    * `net.core.rmem_max = 67108864` (64 MB)
    * `net.core.wmem_max = 67108864` (64 MB)
    * `net.core.rmem_default = 33554432` (32 MB, increased from 208 KB)
    * `net.core.wmem_default = 33554432` (32 MB)
    * `net.core.netdev_max_backlog = 10000`
    * `net.core.somaxconn = 8192`
    * `net.ipv4.tcp_rmem = 4096 87380 33554432`
    * `net.ipv4.tcp_wmem = 4096 65536 33554432`
    * `net.ipv4.tcp_window_scaling = 1`
    * `net.ipv4.tcp_congestion_control = bbr`
  * **CPU Governor & KMS Polling:** Locked CPU scaling governor to `performance` on all 28 cores, and disabled DRM KMS polling (`poll = N`) to eliminate display interrupt jitter on srsRAN worker threads.
* **Files Impacted:** [`configs/sysctl/99-5g-performance.conf`](file:///home/private-5g/Private-5g_setup/configs/sysctl/99-5g-performance.conf), [`scripts/1_setup_network.sh`](file:///home/private-5g/Private-5g_setup/scripts/1_setup_network.sh).

---

### 9. Edge Computing Test Portal Service
* **Problem:** While network ping to `192.168.50.2` succeeded, opening a web browser from the UE failed because no application was listening on port 8000.
* **Solution:**
  * Developed [`scripts/start_mec_app.sh`](file:///home/private-5g/Private-5g_setup/scripts/start_mec_app.sh).
  * Deployed a responsive Private 5G MEC Edge Cloud web dashboard on `http://192.168.50.2:8000`.
  * Generated a dedicated 10 MB payload file (`speedtest_10mb.bin`) to enable local edge speed testing over the radio link.
* **Files Impacted:** [`scripts/start_mec_app.sh`](file:///home/private-5g/Private-5g_setup/scripts/start_mec_app.sh), [`5G_SYSTEM_OPERATIONS.md`](file:///home/private-5g/Private-5g_setup/5G_SYSTEM_OPERATIONS.md).

---

### 10. Secure Automation & Credential Handling
* **Problem:** Passing sudo passwords directly in terminal commands (`echo pass | sudo -S`) contaminated `.bash_history` and violated user security requirements.
* **Solution:**
  * Implemented [`run_sudo.py`](file:///home/private-5g/Private-5g_setup/run_sudo.py) using `pexpect` to allocate a virtual pseudo-terminal (PTY) and respond to the sudo challenge without exposing the password in bash history.
  * Retained centralized configuration sync inside [`scripts/start_core.sh`](file:///home/private-5g/Private-5g_setup/scripts/start_core.sh) while documenting its rationale in the operations guides.
* **Files Impacted:** [`run_sudo.py`](file:///home/private-5g/Private-5g_setup/run_sudo.py), [`AGENTS.md`](file:///home/private-5g/Private-5g_setup/AGENTS.md).

---

### 11. Operational Scripting & Output Standardization
* **Problem:** 
  1. Terminal outputs from [`scripts/teardown_network.sh`](file:///home/private-5g/Private-5g_setup/scripts/teardown_network.sh) lacked consistent visual formatting, indentation, and step-by-step confirmation feedback present in [`scripts/1_setup_network.sh`](file:///home/private-5g/Private-5g_setup/scripts/1_setup_network.sh).
  2. Running `teardown_network.sh` produced a severe terminal "staircase effect" and crashed with errors like `line 12: 65653 Killed sudo pkill -9 -f "open5gs-upfd"`.
* **Root Cause:**
  1. `pkill -9 -f <pattern>` searches the full `/proc/$PID/cmdline` of all processes. Because the invoked command was `sudo pkill -9 -f open5gs-upfd`, `pkill` matched its own command line (and `sudo`), immediately sending `SIGKILL` to itself.
  2. The violent termination of the process and/or lingering raw terminal modes from the killed `gnb` process left the terminal device with `onlcr` (newline-to-carriage-return translation) disabled, causing all subsequent output lines to print starting from the cursor's previous column rather than column 0.
* **Solution:**
  2. Replaced `pkill -9 -f` with exact process matches using `killall -q -9 gnb open5gs-upfd` and `pkill -9 -x`, preventing self-termination.
  3. Added `stty sane < /dev/tty 2>/dev/null || stty sane 2>/dev/null || true` at the entry and exit of `teardown_network.sh` to guarantee the TTY is always restored to canonical mode with carriage returns.
  4. Aligned banners to a consistent 56-character width.
  5. Added structured step-by-step confirmation echos with standard 2-space indented sub-bullets (`  -> ...`) for process termination, namespace deletion, interface removal, and routing table flushes.
  6. Implemented a clean, formatted summary box at the end of teardown with aligned colons (` : `) displaying the exact restored state across all system subsystems.
* **Files Impacted:** [`scripts/teardown_network.sh`](file:///home/private-5g/Private-5g_setup/scripts/teardown_network.sh), [`5G_SYSTEM_OPERATIONS.md`](file:///home/private-5g/Private-5g_setup/5G_SYSTEM_OPERATIONS.md).

---

### 12. PFCP Peer Mismatch & UPF Subnet NAT Resolution
* **Problem:** 
  1. Commercial smartphones connected to the 5G signal with active RRC signaling, but showed no cellular data icon ("Connected without internet") and could not browse or send data.
  2. Pinging from inside `upf1-ns` resulted in 100% packet loss.
  3. Upstream backhaul network dropped ICMP ping to `8.8.8.8`.
* **Root Cause:**
  1. **PFCP Asymmetric Peer Rejection:** Open5GS SMF binds its primary sending socket (`pfcp_sock`) to the first entry in `pfcp.server` (`10.200.1.1`). Outbound PFCP Session Establishment Requests (type 50) were sent from `10.200.1.1`. However, UPF1 and UPF2 were configured with SMF client targets `10.200.3.1` and `10.200.4.1`. When UPF received message type 50 from `10.200.1.1`, it failed node lookup (`Cannot find PFCP-Node from 10.200.1.1`) and dropped the packet without responding. SMF timed out and rejected the PDU session (`PDU session establishment reject`), preventing Data Radio Bearers (DRB) from being established.
  2. **Missing UPF Namespace NAT:** In `scripts/1_setup_network.sh`, iptables masqueraded `10.200.1.0/24`, `10.45.0.0/16`, and `10.46.0.0/16`, but omitted `10.200.3.0/24` and `10.200.4.0/24`. Packets originating inside `upf1-ns` left the host WAN unmasqueraded and were dropped upstream.
  3. **Upstream ICMP Drop:** The enterprise firewall drops ICMP ping to `8.8.8.8` (while UDP port 53 is open). Cloudflare `1.1.1.1` allows both ping and DNS.
* **Solution:**
  1. Updated [`configs/open5gs/upf_internet.yaml`](file:///home/private-5g/Private-5g_setup/configs/open5gs/upf_internet.yaml) and [`configs/open5gs/upf_mec.yaml`](file:///home/private-5g/Private-5g_setup/configs/open5gs/upf_mec.yaml) to point their client SMF target to `10.200.1.1`, matching SMF's outbound `pfcp_sock`.
  2. Updated [`scripts/1_setup_network.sh`](file:///home/private-5g/Private-5g_setup/scripts/1_setup_network.sh) to add iptables NAT MASQUERADE for `10.200.3.0/24` and `10.200.4.0/24`.
  3. Added `1.1.1.1` to [`configs/open5gs/smf.yaml`](file:///home/private-5g/Private-5g_setup/configs/open5gs/smf.yaml) DNS distribution list.
* **Files Impacted:** [`configs/open5gs/upf_internet.yaml`](file:///home/private-5g/Private-5g_setup/configs/open5gs/upf_internet.yaml), [`configs/open5gs/upf_mec.yaml`](file:///home/private-5g/Private-5g_setup/configs/open5gs/upf_mec.yaml), [`configs/open5gs/smf.yaml`](file:///home/private-5g/Private-5g_setup/configs/open5gs/smf.yaml), [`scripts/1_setup_network.sh`](file:///home/private-5g/Private-5g_setup/scripts/1_setup_network.sh).
