#!/bin/bash
# Deploy the image-host code to the server and (re)provision it.
# Idempotent: rsyncs only changes and setup.sh only restarts what changed.
#
# Usage:
#   ./deploy.sh                          deploy to root@pimac.net
#   PIMAC_HOST=root@1.2.3.4 ./deploy.sh  deploy elsewhere
#
# Environment:
#   PIMAC_HOST       ssh destination (default root@pimac.net)
#   PIMAC_SSH_KEY    private key file for ssh (optional)
#   PIMAC_DOMAINS    hostnames passed through to setup.sh (optional)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIMAC_HOST="${PIMAC_HOST:-root@pimac.net}"

SSH_OPTS=(-o IdentitiesOnly=yes)
if [ -n "${PIMAC_SSH_KEY:-}" ]; then
	SSH_OPTS+=(-i "${PIMAC_SSH_KEY}")
fi

echo ">>> Making sure rsync exists on ${PIMAC_HOST}"
ssh "${SSH_OPTS[@]}" "${PIMAC_HOST}" \
	'if ! command -v rsync > /dev/null; then apt-get update -qq && apt-get install -y -qq rsync; fi'

echo ">>> Deploying image-host/ to ${PIMAC_HOST}:/opt/pimac"
rsync -az --delete \
	--exclude '__pycache__' \
	-e "ssh ${SSH_OPTS[*]}" \
	"${SCRIPT_DIR}/" "${PIMAC_HOST}:/opt/pimac/"

echo ">>> Running setup.sh on ${PIMAC_HOST}"
REMOTE_ENV=""
if [ -n "${PIMAC_DOMAINS:-}" ]; then
	REMOTE_ENV="PIMAC_DOMAINS=$(printf '%q' "${PIMAC_DOMAINS}")"
fi
if [ -n "${PIMAC_ADMIN_PASSWORD:-}" ]; then
	REMOTE_ENV="${REMOTE_ENV} PIMAC_ADMIN_PASSWORD=$(printf '%q' "${PIMAC_ADMIN_PASSWORD}")"
fi
ssh "${SSH_OPTS[@]}" "${PIMAC_HOST}" "${REMOTE_ENV} bash /opt/pimac/server/setup.sh"

echo ">>> Deploy complete."
