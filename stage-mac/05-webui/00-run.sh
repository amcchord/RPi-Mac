#!/bin/bash -e

# Install the web control panel application via the shared installer (shared
# with the Orange Pi build).

RPIMAC_DEST="${ROOTFS_DIR}" \
RPIMAC_WEBUI="${STAGE_DIR}/../webui" \
	"${STAGE_DIR}/../provision/install-webui.sh"
