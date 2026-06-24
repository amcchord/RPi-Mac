#!/bin/bash -e

# Enable RPi-Mac services, grant the emulator user device access and bake the
# default boot configuration. Runs INSIDE the target chroot - the pi-gen stage
# stages it into the rootfs and runs it via on_chroot; the Orange Pi Armbian
# customize-image hook runs it directly from the overlay. Idempotent.
#
# Environment:
#   RPIMAC_FAMILY  rpi | orangepi | orangepi-a733 (passed to rpimac-boot-config)
#   RPIMAC_USER    emulator user (default mac)
set -eu

FAMILY="${RPIMAC_FAMILY:-rpi}"
EMU_USER="${RPIMAC_USER:-mac}"

# Self-heal: a pre-rename incremental build may have left the old
# basilisk.service (and its enable symlink) in the cached rootfs, which would
# run BasiliskII alongside DOSBox-X. Remove it before enabling the new unit.
systemctl disable basilisk.service 2> /dev/null || true
rm -f /etc/systemd/system/basilisk.service \
	/etc/systemd/system/multi-user.target.wants/basilisk.service

for UNIT in \
	rpimac-emulator rpimac-web rpimac-boot-config rpimac-expand-disks \
	rpimac-expand-win98 rpimac-boot-ok rpimac-touch-fix rpimac-wifi-fallback; do
	systemctl enable "${UNIT}.service"
done

# The emulator owns the screen; no login prompt on tty1.
systemctl disable getty@tty1.service

# Keep the splash on screen until the emulator takes over the display.
# rpimac-emulator.service quits plymouth itself with --retain-splash.
systemctl mask plymouth-quit.service
systemctl mask plymouth-quit-wait.service

# Give the emulator user access to DRM, input devices and audio.
usermod -aG video,render,input,audio,tty "${EMU_USER}"

# Persistent journal storage
install -d -m 2755 -g systemd-journal /var/log/journal

# Bake the default settings from mac.txt into the boot configuration so the
# first boot does not need a config-change reboot. RPIMAC_FAMILY pins the boot
# path (the build chroot sees the build host's device tree, not the target's).
RPIMAC_BUILD=1 RPIMAC_FAMILY="${FAMILY}" /usr/local/bin/rpimac-boot-config
