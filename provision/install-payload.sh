#!/bin/bash -e

# Install the Macintosh ROM, the Mac OS disk images and the System 7.5.3 install
# ISO into ${DEST}/opt/rpimac, and (when present) the optional Windows 98 mode
# payload. DEST-aware: used by the pi-gen payload stage (RPIMAC_DEST=${ROOTFS_DIR})
# and the Orange Pi Armbian customize-image hook (RPIMAC_DEST=""). Idempotent.
#
# Mac OS 8 (Mac8.dsk) is decompressed at build time so the board boots straight
# into it; Mac OS 7 ships compressed and is expanded on demand from the web UI.
#
# Environment:
#   RPIMAC_PAYLOAD  payload directory (Q650.ROM, Mac8.dsk.zip, ...) (required)
#   RPIMAC_DEST     target rootfs prefix (default "" = the running root)
#
# Files are owned by uid/gid 1000 (the emulator user); the caller must ensure
# that user exists.
set -eu

PAYLOAD_DIR="${RPIMAC_PAYLOAD:?RPIMAC_PAYLOAD not set}"
DEST="${RPIMAC_DEST:-}"

for FILE in Q650.ROM Mac8.dsk.zip Mac7.dsk.zip System753.iso; do
	if [ ! -f "${PAYLOAD_DIR}/${FILE}" ]; then
		echo "ERROR: ${FILE} not found in ${PAYLOAD_DIR}." >&2
		exit 1
	fi
done

install -v -d -m 755 "${DEST}/opt/rpimac"
install -v -d -m 775 -o 1000 -g 1000 "${DEST}/opt/rpimac/disks"
install -v -d -m 775 -o 1000 -g 1000 "${DEST}/opt/rpimac/zips"
install -v -d -m 775 -o 1000 -g 1000 "${DEST}/opt/rpimac/isos"
install -v -d -m 775 -o 1000 -g 1000 "${DEST}/opt/rpimac/shared"

install -v -m 644 -o 1000 -g 1000 "${PAYLOAD_DIR}/Q650.ROM" "${DEST}/opt/rpimac/Q650.ROM"

# Mac OS 8: decompress straight into the disks dir at build time so there is no
# first-boot expansion. Writing to the exact target name avoids relying on the
# filename stored inside the zip.
MAC8_DISK="${DEST}/opt/rpimac/disks/Mac8.dsk"
echo "Expanding Mac8.dsk.zip into the image (no first-boot decompression)..."
unzip -p "${PAYLOAD_DIR}/Mac8.dsk.zip" > "${MAC8_DISK}"
chown 1000:1000 "${MAC8_DISK}"
chmod 664 "${MAC8_DISK}"

install -v -m 664 -o 1000 -g 1000 "${PAYLOAD_DIR}/Mac7.dsk.zip" "${DEST}/opt/rpimac/zips/Mac7.dsk.zip"
install -v -m 664 -o 1000 -g 1000 "${PAYLOAD_DIR}/System753.iso" "${DEST}/opt/rpimac/isos/System753.iso"

# Optional Windows 98 mode payload (DOSBox-X + pre-installed disk). Installed
# only when present; without it the image is Mac-only.
if [ -f "${PAYLOAD_DIR}/dosbox-x-arm64" ] && [ -f "${PAYLOAD_DIR}/Win98.vhd.zip" ]; then
	echo "Installing Windows 98 mode payload (DOSBox-X + disk image)"
	install -v -d -m 775 -o 1000 -g 1000 "${DEST}/opt/rpimac/win98"
	install -v -d -m 775 -o 1000 -g 1000 "${DEST}/opt/rpimac/win98/isos"
	install -v -d -m 775 -o 1000 -g 1000 "${DEST}/opt/rpimac/win98/shared"
	install -v -m 755 "${PAYLOAD_DIR}/dosbox-x-arm64" "${DEST}/usr/local/bin/dosbox-x"
	install -v -m 664 -o 1000 -g 1000 "${PAYLOAD_DIR}/Win98.vhd.zip" "${DEST}/opt/rpimac/zips/Win98.vhd.zip"
else
	echo "Windows 98 mode payload not present; building Mac-only image"
fi
