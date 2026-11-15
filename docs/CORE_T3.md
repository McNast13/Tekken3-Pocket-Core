# Tekken 3 core: from the System 11 tree to System 12 (build plan)

Started 2026-11-13. Goal of the first milestone: **Tekken 3's attract mode on the Pocket**, silent and without controls,
with a fake H8 (docs/STUDY.md section 7) in place of the real one. Everything here carries into the finished core; the
real H8 replaces the fake later. Sources: MAME `src/mame/namco/namcos12.cpp` (master, read 2026-11-13) and the System 11
core tree that `tools/build_core_tree.py` assembles.

## What changes, and where

| # | Change | System 11 today | System 12 / Tekken 3 | Files |
|---|---|---|---|---|
| 1 | Data slots and ROM files | 10 slots; C76 program 256 KB, wave 4 MB, C76 BIOS | program 4 MB, banked ROM 28 MB (slots 4+5), wave 8 MB, H8 program 512 KB; no C76 BIOS | `pocket/dist/.../data.json`, `tools/make_games.py` (Tekken 3 set only) |
| 2 | SDRAM layout | RAM 0, BIOS/program 0x400000, fixed ROM 0x480000, banked 0x800000, SPROG 0x2800000, wave 0x2840000 | see below | `SYSTEM11.sv` loader (`*_START`, `ramdownload_wraddr`) |
| 3 | Boot ROM | program ROM at 0x1FC00000 | same | (check only) |
| 4 | Bank select + CPU window | 8 x 1 MB windows at 0x1F000000 (`s11_bank`) | 16-bit write at 0x1F000000 picks a 2 MB page; window 0x1FA00000-0x1FBFFFFF | `memorymux.vhd` |
| 5 | **ROM DMA (channel 5)** | channel 5 does nothing | write 0x1F700000+o (data d) sets offset = o*2 or (d << 16); bit 31 = program ROM, else banked ROM; channel 5 copies 16-bit ROM words, two per 32-bit RAM word, to D_MADR | `dma.vhd` + a ROM reader on an SDRAM port, `memorymux.vhd` (offset register) |
| 6 | Shared RAM | C76 mailbox in `zn1_io` (0x1FA04000-...) and `c76_sound` | 16 KB at 0x1F080000, 16-bit, shared with the H8 | new block (block RAM) |
| 7 | Fake H8 | C76 | reply 0x7601 when 0x3163 is written to 0x3002; clear 0x30F0, 0x306A, 0x3078 every frame | new small block on the shared RAM's second port |
| 8 | EEPROM | `zn1_io` at 0x1FAF0000 | AT28C16 at 0x1F140000, byte lanes 0 and 2 | `zn1_io.vhd` or the memory mux |
| 9 | I/O block at 0x1FA00000 | inputs, keycus, guns, EEPROM (`zn1_io`) | that range is now the ROM window: `zn1_io` decode moves off it | `memorymux.vhd`, `zn1_io.vhd` |
| 10 | Ignored writes | | 0x1F008000, 0x1F010000, 0x1F018000 (watchdog), 0x1F1BFF08-0F | `memorymux.vhd` |
| 11 | VRAM | 1 MB | 2 MB | GPU addressing + `psx_vram_psram` |
| 12 | C76, C352 | C76 + C352 | C352 stays (driven by the H8 later); C76 removed | `SYSTEM11.sv`, `c76_sound.vhd` |
| 13 | Area cuts | | `t3_gpu_cuts`, `t3_io_cuts` (measured in t3cut1) | variants |

Not needed for the first milestone: sound (needs the H8), controls (inputs reach the main CPU through the H8),
RTC/settings (the "FIRST POWER ON" screen is expected without them), CPU speed.

## SDRAM layout (64 MB)

| From | To | Contents | Size |
|---|---|---|---|
| 0x0000000 | 0x03FFFFF | main RAM | 4 MB |
| 0x0400000 | 0x07FFFFF | program ROM (`tet2vere1.2e/.2j`), boot ROM at 0x1FC00000 | 4 MB |
| 0x0800000 | 0x23FFFFF | banked ROM (`tet1rom0-2`, `tet1fl3`) | 28 MB |
| 0x2400000 | 0x2BFFFFF | wave ROM (`tet1wave0/1`) for the C352 | 8 MB |
| 0x2C00000 | 0x2C7FFFF | H8 program (`tet1vere.11s`) | 512 KB |

44.5 MB in all; the rest is free. Program and banked ROM keep their System 11 start addresses.

## Order of work

1. ROM DMA (5) with its offset register: the biggest new piece. Simulate it with a testbench (nvc) before any build.
2. Memory map (4, 6, 8, 9, 10) and the fake H8 (7).
3. Loader and slots (1, 2) and the Tekken 3 instance.
4. VRAM 2 MB (11).
5. First build: boot to attract mode on the Pocket. Checks: the "FIRST POWER ON" screen, then the attract demo fights.
6. CPU speed measurement on Tekken 3 (stall probe, then the data cache).

## Milestone 1 reached: Tekken 3 attract mode on the Pocket (2026-11-14)

Build t3boot2 (seed 99, `S11_POSEDGE_OUT`; `S11_PROBES=t3_gpu_cuts,t3_io_cuts,t3_s12map,s11_stallprobe,t3_turbo_cache`,
`STALL_GAME=tekken3`): 14,135 ALMs of 18,480 (76%). Timing: setup misses only Slow 0C on the video clock (-0.659 ns);
hold misses only Fast 0C on clk2x (-0.057 ns, four MDEC scale-table paths, clk1x to clk2x). On the Pocket: the colour bars,
then the attract mode, running slowly; no sound or controls (fake H8). No visible corruption with the data cache on.

What `synth/pocket_probe/variants/t3_s12map.apply` does (items 4-12): the System 12 memory map in `memorymux.vhd`, the ROM
DMA (`pocket/core/s12/s12_romdma.vhd` on SDRAM channel 3, DMA channel 5 in `dma.vhd`), the fake H8 in the C76's place,
the GPU in the retail texture-page layout (the GPU already addressed 2 MB of VRAM), and an 8 MB wave ROM download. ROM
images: `tools/make_t3_roms.py` (program, banked and wave images byte-identical to MAME's loaded regions).

Found on the way, all checked in MAME first:
- Tekken 3 does 56,861 channel 5 DMAs in 200 s of attract: all manual mode (CHCR 0x01000000), offsets written as low-half
  stores, never on an odd halfword; it never writes the bank register. Each DMA ends with the channel 5 interrupt
  (DICR 0x00A00000), which the game waits for.
- It needs the upper megabyte of VRAM: 7,586 of 12,303 texture uploads land at rows 512 and up; 31% of textured polygons
  use texture-page bit 11.
- The System 11 rule "no KEYCUS means Tekken 1's GPU (gputype1)" would have put Tekken 3 in the wrong texture-page layout.
- Vsync wait loop: 0x801BBC28-0x801BBC74 and the routine it calls, 0x801B2468-0x801B2484.

Two bugs, both mine, both caught before or on the Pocket:
- `s12_romdma` held its SDRAM request high; `sdram.sv` latches requests, so every read would have been issued twice. The
  request is now one clock, and `tests/romdma/tb_s12_romdma.vhd` models the latch.
- Channel 5 never started (t3boot1 froze on the colour bars waiting for the DMA interrupt): `dma.vhd` starts a channel from
  CHCR bit 28 or its device's request line, and channel 5 had neither. Fix: channel 5 always requests (the ROM is always
  ready). `tests/romdma/tb_s12_dma.vhd` runs the core's own `dma.vhd` with `s12_romdma` and Tekken 3's register sequence;
  it fails on the t3boot1 tree and passes on the fixed one.

Speed: the stall probe's figures per 4 s window (Off / Memory / Memory + compute / + data cache) are not comparable with
each other, because each photo averages a different stretch of the attract mode (Memory + compute came out below Memory
alone). Next: a probe that counts the game's own frames per second.

## Frame rate on the Pocket (t3fps1, 2026-11-14)

`s11_stallprobe.apply` row 9 now counts game frames per 256-vblank window: exits from Tekken 3's vsync wait loop (PC
0x801BBC78). MAME's attract mode runs that loop 60 times a second, so 256 is full speed. Build t3fps1 (as t3boot2 plus
the counter): 14,140 ALMs; setup misses only Slow 0C on the video clock (-0.945 ns), hold met in all four models. Two
photos per CPU turbo setting, 3D attract scenes:

| Setting | Game frames / 256 | Speed | Instructions per busy clock |
|---|---|---|---|
| Off | 128, 128 | 30 fps | 0.45 |
| Memory | 128, 128 | 30 fps | 0.49 |
| Memory + compute | 128, 128 | 30 fps | 0.48 |
| + data cache | 175, 233 | 41, 55 fps | 0.61 |

The game is tied to vsync (60 or 30 per frame). Without the data cache a frame's work takes about 1.3-1.4 frame times, so
it runs at exactly 30; the memory and compute settings (+8%) do not change that. The data cache cuts load waits from 16%
to 5% of busy clocks and memory-stage stalls from 16% to 8%. With it, the largest remaining stall is instruction fetch
(15%). Open: a long soak test of the data cache (it was turned off on System 11 for read corruption), then the remaining
10-25% in heavy scenes.

Data cache soak test (t3fps1, 2026-11-14): 30 minutes of attract mode with the data cache on, no glitches seen. Two
diagnostic screens at the end: 213 game frames per window (50 fps, CPU busy 84%) and 256 (60 fps, a light scene, CPU in
the vsync wait loop), so the main loop was still running normally. The System 11 read corruption that made the upstream
core turn the cache off has not shown up on Tekken 3 so far.

MDEC (movie decoder): Tekken 3 uses it, so it stays (619 ALMs). MAME, 2026-11-14: 1,330 MDEC decode commands (0x3Axxxxxx
at 0x1F801820) and as many DMA channel 0 and 1 starts in 20 minutes of attract mode, 532 in a coin-started game; they come
in bursts (movie clips), not every frame.

## Milestone 2: sound and controls through the real H8 (2026-11-15)

The fake H8 is replaced by a real H8/300H in the C76's place (docs/H8.md for the CPU, peripherals and their tests):
`pocket/core/s12/h8_c76.vhd`, variant `t3_h8.apply` after `t3_s12map.apply`. The H8 program (`tet1vere.11s`, first
256 KB in the H8's byte order) is data slot 6, "H8 program" (`tools/make_t3_roms.py` `rom_6.bin`), read from SDRAM through
an 8 KB cache. Builds on the Pocket, in order:

| Build | Change | On the Pocket |
|---|---|---|
| t3h8snd1 | first real H8 (17,454 ALMs) | boot sounds and attract music play; fights slow, effects "late", only punches work, data-cache turbo setting missing from the menu |
| t3h8meter1, t3h8meter2 | timing meters on the diagnostic screen (`t3_h8_meter*.apply`) | the H8 keeps MAME's rates (vblank 60/s, tempo timers ~120/s each, frame routine 60/s), is 84-86% idle, its program reads wait ~9 clocks, and the main CPU never waits on its sound-command lock (shared 0x3006); fights run at 30 fps |
| t3h8snd2 | cache line fill fixed (4 SDRAM reads a line, was 16); turbo option renamed "Mem + compute + cache" (the 29-character name did not show) | option visible; fights no faster with it; effects "at half speed" |
| t3h8snd4 seed 22 | C352 wave reader widened to 8 MB (it took 22 bits: samples in the upper 4 MB, about a third of Tekken 3's in MAME, played the wrong data); the System 12 input bytes as MAME's in_r builds them (Tekken 3's kicks are JVS buttons 4 and 5, read at 0x300003) | kicks work; sound close to normal; best speed with "Mem + compute + cache" |

t3h8snd4 seed 22: 17,440 / 18,480 ALMs, 285 / 308 M10K, 42 / 66 DSP; timing met everywhere except one setup path in the
diagnostic overlay (video clock, Slow 0C -0.509 ns). Seeds 3 and 99 of the same design failed on the GPU clock, so seeds
are compared for every changed design.

Open:
- Speed: fights stay at 30 fps even with the data cache (the cache's 41-55 fps was measured in attract scenes only). Next:
  a frame-rate / stall probe build in a fight, then the CPU work (the real System 12 runs its CPU at 50.8 MHz, 1.5x the
  core's).
- Sound accuracy: by ear "close to normal"; not compared with MAME on the Pocket. In simulation 157 / 160 C352 registers
  follow MAME's over 16 s (one note goes to a different voice at 13 s).
- Space: 1,040 ALMs free; LABs are nearly all in use.
