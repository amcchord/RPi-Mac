#!/bin/bash
# Provision a Debian machine as a pimac image host. Idempotent: run it
# as often as you like; it only changes what needs changing.
#
# Run as root on the server, from a deployed copy of image-host/
# (deploy.sh does this for you):
#
#   PIMAC_DOMAINS="pimac.net www.pimac.net" bash /opt/pimac/server/setup.sh
#
# Environment:
#   PIMAC_DOMAINS          hostnames for Caddy (default "pimac.net www.pimac.net").
#                          Every name listed must already resolve to this
#                          machine or certificate issuance will fail.
#   PIMAC_ADMIN_PASSWORD   seed the admin password on first setup (optional;
#                          you can also run manage.py set-admin-password later)
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
	echo "setup.sh must run as root" >&2
	exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "${SCRIPT_DIR}")"
PIMAC_ROOT="/srv/pimac"
PIMAC_DOMAINS="${PIMAC_DOMAINS:-pimac.net www.pimac.net}"

echo ">>> Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
	python3 python3-flask python3-waitress \
	xz-utils pv util-linux e2fsprogs mount rsync unzip \
	debian-keyring debian-archive-keyring apt-transport-https curl gnupg

# ------------------------------------------------------------------ caddy ---
if [ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]; then
	echo ">>> Adding the Caddy apt repository"
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
		| gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
fi
if [ ! -f /etc/apt/sources.list.d/caddy-stable.list ]; then
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
		-o /etc/apt/sources.list.d/caddy-stable.list
	apt-get update -qq
fi
if ! dpkg -s caddy > /dev/null 2>&1; then
	echo ">>> Installing Caddy"
	apt-get install -y caddy
fi

# ------------------------------------------------------------ user + dirs ---
if ! id pimac > /dev/null 2>&1; then
	echo ">>> Creating the pimac service user"
	useradd --system --home-dir "${PIMAC_ROOT}" --shell /usr/sbin/nologin pimac
fi

echo ">>> Creating the data layout under ${PIMAC_ROOT}"
install -d -m 755 "${PIMAC_ROOT}"
install -d -m 755 -o pimac -g pimac \
	"${PIMAC_ROOT}/releases" \
	"${PIMAC_ROOT}/library" \
	"${PIMAC_ROOT}/library/roms" \
	"${PIMAC_ROOT}/library/disks" \
	"${PIMAC_ROOT}/library/isos" \
	"${PIMAC_ROOT}/data"
install -d -m 755 "${PIMAC_ROOT}/builds"
install -d -m 700 "${PIMAC_ROOT}/scratch"

# --------------------------------------------------------------- caddyfile ---
echo ">>> Writing /etc/caddy/Caddyfile for: ${PIMAC_DOMAINS}"
DOMAIN_LIST="$(echo "${PIMAC_DOMAINS}" | sed 's/ \+/, /g')"
sed "s|__DOMAINS__|${DOMAIN_LIST}|" "${SCRIPT_DIR}/Caddyfile.template" \
	> /etc/caddy/Caddyfile.new
if [ ! -f /etc/caddy/Caddyfile ] || \
   ! cmp -s /etc/caddy/Caddyfile.new /etc/caddy/Caddyfile; then
	mv /etc/caddy/Caddyfile.new /etc/caddy/Caddyfile
	systemctl reload-or-restart caddy
else
	rm -f /etc/caddy/Caddyfile.new
fi
systemctl enable --now caddy

# ----------------------------------------------------------- systemd units ---
echo ">>> Installing systemd units"
UNITS_CHANGED=0
for UNIT in pimac-web.service pimac-builder.service \
            pimac-cleanup.service pimac-cleanup.timer; do
	if [ ! -f "/etc/systemd/system/${UNIT}" ] || \
	   ! cmp -s "${SCRIPT_DIR}/${UNIT}" "/etc/systemd/system/${UNIT}"; then
		install -m 644 "${SCRIPT_DIR}/${UNIT}" "/etc/systemd/system/${UNIT}"
		UNITS_CHANGED=1
	fi
done
if [ "${UNITS_CHANGED}" = "1" ]; then
	systemctl daemon-reload
fi

# The units expect the code at /opt/pimac
if [ "${INSTALL_DIR}" != "/opt/pimac" ]; then
	echo ">>> NOTE: code is at ${INSTALL_DIR}, but the systemd units run"
	echo ">>>       /opt/pimac - deploy with deploy.sh or copy it there."
fi

# ----------------------------------------------------------- admin password ---
if ! sudo -u pimac PIMAC_ROOT="${PIMAC_ROOT}" \
		python3 /opt/pimac/app/manage.py has-admin-password 2> /dev/null; then
	if [ -n "${PIMAC_ADMIN_PASSWORD:-}" ]; then
		echo ">>> Setting the admin password from PIMAC_ADMIN_PASSWORD"
		sudo -u pimac PIMAC_ROOT="${PIMAC_ROOT}" \
			python3 /opt/pimac/app/manage.py set-admin-password "${PIMAC_ADMIN_PASSWORD}"
	else
		echo ">>> No admin password set yet. Set one with:"
		echo ">>>   sudo -u pimac python3 /opt/pimac/app/manage.py set-admin-password"
	fi
fi

# ------------------------------------------------------------------ start ---
echo ">>> Enabling and starting services"
systemctl enable --now pimac-web.service pimac-builder.service pimac-cleanup.timer
systemctl restart pimac-web.service pimac-builder.service

echo ">>> Done. Site: https://${PIMAC_DOMAINS%% *}/"
