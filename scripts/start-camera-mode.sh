#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_device_ip
require_command sshpass

sshpass -p "$DEVICE_PASS" ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  "$DEVICE_USER@$DEVICE_IP" 'camera-mode on'

echo "Waiting for status endpoint..."
sleep 4
curl -sS --max-time 8 "http://$DEVICE_IP:8080/status" || true
echo
echo "RTSP:"
echo "  rtsp://$DEVICE_IP:8554/live"
