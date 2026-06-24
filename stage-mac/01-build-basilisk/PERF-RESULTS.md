# Basilisk II performance tuning results (Pi Zero 2 W)

Measured with `scripts/dev-basilisk.sh` (builds on the aarch64 dev box with
`-mcpu=cortex-a53`, deploys the binary to the Pi, restarts the emulator and
reads the in-emulator telemetry). Two headline metrics, both from a fresh
cold boot of the bundled Mac OS 8 disk:

- **boot_to_steady** - wall time from first 68k execution to the Finder
  desktop becoming idle (lower is better). The emulator detects this itself
  via the screen going quiet and reports it once.
- **steady_mips** - sustained 68k interpreter throughput once idle, median of
  the last 15 one-second samples (higher is better).

Target hardware: Raspberry Pi Zero 2 W, 4x Cortex-A53 @ 1.0 GHz, `performance`
governor, Debian 13 (trixie), kernel 6.18.34+rpt-rpi-v8. The emulator config
is the shipped default (Quadra 650 / 68040, 64 MiB, 640x480, direct
addressing, MPFR FPU). Telemetry is env-gated (`RPIMAC_TELEMETRY=1`) and
compiled into every build below; with it off the hot loop is unchanged.

## Results

All boot_to_steady numbers below are warm-cache (a discarded warm-up boot
precedes each measurement) so they reflect CPU work, not SD-card I/O.

### Build-flag tier (cumulative)

| # | Build | Flags / change | boot | steady_mips | vs baseline |
|---|-------|----------------|-----:|------------:|------------:|
| 0 | baseline | stock `-O2`, no `-mcpu` (production-equivalent) | 11.0 s | 12.93 | 1.00x |
| 1 | +mcpu | `-O2 -mcpu=cortex-a53` | 11.0 s | 12.92 | 1.00x |
| 2 | +O3 | `-O3 -mcpu=cortex-a53` | 11.0 s | 13.14 | 1.02x |
| 3 | +LTO | `-O3 -flto -mcpu=cortex-a53` | 11.0 s | 13.39 | 1.04x |
| 4 | +cheap | add `-fno-semantic-interposition -fno-plt` (REJECTED, slower) | 11.0 s | 12.81 | 0.99x |
| 5 | +PGO | `-O3 -flto -fprofile-use` (profile from a Pi boot+idle run) | 11.0 s | 14.06 | 1.09x |

Notes: `-mcpu` alone does nothing (the interpreter is dispatch-bound, not
scheduling-bound). `-O3` and LTO each add ~2%. PGO is the biggest build-flag
lever (+5% over O3+LTO) because it lays out the giant opcode-dispatch and hot
handlers for the actual instruction mix. The "cheap extras" regressed and were
dropped. Boot time is dominated by fixed I/O/ROM work and barely moves with
these flags; steady MIPS is the sensitive metric here.

### Interpreter + FPU tiers

| # | Build | Flags / change | boot | steady_mips | vs baseline |
|---|-------|----------------|-----:|------------:|------------:|
| 3 | O3+LTO | (reference for this tier) | 11.0 s | 13.39 | 1.04x |
| 6 | +ARAM_PAGE_CHECK | REJECTED: `check_ram_boundary` is already a no-op in `uae_cpu_2021` and `pc_page`/`pc_offset`/`ARAM_PAGE_MASK` are undefined there - nothing to gain | - | - | - |
| 7 | +unswapped fetch | `-DHAVE_GET_WORD_UNSWAPPED` (+ port `do_get_mem_word_unswapped` to aarch64); drops a byteswap per opcode fetch, pairs with pre-swapped dispatch table | 11.0 s | 13.55 | 1.05x |
| 8 | +IEEE FPU | `--enable-fpu-ieee` (host hardware `double` instead of MPFR) | 11.0 s | 13.53 | 1.05x |

The IEEE FPU change is invisible to steady/boot MIPS because the idle desktop and
boot are FP-light. Its impact is on floating-point work itself:

### FPU backend microbenchmark (on the Pi, Cortex-A53)

Per `(mul + add)` op at 64-bit (68881 extended) precision:

| Backend | ns/op | Note |
|---------|------:|------|
| MPFR (prec 64) - the old default | 530 ns | arbitrary-precision software |
| host `double` - what `fpu_ieee` uses on aarch64 | 18 ns | **~29x faster**, hardware FP |

So FP-heavy guest code (spreadsheet recalc, scientific/graphics apps, anything
using the 68881/68040 FPU) runs up to ~29x faster on the FPU instructions
themselves. Trade-off: precision drops from 64-bit (extended) to 53-bit
(double); fine for essentially all classic Mac software. Mac OS 8 boots and runs
correctly on the IEEE core, and the binary no longer links `libmpfr`/`libgmp`.

### Final stacks

| Build | Flags | boot | steady_mips | vs baseline | FP ops |
|-------|-------|-----:|------------:|------------:|-------:|
| **shipped image** | O3+LTO+mcpu+unswapped+IEEE FPU (no PGO) | ~11-13 s | 13.56 | **1.05x** | ~29x |
| **full stack (dev/PGO)** | shipped + PGO profile from a Pi boot+idle run | ~10-12 s | 14.25 | **1.10x** | ~29x |

## Conclusions

- General/integer/UI throughput on the pure 68k interpreter is fundamentally
  CPU-bound on the A53. Build-flag + interpreter tuning yields about **+5%**
  (shipped) to **+10%** (with PGO). It is not possible to reach a 2-5x *general*
  speedup without a native ARM JIT (a large effort; macemu's JIT is x86-only).
- **Floating-point** is the one place with a large win: swapping MPFR for the
  hardware-double IEEE core is **~29x** on FP ops, so FP-heavy apps see a big
  jump. This also removes the `libmpfr`/`libgmp` dependencies.
- PGO is the biggest build-flag lever (+5% over O3+LTO) but needs a two-phase
  build with a profiling run on real hardware, so it is a documented optional
  step (`scripts/dev-basilisk.sh`), not part of the default chroot image build.
- Telemetry stays compiled in but off unless `RPIMAC_TELEMETRY=1`.

## AArch64 JIT (in progress, not shipped)

A native ARM64 JIT is the only path to a 2-5x *general* speedup, so the
existing AArch64 JIT (the rcarmo/macemu fork) was integrated and tested on the
Pi Zero 2.

Update (2026-06-18, branch `perf/aarch64-jit-v2`): the earlier "JIT hangs the
board" finding was a **memory over-commit**, now fixed. The fork eagerly filled
~650 MB of empty-bus I/O/NuBus regions with 0xFF on a 415 MB board, which
thrashed zram (board impossibly slow, not a clean OOM). A **lazy 0xFF fill on
fault** (`files/0004-fork-lazy-io-fill.patch`) drops resident memory to
~20-90 MB, and the JIT now runs the ROM + early Mac OS video on the Pi without
hanging the board.

A second fix this pass, `files/0006-fork-jit-specialmem-safe.patch`, removes a
deterministic JIT crash: the special-mem path dispatched through an all-NULL
`regs.mem_banks` table and null-dereferenced on the first L2-native NuBus
access. With it, the JIT clears CLKNOMEM and reaches the video driver / 1bpp
gray desktop at ~59 fps. It still does **not finish booting Mac OS 8**: it
diverges into an un-emulated hardware-poll loop (Slot-Manager parser at
`0x040b98fa`) that the interpreter avoids. NOTE: the previously-reported
"stalls in a clock-calibration loop / sync-tick VIA timer" cause was
**disproven** on hardware - CLKNOMEM behaves identically in the interpreter,
which boots past it. The tuned interpreter above remains the shipping product.
Full write-up, diagnosis, and the safe on-hardware test loop:
[JIT-FINDINGS.md](JIT-FINDINGS.md).

## Notes

- The interpreter runs at ~the same MIPS during boot and at idle (host
  instruction throughput is roughly constant), so MIPS alone does not separate
  boot from idle - frame activity does. Boot detection keys off the screen
  going quiet after the desktop is drawn.
- `boot_to_steady` can vary ~+/-1 s run to run (disk cache, RNG in the boot
  path); important comparisons are run 2-3x.

## Graphics / framebuffer path (Speedometer Graphics, 960x540)

Investigated because the Speedometer *Graphics* sub-score is far lower than the
others and degrades fast with resolution (CPU 2.2, Math 32, **Graphics ~0.55**
at 960x540). New per-stage video telemetry was added to attribute the host-side
cost (patch `files/0003-basilisk-video-perf.patch`, env-gated under
`RPIMAC_TELEMETRY=1`); it emits a second line per second:

```
rpimac-telemetry-video t=.. bbox_ms=.. upload_ms=.. present_ms=.. dirty_pct=.. scan_MBps=.. upload_MBps=.. fb_kib=..
```

- `bbox_ms`  - wall-ms/s in the dirty-region scan (redraw thread)
- `upload_ms`- wall-ms/s in `SDL_LockTexture`+row copy+`glTexSubImage2D` (present)
- `present_ms`- wall-ms/s in `RenderCopyEx`+`RenderPresent`
- `dirty_pct`- fraction of the scanned framebuffer that actually changed

### What the telemetry showed

| State (960x540) | bbox_ms | upload_ms | present_ms | note |
|-----------------|--------:|----------:|-----------:|------|
| idle, legacy tile scan | 290-370 | 0 | 0 | ~30% of a core scanning a static screen |
| heavy draw, legacy | 420-470 | 165-600 | 20-38 | interpreter MIPS collapses to 3-11 |

Two findings:

1. **The dirty scan was pathologically expensive.** Upstream
   `update_display_static_bbox()` compares the framebuffer to its shadow in
   64x64 tiles - thousands of tiny *strided* `memcmp()`s per frame at 60 Hz,
   ~30% of a core even when nothing changes - and then `present_sdl_video()`
   uploads only the *union* of the dirty boxes (one rectangle), so the per-tile
   precision is discarded anyway.
2. **The Graphics *score* is gated by the GPU present path, not the scan.**
   During the test `upload_ms` reaches ~600 ms/s with only 2-26 MB/s of data -
   i.e. it is per-present *fixed overhead* (`glTexSubImage2D` on the VideoCore's
   tiled textures), not data volume - and it starves the 68k interpreter.

### Dirty-scan rewrite (patch `files/0004-basilisk-video-fastpath.patch`)

Replaced the tile scan with a contiguous bounding-box scan: per-row `memcmp()`
(glibc's tuned NEON assembly, early-outs at the first differing byte) for
detection, column-extent narrowing only on rows that changed, one shadow copy
and one dirty rect. Runtime toggles (`RPIMAC_VIDEO_FASTSCAN`,
`RPIMAC_VIDEO_NEON`, `RPIMAC_VIDEO_SCAN_THREADS`) allow A/B and fallback.

Result: idle scan **~330 -> ~200 ms/s** (~40% less, and resolution-scalable).

Measured but **not** beneficial here (kept off/secondary, documented honestly):
- *Hand-rolled NEON per-row compare*: ~260-400 ms/s idle vs ~200 for glibc
  `memcmp` - glibc wins (the scan is memory-bandwidth bound, and `memcmp` is
  already SIMD). NEON is used only for the small per-changed-row column scan.
- *Multi-threaded scan* (`RPIMAC_VIDEO_SCAN_THREADS=2|3`): no improvement
  (bandwidth bound), default 1.
- *Skipping `SDL_RenderClear` when the image fills the output*: **regressed**
  the score - on the tile-based VideoCore a full clear is the *fast* path (it
  lets the driver skip loading the previous framebuffer into tile memory).
  Reverted to always-clear.
- *VOSF* (`--enable-vosf`, page-fault dirty tracking): **crashes with SIGSEGV
  on the KMSDRM display** on aarch64 (the same instability that made the JIT
  fork disable it). Rejected; the rect-based scan ships instead.

Important: single Speedometer runs are dominated by Pi Zero 2 thermal drift (the
board spins with `idlewait false`), so the headline numbers earlier in a session
(cold chip) are not comparable to later ones. A matched-temperature A/B (warm
chip, back-to-back) showed the dirty-scan rewrite alone is **score-neutral** - it
cuts host *CPU* (good for power/heat/headroom and lighter workloads) but the
Graphics *score* is bound downstream by the GPU present path.

### What actually moves the score: the texture upload

Telemetry pinned the heavy-draw bottleneck on `upload_ms` (~600 ms/s) with tiny
`upload_MBps` (2-26) - i.e. per-present *fixed cost*, not data volume. Two levers
attack it (patch `0004`, runtime knob `RPIMAC_VIDEO_UPLOAD`):

- **Upload method (default = `SDL_UpdateTexture`, mode 1).** The upstream path is
  `SDL_LockTexture` + a per-row `memcpy` into SDL's staging buffer, then
  `glTexSubImage2D`. Mode 1 uploads the dirty rect straight from the framebuffer
  in one step, removing SDL's staging buffer *and* our per-row copy (up to
  ~120 MB/s of CPU copying at 60 Hz). Mode 2 (whole-frame `SDL_UpdateTexture`)
  moves more bytes through the same fixed-overhead path and tested slower.
- **Present frequency (`frameskip`).** `frameskip 2` presents at ~30 Hz instead
  of 60 Hz, halving how often the upload/present overhead is paid.

### Matched-temperature results (warm ~60C, 960x540, 3 runs each)

| Upload mode | `frameskip` | Display | Graphics |
|-------------|-------------|---------|---------:|
| 0 (Lock+memcpy, upstream) | 0 | 60 Hz | ~0.71 |
| **1 (`SDL_UpdateTexture`, default)** | **0** | **60 Hz** | **0.934** |
| 0 (Lock+memcpy) | 2 | 30 Hz | 1.274 |
| **1 (`SDL_UpdateTexture`)** | **2** | **30 Hz** | **1.318** |

So mode 1 is a **~1.3x win at full 60 Hz with no display tradeoff** (shipped as
the default), and `frameskip 2` stacks on top for **~1.85x** at 30 Hz. During the
fast configs interpreter MIPS recovers from ~11 (collapsing to 3) up to ~19.75 -
the win is the guest getting its cores back. (For reference the original cold-chip
reading was ~0.55; matched-warm baseline is ~0.71.)

### Conclusions

- Ship telemetry (`0003`) and the video fast path (`0004`): contiguous dirty
  scan (~40% less host CPU, resolution-scalable) **and** `SDL_UpdateTexture`
  upload (default, ~1.3x Graphics at 60 Hz, no downside).
- For more at high resolution, raise `frameskip` to 2 (~1.85x, 30 Hz refresh);
  selectable in the web UI (Settings -> Frame skip).
- Rejected after measurement: hand-rolled NEON scan (glibc `memcmp` wins),
  multi-threaded scan (bandwidth bound), skipping `RenderClear` (regresses on
  the tiled VideoCore), whole-frame upload (mode 2, slower), and VOSF (SIGSEGV
  on KMSDRM). The remaining ceiling is `glTexSubImage2D` throughput on the
  VideoCore; going further would need texture double-buffering or a zero-copy
  DMABUF/EGLImage path (future work).
