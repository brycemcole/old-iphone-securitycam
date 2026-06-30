#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

echo "Checking shell scripts..."
for script in "$PROJECT"/scripts/*.sh; do
  bash -n "$script"
done

echo "Checking JavaScript helper syntax..."
for script in "$PROJECT"/scripts/*.js; do
  node --check "$script"
done

echo "Checking package maintainer scripts..."
for script in "$PROJECT"/layout/DEBIAN/postinst "$PROJECT"/layout/DEBIAN/prerm "$PROJECT"/layout/DEBIAN/postrm; do
  test -x "$script"
  sh -n "$script"
done

echo "Checking for local-only paths and addresses..."
private_path='Users[\/]bryce'
old_ip='192[.]168[.]86[.]28'
if rg -n -e "$private_path" -e "$old_ip" "$PROJECT" \
  -g '!/.theos/**' \
  -g '!/packages/**' \
  -g '!/artifacts/**'; then
  echo "Release check failed: remove local-only paths or IPs from source files." >&2
  exit 1
fi

echo "Checking old package id only appears in migration hooks..."
old_package='com[.]bryce'
if rg -n -e "$old_package" "$PROJECT" \
  -g '!/.theos/**' \
  -g '!/packages/**' \
  -g '!/artifacts/**' \
  -g '!/control' \
  -g '!/layout/DEBIAN/postinst'; then
  echo "Release check failed: old private package id appears outside migration hooks." >&2
  exit 1
fi

echo "Release check passed."
