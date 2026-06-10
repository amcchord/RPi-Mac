#!/bin/bash -e

# Build Basilisk II (SDL2, no X11) from the staged source and install it to
# /usr/local/bin. Build dependencies are removed afterwards to keep the
# image small. Idempotent: skips the build if the binary is already present.

if [ -x /usr/local/bin/BasiliskII ]; then
	echo "BasiliskII already built, skipping"
	exit 0
fi

# libgmp-dev/libmpfr-dev: the non-x86 build uses an MPFR-based 68881 FPU
BUILD_DEPS="build-essential autoconf automake libsdl2-dev libgmp-dev libmpfr-dev patch"

apt-get update
apt-get install -y --no-install-recommends ${BUILD_DEPS}

cd /tmp/macemu-src
patch -p1 < 0001-sdlrotate.patch

cd /tmp/macemu-src/BasiliskII/src/Unix
NO_CONFIGURE=1 ./autogen.sh
./configure \
	--enable-sdl-video \
	--enable-sdl-audio \
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
