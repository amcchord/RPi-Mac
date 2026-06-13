#!/bin/bash
# Publish the newest built image (plus .bmap/.info sidecars) to the
# pimac image host, where it appears on the downloads page and becomes
# the newest base image for the SD card builder.
#
# Idempotent: rsync skips files the server already has.
#
# Usage:
#   ./scripts/publish-image.sh             publish newest image in deploy/
#   ./scripts/publish-image.sh FILE.img.xz publish a specific image
#
# Environment:
#   PIMAC_HOST     ssh destination (default root@pimac.net)
#   PIMAC_SSH_KEY  private key file for ssh (optional)
#   DEPLOY_DIR     where to look for images (default <repo>/deploy)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
DEPLOY_DIR="${DEPLOY_DIR:-${REPO_DIR}/deploy}"
PIMAC_HOST="${PIMAC_HOST:-root@pimac.net}"
RELEASES_DIR="/srv/pimac/releases"

SSH_OPTS=(-o IdentitiesOnly=yes)
if [ -n "${PIMAC_SSH_KEY:-}" ]; then
	SSH_OPTS+=(-i "${PIMAC_SSH_KEY}")
fi

# ------------------------------------------------------- pick the image ---
IMAGE="${1:-}"
if [ -z "${IMAGE}" ]; then
	IMAGE="$(ls -t "${DEPLOY_DIR}"/image_*-RPi-Mac*.img.xz 2> /dev/null | head -n 1)"
fi
if [ -z "${IMAGE}" ] || [ ! -f "${IMAGE}" ]; then
	echo "No image_*-RPi-Mac.img.xz found in ${DEPLOY_DIR}" >&2
	exit 1
fi

BASENAME="$(basename "${IMAGE}")"
STEM="${BASENAME#image_}"
STEM="${STEM%.img.xz}"

FILES=("${IMAGE}")
for SIDECAR in "${DEPLOY_DIR}/${STEM}.bmap" "${DEPLOY_DIR}/${STEM}.info"; do
	if [ -f "${SIDECAR}" ]; then
		FILES+=("${SIDECAR}")
	fi
done

echo ">>> Publishing to ${PIMAC_HOST}:${RELEASES_DIR}"
for FILE in "${FILES[@]}"; do
	echo "      $(basename "${FILE}") ($(du -h "${FILE}" | cut -f1))"
done

rsync -av --partial --progress \
	--chmod=F644 --chown=pimac:pimac \
	-e "ssh ${SSH_OPTS[*]}" \
	"${FILES[@]}" "${PIMAC_HOST}:${RELEASES_DIR}/"

echo ">>> Published. The image is now live on the downloads page."
