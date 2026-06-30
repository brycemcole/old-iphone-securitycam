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
  "$DEVICE_USER@$DEVICE_IP" '
echo "ssh=ok"
echo "date=$(date)"
echo "uiopen=$(command -v uiopen || true)"
echo "sbreload=$(command -v sbreload || true)"
echo "camera-mode=$(command -v camera-mode || true)"
test -x /usr/bin/camera-mode && camera-mode status || true
'
