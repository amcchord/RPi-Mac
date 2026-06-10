#!/bin/bash -e

# Install the Macintosh ROM, the bootable Mac OS disk images and the
# System 7.5.3 install ISO extracted from the payload zip by scripts/build.sh.

PAYLOAD_DIR="${STAGE_DIR}/../cache/payload"

for FILE in Q650.ROM Macintosh8.dsk Macintosh7.dsk System753.iso; do
	if [ ! -f "${PAYLOAD_DIR}/${FILE}" ]; then
		echo "ERROR: ${FILE} not found in ${PAYLOAD_DIR}." >&2
		echo "Run scripts/build.sh which downloads and extracts sdCard.zip first." >&2
		exit 1
	fi
done

install -v -d -m 755 "${ROOTFS_DIR}/opt/rpimac"
install -v -d -m 775 -o 1000 -g 1000 "${ROOTFS_DIR}/opt/rpimac/disks"
install -v -d -m 775 -o 1000 -g 1000 "${ROOTFS_DIR}/opt/rpimac/isos"
install -v -d -m 775 -o 1000 -g 1000 "${ROOTFS_DIR}/opt/rpimac/shared"

install -v -m 644 -o 1000 -g 1000 "${PAYLOAD_DIR}/Q650.ROM" "${ROOTFS_DIR}/opt/rpimac/Q650.ROM"
install -v -m 664 -o 1000 -g 1000 "${PAYLOAD_DIR}/Macintosh8.dsk" "${ROOTFS_DIR}/opt/rpimac/disks/Macintosh8.dsk"
install -v -m 664 -o 1000 -g 1000 "${PAYLOAD_DIR}/Macintosh7.dsk" "${ROOTFS_DIR}/opt/rpimac/disks/Macintosh7.dsk"
install -v -m 664 -o 1000 -g 1000 "${PAYLOAD_DIR}/System753.iso" "${ROOTFS_DIR}/opt/rpimac/isos/System753.iso"
