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

## AArch64 JIT (investigated, not shipped)

A native ARM64 JIT is the only path to a 2-5x *general* speedup, so the
existing AArch64 JIT (the rcarmo/macemu fork) was integrated and tested on the
Pi Zero 2. Result: the fork **builds for the A53** and its **interpreter boots**,
but the **JIT hangs the board** (memory over-commit; reproduced twice, even with
a 16 MB cache and the pristine fork). It is therefore **not shipped**; the tuned
interpreter above remains the product. Full write-up and reproduction steps:
[JIT-FINDINGS.md](JIT-FINDINGS.md).

## Notes

- The interpreter runs at ~the same MIPS during boot and at idle (host
  instruction throughput is roughly constant), so MIPS alone does not separate
  boot from idle - frame activity does. Boot detection keys off the screen
  going quiet after the desktop is drawn.
- `boot_to_steady` can vary ~+/-1 s run to run (disk cache, RNG in the boot
  path); important comparisons are run 2-3x.
