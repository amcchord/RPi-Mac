#!/bin/bash -e

# Build Basilisk II (SDL2, no X11) inside a target rootfs from a staged macemu
# source tree and install it to /usr/local/bin. Shared by the pi-gen stage and
# the Orange Pi (Armbian) customize-image hook, both of which stage the source
# (plus this script and the patches) into ${SRC} before invoking it inside the
# chroot. Build dependencies are purged afterwards to keep the image small.
#
# Idempotent: skips the build if the binary is already present.
#
# Usage: build-basilisk.sh [SRC_DIR]   (SRC_DIR default /tmp/macemu-src)
#
# The CPU tuning target is read from ${SRC}/.rpimac-mcpu (default cortex-a53).
# cortex-a53 is the safe baseline: ISA-compatible with and measured perf-neutral
# on the Pi 4 (A72), Pi 5 (A76) and the Allwinner A53 Orange Pi boards.

SRC="${1:-/tmp/macemu-src}"

if [ -x /usr/local/bin/BasiliskII ]; then
	echo "BasiliskII already built, skipping"
	exit 0
fi

# The perf patch switches the FPU to the host IEEE core (hardware double on
# aarch64) instead of the slow MPFR backend, so libgmp-dev/libmpfr-dev are not
# needed to build or run BasiliskII.
BUILD_DEPS="build-essential autoconf automake libsdl2-dev patch"

apt-get update
apt-get install -y --no-install-recommends ${BUILD_DEPS}

cd "${SRC}"
patch -p1 < 0001-sdlrotate.patch
patch -p1 < 0002-basilisk-perf.patch
patch -p1 < 0003-basilisk-video-perf.patch
patch -p1 < 0004-basilisk-video-fastpath.patch

MCPU="cortex-a53"
if [ -f "${SRC}/.rpimac-mcpu" ]; then
	MCPU="$(tr -d '[:space:]' < "${SRC}/.rpimac-mcpu")"
fi
if [ -z "${MCPU}" ]; then
	MCPU="cortex-a53"
fi

# -O3 + LTO + CPU tuning, the unswapped opcode-fetch path
# (-DHAVE_GET_WORD_UNSWAPPED, pairs with the pre-swapped dispatch table), and
# the hardware-double IEEE FPU (--enable-fpu-ieee). The link step uses LDFLAGS
# (not CXXFLAGS), so the optimization flags must be repeated there.
PERF_FLAGS="-O3 -mcpu=${MCPU} -flto -DHAVE_GET_WORD_UNSWAPPED"
export CFLAGS="${PERF_FLAGS}"
export CXXFLAGS="${PERF_FLAGS}"
export LDFLAGS="-O3 -mcpu=${MCPU} -flto"

cd "${SRC}/BasiliskII/src/Unix"
NO_CONFIGURE=1 ./autogen.sh
./configure \
	--enable-sdl-video \
	--enable-sdl-audio \
	--enable-fpu-ieee \
	--without-x \
	--without-gtk \
	--without-mon \
	--without-esd
make -j"$(nproc)"
strip BasiliskII
install -v -m 755 BasiliskII /usr/local/bin/BasiliskII

cd /
rm -rf "${SRC}"

apt-get -y purge ${BUILD_DEPS}
apt-get -y autoremove --purge
apt-get clean
