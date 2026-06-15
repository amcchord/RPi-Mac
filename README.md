# RPi-Mac

Bootable SD card images that turn a Raspberry Pi Zero 2 W into a classic
Macintosh. Power on and the Pi boots straight into
[Basilisk II](https://github.com/kanjitalk755/macemu) emulating a classic
68k Macintosh running Mac OS 8 — no visible Linux, just a classic Mac
boot experience from the moment the screen lights up: grey checkerboard,
Happy Mac, desktop.

## Features

- **Instant Mac**: quiet Linux boot hidden behind a classic-Mac
  checkerboard / Happy Mac Plymouth splash (rotated to match the
  configured screen rotation). The emulator paints the same checkerboard
  as its first frame, so the handoff is seamless.
- **Small images**: the bundled Mac OS system disks ship zipped
  (`/opt/rpimac/zips`) and are expanded on the SD card on first boot,
  with progress shown on the boot splash — the distributed image stays
  a fraction of the installed size. Mac OS 8 is set up automatically;
  Mac OS 7 stays compressed until you install it from the web UI's
  Disks page.
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
  - Disk images: upload, download, create blank disks, attach/detach,
    and install bundled zipped systems (Mac OS 7) on demand.
  - ISOs: upload, download, insert/eject as CD-ROM.
  - Shared folder: drop files in via the browser, they appear on the Mac
    desktop as the "Unix" volume.
  - Bluetooth: pair keyboards and mice.
  - WiFi configuration, emulator restart, reboot, shutdown.
  - Access control: SSH on/off toggle and an optional web UI password
    (both default to open access; recoverable via mac.txt on the SD card).
- **Optional Windows 98 mode**: images built with the Windows payload can
  switch the whole appliance to Windows 98 running in DOSBox-X — toggled
  from the Settings page or via `MODE=win` in `mac.txt`. The web UI
  re-themes itself in Windows 98 style and the Console controls Windows the
  same way it controls the Mac. See [Windows 98 mode](#windows-98-mode).
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

1. Download the latest `.img.xz` from [pimac.net](https://pimac.net/) —
   or use the [SD Card Builder](https://pimac.net/builder) there to
   compose a custom image: pick the Mac OS disk images, install CDs and
   ROM to put on the card and bake in your WiFi settings, so the Mac is
   online the first time it boots.
2. Flash it to an SD card (8 GB or larger) with
   [Raspberry Pi Imager](https://www.raspberrypi.com/software/) (skip the
   OS customisation step — the image manages its own users and WiFi),
   [balenaEtcher](https://etcher.balena.io/), or `dd`.
3. (Optional) Open `mac.txt` on the `bootfs` partition and set your WiFi
   network and display type.
4. Insert the card into a Pi Zero 2 W and power on. First boot takes a
   few minutes longer (filesystem expansion, one automatic reboot as the
   display configuration is applied, and the zipped Mac OS 8 system disk
   is expanded onto the card — the boot splash shows its progress).

## Configuration: `mac.txt`

The FAT boot partition contains a plain-text `mac.txt` readable and
editable from any OS:

```ini
# WiFi
WIFI_SSID=MyNetwork
WIFI_PASS=secret
WIFI_COUNTRY=US

# MODE=mac (default, Basilisk II / Mac OS) or win (DOSBox-X / Windows 98,
# when the Windows payload is on the image)
MODE=mac

# DISPLAY=hdmi (default) or dpi28 (Waveshare 2.8" DPI LCD)
DISPLAY=dpi28

# Screen rotation: 0, 90, 180, 270, or blank for automatic
# (automatic = 90 on the DPI panel, 0 on HDMI)
ROTATE=

# Set DEBUG=1 to show the Linux boot console instead of the Mac splash
DEBUG=0
```

Changes are applied during the next boot. Display/rotation changes
trigger one automatic reboot to take effect; this cannot loop (the boot
counter suppresses automatic reboots after repeated incomplete boots).

## Windows 98 mode

Images built with the Windows payload can run **Windows 98** in
[DOSBox-X](https://dosbox-x.com/) instead of the classic Mac, on the same
hardware and with the same web UI. It is opt-in and fully reversible.

- **Switch from the web UI**: Settings has a Mode panel — "Switch to
  Windows 98" / "Switch to Macintosh". The first switch to Windows expands
  the bundled disk image (about a minute), then the emulator restarts. No
  reboot is needed; both modes share the same display pipeline.
- **Switch from `mac.txt`**: set `MODE=win` (or `MODE=mac`) on the boot
  partition from any computer and power on.
- **What it does**: Windows mode swaps the emulator to DOSBox-X booting the
  pre-installed `Win98.vhd` disk, renders fullscreen on the physical display
  (KMSDRM + OpenGL, rotated to match the panel), and re-themes the web UI in
  Windows 98 style. The Console page streams Windows and takes
  mouse/keyboard exactly like the Mac.
- **Touch & disks**: the physical touchscreen works in Windows mode too — a
  tap lands a left-click where you touch, with the same rotation handling as
  Mac mode. The Disks page shows the Windows disk, uploads ISOs (mounted as a
  CD), and offers a shared FAT disk for moving files in and out.
- **No install CD**: Windows mode boots the pre-installed disk; the Windows
  install ISO is not shipped.
- **Sound** is off in Windows mode for now (the SB16 is detected but host
  audio is muted, which avoids an audio-underrun log storm on hosts without
  a working ALSA sink).

### Rolling back

Windows mode is additive: when `MODE=mac` (the default) the Mac path is
untouched. To return to a known-good Mac:

- Set `MODE=mac` in `mac.txt` (recoverable from the SD card on any
  computer), or use the web UI's "Switch to Macintosh".
- The source tree tags the last pre-Windows release as `v0.3.1` (also
  `known-good-pre-win98`); Windows 98 mode shipped in `v0.5.0`. See
  [`CHANGELOG.md`](CHANGELOG.md) for the full history.

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
- The bundled `Mac8.dsk` (expanded from `Mac8.dsk.zip` on first boot)
  boots Mac OS 8 by default. `Mac7.dsk.zip` (Mac OS 7) ships on the
  card too — install it from the web UI's Disks page when wanted.
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
# Place the (Apple-copyrighted, not distributed here) payload files in
# docs/components/: Q650.ROM, Mac8.dsk.zip, Mac7.dsk.zip, System753.iso
# Optional Windows mode payload (also not distributed): a prebuilt
# dosbox-x-arm64 binary and Win98.vhd.zip (a zipped, pre-installed disk).
sudo ./scripts/build.sh                # release flavour (HDMI default)
sudo ./scripts/build-waveshare-image.sh  # release flavour for the
                                       # Waveshare 2.8" DPI LCD
sudo ./scripts/build-test-image.sh     # dev flavour (DPI display default,
                                       # WiFi credentials pre-baked)
```

The finished image lands in `deploy/`. Useful environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `WIFI_SSID` / `WIFI_PASS` | unset | Seed default WiFi credentials into `mac.txt` |
| `WIFI_COUNTRY` | `US` | WiFi regulatory domain |
| `DISPLAY_DEFAULT` | `hdmi` | Default display in `mac.txt` (`hdmi` or `dpi28`) |
| `MODE_DEFAULT` | `mac` | Default emulator in `mac.txt` (`mac` or `win`; `win` needs the Windows payload) |
| `PAYLOAD_SRC` | `<repo>/docs/components` | Directory with the ROM/OS payload files |
| `WORK_DIR` / `DEPLOY_DIR` | `<repo>/work`, `<repo>/deploy` | Build locations |
| `PUBLISH` | unset | `PUBLISH=1` uploads the finished image to the pimac.net image host |

Releases are built locally and published to [pimac.net](https://pimac.net/)
with `scripts/publish-image.sh` (or `sudo PUBLISH=1 ./scripts/build.sh`
to build and ship in one step).

## The image host and SD card builder

[pimac.net](https://pimac.net/) — the download site and SD card builder —
is part of this repo too, under [image-host/](image-host/). It hosts the
release images, lets visitors assemble personalised SD cards (choice of
disk images, ISOs, ROM, blank disks, WiFi/display settings) and has an
admin backend for uploading new ROMs and disk images over time. See
[image-host/README.md](image-host/README.md) for how it works and how to
run your own.

## How it works

```
pi-gen (stage0-2: Raspberry Pi OS Lite)
  └─ stage-mac (this repo)
      ├─ 00  extra packages (GL/EGL for SDL's KMSDRM renderer, plymouth,
      │      flask, evdev, i2c-tools, zram, ...)
      ├─ 01  Basilisk II built from a pinned macemu commit + patches
      ├─ 02  ROM + zipped disk images + install CD payload
      ├─ 03  system config: services, mac.txt, first-boot disk
      │      expansion, robustness, tuning
      ├─ 04  "classicmac" Plymouth theme (checkerboard + Happy Mac),
      │      one pre-rotated variant per screen rotation
      ├─ 05  web UI (Flask app served by waitress)
      └─ 06  boot tweaks: quiet firmware, Waveshare DPI overlays
```

The emulator runs fullscreen on KMS/DRM via SDL2 (`SDL_VIDEODRIVER=kmsdrm`,
GLES2 renderer) — no X11 or Wayland. System services are pinned to CPU
core 0 while the emulator gets cores 1-3, so the 68k interpreter thread
always owns a full core. Idle-wait is off by default: the emulator paces
itself by spinning rather than sleeping, which costs heat but removes
scheduler wake-up jitter (smooth animations); re-enable "Idle wait" in
Settings if you prefer a cooler Pi. A systemd unit owns tty1, restarts
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
cmdline (including `plymouth.splash=` selecting the boot-splash variant
that matches the screen rotation), `config.txt` display blocks, and
emulator prefs. The web UI edits `mac.txt`/prefs and re-runs the same
script, so there is a single source of truth.

## A note on copyrights

The published images contain a Macintosh Quadra ROM, Apple system
software disk images and a System 7.5.3 install CD, which remain the
copyrighted property of Apple. They are included for hobbyist
preservation purposes. The code in this repository is MIT licensed; the
Apple ROM and OS bits are not covered by that license.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Austin McChord.
