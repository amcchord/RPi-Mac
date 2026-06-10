#!/bin/bash -e

# Install RPi-Mac system files: services, helper scripts, defaults and the
# boot-partition configuration file.

install -v -m 644 files/basilisk.service "${ROOTFS_DIR}/etc/systemd/system/basilisk.service"
install -v -m 644 files/rpimac-web.service "${ROOTFS_DIR}/etc/systemd/system/rpimac-web.service"
install -v -m 644 files/rpimac-boot-config.service "${ROOTFS_DIR}/etc/systemd/system/rpimac-boot-config.service"

install -v -m 755 files/rpimac-basilisk "${ROOTFS_DIR}/usr/local/bin/rpimac-basilisk"
install -v -m 755 files/rpimac-boot-config "${ROOTFS_DIR}/usr/local/bin/rpimac-boot-config"
install -v -m 755 files/rpimac-status "${ROOTFS_DIR}/usr/local/bin/rpimac-status"

install -v -d "${ROOTFS_DIR}/etc/rpimac"
install -v -m 644 files/prefs.default "${ROOTFS_DIR}/etc/rpimac/prefs.default"

install -v -m 644 files/zram-generator.conf "${ROOTFS_DIR}/etc/systemd/zram-generator.conf"

install -v -d "${ROOTFS_DIR}/etc/systemd/journald.conf.d"
install -v -m 644 files/journald.conf "${ROOTFS_DIR}/etc/systemd/journald.conf.d/rpimac.conf"

# Seed mac.txt on the boot partition, substituting build-time WiFi settings
install -v -m 755 files/mac.txt "${ROOTFS_DIR}/boot/firmware/mac.txt"
sed -i \
	-e "s|__WIFI_SSID__|${WIFI_SSID:-}|" \
	-e "s|__WIFI_PASS__|${WIFI_PASS:-}|" \
	-e "s|__WIFI_COUNTRY__|${WIFI_COUNTRY:-US}|" \
	-e "s|__DISPLAY_DEFAULT__|${DISPLAY_DEFAULT:-hdmi}|" \
	"${ROOTFS_DIR}/boot/firmware/mac.txt"
