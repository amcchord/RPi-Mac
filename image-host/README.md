# pimac image host

The code behind [pimac.net](https://pimac.net/): a download site and
**SD card builder** for RPi-Mac images, with an admin backend for
managing the library of ROMs, disk images and CD-ROMs.

Visitors can either download a stock release image, or compose a custom
one — pick the Mac OS disks, install CDs and ROM to put on the card,
add blank disks, and enter WiFi/display settings. The server assembles
a personalised `.img.xz` and hands back a private, 24-hour download
link. The UI is styled after the Apple Platinum appearance of Mac OS 8.

## How it works

```
Caddy (automatic HTTPS)
 ├── /releases/*  -> served straight from disk (stock images)
 ├── /builds/*    -> token check via the app, bytes served from disk
 └── everything else -> Flask app (waitress, port 8080)

pimac-web.service      the Flask app, runs as user "pimac"
pimac-builder.service  build worker, runs as root (loop-mounts images)
pimac-cleanup.timer    hourly: deletes expired builds and stale scratch
```

A build job goes through `builder/assemble-image.sh`:

1. Decompress the chosen stock release (cached per release).
2. Grow the image file and its root partition to fit the selection
   (zipped disks are counted at their expanded size, so the image fits
   any card it can be flashed to).
3. Loop-mount both partitions; swap `/opt/rpimac/{ROM,disks,zips,isos}`
   for the user's picks, create requested blank disks, rewrite the disk
   list in `/etc/rpimac/prefs.default` (and `bootdriver 32` for CD
   boot), and write the user's `mac.txt` to the boot partition.
   Disks stored as `.dsk.zip` in the library stay compressed on the
   card (small downloads) and are expanded by the image's
   `rpimac-expand-disks` service on first boot.
4. Recompress with `xz` and publish a tokenized download.

Custom images contain the WiFi password the user typed, so download
links are unguessable and builds are deleted after 24 hours.

## Directory layout

| Path | Purpose |
| --- | --- |
| `app/` | Flask app: public site, builder API, admin backend |
| `builder/` | build worker and the image assembly script |
| `server/` | provisioning script, Caddyfile template, systemd units |
| `deploy.sh` | rsync the code to a server and run setup there |

On the server:

| Path | Purpose |
| --- | --- |
| `/opt/pimac/` | this directory, deployed |
| `/srv/pimac/releases/` | stock `image_*.img.xz` (+ `.bmap`/`.info`) |
| `/srv/pimac/library/{roms,disks,isos}/` | the component library |
| `/srv/pimac/builds/<job>/` | finished custom builds (24 h TTL) |
| `/srv/pimac/scratch/` | build scratch + decompressed base cache |
| `/srv/pimac/data/pimac.db` | SQLite: components, jobs, settings |

## Hosting it yourself

You need a Debian (12+) box with a public IP, a domain pointed at it,
and roughly 40 GB of free disk (the more, the merrier: scratch space
peaks at about 2x the uncompressed image size per build, plus the
library and releases).

1. Point your domain's A/AAAA records at the server. Caddy needs DNS
   to resolve before it can obtain certificates - that is the only
   TLS "setup" there is.

2. From your checkout of this repo:

   ```bash
   cd image-host
   PIMAC_HOST=root@your-server \
   PIMAC_DOMAINS="example.com www.example.com" \
   PIMAC_ADMIN_PASSWORD="something-long" \
   ./deploy.sh
   ```

   `deploy.sh` rsyncs this directory to `/opt/pimac` and runs
   `server/setup.sh` there, which installs Caddy + dependencies,
   creates the `pimac` user and `/srv/pimac` layout, and enables the
   systemd services. Both scripts are idempotent - rerun `deploy.sh`
   any time you change the code.

3. Publish a base image (from the repo root, after `scripts/build.sh`):

   ```bash
   PIMAC_HOST=root@your-server ./scripts/publish-image.sh
   ```

   Or build and publish in one go: `sudo PUBLISH=1 ./scripts/build.sh`
   (pass `PIMAC_HOST` through too if it isn't the default).

4. Stock the library: log into `https://example.com/admin` with your
   admin password and upload a ROM, disk images and ISOs - or seed
   from the shell:

   ```bash
   ssh root@your-server sudo -u pimac python3 /opt/pimac/app/manage.py \
       add-component rom /path/to/Q650.ROM --name "Quadra 650"
   ```

   Disk images may be uploaded either raw (`.dsk`, `.img`, `.hfv`,
   `.hda`) or zipped (`.dsk.zip`, one disk per zip). Zipped disks keep
   custom downloads small: they ride along compressed and are expanded
   on the SD card the first time the Pi boots.

   The builder needs at least one ROM and one release image before it
   can do anything useful.

### Useful knobs

| Variable | Where | Default | Purpose |
| --- | --- | --- | --- |
| `PIMAC_HOST` | `deploy.sh`, `publish-image.sh` | `root@pimac.net` | ssh destination |
| `PIMAC_SSH_KEY` | `deploy.sh`, `publish-image.sh` | unset | ssh identity file |
| `PIMAC_DOMAINS` | `deploy.sh` / `setup.sh` | `pimac.net www.pimac.net` | Caddy site addresses |
| `PIMAC_ADMIN_PASSWORD` | `deploy.sh` / `setup.sh` | unset | seed the admin password on first setup |
| `PIMAC_ROOT` | app + worker env | `/srv/pimac` | data root |

### Operations notes

- Logs: `journalctl -u pimac-web -u pimac-builder -u caddy`
- Set/replace the admin password:
  `sudo -u pimac python3 /opt/pimac/app/manage.py set-admin-password`
- Releases are just files in `/srv/pimac/releases/`; anything matching
  `image_YYYY-MM-DD-RPi-Mac.img.xz` shows up on the site immediately.
  Delete them there (or from the admin page) to retire them.
- The builder runs one job at a time and the queue is capped, so a
  burst of visitors degrades into a polite line rather than an OOM.
- A word of warning: the Apple ROM and OS images this site serves are
  Apple's copyrighted property, preserved for hobbyist use. Host them
  at your own discretion.
