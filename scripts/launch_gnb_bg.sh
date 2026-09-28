#!/bin/bash
# launch_gnb_bg.sh - Helper to launch gNodeB in background inside ueran-ns
set -e
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p /opt/srsRAN_gnb
cp "$PROJECT_ROOT/configs/srsran/gnb_x310.yml" /opt/srsRAN_gnb/gnb_config.yml
nohup ip netns exec ueran-ns /usr/local/bin/gnb -c /opt/srsRAN_gnb/gnb_config.yml >> /tmp/gnb.log 2>&1 &
sleep 2
echo "gNB PID: $(pgrep -f "/usr/local/bin/gnb" || echo "failed")"
