#!/bin/bash -e

# Install the Macintosh ROM, Mac OS disk images and install ISO (plus the
# optional Windows payload) via the shared installer, shared with the Orange Pi
# build. The payload is staged into cache/payload by scripts/build.sh.

RPIMAC_DEST="${ROOTFS_DIR}" \
RPIMAC_PAYLOAD="${STAGE_DIR}/../cache/payload" \
	"${STAGE_DIR}/../provision/install-payload.sh"
