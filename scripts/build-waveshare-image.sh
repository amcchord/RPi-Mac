#!/bin/bash
# Build the Waveshare release flavour: identical to the standard release
# except the Waveshare 2.8" DPI LCD is the default display, so it works
# on that panel straight after flashing - no mac.txt editing needed.
# Produces image_<date>-RPi-Mac-Waveshare.img.xz.
#
# Wraps scripts/build.sh; safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export DISPLAY_DEFAULT="dpi28"
export IMG_VARIANT="Waveshare"

echo ">>> Building Waveshare release image (display '${DISPLAY_DEFAULT}')"
exec "${SCRIPT_DIR}/build.sh" "$@"
