#!/bin/bash
# Build a development/test image with the Waveshare 2.8inch DPI LCD selected
# as the default display, and (optionally) WiFi pre-baked for convenience.
#
# Wraps scripts/build.sh; safe to re-run.
#
# WiFi credentials are NEVER hardcoded here (this file is committed). Provide
# them via the environment, or via a local, gitignored file next to this
# script named "test-wifi.env", for example:
#
#   WIFI_SSID=MyNetwork
#   WIFI_PASS=mypassword
#   WIFI_COUNTRY=US
#
# Without any of these the image builds with no WiFi baked in (configure it
# later from mac.txt on the SD card or the "RPi-Mac Setup" access point).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load local, gitignored WiFi overrides if present.
if [ -f "${SCRIPT_DIR}/test-wifi.env" ]; then
	set -a
	# shellcheck disable=SC1091
	. "${SCRIPT_DIR}/test-wifi.env"
	set +a
fi

export DISPLAY_DEFAULT="${DISPLAY_DEFAULT:-dpi28}"

echo ">>> Building TEST image: WiFi '${WIFI_SSID:-<none>}', display '${DISPLAY_DEFAULT}'"
exec "${SCRIPT_DIR}/build.sh" "$@"
