# Changelog

All notable changes to RPi-Mac are documented here. Versions are git tags
(`vX.Y.Z`); releases are built locally and published to
[pimac.net](https://pimac.net/).

## [0.5.0] - 2026-06-15

Adds an optional **Windows 98 mode** alongside the classic Macintosh, on the
same hardware and web UI. Windows mode is opt-in and fully reversible — when
`MODE=mac` (the default) the Mac path is untouched.

### Added
- **Windows 98 mode (DOSBox-X)**: run Windows 98 from a pre-installed disk
  image instead of the classic Mac. Switch from the Settings page ("Switch
  to Windows 98" / "Switch to Macintosh") or by setting `MODE=win` in
  `mac.txt`. No reboot needed — both modes share the display pipeline.
- **Unified emulator service** (`rpimac-emulator`) that dispatches Basilisk II
  or DOSBox-X based on `MODE`; only one emulator ever owns the display.
- **Fullscreen DOSBox-X output** on the physical panel via KMSDRM + OpenGL,
  rotated to match the display (`RPIMAC_ROTATE`, same orientation as Mac mode).
- **Physical touchscreen in Windows mode**: a tap lands a left-click where you
  touch (rotation-aware absolute positioning), matching Mac-mode behaviour.
- **Windows-themed web UI**: mode-aware theming (`win98.css`), status, and
  Console/Disks/Files pages. The Console streams Windows and takes
  mouse/keyboard through a virtual `uinput` device (works under KMSDRM).
- **Windows Disks page**: shows the Windows disk, uploads ISOs (attached as a
  CD), and provides a shared FAT disk for moving files in and out.
- **Lazy disk expansion** (`rpimac-expand-win98`): the bundled, zipped VHD is
  expanded on the first switch to Windows; `MSDOS.SYS` is tuned to skip the
  boot-time ScanDisk.
- **Reproducible DOSBox-X build**: the source patch (web-console mirror,
  OpenGL rotation, rotation-aware touchscreen) lives in
  `payload-src/dosbox-x/` with build instructions. The prebuilt arm64 binary
  ships as Windows-mode payload (not in git).
- `build.sh`: `MODE_DEFAULT` and optional caching of the Windows payload
  (`dosbox-x-arm64`, `Win98.vhd.zip`); the image is Mac-only when the payload
  is absent.

### Changed
- The boot config and services were renamed from `basilisk` to the
  mode-neutral `rpimac-emulator`; `mac.txt` gained a documented `MODE` key.
- `build-test-image.sh` no longer hardcodes WiFi credentials — it reads them
  from the environment or a local, gitignored `scripts/test-wifi.env`.

### Notes
- The last pre-Windows release is `v0.3.1` (also tagged `known-good-pre-win98`).
- Sound is disabled in Windows mode for now (avoids an audio-underrun log
  storm on hosts without a working ALSA sink).

## [0.3.1] - 2026-06-13

### Added
- 1080p and 960x540 plus auto-detected HDMI resolutions.

### Changed
- Default DPI-panel rotation is now 90 degrees.

## [0.3.0] - 2026-06-13

### Added
- **pimac.net image host and SD card builder** (`image-host/`): personalised
  SD cards (display, WiFi, hostname) assembled from a base image.
- Local build-and-publish flow (dropped the GitHub Actions release).
- Rotation-aware boot splash (one pre-rotated variant per orientation).
- Mac OS disks now ship zipped and expand on first boot; default OS is Mac OS 8.

### Changed
- Relative pointer motion is applied in hand space (no rotation), fixing
  pointer direction.
- Bluetooth discovery no longer trampling WiFi on the shared 2.4 GHz radio.

## [0.2.0] - 2026-06-11

### Added
- Tablet-style absolute input and working Waveshare touchscreen (taps defer
  the click until the cursor position lands).
- Web Console (screen mirror over shared memory, compressed stream) and disk
  downloads; power-cut protection.
- Setup hotspot ("RPi-Mac Setup" AP), partial screen updates, resilient
  uploads, and access controls (SSH/web-password toggles).
- CPU isolation for the emulator and configurable display margins; disk image
  creation up to 4 GB.

### Changed
- Default machine is the Quadra 650 (Mac OS 8 boots); the 68k thread is kept
  at full speed by moving the screen mirror off the hot path.

### Fixed
- Startup hang and boot robustness (failure counter, verbose-boot fallback,
  rescue console); correct console colours; WiFi power-save disabled.

## [0.1.0] - 2026-06-10

- Initial RPi-Mac image builder: Basilisk II on Raspberry Pi via pi-gen, with
  display rotation, KMSDRM rendering, a web control panel, and the boot-time
  `mac.txt` configuration flow.

[0.5.0]: https://github.com/amcchord/RPi-Mac/releases/tag/v0.5.0
[0.3.1]: https://github.com/amcchord/RPi-Mac/releases/tag/v0.3.1
[0.3.0]: https://github.com/amcchord/RPi-Mac/releases/tag/v0.3.0
[0.2.0]: https://github.com/amcchord/RPi-Mac/releases/tag/v0.2.0
[0.1.0]: https://github.com/amcchord/RPi-Mac/releases/tag/v0.1.0
