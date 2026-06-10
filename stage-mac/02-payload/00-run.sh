#!/bin/bash -e

# Install the Macintosh ROM, bootable Mac OS 8 disk image and PRAM file
# extracted from the payload zip by scripts/build.sh.

PAYLOAD_DIR="${STAGE_DIR}/../cache/payload"

if [ ! -f "${PAYLOAD_DIR}/Q650.ROM" ] || [ ! -f "${PAYLOAD_DIR}/Macintosh8.dsk" ]; then
	echo "ERROR: payload not found in ${PAYLOAD_DIR}." >&2
	echo "Run scripts/build.sh which downloads and extracts sdCard.zip first." >&2
	exit 1
fi

install -v -d -m 755 "${ROOTFS_DIR}/opt/rpimac"
install -v -d -m 775 -o 1000 -g 1000 "${ROOTFS_DIR}/opt/rpimac/disks"
install -v -d -m 775 -o 1000 -g 1000 "${ROOTFS_DIR}/opt/rpimac/isos"
install -v -d -m 775 -o 1000 -g 1000 "${ROOTFS_DIR}/opt/rpimac/shared"

install -v -m 644 -o 1000 -g 1000 "${PAYLOAD_DIR}/Q650.ROM" "${ROOTFS_DIR}/opt/rpimac/Q650.ROM"
install -v -m 664 -o 1000 -g 1000 "${PAYLOAD_DIR}/Macintosh8.dsk" "${ROOTFS_DIR}/opt/rpimac/disks/Macintosh8.dsk"

if [ -f "${PAYLOAD_DIR}/BasiliskII_XPRAM" ]; then
	install -v -m 664 -o 1000 -g 1000 "${PAYLOAD_DIR}/BasiliskII_XPRAM" "${ROOTFS_DIR}/opt/rpimac/xpram"
fi
