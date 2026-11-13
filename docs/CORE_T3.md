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
