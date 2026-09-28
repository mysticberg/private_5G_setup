#!/bin/bash
# start_mec_app.sh
# Launch lightweight test HTTP service inside mec-app-ns on 192.168.50.2:8000
set -e

if ! ip netns list | grep -q "mec-app-ns"; then
    echo "[-] Error: Namespace 'mec-app-ns' does not exist."
    exit 1
fi

MEC_DIR=/var/www/mec_app
sudo mkdir -p "$MEC_DIR"
sudo tee "$MEC_DIR/index.html" >/dev/null <<'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Private 5G MEC Edge Cloud</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0f172a; color: #f8fafc; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
        .card { background: #1e293b; border: 1px solid #334155; border-radius: 12px; padding: 2rem; max-width: 480px; box-shadow: 0 20px 25px -5px rgba(0,0,0,0.5); text-align: center; }
        h1 { color: #38bdf8; font-size: 1.6rem; margin-bottom: 0.5rem; }
        .badge { display: inline-block; background: #0284c7; color: white; padding: 0.25rem 0.75rem; border-radius: 9999px; font-size: 0.875rem; font-weight: 600; margin-bottom: 1rem; }
        p { color: #94a3b8; font-size: 0.95rem; line-height: 1.5; }
        .stats { background: #0f172a; border-radius: 8px; padding: 1rem; margin-top: 1.5rem; font-family: monospace; font-size: 0.85rem; color: #a5f3fc; text-align: left; }
    </style>
</head>
<body>
    <div class="card">
        <div class="badge">Slice: mec-secure (SST: 1, SD: 2)</div>
        <h1>MEC Edge Server Active</h1>
        <p>You have successfully routed traffic to the isolated Multi-Access Edge Computing (MEC) domain!</p>
        <div class="stats">
            • Server IP: 192.168.50.2:8000<br>
            • Slice Gateway: 192.168.50.1<br>
            • Isolation: VRF Table 200 (Zero Trust)<br>
            • Test File: <a href="speedtest_10mb.bin" style="color:#38bdf8">speedtest_10mb.bin (10 MB)</a>
        </div>
    </div>
</body>
</html>
EOF

# Create 10MB test file for speed testing
if [ ! -f "$MEC_DIR/speedtest_10mb.bin" ]; then
    sudo truncate -s 10M "$MEC_DIR/speedtest_10mb.bin"
fi

# Kill old instances
sudo pkill -f "python3 -m http.server 8000 --directory $MEC_DIR" 2>/dev/null || true

# Start background server
sudo ip netns exec mec-app-ns nohup python3 -m http.server 8000 --directory "$MEC_DIR" > /var/log/mec_http.log 2>&1 &
sleep 1

if sudo ip netns exec mec-app-ns pgrep -f "http.server 8000" >/dev/null; then
    echo "[✓] MEC HTTP server listening on 192.168.50.2:8000"
else
    echo "[-] Failed to start MEC HTTP server"
    exit 1
fi
