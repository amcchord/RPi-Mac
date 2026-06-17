#!/bin/bash -e

# Install the Macintosh ROM, the Mac OS disk images and the System 7.5.3
# install ISO staged into cache/payload by scripts/build.sh.
#
# Mac OS 8 (Mac8.dsk) is decompressed here at build time so the Pi boots
# straight into it with no first-boot expansion step. Mac OS 7 (Mac7.dsk)
# still ships compressed in /opt/rpimac/zips and is expanded only if the
# user installs it from the web UI, keeping the distributed image smaller.

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

# Mac OS 8: decompress straight into the disks dir at build time so there is
# no first-boot expansion. rpimac-expand-disks then has nothing to do for it
# (the target already exists). Writing to the exact target name avoids relying
# on the filename stored inside the zip.
MAC8_DISK="${ROOTFS_DIR}/opt/rpimac/disks/Mac8.dsk"
echo "Expanding Mac8.dsk.zip into the image (no first-boot decompression)..."
unzip -p "${PAYLOAD_DIR}/Mac8.dsk.zip" > "${MAC8_DISK}"
chown 1000:1000 "${MAC8_DISK}"
chmod 664 "${MAC8_DISK}"

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
