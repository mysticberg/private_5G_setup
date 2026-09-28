# Private 5G Standalone (SA) Multi-Slice & MEC Network

A complete, production-grade 5G Standalone network implementation built on **Open5GS**, **srsRAN Project**, an **Ettus USRP X310 SDR**, and Linux Network Namespaces with VRF-isolated Edge Computing (MEC).

---

## Architecture at a Glance

* **5G Control Plane:** Open5GS (Rel-16/17 NFs) running on the Host OS.
* **5G RAN:** srsRAN Project gNodeB isolated in namespace `ueran-ns`, transmitting 5G NR TDD Band n78 (DL ARFCN 632628, 20 MHz, 30 kHz SCS) via USRP X310 over 1 GbE/10 GbE (MTU 9000).
* **Multi-Namespace Data Plane:**
  * **UPF1 (`upf1-ns`):** Slice 1 (eMBB / Internet, `10.45.0.0/16`) with host NAT masquerading.
  * **UPF2 (`upf2-ns`):** Slice 2 (URLLC / MEC, `10.46.0.0/16`) and Slice 3 (IoT, `10.47.0.0/16`).
* **Isolated MEC Domain (`mec-app-ns`):** Low-latency edge applications running on `192.168.50.2:8000`, protected by Policy Routing (Table 200) with simultaneous local breakout to public internet.

---

## Quick Navigation

| Document | Purpose | Audience |
| :--- | :--- | :--- |
| **[5G_SYSTEM_OPERATIONS.md](file:///home/private-5g/Private-5g_setup/5G_SYSTEM_OPERATIONS.md)** | Step-by-step daily startup, verification, and teardown runbook | Network Engineers & Operators |
| **[AGENTS.md](file:///home/private-5g/Private-5g_setup/AGENTS.md)** | AI assistant instructions, topology maps, architectural invariants | LLMs & Autonomous Coding Agents |
| **[MODIFICATIONS.md](file:///home/private-5g/Private-5g_setup/MODIFICATIONS.md)** | Complete technical history of all bug fixes, routing fixes, and tuning | Developers & Architects |
| **[Private_5G_setup.pdf](file:///home/private-5g/Private-5g_setup/Private_5G_setup.pdf)** | Original senior engineering baseline specification | Reference |
| **[Private_5G_Network_Cookbook.pdf](file:///home/private-5g/Private-5g_setup/Private_5G_Network_Cookbook.pdf)** | Detailed architectural cookbook and setup rationale | Reference |

---

## Quick Start (Daily Operations)

Execute from `/home/private-5g/Private-5g_setup/`:

```bash
# 1. Initialize Network Namespaces, veth pairs, MTU 9000 & Host NAT
sudo ./scripts/1_setup_network.sh

# 2. Deploy configs and start Open5GS Control Plane
sudo ./scripts/start_core.sh

# 3. Start Dual UPFs (Internet in upf1-ns, MEC in upf2-ns)
sudo ./scripts/start_upfs.sh

# 4. Initialize Isolated MEC Domain & Start Edge Web Service
sudo ./setup_mec.sh
sudo ./scripts/start_mec_app.sh

# 5. Launch srsRAN gNodeB (transmits 5G NR over the air)
sudo ./scripts/start_gnb.sh

# 6. Run Status & Connectivity Checks (non-destructive)
./scripts/check_status.sh
./scripts/test_mec_connectivity.sh

# 7. Teardown & Clean Reset (when finished)
sudo ./scripts/teardown_network.sh
```

---

## APN & Slice Mapping for UEs

| APN Name | Subnet | Slice (SST/SD) | Purpose | Access Capabilities |
| :--- | :---: | :---: | :--- | :--- |
| **`internet`** | `10.45.0.0/16` | 1 / 1 | Public Internet Browsing | Public Internet, Speedtest, App downloads |
| **`mec-secure`** | `10.46.0.0/16` | 1 / 2 | Private Edge Cloud (MEC) | Local Portal (`http://192.168.50.2:8000`) + Public Internet |
| **`critical`** | `10.46.0.0/16` | 1 / 2 | URLLC Control | Low-latency mission critical communication |
| **`iot`** | `10.47.0.0/16` | 1 / 3 | Camera / Sensors | IoT telemetry & RTSP video streaming |
