# Private 5G System Operations Runbook

> [!NOTE]
> **Quick Reference Guide**: Use this runbook to manage, operate, verify, and teardown the Private 5G network (Open5GS + srsRAN gNB + USRP X310 + Multi-Namespace Data Plane & MEC).

---

## 🗺️ Daily Operational Flowchart

```mermaid
graph TD
    A --> B[1. Verify USRP\n`uhd_find_devices`] 
    B --> C[2. Setup Network\n`1_setup_network.sh`]
    C --> D[3. Start Core\n`start_core.sh`]
    D --> E[4. Start UPFs\n`start_upfs.sh`]
    E --> F[5. Setup MEC\n`setup_mec.sh`]
    F --> G[6. Launch gNodeB\n`start_gnb.sh`]
    G --> H[7. Test Connectivity\n`test_mec_connectivity.sh`]
    H --> I[8. Teardown Network\n`teardown_network.sh`]
```

---

## 1. 🔍 Pre-Flight Check (USRP X310 Radio)

Ensure the USRP X310 is powered **ON** and the Ethernet cable is connected to `eno1`.

```bash
# Verify USRP X310 is detected over Ethernet
uhd_find_devices
```
> [!TIP]
> *Expected output: UHD Device 0, type: x300, product: X310, addr: 192.168.10.2*

---

## 2. 🌐 Step 1: Create Network Topology & Isolate USRP

Creates `ueran-ns`, `upf1-ns`, `upf2-ns`, isolates `eno1` (MTU 9000), and configures host routes and NAT.

```bash
sudo ./scripts/1_setup_network.sh
```

**Key Results:**
- `ueran-ns`: `10.200.1.2` (Host: `10.200.1.1`) + `eno1` (`192.168.10.1`, MTU 9000)
- `upf1-ns`: `10.200.3.2` (Host: `10.200.3.1`)
- `upf2-ns`: `10.200.4.2` (Host: `10.200.4.1`)
- Host routes to `10.45.0.0/16` and `10.46.0.0/16` established

---

## 3. 🧠 Step 2: Start 5G Core Control Plane

Deploys configuration templates and restarts Open5GS control plane services (AMF, SMF, NRF, etc.).

```bash
sudo ./scripts/start_core.sh
```

**Key Results:**
- Host `open5gs-upfd` is stopped/disabled to prevent port conflicts.
- AMF NGAP server listening on `10.200.1.1:38412`.
- SMF PFCP server listening on `10.200.1.1:8805`.

---

## 4. 🔗 Step 3: Start Dual UPFs (Internet & MEC Slices)

Initializes TUN devices (`ogstun`, `ogstun2`) and starts namespaced UPF daemons.

```bash
sudo ./scripts/start_upfs.sh
```

**Key Results:**
- `upf1-ns`: UPF1 active (`ogstun` `10.45.0.1/16` - Internet slice)
- `upf2-ns`: UPF2 active (`ogstun` `10.46.0.1/16` - MEC slice, `ogstun2` `10.47.0.1/16` - IoT slice)

---

## 5. 🏢 Step 4: Setup Isolated MEC Application Domain

Initializes `mec-app-ns` and activates Policy-Based Routing (Table 200).

```bash
sudo ./setup_mec.sh

# Start lightweight MEC web service on 192.168.50.2:8000 for UE testing
sudo ./scripts/start_mec_app.sh
```

> [!IMPORTANT]
> **Key Results:**
> - `mec-app-ns`: `192.168.50.2/24` (Gateway: `192.168.50.1`).
> - Table 200 enforces that **only** UPF2 traffic (`10.46.0.0/16`) can access `192.168.50.2`.
> - Host and UPF1 are strictly blocked.
> - Test web portal available at `http://192.168.50.2:8000` for UEs on `mec-secure` slice.

---

## 6. 🩺 Step 5: System Diagnostics & Health Check

Run non-destructive status checks across all components:

```bash
# Check all namespaces, link pings, USRP status, and NF daemons
./scripts/check_status.sh

# Check MEC connectivity and verify security isolation
./scripts/test_mec_connectivity.sh
```

---

## 7. 📡 Step 6: Launch srsRAN 5G gNodeB (RF Transmission)

Starts cell transmission on **Band n78 (3.5 GHz)** connecting to AMF at `10.200.1.1`.

```bash
sudo ./scripts/start_gnb.sh
```

**Key Results:**
- gNB binds to `10.200.1.2` and connects to AMF over NGAP (`10.200.1.1:38412`).
- USRP X310 starts transmitting 5G NR carrier (DL ARFCN 632628, 20 MHz, PLMN 00101, TAC 1).
- Press `Ctrl+C` to terminate the gNodeB.

---

## 8. 📱 Testing from UE (Physical Smartphone or UPF2)

### A. Physical 5G Smartphone over RF
1. Insert provisioned SIM card (PLMN: `00101`).
2. Configure phone APN settings:
   - **Internet access:** APN name = `internet` (Receives IP `10.45.x.x`)
   - **MEC access:** APN name = `critical` (Receives IP `10.46.x.x`)
3. Connect phone to the 5G network.
4. From phone browser or terminal (Termux):
   ```bash
   # Ping MEC server
   ping 192.168.50.2

   # Query HTTP service
   curl http://192.168.50.2:8000/
   ```

### B. Testing Direct Connectivity from UPF2
```bash
# Ping MEC server from inside UPF2
sudo ip netns exec upf2-ns ping -c 3 192.168.50.2

# Ping with UE gateway source address (10.46.0.1)
sudo ip netns exec upf2-ns ping -I 10.46.0.1 -c 3 192.168.50.2

# Query HTTP service from UPF2
sudo ip netns exec upf2-ns curl http://192.168.50.2:8000/
```

> [!WARNING]
> **Note:** Never run `ping -I ogstun 192.168.50.2`. Passing an interface name forces device binding, sending packets into the UPF tunnel rather than the upstream gateway. Use `ping -c 3 192.168.50.2` or `ping -I 10.46.0.1 192.168.50.2`.

### C. Testing a Sample Service in `mec-app-ns`
```bash
# Start a sample HTTP server in mec-app-ns (in a background terminal)
sudo ip netns exec mec-app-ns python3 -m http.server 8000 --bind 192.168.50.2

# Or launch RTSP video stream viewer
sudo ip netns exec mec-app-ns ffplay "rtsp://admin:admin123@10.47.0.4:554/avstream/channel=1/stream=0.sdp"
```

---

## 9. 📊 Live Monitoring Dashboards

Open separate terminal tabs to monitor all logs in real-time:

| Component | Log File / Command |
| :--- | :--- |
| **AMF (Control Plane)** | `sudo tail -f /var/log/open5gs/amf.log` |
| **SMF (Session Mgmt)** | `sudo tail -f /var/log/open5gs/smf.log` |
| **UPF1 (Internet Data Plane)** | `sudo tail -f /var/log/open5gs/upf_internet.log` |
| **UPF2 (MEC Data Plane)** | `sudo tail -f /var/log/open5gs/upf_mec.log` |
| **srsRAN gNodeB (RF / PHY)** | `sudo tail -f /tmp/gnb.log` |

---

## 10. 🧹 Teardown & Reset

When you finish your work, cleanly restore the system:

```bash
sudo ./scripts/teardown_network.sh
```

**What this restores:**
- Kills running `gnb` and `open5gs-upfd` processes.
- Moves `eno1` back to the Host root namespace (restores IP `192.168.10.1/24`, MTU 9000).
- Deletes `ueran-ns`, `upf1-ns`, `upf2-ns`, and `mec-app-ns`.
- Deletes all `veth` interfaces.
- Flushes Table 200 routing rules and custom iptables NAT entries.
