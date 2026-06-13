#!/bin/bash
# Assemble a personalised RPi-Mac SD card image from a stock release.
#
# Takes a stock image_*.img.xz, grows it to fit the requested payload,
# loop-mounts both partitions, swaps in the chosen ROM / disks / ISOs,
# rewrites the emulator prefs template and mac.txt, then recompresses.
#
# Must run as root (loop devices + mounts). Emits machine-readable
# progress lines on stdout:  PROGRESS <percent> <message>
#
# Usage:
#   assemble-image.sh --base FILE.img.xz --cache DIR --work DIR --out FILE \
#       --mac-txt FILE --rom FILE --boot disk|cdrom \
#       [--disk FILE]... [--blank NAME:SIZE_MB]... [--iso FILE]...
set -euo pipefail

BASE=""
CACHE_DIR=""
WORK_DIR=""
OUT_FILE=""
MAC_TXT=""
ROM_FILE=""
BOOT_FROM="disk"
DISK_FILES=()
BLANK_SPECS=()
ISO_FILES=()

while [ $# -gt 0 ]; do
	case "$1" in
		--base) BASE="$2"; shift 2 ;;
		--cache) CACHE_DIR="$2"; shift 2 ;;
		--work) WORK_DIR="$2"; shift 2 ;;
		--out) OUT_FILE="$2"; shift 2 ;;
		--mac-txt) MAC_TXT="$2"; shift 2 ;;
		--rom) ROM_FILE="$2"; shift 2 ;;
		--boot) BOOT_FROM="$2"; shift 2 ;;
		--disk) DISK_FILES+=("$2"); shift 2 ;;
		--blank) BLANK_SPECS+=("$2"); shift 2 ;;
		--iso) ISO_FILES+=("$2"); shift 2 ;;
		*) echo "Unknown argument: $1" >&2; exit 2 ;;
	esac
done

for VAR in BASE CACHE_DIR WORK_DIR OUT_FILE MAC_TXT ROM_FILE; do
	if [ -z "${!VAR}" ]; then
		echo "Missing required argument: ${VAR}" >&2
		exit 2
	fi
done

progress() {
	echo "PROGRESS $1 $2"
}

LOOP_DEV=""
MNT_ROOT="${WORK_DIR}/mnt-root"
MNT_BOOT="${WORK_DIR}/mnt-boot"

cleanup() {
	set +e
	if mountpoint -q "${MNT_BOOT}"; then
		umount "${MNT_BOOT}"
	fi
	if mountpoint -q "${MNT_ROOT}"; then
		umount "${MNT_ROOT}"
	fi
	if [ -n "${LOOP_DEV}" ]; then
		losetup -d "${LOOP_DEV}" 2> /dev/null
	fi
}
trap cleanup EXIT

mkdir -p "${WORK_DIR}" "${CACHE_DIR}" "${MNT_ROOT}" "${MNT_BOOT}"

# ------------------------------------------------ decompress (cached) ---
BASE_NAME="$(basename "${BASE}" .xz)"
CACHED_IMG="${CACHE_DIR}/${BASE_NAME}"
if [ ! -f "${CACHED_IMG}" ]; then
	progress 3 "Unpacking the base system image (first time for this release)"
	xz --decompress --keep --stdout --threads=0 "${BASE}" > "${CACHED_IMG}.tmp"
	mv "${CACHED_IMG}.tmp" "${CACHED_IMG}"
fi

progress 8 "Preparing your copy of the system image"
IMG="${WORK_DIR}/rpimac.img"
cp "${CACHED_IMG}" "${IMG}"

# ------------------------------------------------------- grow the image ---
# Always grow by the full payload size plus headroom; the added space is
# zeros, which cost almost nothing after xz, and the filesystem expands
# to fill the SD card on first boot anyway.
PAYLOAD_BYTES=0
for FILE in "${ROM_FILE}" "${DISK_FILES[@]+"${DISK_FILES[@]}"}" "${ISO_FILES[@]+"${ISO_FILES[@]}"}"; do
	SIZE="$(stat -c %s "${FILE}")"
	PAYLOAD_BYTES=$((PAYLOAD_BYTES + SIZE))
	case "${FILE}" in
		*.dsk.zip)
			# Zipped disks are expanded by the Pi on first boot; reserve
			# their expanded size too, so the image fits any card it can
			# be flashed to (the zeros cost ~nothing after xz).
			EXPANDED="$(unzip -l "${FILE}" | awk 'END { print $1 }')"
			case "${EXPANDED}" in
				''|*[!0-9]*) EXPANDED=0 ;;
			esac
			PAYLOAD_BYTES=$((PAYLOAD_BYTES + EXPANDED))
			;;
	esac
done
for SPEC in "${BLANK_SPECS[@]+"${BLANK_SPECS[@]}"}"; do
	SIZE_MB="${SPEC##*:}"
	PAYLOAD_BYTES=$((PAYLOAD_BYTES + SIZE_MB * 1024 * 1024))
done
EXTRA_BYTES=$((PAYLOAD_BYTES + 384 * 1024 * 1024))

progress 12 "Growing the image to fit your selection"
truncate -s "+${EXTRA_BYTES}" "${IMG}"
echo ", +" | sfdisk -N 2 --no-reread --no-tell-kernel "${IMG}" > /dev/null

LOOP_DEV="$(losetup --find --show --partscan "${IMG}")"
for _ in $(seq 1 50); do
	if [ -b "${LOOP_DEV}p2" ]; then
		break
	fi
	sleep 0.1
done
if [ ! -b "${LOOP_DEV}p2" ]; then
	echo "Loop partition ${LOOP_DEV}p2 never appeared" >&2
	exit 1
fi

progress 15 "Expanding the Linux filesystem"
e2fsck -pf "${LOOP_DEV}p2" > /dev/null || true
resize2fs "${LOOP_DEV}p2" > /dev/null 2>&1

mount "${LOOP_DEV}p2" "${MNT_ROOT}"
mount "${LOOP_DEV}p1" "${MNT_BOOT}"

RPIMAC_DIR="${MNT_ROOT}/opt/rpimac"
if [ ! -d "${RPIMAC_DIR}" ]; then
	echo "This does not look like an RPi-Mac image (no /opt/rpimac)" >&2
	exit 1
fi

# -------------------------------------------------- swap in the payload ---
progress 18 "Removing the stock Mac software"
rm -f "${RPIMAC_DIR}"/*.ROM "${RPIMAC_DIR}"/*.rom
rm -f "${RPIMAC_DIR}/disks/"* "${RPIMAC_DIR}/isos/"*
# Stock images ship zipped disks (expanded on first boot); clear those
# too, and make sure the directory exists for the user's picks.
rm -f "${RPIMAC_DIR}/zips/"*
install -d -m 775 -o 1000 -g 1000 "${RPIMAC_DIR}/zips"

TOTAL_ITEMS=$((1 + ${#DISK_FILES[@]} + ${#BLANK_SPECS[@]} + ${#ISO_FILES[@]}))
DONE_ITEMS=0

copy_progress() {
	DONE_ITEMS=$((DONE_ITEMS + 1))
	progress $((20 + DONE_ITEMS * 45 / TOTAL_ITEMS)) "$1"
}

ROM_NAME="$(basename "${ROM_FILE}")"
install -m 644 -o 1000 -g 1000 "${ROM_FILE}" "${RPIMAC_DIR}/${ROM_NAME}"
copy_progress "Installed ROM ${ROM_NAME}"

PREFS_DISKS=()
for FILE in "${DISK_FILES[@]+"${DISK_FILES[@]}"}"; do
	NAME="$(basename "${FILE}")"
	case "${NAME}" in
		*.dsk.zip)
			# Zipped disk: stays compressed on the card; the image's
			# rpimac-expand-disks service expands it on first boot
			# because the prefs reference the expanded disk.
			install -m 664 -o 1000 -g 1000 "${FILE}" "${RPIMAC_DIR}/zips/${NAME}"
			PREFS_DISKS+=("/opt/rpimac/disks/${NAME%.zip}")
			copy_progress "Installed compressed disk ${NAME}"
			;;
		*)
			install -m 664 -o 1000 -g 1000 "${FILE}" "${RPIMAC_DIR}/disks/${NAME}"
			PREFS_DISKS+=("/opt/rpimac/disks/${NAME}")
			copy_progress "Installed disk ${NAME}"
			;;
	esac
done

for SPEC in "${BLANK_SPECS[@]+"${BLANK_SPECS[@]}"}"; do
	NAME="${SPEC%:*}.dsk"
	SIZE_MB="${SPEC##*:}"
	truncate -s "${SIZE_MB}M" "${RPIMAC_DIR}/disks/${NAME}"
	chown 1000:1000 "${RPIMAC_DIR}/disks/${NAME}"
	chmod 664 "${RPIMAC_DIR}/disks/${NAME}"
	PREFS_DISKS+=("/opt/rpimac/disks/${NAME}")
	copy_progress "Created blank disk ${NAME} (${SIZE_MB} MB)"
done

PREFS_ISOS=()
for FILE in "${ISO_FILES[@]+"${ISO_FILES[@]}"}"; do
	NAME="$(basename "${FILE}")"
	install -m 664 -o 1000 -g 1000 "${FILE}" "${RPIMAC_DIR}/isos/${NAME}"
	PREFS_ISOS+=("/opt/rpimac/isos/${NAME}")
	copy_progress "Installed CD-ROM ${NAME}"
done

# ------------------------------------------------- rewrite prefs.default ---
progress 68 "Writing emulator configuration"
PREFS="${MNT_ROOT}/etc/rpimac/prefs.default"
PREFS_NEW="${WORK_DIR}/prefs.new"
{
	echo "rom /opt/rpimac/${ROM_NAME}"
	for DISK in "${PREFS_DISKS[@]+"${PREFS_DISKS[@]}"}"; do
		echo "disk ${DISK}"
	done
	for ISO in "${PREFS_ISOS[@]+"${PREFS_ISOS[@]}"}"; do
		echo "cdrom ${ISO}"
	done
	if [ "${BOOT_FROM}" = "cdrom" ]; then
		echo "bootdriver 32"
	fi
	grep -v -E '^(rom|disk|cdrom|bootdriver) ' "${PREFS}"
} > "${PREFS_NEW}"
install -m 644 "${PREFS_NEW}" "${PREFS}"
rm -f "${PREFS_NEW}"

# The stock image has no /home/mac/.basilisk_ii_prefs (it is created from
# prefs.default on first boot), but clear one out if a future base image
# ever ships with it, so our prefs always win.
rm -f "${MNT_ROOT}/home/mac/.basilisk_ii_prefs"

# -------------------------------------------------------------- mac.txt ---
progress 70 "Writing mac.txt with your network settings"
install -m 755 "${MAC_TXT}" "${MNT_BOOT}/mac.txt"

# ------------------------------------------------------------ unmount ---
umount "${MNT_BOOT}"
umount "${MNT_ROOT}"
losetup -d "${LOOP_DEV}"
LOOP_DEV=""

# ----------------------------------------------------------- compress ---
progress 72 "Compressing your image (this is the long part)"
if command -v pv > /dev/null; then
	pv -n "${IMG}" 2> "${WORK_DIR}/pv.progress" | \
		xz --compress -2 --threads=0 --stdout > "${OUT_FILE}.tmp" &
	XZ_PID=$!
	while kill -0 "${XZ_PID}" 2> /dev/null; do
		PCT="$(tail -n 1 "${WORK_DIR}/pv.progress" 2> /dev/null | tr -cd '0-9')"
		if [ -n "${PCT}" ]; then
			progress $((72 + PCT * 27 / 100)) "Compressing your image (${PCT}%)"
		fi
		sleep 3
	done
	wait "${XZ_PID}"
else
	xz --compress -2 --threads=0 --stdout "${IMG}" > "${OUT_FILE}.tmp"
fi
mv "${OUT_FILE}.tmp" "${OUT_FILE}"
rm -f "${IMG}"

progress 100 "Done"
