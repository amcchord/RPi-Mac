#!/bin/bash
# RPi-Mac image build wrapper.
#
# Idempotent: safe to re-run; caches the payload download, only installs
# missing host packages, and regenerates config from the environment.
#
# Environment overrides:
#   WIFI_SSID / WIFI_PASS  default WiFi credentials baked into mac.txt
#   WIFI_COUNTRY           WiFi regulatory domain (default US)
#   DISPLAY_DEFAULT        default display in mac.txt: hdmi (default) or dpi28
#   MODE_DEFAULT           default emulator in mac.txt: mac (default) or win
#                          (win requires the Windows payload in PAYLOAD_SRC:
#                          dosbox-x-arm64 and Win98.vhd.zip)
#   IMG_VARIANT            suffix for the image name, e.g. "Waveshare"
#                          produces image_<date>-RPi-Mac-Waveshare.img.xz
#   PAYLOAD_SRC            directory holding the ROM/OS payload files
#                          (default <repo>/docs/components)
#   WORK_DIR               pi-gen scratch directory (default <repo>/work)
#   DEPLOY_DIR             output directory (default <repo>/deploy)
#   PUBLISH                set to 1 to upload the finished image to the
#                          pimac image host (scripts/publish-image.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -E -- "$0" "$@"
fi

PAYLOAD_SRC="${PAYLOAD_SRC:-${REPO_DIR}/docs/components}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASS="${WIFI_PASS:-}"
WIFI_COUNTRY="${WIFI_COUNTRY:-US}"
DISPLAY_DEFAULT="${DISPLAY_DEFAULT:-hdmi}"
MODE_DEFAULT="${MODE_DEFAULT:-mac}"
IMG_VARIANT="${IMG_VARIANT:-}"
WORK_DIR="${WORK_DIR:-${REPO_DIR}/work}"
DEPLOY_DIR="${DEPLOY_DIR:-${REPO_DIR}/deploy}"

IMG_NAME="RPi-Mac"
if [ -n "${IMG_VARIANT}" ]; then
	IMG_NAME="RPi-Mac-${IMG_VARIANT}"
fi

CACHE_DIR="${REPO_DIR}/cache"
PAYLOAD_DIR="${CACHE_DIR}/payload"
PIGEN_DIR="${REPO_DIR}/pi-gen"

# ------------------------------------------------------ host dependencies ---
HOST_DEPS="coreutils quilt parted qemu-user-binfmt debootstrap zerofree zip
dosfstools e2fsprogs libarchive-tools libcap2-bin grep rsync xz-utils file
git curl bc gpg pigz xxd arch-test bmap-tools kmod unzip wget"

MISSING=""
for PKG in ${HOST_DEPS}; do
	if ! dpkg -s "${PKG}" > /dev/null 2>&1; then
		MISSING="${MISSING} ${PKG}"
	fi
done
if [ -n "${MISSING}" ]; then
	echo ">>> Installing host dependencies:${MISSING}"
	apt-get update
	apt-get install -y --no-install-recommends ${MISSING}
fi

# ------------------------------------------------------------- submodule ---
if [ ! -f "${PIGEN_DIR}/build.sh" ]; then
	echo ">>> Initialising pi-gen submodule"
	git -C "${REPO_DIR}" submodule update --init
fi

# ---------------------------------------------------------------- payload ---
# The ROM, the zipped Mac OS disk images and the install CD are kept
# locally (they are Apple-copyrighted, so not in git). Seed the build
# cache from PAYLOAD_SRC; re-copy only when missing or out of date.
mkdir -p "${CACHE_DIR}" "${PAYLOAD_DIR}"
for FILE in Q650.ROM Mac8.dsk.zip Mac7.dsk.zip System753.iso; do
	if [ ! -f "${PAYLOAD_SRC}/${FILE}" ]; then
		echo "ERROR: ${PAYLOAD_SRC}/${FILE} not found." >&2
		echo "Place the payload files (Q650.ROM, Mac8.dsk.zip, Mac7.dsk.zip," >&2
		echo "System753.iso) in ${PAYLOAD_SRC} or set PAYLOAD_SRC." >&2
		exit 1
	fi
	if [ ! -f "${PAYLOAD_DIR}/${FILE}" ] || [ "${PAYLOAD_SRC}/${FILE}" -nt "${PAYLOAD_DIR}/${FILE}" ]; then
		echo ">>> Caching payload file ${FILE}"
		cp "${PAYLOAD_SRC}/${FILE}" "${PAYLOAD_DIR}/${FILE}.part"
		mv "${PAYLOAD_DIR}/${FILE}.part" "${PAYLOAD_DIR}/${FILE}"
	fi
done

# Optional Windows-98 mode payload: the prebuilt (patched) DOSBox-X arm64
# binary and the zipped, pre-installed Windows 98 disk image. When both are
# present in PAYLOAD_SRC the image gains a selectable Windows mode; when they
# are absent the build still produces a normal Mac-only image.
for FILE in dosbox-x-arm64 Win98.vhd.zip; do
	if [ -f "${PAYLOAD_SRC}/${FILE}" ]; then
		if [ ! -f "${PAYLOAD_DIR}/${FILE}" ] || [ "${PAYLOAD_SRC}/${FILE}" -nt "${PAYLOAD_DIR}/${FILE}" ]; then
			echo ">>> Caching optional Windows payload ${FILE}"
			cp "${PAYLOAD_SRC}/${FILE}" "${PAYLOAD_DIR}/${FILE}.part"
			mv "${PAYLOAD_DIR}/${FILE}.part" "${PAYLOAD_DIR}/${FILE}"
		fi
	else
		echo ">>> Optional Windows payload ${FILE} not present; skipping"
		rm -f "${PAYLOAD_DIR}/${FILE}"
	fi
done

# --------------------------------------------------------------- debug key ---
if [ ! -f "${REPO_DIR}/debug/id_rpimac.pub" ]; then
	echo ">>> Generating debug SSH keypair"
	mkdir -p "${REPO_DIR}/debug"
	ssh-keygen -t ed25519 -N "" -C "rpimac-debug" -f "${REPO_DIR}/debug/id_rpimac" -q
fi
DEBUG_PUBKEY="$(cat "${REPO_DIR}/debug/id_rpimac.pub")"

# ----------------------------------------------------------- pi-gen config ---
CONFIG_FILE="${CACHE_DIR}/pigen.config"
cat > "${CONFIG_FILE}" << EOF
export IMG_NAME="${IMG_NAME}"
export RELEASE="trixie"
export DEPLOY_COMPRESSION="xz"
export COMPRESSION_LEVEL="6"
export TARGET_HOSTNAME="rpimac"
export FIRST_USER_NAME="mac"
export FIRST_USER_PASS="rpimac"
export DISABLE_FIRST_BOOT_USER_RENAME="1"
export PASSWORDLESS_SUDO="1"
export ENABLE_SSH="1"
export PUBKEY_SSH_FIRST_USER="${DEBUG_PUBKEY}"
export LOCALE_DEFAULT="en_US.UTF-8"
export KEYBOARD_KEYMAP="us"
export KEYBOARD_LAYOUT="English (US)"
export TIMEZONE_DEFAULT="America/New_York"
export WPA_COUNTRY="${WIFI_COUNTRY}"
export ENABLE_CLOUD_INIT="0"
export STAGE_LIST="stage0 stage1 stage2 ${REPO_DIR}/stage-mac"
export WORK_DIR="${WORK_DIR}"
export DEPLOY_DIR="${DEPLOY_DIR}"
export WIFI_SSID="${WIFI_SSID}"
export WIFI_PASS="${WIFI_PASS}"
export WIFI_COUNTRY="${WIFI_COUNTRY}"
export DISPLAY_DEFAULT="${DISPLAY_DEFAULT}"
export MODE_DEFAULT="${MODE_DEFAULT}"
EOF

# Only export the image from our custom stage, not the intermediate lite one
touch "${PIGEN_DIR}/stage2/SKIP_IMAGES"

# -------------------------------------------------------------------- build ---
echo ">>> Starting pi-gen build (logs in ${WORK_DIR}/build.log)"
cd "${PIGEN_DIR}"
./build.sh -c "${CONFIG_FILE}"

echo ">>> Build complete. Images in ${DEPLOY_DIR}:"
ls -lh "${DEPLOY_DIR}"

# ----------------------------------------------------------------- publish ---
if [ "${PUBLISH:-0}" = "1" ]; then
	echo ">>> Publishing the new image to the pimac image host"
	DEPLOY_DIR="${DEPLOY_DIR}" "${SCRIPT_DIR}/publish-image.sh"
fi
