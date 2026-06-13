#!/bin/bash -e

# Install the classicmac Plymouth theme: one variant per output rotation
# (classicmac = 0 degrees, classicmac90/180/270), generated from the
# shared template in files/classicmac. rpimac-boot-config selects the
# variant matching the configured rotation via plymouth.splash= on the
# kernel command line.

for ROT in 0 90 180 270; do
	THEME="classicmac"
	if [ "${ROT}" != "0" ]; then
		THEME="classicmac${ROT}"
	fi
	DEST="${ROOTFS_DIR}/usr/share/plymouth/themes/${THEME}"
	install -v -d "${DEST}"
	sed -e "s/__ROTATION__/${ROT}/g" -e "s/__THEME__/${THEME}/g" \
		files/classicmac/classicmac.plymouth > "${DEST}/${THEME}.plymouth"
	sed -e "s/__ROTATION__/${ROT}/g" \
		files/classicmac/classicmac.script > "${DEST}/${THEME}.script"
	chmod 644 "${DEST}/${THEME}.plymouth" "${DEST}/${THEME}.script"
	install -v -m 644 files/classicmac/checker.png "${DEST}/checker.png"
	install -v -m 644 files/classicmac/white.png "${DEST}/white.png"
	install -v -m 644 "files/classicmac/happymac${ROT}.png" "${DEST}/happymac${ROT}.png"
done

# Pull the variants into the initramfs alongside the default theme.
install -v -d "${ROOTFS_DIR}/etc/initramfs-tools/hooks"
install -v -m 755 files/initramfs-hook "${ROOTFS_DIR}/etc/initramfs-tools/hooks/plymouth-classicmac"
