#!/bin/bash
# Build a development/test image with WiFi credentials pre-baked and the
# Waveshare 2.8inch DPI LCD selected as the default display.
#
# Wraps scripts/build.sh; safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export WIFI_SSID="${WIFI_SSID:-SvensHaus}"
export WIFI_PASS="${WIFI_PASS:-montreal19}"
export WIFI_COUNTRY="${WIFI_COUNTRY:-US}"
export DISPLAY_DEFAULT="${DISPLAY_DEFAULT:-dpi28}"

echo ">>> Building TEST image: WiFi '${WIFI_SSID}', display '${DISPLAY_DEFAULT}'"
exec "${SCRIPT_DIR}/build.sh" "$@"
