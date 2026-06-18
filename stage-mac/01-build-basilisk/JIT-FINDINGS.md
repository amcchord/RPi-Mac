# AArch64 JIT investigation (Basilisk II on the Pi Zero 2)

Goal: replace the pure 68k interpreter with a native ARM64 JIT for a large
(2-5x) speedup using the existing AArch64 JIT in the rcarmo/macemu fork.

Status (2026-06-18, branch `perf/aarch64-jit-v2`): **the JIT now runs on the
Pi Zero 2 without hanging the board** - the previous "hangs the board" blocker
was a memory over-commit, now fixed (see "The real blocker", below). With
`B2_JIT_ALL_SPECIAL_MEM=1` the JIT executes the ROM, clears CLKNOMEM, reaches
Mac OS 8's video-driver init, and refreshes the 1bpp gray desktop at ~59 fps,
but **Mac OS 8 does not yet finish booting**. The remaining issue is JIT
*correctness* (control-flow divergence into un-emulated hardware-poll loops),
not memory and not the clock. The shipping image still uses the tuned
interpreter; the JIT is dev-only on this branch.

**Correction (this pass):** an earlier finding said the JIT "stalls in a ROM
clock-calibration loop (CLKNOMEM)" and blamed the synchronous tick model not
advancing the VIA timer. A controlled interpreter-vs-JIT comparison on the Pi
**disproves** that: both cores run the CLKNOMEM `d1` count-up identically with
`Ticks`($016a) frozen, and the interpreter then boots straight on to
`CHECKLOAD`/System loading. CLKNOMEM is bounded calibration, not a tick stall.
The real blockers are JIT memory/control-flow correctness (below).

## Approach
[rcarmo/macemu](https://github.com/rcarmo/macemu) is a fork of the same
kanjitalk755 base we pin, adding an experimental AArch64 JIT
(`uae_cpu_2026/compiler/codegen_arm64.*`, `compemu_*_arm64*`), a managed-IRQ
model, and Raspberry Pi SDL2/KMS packaging.

Pinned fork commit: `bb1b2f28eba9ca4de2daee471032d2b66dd22dce`
(cached as `cache/macemu-rcarmo-<commit>.tar.gz`).

Patches (in `files/`, applied in this order by `scripts/dev-basilisk.sh`):
- `0001-fork-jit-sdlrotate.patch` - display rotation / KMS packaging (pre-existing)
- `0003-fork-interp-buildfix.patch` - **NEW.** Makes the fork build at all in
  pure-interpreter mode: the fork's `EMULOP_DIAG` line in `newcpu.cpp` and the
  `jit_describe_native_pc_for_segv` call in `main_unix.cpp` reference
  symbols/fields that only exist under `OPTIMIZED_FLAGS` / `USE_JIT`. Guards
  them so a non-JIT aarch64 build links. (No prior pure-interpreter fork build
  had ever actually succeeded; all earlier "fork interpreter" trees were
  secretly JIT-configured.)
- `0004-fork-lazy-io-fill.patch` - **NEW. The key fix** (see below).
- `0005-fork-jit-quiet-trace.patch` - **NEW.** Gates the fork's per-dispatch
  `JIT_ENTRY` and per-block `DC[...]` `fprintf`+`fflush` hot-path tracing behind
  `B2_JIT_TRACE=1` (default off). Left on, it floods the journal and cripples
  throughput.
- `0002-fork-jit-perf.patch` - telemetry + IEEE-FPU option (pre-existing). It
  builds and runs fine now; its previous "crashes early init" was the same
  over-commit below, not a defect in the patch. NOTE: its MIPS counter assumes
  the interpreter's tick cadence and is **not** meaningful under this JIT.
- `0006-fork-jit-specialmem-safe.patch` - **NEW.** Fixes a deterministic JIT
  crash: the special-mem read/write path (used by `B2_JIT_ALL_SPECIAL_MEM=1`)
  dispatched through `regs.mem_banks[adr>>16]`, an all-NULL table in this
  flat direct-addressing build, so the first L2-native special access
  dereferenced NULL and segfaulted (seen as the NuBus Slot-Manager read at
  guest `0x0404b0c0`, `host=(nil)`). Routes the special path through the safe
  direct host mapping instead (lazy-fill backs IO/NuBus with 0xFF). Default JIT
  and the pure interpreter are unaffected. With this fix the JIT advances past
  the crash into video init / the gray desktop.

## The real blocker (now fixed): memory over-commit -> zram thrash
The prior finding was "the JIT hangs the entire Pi Zero 2 ... requiring a
re-image." Root cause, confirmed this pass:

- The fork's `main_unix.cpp` eagerly `memset(..., 0xFF, size)` of the Mac
  empty-bus I/O and NuBus probe regions: I/O (240 MB) + NuBus-super (256 MB) +
  NuBus-lo (~120 MB) + I/O-48 (32 MB) ~= **650 MB committed on a 415 MB board.**
  The log `NuBus-lo head map/protect failed: Cannot allocate memory` is this
  running out of RAM partway.
- With **zram swap on** (`/dev/zram0`, ~415 MB, `vm.swappiness=60`), the burst
  doesn't cleanly OOM - it evicts everything else (including `sshd`) into zram,
  so the board answers ping in <1 ms but is far too slow to complete an SSH
  handshake. Combined with the emulator service's `Restart=always`, each 3 s
  restart re-thrashed, keeping the board unreachable. This is the "impossibly
  slow, not out of memory" behaviour, not a JIT defect.
- The v0.6.0 FAT-corruption fix removed the *recovery* pain (the re-image loop)
  that previously confounded all of this.

### Fix: lazy 0xFF fill on fault (`0004-fork-lazy-io-fill.patch`)
Map the `fill_ff` regions `PROT_NONE` + `MAP_NORESERVE` instead of committing
them, register their host ranges, and fill **one page at a time with 0xFF in
the existing SIGSEGV handler** on first access (returning
`SIGSEGV_RETURN_SUCCESS` to retry). Empty-bus 0xFF read semantics are preserved
for any probed address, but only the handful of pages the ROM/OS actually
touches consume RAM.

Result: interpreter and JIT both reach full `InitAll` with **RSS ~20-90 MB**
instead of ~650 MB; the board stays healthy (no swap thrash), `SEGV_SKIP`
count stays ~0.

## Current JIT status: diverges into hardware-poll loops (correctness)
With lazy-fill + `0006` (special-mem fix), the JIT build (`jit true`, 8 MB
cache, `max_optlev=2`, `B2_JIT_ALL_SPECIAL_MEM=1`):
- maps all regions lazily, completes `InitAll`, allocates the translation
  cache, executes translated ARM64 code, **clears CLKNOMEM**, and reaches the
  video driver - `video_open`, GDevice/PixMap setup, `SetEntries`, and refreshes
  the 1bpp gray desktop at ~59 fps - but this is the boot screen, **not** the
  Finder. `DiskStatus`/`CHECKLOAD` are still 0 (the boot volume is never
  mounted).

Diagnosed on-Pi via `B2_TRACE_BOOT_STAGE=1`, `B2_JIT_TRACE=1`, a 68k
disassembly of `Q650.ROM`, and an interpreter-vs-JIT control run:

1. **(was a red herring) CLKNOMEM at `0x040b35c6`.** This is the ROM's
   VIA-bit-banged RTC/PRAM clock routine (`movew sr,d2; ori #$0700,sr; ...`),
   already replaced by `EMUL_OP_CLKNOMEM`. Its caller counts `d1` up by `0x400`
   while `Ticks`($016a) stays 0. **The interpreter does the *identical* count
   with `Ticks` frozen and boots on** - so this is bounded calibration, not a
   tick stall. The earlier "advance the sync-tick VIA timer" lead is wrong.
2. **(fixed) NuBus special-mem null-deref crash, guest `0x0404b0c0`.** With
   `ALL_SPECIAL_MEM`, the Slot Manager's `addal (52,a3),a3` (A3 -> NuBus
   `0xf0000000`) crashed: the special path dispatched through an all-NULL
   `regs.mem_banks`, dereferencing NULL (`host=(nil)`), and the compiled-code
   SEGV recovery (a non-functional stub - `jit_recovery_address` is never set)
   missed and crashed. Fixed by `0006` (route special-mem to the direct host
   mapping). The interpreter SEGV-skips the same read.
3. **(remaining blocker) JIT diverges into hardware-poll loops the interpreter
   avoids.** Both with and without `ALL_SPECIAL_MEM`, the JIT spins ~40M
   dispatches in a threaded-code parser at `pc 0x040b98fa / 0x040b9aba /
   0x040ba0a8-0x040ba0d6` (a Slot-Manager / declaration-ROM byte-code loop that
   polls a device status register at `(A3+2)`/`(A3+6)` gated by `d7` bits
   17/19). BasiliskII does not emulate that register, so the polled value never
   changes and the loop never exits. The interpreter does not get stuck here
   (it reaches `CHECKLOAD`/System loading), so the JIT is either taking a wrong
   branch into this routine or reading the wrong sentinel. This is the same
   class of "JIT control-flow divergence into un-emulated hardware polling" the
   fork's own `AARCH64_JIT_BRINGUP.md` documents and never resolved (pure-L2
   has never reached the Finder, even on faster hardware).

## Recommended next steps (where to start next)
1. **Resolve the divergence at `0x040b98fa`/`0x040ba0a8`** (the gating blocker).
   Capture an aligned interpreter-vs-JIT PC+register trace from the last shared
   PC before the JIT enters this parser (the isolation-matrix method in
   `BasiliskII/docs/AARCH64_JIT_ISOLATION_MATRIX.md`) to decide between (a) a
   real codegen/branch bug feeding the loop vs (b) a wrong byte read from the
   emulated slot/declaration ROM. If it is an un-emulated-register poll the
   interpreter also hits but exits, a signature-guarded ROM patch (mirroring the
   disabled NuBus-scanner skips already stubbed in `rom_patches.cpp` near
   `0xb9874`/`0xba0b0`) is the low-risk unblock.
2. Replace the blunt `B2_JIT_ALL_SPECIAL_MEM=1` with marking **only** the
   I/O / VIA / NuBus host ranges JIT-special, so the rest of memory keeps the
   fast direct path (needs trace-time IO-range detection feeding
   `pc_hist[].specmem`, which is currently never set).
3. Then measure throughput. The existing telemetry MIPS is interpreter-specific;
   add a JIT-aware instruction counter (e.g. accumulate per-block 68k
   instruction counts at dispatch) before trusting any MIPS number.

## How to build + test (dev harness, not the image build)
Build on the aarch64 dev box, deploy the binary to the Pi:

```bash
export ac_cv_have_asm_extended_signals=yes
PI_HOST=192.168.1.198 \
MACEMU_TARBALL="cache/macemu-rcarmo-bb1b2f28eba9ca4de2daee471032d2b66dd22dce.tar.gz" \
BUILD_NAME=fork-jit MCPU=cortex-a53 PERF_CFLAGS="-O3" PERF_CXXFLAGS="-O3" \
PATCHES="0001-fork-jit-sdlrotate.patch 0003-fork-interp-buildfix.patch 0004-fork-lazy-io-fill.patch 0005-fork-jit-quiet-trace.patch 0002-fork-jit-perf.patch 0006-fork-jit-specialmem-safe.patch" \
CONFIGURE_EXTRA="--enable-jit-compiler --enable-aarch64-jit-experimental --disable-vosf --enable-addressing=direct" \
scripts/dev-basilisk.sh build
```

Enable the JIT at runtime with prefs `jit true` + `jitcachesize 8192`, and run
with `B2_JIT_ALL_SPECIAL_MEM=1` (current furthest-reaching config: clears
CLKNOMEM + the NuBus crash, reaches the gray desktop). A 68k disassembler for
diagnosis: `apt install binutils-m68k-linux-gnu`, then
`m68k-linux-gnu-objdump -D -b binary -m m68k:68040 --adjust-vma=0x04000000 Q650.ROM`.

### Safe test protocol (the over-commit is fixed, but stay defensive)
- NEVER deploy an experimental binary to the auto-restarting service for a
  *first* test. The over-commit is fixed, but a crash loop on `Restart=always`
  still risks Mac-disk corruption from repeated unclean kills mid-boot.
- For init/footprint checks, run **headless + cgroup-capped** so a regression
  is OOM-killed in its own cgroup instead of touching the board:

```bash
sudo systemctl stop rpimac-emulator
sudo systemd-run --scope -p MemoryMax=340M -p MemorySwapMax=0 --uid=mac --gid=mac \
  env HOME=/tmp/testhome SDL_VIDEODRIVER=dummy \
  timeout -s KILL 12 /tmp/BasiliskII-test    # NOTE: BasiliskII ignores SIGTERM; use -s KILL
sudo systemctl start rpimac-emulator
```

- For an on-display boot test, deploy and add a `Restart=no` drop-in so a
  failure does not loop; stopping the service blanks the screen, so warn first.
- Diagnostics: `B2_TRACE_BOOT_STAGE=1` (boot progress), `B2_JIT_TRACE=1`
  (per-dispatch/block pc, very verbose), `B2_JIT_ALL_SPECIAL_MEM=1`
  (force live I/O), `B2_JIT_MAX_OPTLEV=0|1|2`, `B2_JIT_MANAGED_IRQ=1`.

## Recommendation
The headline blocker is solved: the JIT is now testable on the Pi Zero 2
without bricking the board. Keep the tuned interpreter shipping while the
synchronous-tick / VIA-timer fix is developed; the JIT path is preserved on
`perf/aarch64-jit-v2` with a safe iterate-on-hardware loop.
