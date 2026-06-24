#!/bin/bash -e

# Install the classicmac Plymouth theme (one variant per output rotation) via
# the shared installer, so the pi-gen and Orange Pi builds share it. The theme
# is activated and pulled into the initramfs by 01-run-chroot.sh.

RPIMAC_DEST="${ROOTFS_DIR}" \
RPIMAC_THEME_SRC="$(pwd)/files/classicmac" \
RPIMAC_FILES_DIR="$(pwd)/files" \
	"${STAGE_DIR}/../provision/install-plymouth.sh"
