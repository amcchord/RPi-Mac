#!/bin/bash -e

# Generate the classicmac Plymouth theme into ${DEST}: one variant per output
# rotation (classicmac = 0 degrees, classicmac90/180/270) from the shared
# template, plus the initramfs hook. DEST-aware so it works from the pi-gen
# host stage and the Orange Pi Armbian customize-image hook. Idempotent.
#
# rpimac-boot-config selects the variant matching the configured rotation via
# plymouth.splash= on the kernel command line. Activating the theme and
# rebuilding the initramfs (plymouth-set-default-theme + update-initramfs) must
# run inside the target chroot and is left to the caller.
#
# Environment:
#   RPIMAC_THEME_SRC   files/classicmac directory (templates + assets, required)
#   RPIMAC_FILES_DIR   directory containing initramfs-hook (required)
#   RPIMAC_DEST        target rootfs prefix (default "" = the running root)
set -eu

THEME_SRC="${RPIMAC_THEME_SRC:?RPIMAC_THEME_SRC not set}"
FILES_DIR="${RPIMAC_FILES_DIR:?RPIMAC_FILES_DIR not set}"
DEST="${RPIMAC_DEST:-}"

for ROT in 0 90 180 270; do
	THEME="classicmac"
	if [ "${ROT}" != "0" ]; then
		THEME="classicmac${ROT}"
	fi
	TDEST="${DEST}/usr/share/plymouth/themes/${THEME}"
	install -v -d "${TDEST}"
	sed -e "s/__ROTATION__/${ROT}/g" -e "s/__THEME__/${THEME}/g" \
		"${THEME_SRC}/classicmac.plymouth" > "${TDEST}/${THEME}.plymouth"
	sed -e "s/__ROTATION__/${ROT}/g" \
		"${THEME_SRC}/classicmac.script" > "${TDEST}/${THEME}.script"
	chmod 644 "${TDEST}/${THEME}.plymouth" "${TDEST}/${THEME}.script"
	install -v -m 644 "${THEME_SRC}/checker.png" "${TDEST}/checker.png"
	install -v -m 644 "${THEME_SRC}/white.png" "${TDEST}/white.png"
	install -v -m 644 "${THEME_SRC}/happymac${ROT}.png" "${TDEST}/happymac${ROT}.png"
done

# Pull the variants into the initramfs alongside the default theme.
install -v -D -m 755 "${FILES_DIR}/initramfs-hook" \
	"${DEST}/etc/initramfs-tools/hooks/plymouth-classicmac"
