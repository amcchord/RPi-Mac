#!/bin/bash -e

# Install the classicmac Plymouth theme.

install -v -d "${ROOTFS_DIR}/usr/share/plymouth/themes/classicmac"
install -v -m 644 files/classicmac/classicmac.plymouth "${ROOTFS_DIR}/usr/share/plymouth/themes/classicmac/"
install -v -m 644 files/classicmac/classicmac.script "${ROOTFS_DIR}/usr/share/plymouth/themes/classicmac/"
install -v -m 644 files/classicmac/checker.png "${ROOTFS_DIR}/usr/share/plymouth/themes/classicmac/"
install -v -m 644 files/classicmac/happymac.png "${ROOTFS_DIR}/usr/share/plymouth/themes/classicmac/"
install -v -m 644 files/classicmac/happymac90.png "${ROOTFS_DIR}/usr/share/plymouth/themes/classicmac/"
