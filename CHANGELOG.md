# Changelog

All notable changes to RPi-Mac are documented here. Versions are git tags
(`vX.Y.Z`); releases are built locally and published to
[pimac.net](https://pimac.net/).

## [0.7.0] - 2026-06-24

Multi-board support. One Raspberry Pi image now boots and tunes itself across
the Pi Zero 2 W, Pi 4 and Pi 5, and the stage-mac provisioning was refactored
into a shared library so an Orange Pi (Allwinner, Armbian-based) image family
can reuse it. Orange Pi support lands in code here; its images follow once
validated on hardware.

### Added
- **Unified Raspberry Pi image (Zero 2 W / 4 / 5)** that detects the board at
  boot and tunes itself: `rpimac-detect-board` classifies the model/family, the
  emulator memory cgroup ceiling is sized from actual RAM (instead of the fixed
  512 MB-era 300 MB cap), and zram scales with RAM (`min(ram / 2, 1024)`). The
  detected board is shown on the web dashboard and in `rpimac-status`.
- **Shared provisioning library** in [`provision/`](provision/)
  (`build-basilisk.sh`, `install-system.sh`, `install-plymouth.sh`,
  `install-webui.sh`, `install-payload.sh`, `enable-services.sh`), called by
  both the pi-gen `stage-mac` stages and the Orange Pi build.
- **Orange Pi (Allwinner) build path** (code; HDMI only): `rpimac-boot-config`
  is now SoC-family aware (Raspberry Pi firmware `config.txt`/`cmdline.txt` vs
  Allwinner `armbianEnv.txt`), [`scripts/build-orangepi-image.sh`](scripts/build-orangepi-image.sh)
  drives the Armbian build framework through
  [`orangepi/customize-image.sh`](orangepi/customize-image.sh) for the Zero 2 /
  Zero 2W / Zero 3, and [`scripts/orangepi-display-spike.sh`](scripts/orangepi-display-spike.sh)
  is a hardware gate that proves the `kmsdrm` + GLES2 path before shipping.
- **`MCPU` build variable** (default `cortex-a53`) for the Basilisk II build.

### Changed
- `rpimac-boot-config` derives the boot-partition layout and WiFi/regulatory
  handling from the board family (guards `wlan0`/`raspi-config`, adds an `iw`
  regulatory-domain fallback), and orders after Armbian's resize service as
  well as the Pi's.
- The image host distinguishes Raspberry Pi and Orange Pi images and keeps the
  SD Card Builder Raspberry-Pi-only (the Orange Pi layout differs).

### Notes
- The **Orange Pi Zero 3W** (Allwinner A733 / PowerVR) is intentionally not
  supported: it has no mainline kernel, no Armbian board, and no open-source
  GLES driver. It is gated behind the display spike on its vendor BSP.

## [0.6.0] - 2026-06-17

First-boot robustness, a zero-config setup hotspot, and a pre-expanded Mac OS
8, alongside the Basilisk II performance tuning for the Pi Zero 2 W measured on
real hardware (see
[`stage-mac/01-build-basilisk/PERF-RESULTS.md`](stage-mac/01-build-basilisk/PERF-RESULTS.md)).

### Added
- **Captive portal on the "RPi-Mac Setup" hotspot**: joining the setup access
  point now opens the configuration page automatically - the hotspot's DNS
  resolves every name to the Pi and the web UI redirects the operating
  system's connectivity check - so there is no `10.x.x.x` address to type.
- **Mac OS 8 ships pre-expanded**: its system disk is decompressed at image
  build time instead of on the Pi, so the first boot goes straight to the
  desktop with no expansion step (Mac OS 7 still installs on demand).
- **In-emulator performance telemetry**, env-gated and off by default. Set
  `RPIMAC_TELEMETRY=1` to log, once per second, sustained 68k throughput
  (MIPS), video frame rate, and a one-shot **boot-to-steady-state** time (when
  the Finder desktop goes idle). Instruction counting piggybacks on the
  existing 65536-instruction callback, so the hot loop is unchanged when off.
  Carried in `0002-basilisk-perf.patch`; `RPIMAC_TELEMETRY_FILE=path`
  redirects output.
- **`scripts/dev-basilisk.sh`**: idempotent dev harness that builds BasiliskII
  on a fast aarch64 box (tuned `-mcpu=cortex-a53`), deploys the binary to a Pi
  over SSH, restarts the emulator and reports the telemetry; supports A/B
  build flags and a two-phase PGO workflow.

### Changed
- **BasiliskII build is tuned for the Cortex-A53**: `-O3 -flto
  -mcpu=cortex-a53`, the unswapped opcode-fetch path
  (`-DHAVE_GET_WORD_UNSWAPPED`, paired with the pre-swapped dispatch table),
  for about +5% sustained interpreter throughput (~+10% with optional PGO).
- **FPU core swapped from MPFR to the host IEEE core** (`--enable-fpu-ieee`),
  which uses hardware `double` on aarch64 instead of arbitrary-precision
  software. Floating-point operations run ~29x faster (FP-heavy apps benefit
  most); precision goes from 64-bit extended to 53-bit double. This also drops
  the `libmpfr`/`libgmp` build and runtime dependencies.
- **System 7.5.3 install CD is no longer auto-attached** in the default
  configuration (Mac OS 8 boots from its own disk). The ISO still ships on the
  card and can be inserted from the web UI's Disks page.

### Fixed
- **FAT boot partition no longer corrupts after the first reboot.** The
  first-boot configuration step now syncs and remounts `/boot/firmware`
  read-only before rebooting; that reboot is non-blocking and ordered after
  the root-filesystem resize so the two never race; the partition is mounted
  with `flush`; and any leftover temp file from a write interrupted by an
  earlier unclean shutdown is cleaned up on boot.

### Notes
- The pure 68k interpreter is CPU-bound on the A53; a larger general speedup
  would require a native ARM JIT (macemu's JIT is x86-only) - out of scope here.
- **AArch64 JIT investigated, not shipped**: the experimental AArch64 JIT from
  the rcarmo/macemu fork builds for the A53 and its interpreter boots, but the
  JIT hangs the Pi Zero 2 (memory over-commit; reproduced even with a 16 MB
  cache and the pristine fork). The tuned interpreter remains the shipping path;
  see `stage-mac/01-build-basilisk/JIT-FINDINGS.md`. The rebased fork patches
  and dev-harness build path are kept for future work on higher-RAM hardware.

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

[0.6.0]: https://github.com/amcchord/RPi-Mac/releases/tag/v0.6.0
[0.5.0]: https://github.com/amcchord/RPi-Mac/releases/tag/v0.5.0
[0.3.1]: https://github.com/amcchord/RPi-Mac/releases/tag/v0.3.1
[0.3.0]: https://github.com/amcchord/RPi-Mac/releases/tag/v0.3.0
[0.2.0]: https://github.com/amcchord/RPi-Mac/releases/tag/v0.2.0
[0.1.0]: https://github.com/amcchord/RPi-Mac/releases/tag/v0.1.0
