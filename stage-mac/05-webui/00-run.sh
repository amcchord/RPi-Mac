#!/bin/bash -e

# Install the web control panel application.

WEBUI_SRC="${STAGE_DIR}/../webui"

if [ ! -f "${WEBUI_SRC}/app.py" ]; then
	echo "ERROR: webui sources not found at ${WEBUI_SRC}" >&2
	exit 1
fi

rm -rf "${ROOTFS_DIR}/opt/rpimac/webui"
mkdir -p "${ROOTFS_DIR}/opt/rpimac/webui"
rsync -a --exclude='__pycache__' "${WEBUI_SRC}/" "${ROOTFS_DIR}/opt/rpimac/webui/"
