#!/bin/bash -e

# Install RPi-Mac system files: services, helper scripts, defaults and the
# boot-partition configuration file.

PROVISION="${STAGE_DIR}/../provision"

# Board-agnostic system files (units, helper scripts, configs, defaults). The
# same installer is used by the Orange Pi (Armbian) build; here it targets the
# pi-gen rootfs via RPIMAC_DEST.
RPIMAC_DEST="${ROOTFS_DIR}" \
RPIMAC_FILES="$(pwd)/files" \
RPIMAC_FAMILY="${RPIMAC_FAMILY:-rpi}" \
	"${PROVISION}/install-system.sh"

# ---- Raspberry Pi firmware specifics (not shared with the Orange Pi build) ---

# Seed mac.txt on the boot partition, substituting build-time WiFi settings
install -v -m 755 files/mac.txt "${ROOTFS_DIR}/boot/firmware/mac.txt"
sed -i \
	-e "s|__WIFI_SSID__|${WIFI_SSID:-}|" \
	-e "s|__WIFI_PASS__|${WIFI_PASS:-}|" \
	-e "s|__WIFI_COUNTRY__|${WIFI_COUNTRY:-US}|" \
	-e "s|__DISPLAY_DEFAULT__|${DISPLAY_DEFAULT:-hdmi}|" \
	-e "s|__MODE_DEFAULT__|${MODE_DEFAULT:-mac}|" \
	"${ROOTFS_DIR}/boot/firmware/mac.txt"

# Stage the shared service-enable step into the rootfs for 01-run-chroot.sh to
# run inside the chroot (where the host repo is not visible).
install -v -m 755 "${PROVISION}/enable-services.sh" "${ROOTFS_DIR}/tmp/rpimac-enable-services.sh"
