#!/bin/bash -e

# Wire up services and permissions inside the image.

# Self-heal: a pre-rename incremental build may have left the old
# basilisk.service (and its enable symlink) in the cached rootfs, which would
# run BasiliskII alongside DOSBox-X. Remove it before enabling the new unit.
systemctl disable basilisk.service 2> /dev/null || true
rm -f /etc/systemd/system/basilisk.service \
	/etc/systemd/system/multi-user.target.wants/basilisk.service

systemctl enable rpimac-emulator.service
systemctl enable rpimac-web.service
systemctl enable rpimac-boot-config.service
systemctl enable rpimac-expand-disks.service
systemctl enable rpimac-expand-win98.service
systemctl enable rpimac-boot-ok.service
systemctl enable rpimac-touch-fix.service
systemctl enable rpimac-wifi-fallback.service

# The emulator owns the screen; no login prompt on tty1.
systemctl disable getty@tty1.service

# Keep the splash on screen until the emulator takes over the display.
# rpimac-emulator.service quits plymouth itself with --retain-splash.
systemctl mask plymouth-quit.service
systemctl mask plymouth-quit-wait.service

# Give the emulator user access to DRM, input devices and audio.
usermod -aG video,render,input,audio,tty mac

# Persistent journal storage
install -d -m 2755 -g systemd-journal /var/log/journal

# Bake the default settings from mac.txt into config.txt/cmdline.txt so the
# first boot does not need a config-change reboot.
RPIMAC_BUILD=1 /usr/local/bin/rpimac-boot-config
