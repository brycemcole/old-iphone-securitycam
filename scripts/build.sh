#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

find_theos
cd "$PROJECT"
make clean package

echo
echo "Latest package:"
ls -t "$PROJECT"/packages/*.deb | head -n1
