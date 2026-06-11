# RPi-Mac

Bootable SD card images that turn a Raspberry Pi Zero 2 W into a classic
Macintosh. Power on and the Pi boots straight into
[Basilisk II](https://github.com/kanjitalk755/macemu) emulating a classic
68k Macintosh running System 7.5 — no visible Linux, just a classic Mac
boot experience from the moment the screen lights up: grey checkerboard,
Happy Mac, desktop.

## Features

- **Instant Mac**: quiet Linux boot hidden behind a classic-Mac
  checkerboard / Happy Mac Plymouth splash. The emulator paints the same
  checkerboard as its first frame, so the handoff is seamless.
- **Base OS**: Raspberry Pi OS Lite 64-bit (Debian trixie), built with the
  official [pi-gen](https://github.com/RPi-Distro/pi-gen) tooling.
- **Displays**:
  - HDMI out of the box.
  - [Waveshare 2.8" DPI LCD](https://www.waveshare.com/wiki/2.8inch_DPI_LCD)
    (480x640 panel shown as a pixel-perfect 640x480 landscape Mac screen),
    including its capacitive **touchscreen**: drag moves the cursor,
    tap clicks.
  - Output rotation (0/90/180/270) configurable per display.
- **Web UI** (System 7 styled, port 80):
  - **Console**: live view of the Mac screen (~15 fps) with full remote
    control — tablet-style absolute mouse, keyboard, works from phones.
  - Emulator settings: RAM, resolution, CPU (68020/030/040), rotation,
    display margins (shrink the Mac screen pixel-perfectly around a
    physical bezel), sound, shared folder, networking.
  - Disk images: upload, download, create blank disks, attach/detach.
  - ISOs: upload, download, insert/eject as CD-ROM.
  - Shared folder: drop files in via the browser, they appear on the Mac
    desktop as the "Unix" volume.
  - Bluetooth: pair keyboards and mice.
  - WiFi configuration, emulator restart, reboot, shutdown.
  - Access control: SSH on/off toggle and an optional web UI password
    (both default to open access; recoverable via mac.txt on the SD card).
- **Networking inside the Mac**: slirp user-mode NAT (`ether slirp`) is on
  by default — set TCP/IP to DHCP inside Mac OS and you're online.
- **Easy WiFi**: set at image build time, by editing `mac.txt` on the
  SD card's boot partition from any computer, or from the web UI.
- **Self-diagnosing boot**: after 3 failed boots the image automatically
  switches to a verbose console; if the emulator crash-loops, a rescue
  login appears on screen instead of eternal black.
- **Debug friendly**: SSH enabled (`mac` / `rpimac`), mDNS at
  `rpimac.local`, persistent journal, `rpimac-status` diagnostic helper.

## Flashing an image

1. Download the latest `.img.xz` from
   [Releases](https://github.com/amcchord/RPi-Mac/releases).
2. Flash it to an SD card (8 GB or larger) with
   [Raspberry Pi Imager](https://www.raspberrypi.com/software/) (skip the
   OS customisation step — the image manages its own users and WiFi),
   [balenaEtcher](https://etcher.balena.io/), or `dd`.
3. (Optional) Open `mac.txt` on the `bootfs` partition and set your WiFi
   network and display type.
4. Insert the card into a Pi Zero 2 W and power on. First boot takes a
   little longer (filesystem expansion + one automatic reboot as the
   display configuration is applied).

## Configuration: `mac.txt`

The FAT boot partition contains a plain-text `mac.txt` readable and
editable from any OS:

```ini
# WiFi
WIFI_SSID=MyNetwork
WIFI_PASS=secret
WIFI_COUNTRY=US

# DISPLAY=hdmi (default) or dpi28 (Waveshare 2.8" DPI LCD)
DISPLAY=dpi28

# Screen rotation: 0, 90, 180, 270, or blank for automatic
# (automatic = 270 on the DPI panel, 0 on HDMI)
ROTATE=

# Set DEBUG=1 to show the Linux boot console instead of the Mac splash
DEBUG=0
```

Changes are applied during the next boot. Display/rotation changes
trigger one automatic reboot to take effect; this cannot loop (the boot
counter suppresses automatic reboots after repeated incomplete boots).

## Web UI

Browse to `http://rpimac.local/` (or the Pi's IP). The interface is
intentionally unsecured — this is a toy for trusted networks, not an
appliance for the open internet.

The **Console** page deserves a special mention: it streams the Mac's
screen (the emulator mirrors frames to shared memory, the UI fetches them
deflate-compressed) and injects input through a virtual `uinput` tablet,
so the cursor lands exactly where you click — classic Mac mouse
acceleration doesn't apply to absolute pointers.

## Inside the Mac

- The machine reports itself as a **Quadra 650** (matching the bundled
  ROM) with a 68040 — the configuration Mac OS 8.x demands. Other
  machine identities are selectable in Settings, but note: model IDs
  the ROM doesn't know (e.g. Quadra 900) won't boot at all, and 68030
  machines (IIci) are rejected by Mac OS 8 installers/CDs.
- The bundled `Macintosh7.dsk` boots System 7.5 (volume "MicroMac7").
- Bootable OS 8.x install CDs work: upload the ISO, insert it, and set
  the emulator to boot from CD-ROM if needed (prefs `bootdriver 32`).
- `System753.iso` is a bootable System 7.5.3 install CD, attached as the
  CD-ROM drive. It also serves as the recovery volume: if a disk loses
  its boot blessing, boot from the CD, open the System Folder on the
  affected volume once in the Finder, and restart.
- For networking: Control Panels ▸ TCP/IP ▸ Connect via Ethernet,
  Configure via DHCP.
- Power-cut protection: dirty pages are flushed within ~1-2 s, but the
  clean way to power off is Special ▸ Shut Down (or the web UI's
  Shut Down button).

## Recovery and debugging

| Situation | What happens / what to do |
| --- | --- |
| Boot fails 3 times in a row | Verbose Linux console appears automatically (`bootcount.txt` on the boot partition tracks attempts) |
| Emulator crash-loops | Rescue login console appears on screen with recent logs |
| Need a shell | `ssh mac@rpimac.local`, password `rpimac` (passwordless sudo) |
| Quick health check | run `rpimac-status` over SSH, or `http://<pi>/status.txt` |
| See the boot messages | set `DEBUG=1` in `mac.txt` |
| Touchscreen dead after boot | shouldn't happen (the `rpimac-touch-fix` service un-wedges the GT911 controller at boot) — `systemctl status rpimac-touch-fix` to verify |

## Building images yourself

On a Debian/Ubuntu arm64 machine:

```bash
git clone --recurse-submodules https://github.com/amcchord/RPi-Mac.git
cd RPi-Mac
sudo ./scripts/build.sh                # release flavour (HDMI default)
sudo ./scripts/build-test-image.sh     # dev flavour (DPI display default,
                                       # WiFi credentials pre-baked)
```

The finished image lands in `deploy/`. Useful environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `WIFI_SSID` / `WIFI_PASS` | unset | Seed default WiFi credentials into `mac.txt` |
| `WIFI_COUNTRY` | `US` | WiFi regulatory domain |
| `DISPLAY_DEFAULT` | `hdmi` | Default display in `mac.txt` (`hdmi` or `dpi28`) |
| `PAYLOAD_URL` | mcchord.net sdCard.zip | Where to fetch the ROM/OS payload |
| `WORK_DIR` / `DEPLOY_DIR` | `<repo>/work`, `<repo>/deploy` | Build locations |

Releases are built automatically by GitHub Actions on `v*` tags
(`.github/workflows/release.yml`, arm64 runners).

## How it works

```
pi-gen (stage0-2: Raspberry Pi OS Lite)
  └─ stage-mac (this repo)
      ├─ 00  extra packages (GL/EGL for SDL's KMSDRM renderer, plymouth,
      │      flask, evdev, i2c-tools, zram, ...)
      ├─ 01  Basilisk II built from a pinned macemu commit + patches
      ├─ 02  ROM + disk images + install CD payload
      ├─ 03  system config: services, mac.txt, robustness, tuning
      ├─ 04  "classicmac" Plymouth theme (checkerboard + Happy Mac)
      ├─ 05  web UI (Flask app served by waitress)
      └─ 06  boot tweaks: quiet firmware, Waveshare DPI overlays
```

The emulator runs fullscreen on KMS/DRM via SDL2 (`SDL_VIDEODRIVER=kmsdrm`,
GLES2 renderer) — no X11 or Wayland. System services are pinned to CPU
core 0 while the emulator gets cores 1-3, so the 68k interpreter thread
always owns a full core. A systemd unit owns tty1, restarts
the emulator on exit (instantly: SIGKILL with `SuccessExitStatus`), and
falls back to a rescue console if it keeps failing.

Local patches carried against macemu
([stage-mac/01-build-basilisk/files/0001-sdlrotate.patch](stage-mac/01-build-basilisk/files/0001-sdlrotate.patch)):

- `sdlrotate` pref: rotated, pixel-perfect presentation for portrait
  panels, with matching absolute-input coordinate mapping
- shared-memory frame mirror (`/dev/shm/rpimac-screen`) powering the web
  console, with pixel-format metadata in the header
- direct SDL finger-event handling (SDL's touch-to-mouse synthesis is
  inert on KMSDRM), with the tap click deferred two ticks so the Mac
  sees the cursor position before the button press
- boot-frame checkerboard for a seamless splash handoff
- registration of the `scale_nearest` / `scale_integer` prefs on Unix

Runtime configuration flows one way: `mac.txt` (boot partition) →
`rpimac-boot-config` (every boot) → NetworkManager keyfiles, kernel
cmdline, `config.txt` display blocks, and emulator prefs. The web UI
edits `mac.txt`/prefs and re-runs the same script, so there is a single
source of truth.

## A note on copyrights

The published images contain a Macintosh Quadra ROM, Apple system
software disk images and a System 7.5.3 install CD, which remain the
copyrighted property of Apple. They are included for hobbyist
preservation purposes. The code in this repository is MIT licensed; the
Apple ROM and OS bits are not covered by that license.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Austin McChord.
