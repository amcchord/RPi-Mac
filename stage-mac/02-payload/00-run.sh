#!/bin/bash -e

# Install the Macintosh ROM, the zipped Mac OS disk images and the
# System 7.5.3 install ISO staged into cache/payload by scripts/build.sh.
#
# The disk images ship compressed (in /opt/rpimac/zips) and are expanded
# on the Pi: Mac8.dsk on first boot (it is referenced by prefs.default),
# Mac7.dsk only if the user installs it from the web UI. This keeps the
# distributed SD image small.

PAYLOAD_DIR="${STAGE_DIR}/../cache/payload"

for FILE in Q650.ROM Mac8.dsk.zip Mac7.dsk.zip System753.iso; do
	if [ ! -f "${PAYLOAD_DIR}/${FILE}" ]; then
		echo "ERROR: ${FILE} not found in ${PAYLOAD_DIR}." >&2
		echo "Run scripts/build.sh which seeds the payload cache first." >&2
		exit 1
	fi
done

install -v -d -m 755 "${ROOTFS_DIR}/opt/rpimac"
install -v -d -m 775 -o 1000 -g 1000 "${ROOTFS_DIR}/opt/rpimac/disks"
install -v -d -m 775 -o 1000 -g 1000 "${ROOTFS_DIR}/opt/rpimac/zips"
install -v -d -m 775 -o 1000 -g 1000 "${ROOTFS_DIR}/opt/rpimac/isos"
install -v -d -m 775 -o 1000 -g 1000 "${ROOTFS_DIR}/opt/rpimac/shared"

install -v -m 644 -o 1000 -g 1000 "${PAYLOAD_DIR}/Q650.ROM" "${ROOTFS_DIR}/opt/rpimac/Q650.ROM"
install -v -m 664 -o 1000 -g 1000 "${PAYLOAD_DIR}/Mac8.dsk.zip" "${ROOTFS_DIR}/opt/rpimac/zips/Mac8.dsk.zip"
install -v -m 664 -o 1000 -g 1000 "${PAYLOAD_DIR}/Mac7.dsk.zip" "${ROOTFS_DIR}/opt/rpimac/zips/Mac7.dsk.zip"
install -v -m 664 -o 1000 -g 1000 "${PAYLOAD_DIR}/System753.iso" "${ROOTFS_DIR}/opt/rpimac/isos/System753.iso"
