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

# Optional Windows 98 mode payload: the prebuilt (patched) DOSBox-X binary and
# the zipped, pre-installed Windows disk. Installed only when present in the
# payload cache (seeded by scripts/build.sh); without them the image is
# Mac-only and Windows mode simply has nothing to launch. The Windows install
# ISO is intentionally not shipped - Windows mode boots the pre-installed disk.
if [ -f "${PAYLOAD_DIR}/dosbox-x-arm64" ] && [ -f "${PAYLOAD_DIR}/Win98.vhd.zip" ]; then
	echo "Installing Windows 98 mode payload (DOSBox-X + disk image)"
	install -v -d -m 775 -o 1000 -g 1000 "${ROOTFS_DIR}/opt/rpimac/win98"
	install -v -d -m 775 -o 1000 -g 1000 "${ROOTFS_DIR}/opt/rpimac/win98/isos"
	install -v -d -m 775 -o 1000 -g 1000 "${ROOTFS_DIR}/opt/rpimac/win98/shared"
	install -v -m 755 "${PAYLOAD_DIR}/dosbox-x-arm64" "${ROOTFS_DIR}/usr/local/bin/dosbox-x"
	install -v -m 664 -o 1000 -g 1000 "${PAYLOAD_DIR}/Win98.vhd.zip" "${ROOTFS_DIR}/opt/rpimac/zips/Win98.vhd.zip"
else
	echo "Windows 98 mode payload not present; building Mac-only image"
fi
