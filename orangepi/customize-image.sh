#!/bin/bash
# Armbian customize-image hook: provision RPi-Mac onto an Orange Pi image.
#
# Armbian runs this INSIDE the image chroot at the end of the build, with the
# contents of userpatches/overlay/ available at /tmp/overlay. It mirrors the
# pi-gen stage-mac stages by calling the same shared provision/ scripts, so the
# emulator, web UI, services and boot-config behaviour match the Raspberry Pi
# image. Idempotent where the underlying scripts are.
#
# Args (passed by Armbian): $1 RELEASE  $2 LINUXFAMILY  $3 BOARD  $4 BUILD_DESKTOP  $5 ARCH
set -euo pipefail

BOARD="${3:-unknown}"
OVERLAY=/tmp/overlay
PROVISION="${OVERLAY}/provision"
SYS_FILES="${OVERLAY}/stage-mac/03-system-config/files"
PLYMOUTH_FILES="${OVERLAY}/stage-mac/04-plymouth-theme/files"
EMU_USER=mac
EMU_PASS=rpimac

echo ">>> rpimac customize-image: provisioning Orange Pi (board=${BOARD})"
export DEBIAN_FRONTEND=noninteractive

# Build-time settings handed over by scripts/build-orangepi-image.sh.
if [ -f "${OVERLAY}/rpimac-build-env.sh" ]; then
	# shellcheck disable=SC1091
	. "${OVERLAY}/rpimac-build-env.sh"
fi

# ----------------------------------------------------------------- packages ---
# The shared package list, minus Raspberry Pi-only packages (pi-bluetooth). The
# Mali G31 GLES2 path uses Mesa/Panfrost (libgl1-mesa-dri + libegl/ libgles2,
# already in the list).
PKGS="$(grep -vE '^[[:space:]]*#' "${OVERLAY}/stage-mac/00-install-packages/00-packages-nr" \
	| tr '\n' ' ' | sed -e 's/pi-bluetooth//g')"
apt-get update
# shellcheck disable=SC2086
apt-get install -y --no-install-recommends ${PKGS}
# Orange Pi extras: NetworkManager (web UI uses nmcli), Bluetooth stack, the
# regulatory tooling used by rpimac-boot-config's iw fallback, and Mesa test
# tools handy for the display spike.
apt-get install -y --no-install-recommends \
	network-manager bluez wireless-regdb iw mesa-utils || true
systemctl enable NetworkManager.service || true

# ---------------------------------------------------------- emulator user ---
# RPi-Mac expects the 'mac' user at uid/gid 1000 (the payload is owned by it).
# Disable Armbian's interactive first-login account wizard.
if ! getent group "${EMU_USER}" > /dev/null 2>&1; then
	groupadd -g 1000 "${EMU_USER}" || groupadd "${EMU_USER}"
fi
if ! id "${EMU_USER}" > /dev/null 2>&1; then
	useradd -m -u 1000 -g 1000 -s /bin/bash "${EMU_USER}"
fi
echo "${EMU_USER}:${EMU_PASS}" | chpasswd
install -d -m 755 /etc/sudoers.d
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${EMU_USER}" > /etc/sudoers.d/010-rpimac-nopasswd
chmod 440 /etc/sudoers.d/010-rpimac-nopasswd
rm -f /root/.not_logged_in_yet 2> /dev/null || true

if [ -f "${OVERLAY}/debug/id_rpimac.pub" ]; then
	install -d -m 700 -o 1000 -g 1000 "/home/${EMU_USER}/.ssh"
	install -m 600 -o 1000 -g 1000 "${OVERLAY}/debug/id_rpimac.pub" "/home/${EMU_USER}/.ssh/authorized_keys"
fi

echo rpimac > /etc/hostname

# ------------------------------------------------------------- Basilisk II ---
if [ ! -x /usr/local/bin/BasiliskII ]; then
	rm -rf /tmp/macemu-src
	cp -a "${OVERLAY}/macemu-src" /tmp/macemu-src
	/tmp/macemu-src/build-basilisk.sh /tmp/macemu-src
fi

# --------------------------------------------- system files / webui / payload ---
RPIMAC_DEST="" RPIMAC_FILES="${SYS_FILES}" RPIMAC_FAMILY=orangepi \
	"${PROVISION}/install-system.sh"

RPIMAC_DEST="" RPIMAC_THEME_SRC="${PLYMOUTH_FILES}/classicmac" \
	RPIMAC_FILES_DIR="${PLYMOUTH_FILES}" \
	"${PROVISION}/install-plymouth.sh"
plymouth-set-default-theme classicmac || true

RPIMAC_DEST="" RPIMAC_WEBUI="${OVERLAY}/webui" "${PROVISION}/install-webui.sh"

RPIMAC_DEST="" RPIMAC_PAYLOAD="${OVERLAY}/cache/payload" "${PROVISION}/install-payload.sh"

# ------------------------------------------------------ mac.txt onto /boot ---
# Armbian Allwinner images keep boot files on the ext4 partition at /boot.
install -m 644 "${OVERLAY}/orangepi/mac.txt" /boot/mac.txt
sed -i \
	-e "s|__WIFI_SSID__|${WIFI_SSID:-}|" \
	-e "s|__WIFI_PASS__|${WIFI_PASS:-}|" \
	-e "s|__WIFI_COUNTRY__|${WIFI_COUNTRY:-US}|" \
	-e "s|__MODE_DEFAULT__|${MODE_DEFAULT:-mac}|" \
	/boot/mac.txt

# --------------------------------------------- enable services + boot config ---
RPIMAC_FAMILY=orangepi RPIMAC_USER="${EMU_USER}" "${PROVISION}/enable-services.sh"

# Rebuild the initramfs so the classicmac splash is available early.
update-initramfs -u -k all || true

echo ">>> rpimac customize-image: done (board=${BOARD})"
