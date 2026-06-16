#!/bin/bash
# Dev harness for iterating on Basilisk II performance.
#
# Builds Basilisk II from the pinned macemu snapshot on this (fast, multi-core,
# aarch64) box, then deploys the binary to a Pi Zero 2 W over SSH and collects
# the in-emulator MIPS/fps telemetry. Building here and copying the binary to
# the Pi is dramatically faster than compiling on the Pi itself; both run
# Debian 13 aarch64 so the dynamic libraries match. The binary is always
# tuned for the Pi's CPU with -mcpu=cortex-a53 (never -mcpu=native), so it
# stays runnable on the Cortex-A53.
#
# Idempotent: re-running rebuilds incrementally, re-extracts only when the
# source tree is missing (or FORCE_CLEAN=1), reconfigures only when the build
# flags change, and never duplicates the Pi-side backup or telemetry drop-in.
#
# Usage:
#   scripts/dev-basilisk.sh build            # configure + make on this box
#   scripts/dev-basilisk.sh deploy           # copy binary to the Pi
#   scripts/dev-basilisk.sh bench [SECONDS]  # restart emulator, gather telemetry
#   scripts/dev-basilisk.sh all   [SECONDS]  # build + deploy + bench
#   scripts/dev-basilisk.sh shell  '<cmd>'   # run a command on the Pi
#
# Key environment knobs (all optional):
#   BUILD_NAME       label for this variant's build tree (default "baseline")
#   PERF_CFLAGS      extra C flags     (e.g. "-O3 -flto")
#   PERF_CXXFLAGS    extra C++ flags   (e.g. "-O3 -flto")
#   MCPU             -mcpu value       (default "cortex-a53"; set "" to omit)
#   CONFIGURE_EXTRA  extra ./configure args (e.g. "--enable-fpe=ieee")
#   EXTRA_PATCHES    extra patch files applied after 0001-sdlrotate.patch
#   EXTRA_DEFINES    appended to CXXFLAGS/CFLAGS (e.g. "-DARAM_PAGE_CHECK")
#   NO_STRIP=1       keep symbols (needed for PGO / profiling)
#   FORCE_CLEAN=1    wipe and re-extract this variant's source tree
#   PI_HOST          Pi address  (default 192.168.1.231)
#   PI_USER          Pi user     (default mac)
#   SSH_KEY          private key  (default <repo>/debug/id_rpimac)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"

MACEMU_COMMIT="${MACEMU_COMMIT:-9a3f687fc1080b1cfdc4e0132a2017d9c734a950}"
CACHE_DIR="${REPO_DIR}/cache"
TARBALL="${CACHE_DIR}/macemu-${MACEMU_COMMIT}.tar.gz"
PATCH_DIR="${REPO_DIR}/stage-mac/01-build-basilisk/files"

BUILD_NAME="${BUILD_NAME:-baseline}"
BUILD_ROOT="${REPO_DIR}/work/basilisk-dev"
SRC_DIR="${BUILD_ROOT}/src-${BUILD_NAME}"
UNIX_DIR="${SRC_DIR}/BasiliskII/src/Unix"
ARTIFACT="${BUILD_ROOT}/BasiliskII-${BUILD_NAME}"

MCPU="${MCPU-cortex-a53}"
PERF_CFLAGS="${PERF_CFLAGS:-}"
PERF_CXXFLAGS="${PERF_CXXFLAGS:-}"
EXTRA_DEFINES="${EXTRA_DEFINES:-}"
CONFIGURE_EXTRA="${CONFIGURE_EXTRA:-}"
EXTRA_PATCHES="${EXTRA_PATCHES:-}"

PI_HOST="${PI_HOST:-192.168.1.231}"
PI_USER="${PI_USER:-mac}"
SSH_KEY="${SSH_KEY:-${REPO_DIR}/debug/id_rpimac}"
PI_BIN="/usr/local/bin/BasiliskII"

SSH_OPTS=(-i "${SSH_KEY}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10)

log() { printf '>>> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

pi_ssh() { ssh "${SSH_OPTS[@]}" "${PI_USER}@${PI_HOST}" "$@"; }

# --- compose the build flags -------------------------------------------------
compose_flags() {
	local mcpu_flag=""
	if [ -n "${MCPU}" ]; then
		mcpu_flag="-mcpu=${MCPU}"
	fi
	# Baseline match: when no perf flags are requested, fall back to the
	# autoconf default (-g -O2) by leaving the env unset. Any perf knob
	# switches us to an explicit flag set (which overrides the -O2 default).
	EFFECTIVE_CFLAGS=""
	EFFECTIVE_CXXFLAGS=""
	EFFECTIVE_LDFLAGS=""
	if [ -n "${mcpu_flag}${PERF_CFLAGS}${PERF_CXXFLAGS}${EXTRA_DEFINES}" ]; then
		EFFECTIVE_CFLAGS="-O2 ${mcpu_flag} ${PERF_CFLAGS} ${EXTRA_DEFINES}"
		EFFECTIVE_CXXFLAGS="-O2 ${mcpu_flag} ${PERF_CXXFLAGS} ${EXTRA_DEFINES}"
	fi
	# The link rule uses LDFLAGS (not CXXFLAGS), so -flto / -fprofile-* / -mcpu
	# must also be present at link time. We mirror the CPU tuning plus any
	# explicit PERF_LDFLAGS (set this to "-O3 -flto" etc. for LTO/PGO builds).
	if [ -n "${mcpu_flag}${PERF_LDFLAGS:-}" ]; then
		EFFECTIVE_LDFLAGS="${mcpu_flag} ${PERF_LDFLAGS:-}"
	fi
}

stamp_value() {
	printf '%s|%s|%s|%s|%s|%s|%s\n' \
		"${EFFECTIVE_CFLAGS}" "${EFFECTIVE_CXXFLAGS}" "${EFFECTIVE_LDFLAGS}" \
		"${CONFIGURE_EXTRA}" "${EXTRA_PATCHES}" "${MACEMU_COMMIT}" "${NO_STRIP:-0}"
}

# --- extract + patch a pristine source tree (once) ---------------------------
prepare_source() {
	[ -f "${TARBALL}" ] || die "macemu snapshot not found: ${TARBALL}"
	if [ "${FORCE_CLEAN:-0}" = "1" ]; then
		log "FORCE_CLEAN: removing ${SRC_DIR}"
		rm -rf "${SRC_DIR}"
	fi
	if [ -f "${SRC_DIR}/.patched" ]; then
		return 0
	fi
	log "Extracting macemu ${MACEMU_COMMIT} -> ${SRC_DIR}"
	rm -rf "${SRC_DIR}"
	mkdir -p "${SRC_DIR}"
	tar -xzf "${TARBALL}" --strip-components=1 -C "${SRC_DIR}"
	log "Applying 0001-sdlrotate.patch"
	patch -p1 -d "${SRC_DIR}" < "${PATCH_DIR}/0001-sdlrotate.patch"
	local p
	for p in ${EXTRA_PATCHES}; do
		local path="${p}"
		if [ ! -f "${path}" ]; then
			path="${PATCH_DIR}/${p}"
		fi
		[ -f "${path}" ] || die "patch not found: ${p}"
		log "Applying $(basename "${path}")"
		patch -p1 -d "${SRC_DIR}" < "${path}"
	done
	touch "${SRC_DIR}/.patched"
}

# --- configure (only when flags changed) -------------------------------------
configure_source() {
	local stamp_file="${SRC_DIR}/.configure-stamp"
	local want
	want="$(stamp_value)"
	if [ -f "${UNIX_DIR}/Makefile" ] && [ -f "${stamp_file}" ] && \
	   [ "$(cat "${stamp_file}")" = "${want}" ]; then
		log "Configure up to date (${BUILD_NAME})"
		return 0
	fi
	log "Configuring (${BUILD_NAME})"
	log "  CFLAGS  = ${EFFECTIVE_CFLAGS:-<autoconf default -g -O2>}"
	log "  CXXFLAGS= ${EFFECTIVE_CXXFLAGS:-<autoconf default -g -O2>}"
	log "  EXTRA   = ${CONFIGURE_EXTRA:-<none>}"
	# Only export CFLAGS/CXXFLAGS when we actually have flags to set. Passing
	# an empty (but defined) CXXFLAGS makes autoconf suppress its own default
	# "-g -O2", which would silently produce an unoptimized binary.
	local -a cfg_env=()
	if [ -n "${EFFECTIVE_CFLAGS}" ]; then
		cfg_env+=("CFLAGS=${EFFECTIVE_CFLAGS}")
	fi
	if [ -n "${EFFECTIVE_CXXFLAGS}" ]; then
		cfg_env+=("CXXFLAGS=${EFFECTIVE_CXXFLAGS}")
	fi
	if [ -n "${EFFECTIVE_LDFLAGS}" ]; then
		cfg_env+=("LDFLAGS=${EFFECTIVE_LDFLAGS}")
	fi
	( cd "${UNIX_DIR}"
	  NO_CONFIGURE=1 ./autogen.sh
	  env "${cfg_env[@]}" \
	    ./configure \
	      --enable-sdl-video \
	      --enable-sdl-audio \
	      --without-x \
	      --without-gtk \
	      --without-mon \
	      --without-esd \
	      ${CONFIGURE_EXTRA} )
	# make does not track CXXFLAGS/LDFLAGS changes, so when the flags change we
	# must drop the object files to force a recompile with the new flags. (Plain
	# source edits keep the same stamp and stay incremental.)
	rm -rf "${UNIX_DIR}/obj" "${UNIX_DIR}/BasiliskII"
	printf '%s' "${want}" > "${stamp_file}"
}

build_cmd() {
	compose_flags
	prepare_source
	configure_source
	log "Building (${BUILD_NAME}) with make -j$(nproc)"
	( cd "${UNIX_DIR}" && make -j"$(nproc)" )
	cp "${UNIX_DIR}/BasiliskII" "${ARTIFACT}"
	if [ "${NO_STRIP:-0}" != "1" ]; then
		strip "${ARTIFACT}"
	fi
	log "Built: ${ARTIFACT} ($(du -h "${ARTIFACT}" | cut -f1))"
	# Quick confirmation it is a sane aarch64 ELF.
	file "${ARTIFACT}" | sed 's/^/    /'
}

deploy_cmd() {
	[ -f "${ARTIFACT}" ] || die "no artifact for ${BUILD_NAME}; run build first"
	log "Deploying ${BUILD_NAME} -> ${PI_USER}@${PI_HOST}:${PI_BIN}"
	# One-time backup of the original Pi binary for instant rollback.
	pi_ssh "test -f ${PI_BIN}.orig || sudo cp -a ${PI_BIN} ${PI_BIN}.orig; echo backup-ok"
	pi_ssh "sudo systemctl stop rpimac-emulator || true"
	scp "${SSH_OPTS[@]}" "${ARTIFACT}" "${PI_USER}@${PI_HOST}:/tmp/BasiliskII.new"
	pi_ssh "sudo install -m 755 /tmp/BasiliskII.new ${PI_BIN} && rm -f /tmp/BasiliskII.new && echo installed"
	log "Deployed. (Restore original with: scripts/dev-basilisk.sh restore)"
}

restore_cmd() {
	log "Restoring original Pi binary"
	pi_ssh "sudo systemctl stop rpimac-emulator || true; \
	        test -f ${PI_BIN}.orig && sudo install -m 755 ${PI_BIN}.orig ${PI_BIN} && echo restored; \
	        sudo systemctl start rpimac-emulator"
}

# Ensure the telemetry env var is present in the service, restart the emulator
# (which cold-boots Mac OS = a reproducible workload), then capture the
# per-second telemetry lines and summarise boot-to-steady-state time and
# sustained MIPS.
bench_cmd() {
	local secs="${1:-45}"
	log "Enabling telemetry drop-in on the Pi (idempotent)"
	pi_ssh 'sudo mkdir -p /etc/systemd/system/rpimac-emulator.service.d && \
	        printf "[Service]\nEnvironment=RPIMAC_TELEMETRY=1\n" | \
	          sudo tee /etc/systemd/system/rpimac-emulator.service.d/telemetry.conf >/dev/null && \
	        sudo systemctl daemon-reload && echo telemetry-on'
	# Warm-up boot: a fresh deploy/cold cache makes the first boot read the Mac
	# disk image off the SD card, which dominates and masks CPU changes. Boot
	# once and discard it so the measured boot runs against a warm page cache,
	# leaving the interpreter as the variable. Set WARMUP_S=0 to skip.
	local warmup="${WARMUP_S:-22}"
	if [ "${warmup}" != "0" ]; then
		log "Warm-up boot (${warmup}s, discarded)"
		pi_ssh "sudo systemctl restart rpimac-emulator"
		sleep "${warmup}"
	fi
	log "Restarting emulator and capturing ${secs}s of telemetry"
	pi_ssh "sudo systemctl restart rpimac-emulator"
	local raw
	raw="$(pi_ssh "timeout ${secs} journalctl -u rpimac-emulator -f -o cat --since=now 2>/dev/null | grep -m 1000 'rpimac-telemetry' || true")"
	if [ -z "${raw}" ]; then
		log "No telemetry lines captured. Is the deployed binary telemetry-enabled?"
		return 0
	fi
	printf '%s\n' "${raw}"
	# Summarise. Two headline numbers:
	#   - boot_s:  wall time from first 68k execution to the Finder desktop
	#              becoming idle (the emulator reports this itself, one-shot).
	#   - steady:  sustained interpreter throughput (MIPS) once idle, taken as
	#              the avg/median of the last STEADY_TAIL per-second samples.
	printf '%s\n' "${raw}" | awk -v tail="${STEADY_TAIL:-15}" '
		/boot_complete_s=/ {
			for (i = 1; i <= NF; i++) if ($i ~ /^boot_complete_s=/) boot = substr($i, 17) + 0
		}
		/ mips=/ {
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^mips=/) {
					v = substr($i, 6) + 0
					all[++n] = v
					sum += v
					if (v > max) max = v
				}
			}
		}
		END {
			if (n == 0) { exit }
			start = n - tail + 1
			if (start < 1) start = 1
			tn = 0
			for (i = start; i <= n; i++) { t[++tn] = all[i]; tsum += all[i] }
			for (a = 1; a <= tn; a++) for (b = a + 1; b <= tn; b++) if (t[b] < t[a]) { tmp = t[a]; t[a] = t[b]; t[b] = tmp }
			med = t[int((tn + 1) / 2)]
			bootstr = "n/a"
			if (boot > 0) bootstr = sprintf("%.1fs", boot)
			printf(">>> boot_to_steady=%s  steady_mips(last %d): avg=%.2f median=%.2f  peak=%.2f  samples=%d\n",
				bootstr, tn, tsum / tn, med, max, n)
		}'
}

CMD="${1:-all}"
case "${CMD}" in
	build)   build_cmd ;;
	deploy)  deploy_cmd ;;
	bench)   shift || true; bench_cmd "${1:-75}" ;;
	restore) restore_cmd ;;
	shell)   shift; pi_ssh "$@" ;;
	all)     shift || true; build_cmd; deploy_cmd; bench_cmd "${1:-75}" ;;
	*)       die "unknown command: ${CMD} (build|deploy|bench|restore|shell|all)" ;;
esac
