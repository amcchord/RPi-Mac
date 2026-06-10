#!/bin/bash
# RPi-Mac image build wrapper.
#
# Idempotent: safe to re-run; caches the payload download, only installs
# missing host packages, and regenerates config from the environment.
#
# Environment overrides:
#   WIFI_SSID / WIFI_PASS  default WiFi credentials baked into mac.txt
#   WIFI_COUNTRY           WiFi regulatory domain (default US)
#   PAYLOAD_URL            where to fetch the ROM/OS payload zip
#   WORK_DIR               pi-gen scratch directory (default <repo>/work)
#   DEPLOY_DIR             output directory (default <repo>/deploy)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -E -- "$0" "$@"
fi

PAYLOAD_URL="${PAYLOAD_URL:-https://www.mcchord.net/static/sdCard.zip}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASS="${WIFI_PASS:-}"
WIFI_COUNTRY="${WIFI_COUNTRY:-US}"
WORK_DIR="${WORK_DIR:-${REPO_DIR}/work}"
DEPLOY_DIR="${DEPLOY_DIR:-${REPO_DIR}/deploy}"

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
mkdir -p "${CACHE_DIR}" "${PAYLOAD_DIR}"
if [ ! -f "${CACHE_DIR}/sdCard.zip" ]; then
	echo ">>> Downloading payload from ${PAYLOAD_URL}"
	wget -O "${CACHE_DIR}/sdCard.zip.part" "${PAYLOAD_URL}"
	mv "${CACHE_DIR}/sdCard.zip.part" "${CACHE_DIR}/sdCard.zip"
fi

for FILE in Q650.ROM Macintosh8.dsk BasiliskII_XPRAM; do
	if [ ! -f "${PAYLOAD_DIR}/${FILE}" ]; then
		echo ">>> Extracting ${FILE} from payload"
		unzip -o -j "${CACHE_DIR}/sdCard.zip" "sdCard/${FILE}" -d "${PAYLOAD_DIR}"
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
export IMG_NAME="RPi-Mac"
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
EOF

# Only export the image from our custom stage, not the intermediate lite one
touch "${PIGEN_DIR}/stage2/SKIP_IMAGES"

# -------------------------------------------------------------------- build ---
echo ">>> Starting pi-gen build (logs in ${WORK_DIR}/build.log)"
cd "${PIGEN_DIR}"
./build.sh -c "${CONFIG_FILE}"

echo ">>> Build complete. Images in ${DEPLOY_DIR}:"
ls -lh "${DEPLOY_DIR}"
