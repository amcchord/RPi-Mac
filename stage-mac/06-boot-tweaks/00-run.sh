#!/bin/bash -e

# Static boot tweaks: hide the firmware rainbow splash and install the
# Waveshare DPI overlay files so DISPLAY=dpi28 works out of the box.
# Dynamic settings (display selection, quiet console) are handled by
# rpimac-boot-config from mac.txt.

CONFIG_TXT="${ROOTFS_DIR}/boot/firmware/config.txt"
OVERLAY_SRC="${STAGE_DIR}/../boot-config/overlays"

if ! grep -q "^# >>> rpimac base" "${CONFIG_TXT}"; then
	cat >> "${CONFIG_TXT}" << 'EOF'

# >>> rpimac base (managed, do not edit) >>>
# Hide the firmware rainbow splash for a clean classic Mac boot
disable_splash=1
boot_delay=0
# <<< rpimac base <<<
EOF
fi

install -v -d "${ROOTFS_DIR}/boot/firmware/overlays"
# The Waveshare DPI overlays (waveshare-28dpi-*, vc4-kms-dpi-2inch8) are needed
# only for DISPLAY=dpi28; they are not redistributable through this repo, so the
# overlay source directory may be absent. Install whatever is present and warn
# (rather than failing the build) when it is not - HDMI builds need nothing
# here. Provide the .dtbo files in ${OVERLAY_SRC} to enable the Waveshare panel.
DTBO_INSTALLED=0
if [ -d "${OVERLAY_SRC}" ]; then
	shopt -s nullglob
	for DTBO in "${OVERLAY_SRC}"/*.dtbo; do
		install -v -m 644 "${DTBO}" "${ROOTFS_DIR}/boot/firmware/overlays/"
		DTBO_INSTALLED=1
	done
	shopt -u nullglob
fi
if [ "${DTBO_INSTALLED}" -eq 0 ]; then
	echo "06-boot-tweaks: no .dtbo overlays in ${OVERLAY_SRC}; DISPLAY=dpi28 (Waveshare) will not work, HDMI is unaffected"
fi

# Mount the FAT boot partition with `flush` so writes to /boot/firmware
# (the per-boot bootcount, config.txt/cmdline.txt, mac.txt from the web UI)
# reach the card promptly instead of lingering in the async page cache. Part
# of the defence against the boot partition corrupting across reboots/power
# cuts. Done here, in our own layer, so the upstream pi-gen submodule (whose
# stage1 ships the base fstab) stays unmodified. Idempotent.
FSTAB="${ROOTFS_DIR}/etc/fstab"
if grep -qE '[[:space:]]/boot/firmware[[:space:]]+vfat[[:space:]]' "${FSTAB}" \
	&& ! grep -qE '/boot/firmware.*flush' "${FSTAB}"; then
	sed -i -E '\#/boot/firmware[[:space:]]+vfat[[:space:]]# s/(vfat[[:space:]]+)([^[:space:]]+)/\1\2,flush/' "${FSTAB}"
	echo "06-boot-tweaks: enabled 'flush' on the /boot/firmware vfat mount"
fi
