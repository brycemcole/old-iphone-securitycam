#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_device_ip
require_command sshpass

DEB="${1:-$(latest_deb)}"

if [[ -z "$DEB" || ! -f "$DEB" ]]; then
  echo "No .deb found. Run scripts/build.sh first." >&2
  exit 2
fi

echo "Checking SSH reachability..."
sshpass -p "$DEVICE_PASS" ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  "$DEVICE_USER@$DEVICE_IP" 'echo ok'

echo "Copying $DEB..."
sshpass -p "$DEVICE_PASS" scp \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  "$DEB" "$DEVICE_USER@$DEVICE_IP:/var/root/"

BASE="$(basename "$DEB")"
echo "Installing $BASE..."
sshpass -p "$DEVICE_PASS" ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  "$DEVICE_USER@$DEVICE_IP" \
  "dpkg -i '/var/root/$BASE'; uicache -p /Applications/SecurityCam.app >/dev/null 2>&1 || true; launchctl unload '$LAUNCH_DAEMON_PLIST' >/dev/null 2>&1 || true; launchctl load '$LAUNCH_DAEMON_PLIST' >/dev/null 2>&1 || true"

echo "Installed. Start camera mode with:"
echo "  sshpass -p \"$DEVICE_PASS\" ssh -o StrictHostKeyChecking=no $DEVICE_USER@$DEVICE_IP 'camera-mode on'"
