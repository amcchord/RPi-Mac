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
for DTBO in "${OVERLAY_SRC}"/*.dtbo; do
	install -v -m 644 "${DTBO}" "${ROOTFS_DIR}/boot/firmware/overlays/"
done

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
