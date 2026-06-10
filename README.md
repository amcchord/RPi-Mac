# RPi-Mac

Bootable SD card images that turn a Raspberry Pi Zero 2 W into a classic
Macintosh. Power on and the Pi boots straight into
[Basilisk II](https://github.com/kanjitalk755/macemu) emulating a Macintosh
Quadra 950 running Mac OS 8 — no visible Linux, just a classic Mac boot
experience from the moment the screen lights up.

## Features

- **Instant Mac**: quiet Linux boot hidden behind a classic-Mac style
  checkerboard / Happy Mac Plymouth splash, then straight into Mac OS 8.
- **Base OS**: Raspberry Pi OS Lite 64-bit (Debian trixie), built with the
  official [pi-gen](https://github.com/RPi-Distro/pi-gen) tooling.
- **Displays**: HDMI out of the box, plus the
  [Waveshare 2.8" DPI LCD](https://www.waveshare.com/wiki/2.8inch_DPI_LCD)
  (480x640 rotated to 640x480 landscape) via a one-line config toggle.
- **Web UI**: a System 7 styled control panel served on port 80. Edit
  emulator settings, upload ISOs and disk images, create blank disks, drop
  files into a shared folder visible inside Mac OS, pair Bluetooth keyboards
  and mice, and configure WiFi.
- **Easy WiFi**: set your network at image build time, by editing `mac.txt`
  on the SD card's boot partition from any computer, or from the web UI.
- **Debug friendly**: SSH enabled (`mac` / `rpimac`), mDNS at
  `rpimac.local`, persistent logs, and a `rpimac-status` diagnostic helper.

## Flashing an image

1. Download the latest `.img.xz` from
   [Releases](https://github.com/amcchord/RPi-Mac/releases).
2. Flash it to an SD card (8 GB or larger) with
   [Raspberry Pi Imager](https://www.raspberrypi.com/software/),
   [balenaEtcher](https://etcher.balena.io/), or `dd`.
3. (Optional) Open the `mac.txt` file on the `bootfs` partition and set your
   WiFi network, display type, and other options.
4. Insert the card into a Pi Zero 2 W and power on.

## Configuration: `mac.txt`

The FAT boot partition contains a plain-text `mac.txt` readable and editable
from any OS:

```ini
WIFI_SSID=MyNetwork
WIFI_PASS=secret
WIFI_COUNTRY=US

# DISPLAY=hdmi or dpi28 (Waveshare 2.8" DPI LCD)
DISPLAY=hdmi

# Set DEBUG=1 to show the Linux console during boot
DEBUG=0
```

Changes are applied on the next boot.

## Web UI

Browse to `http://rpimac.local/` (or the Pi's IP address). The interface is
intentionally unsecured — this is a toy for trusted networks, not an
appliance for the open internet.

## Building images yourself

On a Debian/Ubuntu arm64 machine (or any machine with binfmt + qemu):

```bash
git clone --recurse-submodules https://github.com/amcchord/RPi-Mac.git
cd RPi-Mac
sudo ./scripts/build.sh
```

The finished image lands in `deploy/`. Optional environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `WIFI_SSID` / `WIFI_PASS` | unset | Seed default WiFi credentials into `mac.txt` |
| `WIFI_COUNTRY` | `US` | WiFi regulatory domain |
| `PAYLOAD_URL` | mcchord.net sdCard.zip | Where to fetch the ROM/OS payload |

Releases are built automatically by GitHub Actions on `v*` tags.

## A note on copyrights

The published images contain a Macintosh Quadra ROM and a Mac OS 8 system
image, which remain the copyrighted property of Apple. They are included for
hobbyist preservation purposes. The code in this repository is MIT licensed;
the Apple ROM and OS bits are not covered by that license.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Austin McChord.
