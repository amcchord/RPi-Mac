# DOSBox-X (Windows 98 mode) — source patch

Windows mode runs Windows 98 SE under a patched build of
[DOSBox-X](https://github.com/joncampbell123/dosbox-x). The image ships the
**prebuilt** arm64 binary as Windows-mode payload (`docs/components/dosbox-x-arm64`,
copied into the cache and installed to `/usr/local/bin/dosbox-x`). That binary
is not in git (see `.gitignore`); this directory keeps the *source* changes so
it can be rebuilt reproducibly.

## What the patch does

`0001-rpimac-win98-kmsdrm-touch.patch` applies on top of upstream commit
`83d561dc9baa6b456b0c4f22cb79437122ee4c5f` and adds:

- **Web console mirror** (`win98_web_console.{cpp,h}`, `output_surface.cpp`,
  `Makefile.am`): publishes the framebuffer to `/dev/shm` and accepts input,
  so the Flask web UI can show and drive the screen. The
  `win98_web_console_publish_bgra` entry point mirrors frames from the OpenGL
  output path.
- **KMSDRM rotation** (`output_opengl.cpp`): rotates the presented image by
  `RPIMAC_ROTATE` (0/90/180/270) so the portrait DPI panel shows landscape,
  matching the boot splash and the Mac emulator.
- **Touchscreen** (`sdlmain.cpp`, `mouse.{cpp,h}`): replaces SDL's built-in
  finger→mouse forwarding (relative deltas only, no rotation) with a
  rotation-aware, absolute tap-to-click that drives Windows 98's relative
  PS/2 mouse to the touched point via an estimated-cursor tracker. Reads the
  same `RPIMAC_ROTATE`.

## Rebuild

```bash
git clone https://github.com/joncampbell123/dosbox-x.git
cd dosbox-x
git checkout 83d561dc9baa6b456b0c4f22cb79437122ee4c5f
git apply /path/to/RPi-Mac/payload-src/dosbox-x/0001-rpimac-win98-kmsdrm-touch.patch
./build-sdl2          # or: ./configure ... && make -j"$(nproc)"
strip --strip-unneeded src/dosbox-x
cp src/dosbox-x /path/to/RPi-Mac/docs/components/dosbox-x-arm64
```

`scripts/build.sh` re-caches `docs/components/dosbox-x-arm64` whenever it is
newer than the cached copy, so the next image build picks it up automatically.
Build on arm64 (or cross-compile) so the binary matches the Pi.
