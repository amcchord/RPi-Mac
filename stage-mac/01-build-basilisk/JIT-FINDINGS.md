# AArch64 JIT investigation (Basilisk II on the Pi Zero 2)

Goal: replace the pure 68k interpreter with a native ARM64 JIT for a large
(2-5x) speedup. Outcome: **not viable on the Pi Zero 2 as it stands** - the
only existing AArch64 JIT (the rcarmo fork) hangs the board on the available
RAM. The shipping image therefore stays on the tuned interpreter (see
`PERF-RESULTS.md`). This document records what was tried so the work can be
resumed on higher-RAM hardware or after upstream memory fixes.

## Approach
There is no need to write a backend from scratch: [rcarmo/macemu](https://github.com/rcarmo/macemu)
is a fork of the same kanjitalk755 base we pin, adding an experimental AArch64
JIT (`uae_cpu_2026/compiler/codegen_arm64.*`, `compemu_*_arm64*`), a managed-IRQ
model, and Raspberry Pi SDL2/KMS packaging. Its README reports BasiliskII
booting to the desktop with the JIT on a 12-core Orange Pi (much more RAM).

Pinned fork commit: `bb1b2f28eba9ca4de2daee471032d2b66dd22dce`
(cached as `cache/macemu-rcarmo-<commit>.tar.gz`).

Our appliance patches were rebased onto the fork and preserved here:
- `files/0001-fork-jit-sdlrotate.patch`
- `files/0002-fork-jit-perf.patch`

## What works
- The fork **builds cleanly for the Cortex-A53** with the JIT enabled
  (`--enable-jit-compiler --enable-aarch64-jit-experimental`, `-O3
  -mcpu=cortex-a53`, no LTO, no `-DHAVE_GET_WORD_UNSWAPPED`; FPU = MPFR).
- The **pristine fork in interpreter mode boots** on the Pi Zero 2 (reaches
  `video_open()` and runs), so the fork core is compatible with our aarch64
  KMS/SDL2 runtime.

## What fails (the blocker)
- **The fork with the JIT enabled hangs the entire Pi Zero 2** - reproduced
  twice, each time making the board unreachable and requiring a re-image. It
  hangs (not crashes), so it survives `Restart=no` and starves a 1 Hz memory
  watchdog. Reproduced even with:
  - a tiny **16 MB** `jitcachesize`,
  - `vm.mmap_min_addr=0`,
  - `B2_JIT_MANAGED_IRQ=1`,
  - the **pristine** fork (no RPi-Mac patches).
- Root cause (strong hypothesis): memory over-commit. The fork maps the full
  Mac address space (NuBus/I-O regions, "filled 0xFF") and logs
  `NuBus-lo head map/protect failed: Cannot allocate memory`; the JIT adds its
  translation cache and direct-mapping needs on top. The fork was validated on
  a board with far more than the Pi Zero 2's 415 MB usable RAM.
- Separately, our rebased patches (`0002-fork-jit-perf`) crash the fork build
  during early init even in interpreter mode (the pristine fork interpreter
  boots; the patched one does not). This was not chased down because the JIT
  hang makes the JIT path unusable regardless.

## Not yet tried (future work)
- `B2_JIT_MAX_OPTLEV=1` (JIT dispatch, no native codegen) in isolation - uses
  less memory than optlev 2; might fit, at much lower speedup. Testing it needs
  a safer mechanism than we had (it can hang the board).
- Shrinking the fork's address-space mapping / translation-cache footprint to
  fit 415 MB.
- A higher-RAM Pi (Pi 4/5) where the fork's footprint is not a problem.

## How to reproduce the JIT build (dev harness, not the image build)
`scripts/dev-basilisk.sh` supports the fork via `MACEMU_TARBALL` + `PATCHES`:

```bash
export ac_cv_have_asm_extended_signals=yes
MACEMU_TARBALL="cache/macemu-rcarmo-bb1b2f28eba9ca4de2daee471032d2b66dd22dce.tar.gz" \
BUILD_NAME=jit MCPU=cortex-a53 PERF_CFLAGS="-O3" PERF_CXXFLAGS="-O3" \
PATCHES="0001-fork-jit-sdlrotate.patch 0002-fork-jit-perf.patch" \
CONFIGURE_EXTRA="--enable-jit-compiler --enable-aarch64-jit-experimental --disable-vosf --enable-addressing=direct" \
scripts/dev-basilisk.sh build
```

WARNING: do not deploy a JIT build to a Pi Zero 2 via the auto-restarting
emulator service - it hangs the board and risks SD-card corruption on the
forced power-cycle. Test only with `Restart=no` and out-of-band recovery.

## Recommendation
Keep the tuned interpreter (the `perf/basilisk-perf` result) as the shipping
path. Revisit the JIT on higher-RAM hardware or once the fork's memory
footprint is reduced.
