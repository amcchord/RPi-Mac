#!/bin/bash -e

# Build Basilisk II (SDL2, no X11) from the staged source and install it to
# /usr/local/bin. Build dependencies are removed afterwards to keep the
# image small. Idempotent: skips the build if the binary is already present.

if [ -x /usr/local/bin/BasiliskII ]; then
	echo "BasiliskII already built, skipping"
	exit 0
fi

# The perf patch switches the FPU to the host IEEE core (fpu_ieee.cpp, hardware
# double on aarch64) instead of the slow MPFR arbitrary-precision backend, so
# libgmp-dev/libmpfr-dev are no longer needed to build or run BasiliskII.
BUILD_DEPS="build-essential autoconf automake libsdl2-dev patch"

apt-get update
apt-get install -y --no-install-recommends ${BUILD_DEPS}

cd /tmp/macemu-src
patch -p1 < 0001-sdlrotate.patch
patch -p1 < 0002-basilisk-perf.patch
patch -p1 < 0003-basilisk-video-perf.patch
patch -p1 < 0004-basilisk-video-fastpath.patch

# Performance tuning for the Pi Zero 2 W (Cortex-A53), measured on hardware
# (see PERF-RESULTS.md): -O3 + LTO + A53 tuning, the unswapped opcode-fetch
# path (-DHAVE_GET_WORD_UNSWAPPED, pairs with the pre-swapped dispatch table),
# and the hardware-double IEEE FPU (--enable-fpu-ieee). The link step uses
# LDFLAGS (not CXXFLAGS), so the optimization flags must be repeated there.
PERF_FLAGS="-O3 -mcpu=cortex-a53 -flto -DHAVE_GET_WORD_UNSWAPPED"
export CFLAGS="${PERF_FLAGS}"
export CXXFLAGS="${PERF_FLAGS}"
export LDFLAGS="-O3 -mcpu=cortex-a53 -flto"

cd /tmp/macemu-src/BasiliskII/src/Unix
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
rm -rf /tmp/macemu-src

apt-get -y purge ${BUILD_DEPS}
apt-get -y autoremove --purge
apt-get clean
