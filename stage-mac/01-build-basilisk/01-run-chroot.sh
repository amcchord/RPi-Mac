#!/bin/bash -e

# Build Basilisk II via the shared provisioning script staged into the chroot
# by 00-run.sh. The build itself (configure flags, CPU tuning, dependency
# purge) lives in provision/build-basilisk.sh so the pi-gen and Orange Pi
# (Armbian) image builds share one implementation. Idempotent: skips when the
# binary is already present (00-run.sh then never staged the source/script).

if [ -x /usr/local/bin/BasiliskII ]; then
	echo "BasiliskII already built, skipping"
	exit 0
fi

/tmp/macemu-src/build-basilisk.sh /tmp/macemu-src
