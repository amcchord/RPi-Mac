#!/bin/bash -e

# Install RPi-Mac system files: services, helper scripts, defaults and the
# boot-partition configuration file.

# The emulator dispatcher runs Basilisk II (Mac) or DOSBox-X (Windows)
# depending on MODE in mac.txt; only one unit ever owns the display.
install -v -m 644 files/rpimac-emulator.service "${ROOTFS_DIR}/etc/systemd/system/rpimac-emulator.service"
install -v -m 644 files/rpimac-web.service "${ROOTFS_DIR}/etc/systemd/system/rpimac-web.service"
install -v -m 644 files/rpimac-boot-config.service "${ROOTFS_DIR}/etc/systemd/system/rpimac-boot-config.service"
install -v -m 644 files/rpimac-boot-ok.service "${ROOTFS_DIR}/etc/systemd/system/rpimac-boot-ok.service"
install -v -m 644 files/rpimac-rescue.service "${ROOTFS_DIR}/etc/systemd/system/rpimac-rescue.service"

install -v -m 644 files/rpimac-expand-disks.service "${ROOTFS_DIR}/etc/systemd/system/rpimac-expand-disks.service"
install -v -m 644 files/rpimac-expand-win98.service "${ROOTFS_DIR}/etc/systemd/system/rpimac-expand-win98.service"

install -v -m 755 files/rpimac-emulator "${ROOTFS_DIR}/usr/local/bin/rpimac-emulator"
install -v -m 755 files/rpimac-basilisk "${ROOTFS_DIR}/usr/local/bin/rpimac-basilisk"
install -v -m 755 files/rpimac-dosbox "${ROOTFS_DIR}/usr/local/bin/rpimac-dosbox"
install -v -m 755 files/rpimac-expand-win98 "${ROOTFS_DIR}/usr/local/bin/rpimac-expand-win98"
install -v -m 755 files/rpimac-boot-config "${ROOTFS_DIR}/usr/local/bin/rpimac-boot-config"
install -v -m 755 files/rpimac-expand-disks "${ROOTFS_DIR}/usr/local/bin/rpimac-expand-disks"
install -v -m 755 files/rpimac-rescue "${ROOTFS_DIR}/usr/local/bin/rpimac-rescue"
install -v -m 755 files/rpimac-touch-fix "${ROOTFS_DIR}/usr/local/bin/rpimac-touch-fix"
install -v -m 644 files/rpimac-touch-fix.service "${ROOTFS_DIR}/etc/systemd/system/rpimac-touch-fix.service"
install -v -m 755 files/rpimac-wifi-fallback "${ROOTFS_DIR}/usr/local/bin/rpimac-wifi-fallback"
install -v -m 644 files/rpimac-wifi-fallback.service "${ROOTFS_DIR}/etc/systemd/system/rpimac-wifi-fallback.service"
install -v -m 755 files/rpimac-status "${ROOTFS_DIR}/usr/local/bin/rpimac-status"

install -v -d "${ROOTFS_DIR}/etc/rpimac"
install -v -m 644 files/prefs.default "${ROOTFS_DIR}/etc/rpimac/prefs.default"
# DOSBox-X base config for Windows mode (the launcher appends the autoexec)
install -v -m 644 files/win98-base.conf "${ROOTFS_DIR}/etc/rpimac/win98-base.conf"

install -v -m 644 files/zram-generator.conf "${ROOTFS_DIR}/etc/systemd/zram-generator.conf"

install -v -d "${ROOTFS_DIR}/etc/systemd/journald.conf.d"
install -v -m 644 files/journald.conf "${ROOTFS_DIR}/etc/systemd/journald.conf.d/rpimac.conf"

# uinput is needed by the web console's virtual keyboard/mouse;
# i2c-dev by the GT911 touchscreen un-wedge helper
install -v -d "${ROOTFS_DIR}/etc/modules-load.d"
printf "uinput\ni2c-dev\n" > "${ROOTFS_DIR}/etc/modules-load.d/rpimac.conf"

# Keep the emulator's /dev/shm screen mirror alive across SSH logouts
install -v -d "${ROOTFS_DIR}/etc/systemd/logind.conf.d"
install -v -m 644 files/logind-rpimac.conf "${ROOTFS_DIR}/etc/systemd/logind.conf.d/rpimac.conf"

# WiFi power saving cripples network throughput on the Zero 2 W
install -v -d "${ROOTFS_DIR}/etc/NetworkManager/conf.d"
install -v -m 644 files/wifi-powersave.conf "${ROOTFS_DIR}/etc/NetworkManager/conf.d/wifi-powersave.conf"

# Fast dirty-page writeback to protect Mac disk images from power cuts
install -v -d "${ROOTFS_DIR}/etc/sysctl.d"
install -v -m 644 files/sysctl-rpimac.conf "${ROOTFS_DIR}/etc/sysctl.d/90-rpimac.conf"

# CPU isolation: system services on core 0, emulator on cores 1-3
install -v -d "${ROOTFS_DIR}/etc/systemd/system.conf.d"
install -v -m 644 files/cpu-affinity.conf "${ROOTFS_DIR}/etc/systemd/system.conf.d/rpimac.conf"

# Seed mac.txt on the boot partition, substituting build-time WiFi settings
install -v -m 755 files/mac.txt "${ROOTFS_DIR}/boot/firmware/mac.txt"
sed -i \
	-e "s|__WIFI_SSID__|${WIFI_SSID:-}|" \
	-e "s|__WIFI_PASS__|${WIFI_PASS:-}|" \
	-e "s|__WIFI_COUNTRY__|${WIFI_COUNTRY:-US}|" \
	-e "s|__DISPLAY_DEFAULT__|${DISPLAY_DEFAULT:-hdmi}|" \
	-e "s|__MODE_DEFAULT__|${MODE_DEFAULT:-mac}|" \
	"${ROOTFS_DIR}/boot/firmware/mac.txt"
