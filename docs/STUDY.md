# Paper study: can Tekken 3 fit on the Pocket?

2026-11-07. A study on paper: nothing was built. It updates the 2026-10-24 feasibility work in [PLAN.md](PLAN.md) with
what has changed since: the System 11 core is at v0.2.2, MIRLO 64 (an N64 core for the Pocket) has shown what this FPGA
can do, and XelaNotPu will not publish the SYSTEM12 source. Sources: the System 11 v0.2.2 fit report
(`../NamcoSystem11`), MAME 0.289 runs of `tekken3` with the new scripts `tools/mame/h8_io.lua` and
`tools/mame/h8_trace.lua`, MAME's `namcos12.cpp`, `h83002.cpp` and `video/psx.cpp` (master, 2026-11-07), and MIRLO 64's
documentation (`references/MIRLO64`).

## Verdict

**Maybe: possible, but not yet proven.** Nothing found so far rules Tekken 3 out. Two questions decide it, and both
can be answered cheaply before the big work (an H8 CPU core) starts:

1. **CPU speed.** Can the System 11 CPU, kept at 33.87 MHz, do Tekken 3's work with PSX_MiSTer's turbo modes? This
   needs the t3turbo2 speed test, which never finished building.
2. **Fit.** The H8 and the System 12 parts have to fit in the room the C76 leaves, about 2,350 ALMs. The best estimate
   just fits. The likely estimate is a few hundred to 1,500 ALMs over, which needs cuts elsewhere.

| Question | Answer | Risk |
|---|---|---|
| ROMs in memory | 44.5 of 64 MB of SDRAM; 2 MB VRAM in the PSRAMs | Low |
| Block RAM | The H8 needs 64 KB; about 71 blocks are free, and the C76 frees more | Low |
| H8 peripherals | Only part of the H8/3002 is used (below) | Low |
| H8 CPU core | None exists to reuse: we write one | Medium: known amount of work |
| Logic (ALMs) | ~2,350 available; 2,350 to 3,850 needed | **High** |
| CPU speed | Not measured yet | **High** |

Estimated chances (see [PLAN.md](PLAN.md#likelihood-of-success-2026-11-07)): playable with some slowdown about one in
three, full speed about one in six.

## 1. CPU speed

Tekken 3 does about 1.65 times Tekken 1's work per frame (MAME profile in PLAN.md). On System 11 hardware, Tekken 1's
demo fight already keeps the CPU 88% busy (t3turbo1, on the Pocket). So at 33.87 MHz the core must run about **1.45
times faster per clock** to keep up.

**What MIRLO 64 shows:** its MIPS CPU runs at **93.75 MHz** on the Pocket's exact chip (Cyclone V `5CEBA4F23C8`, the
slowest speed grade), in a design 97% full. So a MIPS at Tekken 3's real ~50 MHz is physically possible on this FPGA.
It got there by designing the pipeline for speed: cache words used before their tag check, branches decided early,
forwarding selects registered a stage ahead. The PlayStation core's CPU was not built that way: System 11 only just
meets timing with its 2x clock at 67.7 MHz, so that CPU cannot simply be clocked at 50 MHz (a 100 MHz 2x clock).

The options, cheapest first:

| Option | Work | Note |
|---|---|---|
| Keep 33.87 MHz and use the turbo modes (`TURBO_MEM`, `TURBO_COMP`) | Small: already in the tree | Measure with t3turbo2. Too slow would mean slowdown in heavy scenes, not a crash: the game waits for vsync |
| Rework the PS CPU for ~50 MHz, using MIRLO's techniques | Large | Ideas only. MIRLO's code is Apache-2.0, which cannot be mixed into the GPL-2.0 PlayStation core without its author's permission |
| Turbo plus partial rework (for example, caches only) | Medium | Only if the turbo test falls a little short |

## 2. The H8/3002 sound and I/O CPU

**No open-source H8/300H core exists** (searched again 2026-11-07: Renesas sells commercial IP; there is an academic
VHDL design of the older 16-bit H8/300). We write our own and check it against MAME in simulation, as was done for the
C352.

**What Tekken 3 uses** (MAME, 170 s of attract mode, `tools/mame/h8_io.lua`):

| H8/3002 block | Used? | What for |
|---|---|---|
| 16-bit timers (ITU) | Yes: channels 0-3 | Channels 0 and 1 interrupt about 120 times a second; 2 and 3 are read as clocks |
| Serial port 1 (SCI1) | Yes | The RTC and the board's settings chip, in clocked mode |
| A/D converter | Lightly | Status polled; results read only a few times |
| I/O ports 7, 8, A, B | Yes | DIP switches, RTC/settings chip select, vblank |
| Serial port 0 (SCI0) | **No** | JVS: Tekken 3 reads its controls directly (JAMMA, `0x300000`) |
| DMA controller | **No** | |
| Watchdog, DRAM refresh | **No** | |
| Interrupt controller | Yes | Set up before the measurement started, so not counted |

Other numbers from the same run: the H8 touches 34 of its 64 KB of RAM pages, the highest at 55 KB, so all 64 KB must be
block RAM. It accesses that RAM about 1.3 million times a second, far too often for SDRAM. The C352 gets about 3,000
accesses a second.

**Instructions** (MAME trace of 30 frames of the demo fight, `tools/mame/h8_trace.lua`): 1.45 million instructions at
1,807 different addresses use **50 distinct instructions**. Most of the time is a polling loop (`mov.b` and `bne`).
The core should still implement the whole H8/300H instruction set, because start-up, the test menu and other scenes may
use more. The list sets the order of the work and of the tests.

**Size:** the C76's CPU (M37702, also 16-bit) is 1,739 ALMs in System 11. The H8/300H has 32-bit registers and
arithmetic, so the estimate is **1,800 to 2,800 ALMs**, plus **450 to 750** for the peripherals above and its bus.

## 3. Fit (ALMs)

System 11 v0.2.2 uses 18,216 of 18,480 ALMs (99%).

| | ALMs |
|---|---|
| Free today | ~260 |
| Freed: C76 CPU and its wrapper (`c76:icpu`, which includes the M37702's 1,739) | +2,089 |
| **Available** | **~2,350** |
| H8/300H CPU (estimate) | 1,800 - 2,800 |
| H8 peripherals and bus (estimate) | 450 - 750 |
| System 12 glue: bank register, ROM DMA offset, 2 MB VRAM addressing | 100 - 300 |
| **Needed** | **2,350 - 3,850** |

The C352 (2,113) stays, since System 12 uses it too. MDEC (622) stays because the attract FMV needs it. The EEPROM part of
`zn1_io` stays, because System 12 has the same AT28C16.

Also, a design 99% full only closes timing with seed hunting. Running at 100% is not realistic, so plan for a few hundred
ALMs to spare.

**Places to look for room** (to be measured, not counted above): gun-aim logic (Tekken 3 has no guns), savestates
(205), the System 11-only parts of `zn1_io` (572 in all), and synthesis settings. MIRLO 64 builds for area
(`OPTIMIZATION_TECHNIQUE AREA` with a placement effort multiplier of 10); this core has not tried that.

## 4. Memory

- **SDRAM:** program 4 MB, graphics/data 28 MB, wave 8 MB, H8 program 0.5 MB, main RAM 4 MB: 44.5 of 64 MB. The H8's
  program comes from SDRAM, as the C76's does on System 11.
- **VRAM:** System 12's GPU has 2 MB, laid out 1024 x 1024 (MAME `video/psx.cpp`: 2 MB means 1024 lines, not 512). The
  PSRAMs have room; the GPU's addresses need one more bit of Y.
- **Block RAM:** 237 of 308 blocks used, 71 free, plus what the C76 frees. The H8's 64 KB RAM needs about 64 blocks.
- **ROM bank switching:** in MAME, Tekken 3 reads its graphics ROM only by DMA, at most about 1 MB a second. Easy for
  SDRAM.

## 5. Licence

The PlayStation core (PSX_MiSTer, openfpga-PlayStation) and SYSTEM11_MiSTer are GPL-2.0. MIRLO 64 is Apache-2.0, which
cannot be combined with GPL-2.0-only code. Its documents and techniques are free to learn from. Taking its code would
need its author's permission.

## 6. What the Pocket PlayStation core can teach us

This core is already built on it: the CPU, GPU, GTE, MDEC and DMA come from openfpga-PlayStation v0.5.6.

- **PlayStation Tekken 3 is a different program.** Namco rewrote it for the console's 33.87 MHz CPU and 1 MB VRAM, with
  simpler backgrounds and effects. Running well on the PlayStation core says nothing about the arcade code, which was
  written for System 12's ~50 MHz CPU and 2 MB VRAM. It does show that Namco needed cuts to fit the game into a 33.87 MHz
  CPU, which supports expecting the arcade code to be too slow without help.
- **No CPU speed-up to borrow.** The PlayStation core has no overclock. Its tests force `TURBO_CACHE` (and
  `TURBO_CACHE50`) off, matching the System 11 author's finding that it corrupts reads. Only `TURBO_MEM` and `TURBO_COMP`
  remain, which is what the t3turbo2 test measures.
- **Newer versions may give room.** v0.5.7 and v0.5.8 (2026-10-22 onwards) are mostly clean-up, plus a reworked PSRAM VRAM
  path (`psx_vram_x3.sv`, `psx_vram_psram.sv`). Worth checking for area or timing gains during the fit gate, since our VRAM
  path is the known clk2x timing miss.

## Recommended next steps (the go/no-go gates)

1. **Speed gate (on the Pocket):** rebuild t3turbo2 and take the three turbo photos (Off, Memory, Memory + compute) in
   Tekken 1's demo fight. Go if Memory + compute gives about 1.45x or more. A smaller gain points to partial CPU rework,
   or to accepting some slowdown.
2. **Fit gate (on paper and a probe build):** build a System 11 probe with the C76 CPU removed and the candidate cuts
   applied (guns, savestates, System 11-only I/O, area synthesis settings), and measure the real room.
3. **H8 instructions in full:** extend the trace to start-up, the test menu and a full fight, and list every instruction
   and addressing mode used.
4. **Only after 1 and 2 pass:** write the H8/300H core and test it against MAME, then the System 12 memory map.

Gates 1 and 2 cost an evening each. The H8 core is weeks of work, and should wait for both.

## Results of the gates (2026-11-12)

### Speed gate: failed for the cheap route

Build t3turbo2 (seed 99, `s11_cpuload` probe, 18,201 ALMs) on the Pocket, Tekken (`tekkenac`) attract mode, one photo per
CPU turbo setting. Decoded with a perspective-correct grid; the known rows (C76 first PC `00C030B0`, platform `14008000`,
566,203 clocks per frame) match in all three photos.

| CPU turbo | Busy clocks per frame | Instructions while busy | Instructions per busy clock |
|---|---|---|---|
| Off | 412,609 (73%) | 194,518 | 0.471 |
| Memory | 325,628 (58%) | 155,863 | 0.479 |
| Memory + compute | 485,742 (86%) | 225,647 | 0.465 |

The turbo bits reach the CPU, DMA, GTE and memory mux (row 5 shows them), but the instructions per clock do not move:
**about 1.00-1.02x, against the ~1.45x needed.** Each photo averages a different 4-second stretch of attract mode, so
the busy percentages differ; the per-clock rate does not depend on the scene. At about 0.47 instructions per clock the
CPU manages ~266k instructions a frame against Tekken 3's ~363k (MAME, approximate): roughly 70-75% speed in heavy
fights. Full speed needs a faster CPU (MIRLO 64's approach), which is the next step if the fit allows it.

### GPU command trace (MAME, `tools/mame/gpu_cmds.lua`)

Every GP0 command, from CPU writes and DMA channel 2 (linked lists walked in RAM, 0 nodes ending mid-command), over
300 s of attract mode and 300 s of a game started with a coin:

| | Attract | Game |
|---|---|---|
| Polygons | 12.1 M | 13.5 M |
| Rectangles | 546 k | 750 k |
| Lines (`gpu_line`, 494 ALMs) | **0** | **0** |
| VRAM -> CPU reads (`gpu_vram2cpu`, 113 ALMs) | **0** | **0** |
| VRAM fill, copy, CPU -> VRAM | used | used |

Also used: texture windows, dithering, blend modes 0-2, 4- and 8-bit textures, raw textures. Never seen: blend mode 3,
15-bit textures.

Second pass (2026-11-13), all headless with scripted inputs (`GPU_INPUTS`, `GPU_SNAP`) and screenshots to confirm each
screen was really reached:

| Run | Covers | Lines | VRAM -> CPU |
|---|---|---|---|
| Test menu | main menu, Display Test (Color Bar, Convergence, Diagonal), Switch Test with presses, Sound Test, Game Options (all items), Coin Options, A.D.S. pages, Backup Data Clear menu | **0** | **0** |
| 1P game to game over (15 min) | stage 1 lost, continue countdown, GAME OVER, back to attract | **0** | **0** |
| Attract (20 min, 71,792 frames) | several full cycles: intro movies, demo fights, title, Character Time Record and VS Game Wins Record tables | **0** | **0** |
| VS streak (12 min) | 4-win VS streak, streak ended by the challenger, name entry ("4 WINS A", shown in the continue screen), 1P continue | **0** | **0** |

Still never seen: blend mode 3, 15-bit textures. Not covered: the endings (need the game beaten). Even the test menu's
grid and diagonal patterns are polygons, so `gpu_line` and `gpu_vram2cpu` can go.

Test menu controls (for scripts): JVS test button (`JVS_SYSTEM` "Service Mode") opens it once the game is running (the
DIP "Service Mode" does nothing); P1 Up/Down move, P1 Button 1 selects; Start exits most pages, Buttons 3+4 exit Switch
Test; in Display Test, Button 1 steps the pattern.

### Fit probe: fitprobe1

The C76's M37702 replaced by a stub of the same ports (`synth/pocket_probe/variants/fit_no_m37702.apply`) that keeps the
C76 wrapper, shared RAM and C352 live (the C352 stays at 2,055 ALMs, so nothing was pruned). Seed 99, no probes.
**16,152 of 18,480 ALMs: 2,328 free.** Worst timing: Slow 0C setup -0.588 ns (video clock), Fast 0C hold -0.018 ns;
the clk2x VRAM miss of the full builds is gone at this density.

| Room for the H8 and System 12 parts | ALMs |
|---|---|
| Free in fitprobe1 | 2,328 |
| C76 wrapper left in the probe (SFRs, timers: replaced by the H8's peripherals) | 311 |
| GPU lines and VRAM reads (unused by Tekken 3) | ~600 |
| Other games' logic in `zn1_io` (protection chips, guns) | ~400 |
| Diagnostic screen | ~140 |
| **Total** | **~3,780** |

Needed: 2,350-3,850. **The fit now looks likely**, with the H8 core's real size as the remaining unknown. The cuts
after the first row are measured block sizes from the fit report, not yet a build.
