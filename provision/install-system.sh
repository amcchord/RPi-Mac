#!/bin/bash -e

# Install the board-agnostic RPi-Mac system files (systemd units, helper
# scripts, configs and defaults) into a target rootfs. Shared by the pi-gen
# stage (host side, RPIMAC_DEST=${ROOTFS_DIR}) and the Orange Pi Armbian
# customize-image hook (inside the chroot, RPIMAC_DEST="").
#
# Idempotent: every step is an install/overwrite to a fixed path.
#
# Environment:
#   RPIMAC_FILES   directory holding the 03-system-config files/ assets (required)
#   RPIMAC_FAMILY  rpi | orangepi | orangepi-a733 (baked into /etc/rpimac/family)
#   RPIMAC_DEST    target rootfs prefix (default "" = the running root)
#
# Board-specific seeding (mac.txt onto the boot partition, firmware config) is
# deliberately NOT done here - the caller handles it, since the boot layout
# differs per family.
set -eu

FILES="${RPIMAC_FILES:?RPIMAC_FILES not set}"
FAMILY="${RPIMAC_FAMILY:-rpi}"
DEST="${RPIMAC_DEST:-}"

# systemd unit files
for UNIT in \
	rpimac-emulator rpimac-web rpimac-boot-config rpimac-boot-ok rpimac-rescue \
	rpimac-expand-disks rpimac-expand-win98 rpimac-touch-fix rpimac-wifi-fallback; do
	install -v -D -m 644 "${FILES}/${UNIT}.service" "${DEST}/etc/systemd/system/${UNIT}.service"
done

# helper scripts / launchers
for BIN in \
	rpimac-emulator rpimac-basilisk rpimac-dosbox rpimac-expand-win98 \
	rpimac-boot-config rpimac-expand-disks rpimac-rescue rpimac-touch-fix \
	rpimac-wifi-fallback rpimac-status rpimac-detect-board; do
	install -v -D -m 755 "${FILES}/${BIN}" "${DEST}/usr/local/bin/${BIN}"
done

# Emulator defaults and the family marker read by rpimac-boot-config.
install -v -d "${DEST}/etc/rpimac"
printf '%s\n' "${FAMILY}" > "${DEST}/etc/rpimac/family"
install -v -m 644 "${FILES}/prefs.default" "${DEST}/etc/rpimac/prefs.default"
install -v -m 644 "${FILES}/win98-base.conf" "${DEST}/etc/rpimac/win98-base.conf"

# zram swap (size scales with RAM via the generator expression)
install -v -D -m 644 "${FILES}/zram-generator.conf" "${DEST}/etc/systemd/zram-generator.conf"

# journald + logind drop-ins
install -v -D -m 644 "${FILES}/journald.conf" "${DEST}/etc/systemd/journald.conf.d/rpimac.conf"
install -v -D -m 644 "${FILES}/logind-rpimac.conf" "${DEST}/etc/systemd/logind.conf.d/rpimac.conf"

# uinput (web console virtual input) + i2c-dev (GT911 touch un-wedge)
install -v -d "${DEST}/etc/modules-load.d"
printf 'uinput\ni2c-dev\n' > "${DEST}/etc/modules-load.d/rpimac.conf"

# NetworkManager tweaks: no WiFi power save, captive portal for the setup AP
install -v -D -m 644 "${FILES}/wifi-powersave.conf" "${DEST}/etc/NetworkManager/conf.d/wifi-powersave.conf"
install -v -D -m 644 "${FILES}/dnsmasq-captive.conf" "${DEST}/etc/NetworkManager/dnsmasq-shared.d/rpimac-captive.conf"

# Fast dirty-page writeback to protect Mac disk images from power cuts
install -v -D -m 644 "${FILES}/sysctl-rpimac.conf" "${DEST}/etc/sysctl.d/90-rpimac.conf"

# CPU isolation: system services on core 0, emulator on cores 1-3 (all target
# boards are quad-core, so this split holds for every family).
install -v -D -m 644 "${FILES}/cpu-affinity.conf" "${DEST}/etc/systemd/system.conf.d/rpimac.conf"

echo "install-system.sh: installed RPi-Mac system files (family=${FAMILY}, dest='${DEST:-/}')"
