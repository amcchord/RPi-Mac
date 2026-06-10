#!/bin/bash -e

# Activate the classicmac theme and rebuild the initramfs so the splash
# appears as early as possible during boot.

plymouth-set-default-theme classicmac
update-initramfs -u -k all
