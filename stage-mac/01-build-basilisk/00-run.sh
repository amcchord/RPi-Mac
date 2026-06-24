#!/bin/bash -e

# Fetch a pinned macemu source snapshot (cached across builds) and stage it
# plus our patches into the chroot for 01-run-chroot.sh to build.

MACEMU_COMMIT="9a3f687fc1080b1cfdc4e0132a2017d9c734a950"
CACHE_DIR="${STAGE_DIR}/../cache"
TARBALL="${CACHE_DIR}/macemu-${MACEMU_COMMIT}.tar.gz"

if [ -x "${ROOTFS_DIR}/usr/local/bin/BasiliskII" ]; then
	echo "BasiliskII already built, skipping source staging"
	exit 0
fi

mkdir -p "${CACHE_DIR}"
if [ ! -f "${TARBALL}" ]; then
	wget -O "${TARBALL}.part" "https://github.com/kanjitalk755/macemu/archive/${MACEMU_COMMIT}.tar.gz"
	mv "${TARBALL}.part" "${TARBALL}"
fi

rm -rf "${ROOTFS_DIR}/tmp/macemu-src"
mkdir -p "${ROOTFS_DIR}/tmp/macemu-src"
tar -xzf "${TARBALL}" --strip-components=1 -C "${ROOTFS_DIR}/tmp/macemu-src"

install -v -m 644 files/0001-sdlrotate.patch "${ROOTFS_DIR}/tmp/macemu-src/"
install -v -m 644 files/0002-basilisk-perf.patch "${ROOTFS_DIR}/tmp/macemu-src/"
install -v -m 644 files/0003-basilisk-video-perf.patch "${ROOTFS_DIR}/tmp/macemu-src/"
install -v -m 644 files/0004-basilisk-video-fastpath.patch "${ROOTFS_DIR}/tmp/macemu-src/"

# Stage the shared build script (used by both the pi-gen and Orange Pi builds)
# alongside the source so 01-run-chroot.sh can run it inside the chroot.
install -v -m 755 "${STAGE_DIR}/../provision/build-basilisk.sh" "${ROOTFS_DIR}/tmp/macemu-src/build-basilisk.sh"

# Hand the chosen CPU tuning to the in-chroot build (config env vars are not
# guaranteed to survive into the chroot, so pass it through a file).
printf '%s\n' "${MCPU:-cortex-a53}" > "${ROOTFS_DIR}/tmp/macemu-src/.rpimac-mcpu"
