#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$PROJECT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$PROJECT/.env"
  set +a
fi

DEVICE_IP="${DEVICE_IP:-}"
DEVICE_USER="${DEVICE_USER:-root}"
DEVICE_PASS="${DEVICE_PASS:-alpine}"
LAUNCH_DAEMON_PLIST="/Library/LaunchDaemons/com.github.bryce.securitycamd.plist"

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Missing required command: $name" >&2
    exit 2
  fi
}

require_device_ip() {
  if [[ -z "$DEVICE_IP" ]]; then
    echo "Set DEVICE_IP to the jailbroken iPhone address." >&2
    echo "Example: DEVICE_IP=192.168.1.50 $0" >&2
    exit 2
  fi
}

find_theos() {
  if [[ -n "${THEOS:-}" && -d "$THEOS/makefiles" ]]; then
    return
  fi
  if [[ -d "$PROJECT/theos/makefiles" ]]; then
    export THEOS="$PROJECT/theos"
    return
  fi
  if [[ -d "$HOME/theos/makefiles" ]]; then
    export THEOS="$HOME/theos"
    return
  fi
  if [[ -d "/opt/theos/makefiles" ]]; then
    export THEOS="/opt/theos"
    return
  fi
  if [[ -d "/tmp/theos/makefiles" ]]; then
    export THEOS="/tmp/theos"
    return
  fi

  echo "Theos was not found." >&2
  echo "Set THEOS=/path/to/theos or install Theos into one of:" >&2
  echo "  $PROJECT/theos" >&2
  echo "  $HOME/theos" >&2
  echo "  /opt/theos" >&2
  echo "  /tmp/theos" >&2
  exit 2
}

latest_deb() {
  ls -t "$PROJECT"/packages/*.deb 2>/dev/null | head -n1
}
