#!/bin/bash -e

# Wire up services and permissions inside the image via the shared enable step
# staged by 00-run.sh. RPIMAC_FAMILY pins the Raspberry Pi boot path.

RPIMAC_FAMILY=rpi RPIMAC_USER=mac /tmp/rpimac-enable-services.sh
rm -f /tmp/rpimac-enable-services.sh
