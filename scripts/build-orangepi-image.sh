#!/bin/bash
# Build RPi-Mac Orange Pi images with the Armbian build framework.
#
# The Orange Pi boards (Zero 2 / Zero 2W / Zero 3) are Allwinner sunxi parts and
# cannot use pi-gen. This wrapper drives Armbian's compile.sh for each board and
# applies our shared provisioning (provision/*.sh) through an Armbian
# customize-image hook, so the resulting images run the same Basilisk II + web
# UI + services stack as the Raspberry Pi image. HDMI output only.
#
# Run as a NORMAL user (Armbian's compile.sh refuses to run as root and uses
# sudo internally). Idempotent: caches the Armbian checkout, the macemu source
# and the payload; re-runs only redo what changed.
#
# Environment overrides:
#   BOARDS         space-separated Armbian board names to build
#                  (default "orangepizero2 orangepizero2w orangepizero3")
#   RELEASE        Armbian userspace release (default trixie; bookworm is a
#                  more conservative fallback if trixie misbehaves)
#   BRANCH         Armbian kernel branch (default current; try edge if HDMI or
#                  Panfrost is not yet working on current)
#   ARMBIAN_REF    git ref of armbian/build to pin (default main; pin a release
#                  tag for reproducible builds)
#   WIFI_SSID / WIFI_PASS / WIFI_COUNTRY   default WiFi baked into mac.txt
#   MODE_DEFAULT   default emulator (mac or win) in mac.txt
#   MCPU           -mcpu for the Basilisk II build (default cortex-a53; the
#                  Allwinner Zero 2/2W/3 are all Cortex-A53)
#   PAYLOAD_SRC    directory with the ROM/OS payload (default <repo>/docs/components)
#   WORK_DIR / DEPLOY_DIR   build scratch / output (default <repo>/work, <repo>/deploy)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"

if [ "$(id -u)" -eq 0 ]; then
	echo "ERROR: run this as a normal user, not root - Armbian's compile.sh" >&2
	echo "manages privilege escalation itself and refuses to run as root." >&2
	exit 1
fi

BOARDS="${BOARDS:-orangepizero2 orangepizero2w orangepizero3}"
RELEASE="${RELEASE:-trixie}"
BRANCH="${BRANCH:-current}"
ARMBIAN_REF="${ARMBIAN_REF:-main}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASS="${WIFI_PASS:-}"
WIFI_COUNTRY="${WIFI_COUNTRY:-US}"
MODE_DEFAULT="${MODE_DEFAULT:-mac}"
MCPU="${MCPU:-cortex-a53}"
PAYLOAD_SRC="${PAYLOAD_SRC:-${REPO_DIR}/docs/components}"
WORK_DIR="${WORK_DIR:-${REPO_DIR}/work}"
DEPLOY_DIR="${DEPLOY_DIR:-${REPO_DIR}/deploy}"

CACHE_DIR="${REPO_DIR}/cache"
PAYLOAD_DIR="${CACHE_DIR}/payload"
ARMBIAN_DIR="${WORK_DIR}/armbian-build"
OVERLAY_DIR="${WORK_DIR}/orangepi-userpatches"
MACEMU_COMMIT="9a3f687fc1080b1cfdc4e0132a2017d9c734a950"

mkdir -p "${CACHE_DIR}" "${PAYLOAD_DIR}" "${WORK_DIR}" "${DEPLOY_DIR}"

# Map an Armbian board name to the image variant suffix used on the host.
board_variant() {
	case "$1" in
		orangepizero2) echo "OrangePiZero2" ;;
		orangepizero2w) echo "OrangePiZero2W" ;;
		orangepizero3) echo "OrangePiZero3" ;;
		*) echo "OrangePi-$1" ;;
	esac
}

# ------------------------------------------------------------------ payload ---
for FILE in Q650.ROM Mac8.dsk.zip Mac7.dsk.zip System753.iso; do
	if [ ! -f "${PAYLOAD_SRC}/${FILE}" ]; then
		echo "ERROR: ${PAYLOAD_SRC}/${FILE} not found." >&2
		echo "Place the payload files in ${PAYLOAD_SRC} or set PAYLOAD_SRC." >&2
		exit 1
	fi
	if [ ! -f "${PAYLOAD_DIR}/${FILE}" ] || [ "${PAYLOAD_SRC}/${FILE}" -nt "${PAYLOAD_DIR}/${FILE}" ]; then
		echo ">>> Caching payload file ${FILE}"
		cp "${PAYLOAD_SRC}/${FILE}" "${PAYLOAD_DIR}/${FILE}.part"
		mv "${PAYLOAD_DIR}/${FILE}.part" "${PAYLOAD_DIR}/${FILE}"
	fi
done
for FILE in dosbox-x-arm64 Win98.vhd.zip; do
	if [ -f "${PAYLOAD_SRC}/${FILE}" ]; then
		if [ ! -f "${PAYLOAD_DIR}/${FILE}" ] || [ "${PAYLOAD_SRC}/${FILE}" -nt "${PAYLOAD_DIR}/${FILE}" ]; then
			echo ">>> Caching optional Windows payload ${FILE}"
			cp "${PAYLOAD_SRC}/${FILE}" "${PAYLOAD_DIR}/${FILE}.part"
			mv "${PAYLOAD_DIR}/${FILE}.part" "${PAYLOAD_DIR}/${FILE}"
		fi
	else
		rm -f "${PAYLOAD_DIR}/${FILE}"
	fi
done

# --------------------------------------------------------------- debug key ---
if [ ! -f "${REPO_DIR}/debug/id_rpimac.pub" ]; then
	echo ">>> Generating debug SSH keypair"
	mkdir -p "${REPO_DIR}/debug"
	ssh-keygen -t ed25519 -N "" -C "rpimac-debug" -f "${REPO_DIR}/debug/id_rpimac" -q
fi

# ------------------------------------------------------------- macemu source ---
TARBALL="${CACHE_DIR}/macemu-${MACEMU_COMMIT}.tar.gz"
if [ ! -f "${TARBALL}" ]; then
	echo ">>> Downloading macemu source"
	wget -O "${TARBALL}.part" "https://github.com/kanjitalk755/macemu/archive/${MACEMU_COMMIT}.tar.gz"
	mv "${TARBALL}.part" "${TARBALL}"
fi

# ------------------------------------------------------- assemble overlay ---
echo ">>> Assembling Armbian userpatches overlay in ${OVERLAY_DIR}"
rm -rf "${OVERLAY_DIR}"
mkdir -p "${OVERLAY_DIR}/overlay"
install -m 755 "${REPO_DIR}/orangepi/customize-image.sh" "${OVERLAY_DIR}/customize-image.sh"

OV="${OVERLAY_DIR}/overlay"
mkdir -p "${OV}/provision" "${OV}/stage-mac/00-install-packages" \
	"${OV}/stage-mac/03-system-config" "${OV}/stage-mac/04-plymouth-theme" \
	"${OV}/orangepi" "${OV}/debug"
cp "${REPO_DIR}/provision/"*.sh "${OV}/provision/"
chmod 755 "${OV}/provision/"*.sh
cp "${REPO_DIR}/stage-mac/00-install-packages/00-packages-nr" "${OV}/stage-mac/00-install-packages/"
rsync -a "${REPO_DIR}/stage-mac/03-system-config/files" "${OV}/stage-mac/03-system-config/"
rsync -a "${REPO_DIR}/stage-mac/04-plymouth-theme/files" "${OV}/stage-mac/04-plymouth-theme/"
rsync -a --exclude='__pycache__' "${REPO_DIR}/webui" "${OV}/"
rsync -a "${PAYLOAD_DIR}" "${OV}/cache/"
cp "${REPO_DIR}/orangepi/mac.txt" "${OV}/orangepi/mac.txt"
cp "${REPO_DIR}/debug/id_rpimac.pub" "${OV}/debug/id_rpimac.pub"

# Staged macemu source tree (extracted + patches + shared build script + MCPU).
rm -rf "${OV}/macemu-src"
mkdir -p "${OV}/macemu-src"
tar -xzf "${TARBALL}" --strip-components=1 -C "${OV}/macemu-src"
for PATCH in 0001-sdlrotate 0002-basilisk-perf 0003-basilisk-video-perf 0004-basilisk-video-fastpath; do
	cp "${REPO_DIR}/stage-mac/01-build-basilisk/files/${PATCH}.patch" "${OV}/macemu-src/"
done
install -m 755 "${REPO_DIR}/provision/build-basilisk.sh" "${OV}/macemu-src/build-basilisk.sh"
printf '%s\n' "${MCPU}" > "${OV}/macemu-src/.rpimac-mcpu"

# Build-time settings the customize-image hook reads.
cat > "${OV}/rpimac-build-env.sh" << EOF
WIFI_SSID='${WIFI_SSID}'
WIFI_PASS='${WIFI_PASS}'
WIFI_COUNTRY='${WIFI_COUNTRY}'
MODE_DEFAULT='${MODE_DEFAULT}'
MCPU='${MCPU}'
EOF

# --------------------------------------------------------- armbian checkout ---
if [ ! -d "${ARMBIAN_DIR}/.git" ]; then
	echo ">>> Cloning armbian/build (${ARMBIAN_REF})"
	git clone --depth 1 --branch "${ARMBIAN_REF}" https://github.com/armbian/build.git "${ARMBIAN_DIR}" \
		|| git clone "https://github.com/armbian/build.git" "${ARMBIAN_DIR}"
fi
git -C "${ARMBIAN_DIR}" fetch --depth 1 origin "${ARMBIAN_REF}" 2> /dev/null || true
git -C "${ARMBIAN_DIR}" checkout "${ARMBIAN_REF}" 2> /dev/null || true

# ------------------------------------------------------------------- build ---
DATE="$(date +%Y-%m-%d)"
for BOARD in ${BOARDS}; do
	VARIANT="$(board_variant "${BOARD}")"
	echo ">>> Building Orange Pi image: board=${BOARD} variant=${VARIANT} release=${RELEASE} branch=${BRANCH}"

	"${ARMBIAN_DIR}/compile.sh" build \
		BOARD="${BOARD}" \
		BRANCH="${BRANCH}" \
		RELEASE="${RELEASE}" \
		BUILD_MINIMAL=yes \
		BUILD_DESKTOP=no \
		KERNEL_CONFIGURE=no \
		COMPRESS_OUTPUTS=no \
		USERPATCHES_PATH="${OVERLAY_DIR}" \
		SHARE_LOG=no

	# Collect the freshly built image and republish it under the RPi-Mac name.
	SRC_IMG="$(ls -t "${ARMBIAN_DIR}/output/images/"*.img 2> /dev/null | head -n 1 || true)"
	if [ -z "${SRC_IMG}" ] || [ ! -f "${SRC_IMG}" ]; then
		echo "ERROR: no Armbian image produced for ${BOARD} (check ${ARMBIAN_DIR}/output)" >&2
		exit 1
	fi
	OUT="${DEPLOY_DIR}/image_${DATE}-RPi-Mac-${VARIANT}.img"
	echo ">>> Publishing ${OUT}.xz"
	cp "${SRC_IMG}" "${OUT}"
	rm -f "${OUT}.xz"
	xz -T0 -6 "${OUT}"
done

echo ">>> Orange Pi build complete. Images in ${DEPLOY_DIR}:"
ls -lh "${DEPLOY_DIR}"/image_*-RPi-Mac-OrangePi*.img.xz 2> /dev/null || true
