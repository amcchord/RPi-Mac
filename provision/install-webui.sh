#!/bin/bash -e

# Install the web control panel into ${DEST}/opt/rpimac/webui. DEST-aware so it
# works from the pi-gen host stage (RPIMAC_DEST=${ROOTFS_DIR}) and the Orange Pi
# Armbian customize-image hook (RPIMAC_DEST=""). Idempotent.
#
# Environment:
#   RPIMAC_WEBUI   web UI source directory (required)
#   RPIMAC_DEST    target rootfs prefix (default "" = the running root)
set -eu

WEBUI_SRC="${RPIMAC_WEBUI:?RPIMAC_WEBUI not set}"
DEST="${RPIMAC_DEST:-}"

if [ ! -f "${WEBUI_SRC}/app.py" ]; then
	echo "ERROR: webui sources not found at ${WEBUI_SRC}" >&2
	exit 1
fi

rm -rf "${DEST}/opt/rpimac/webui"
mkdir -p "${DEST}/opt/rpimac/webui"
rsync -a --exclude='__pycache__' "${WEBUI_SRC}/" "${DEST}/opt/rpimac/webui/"
