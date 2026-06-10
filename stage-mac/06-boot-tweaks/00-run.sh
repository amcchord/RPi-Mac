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
