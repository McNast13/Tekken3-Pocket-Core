# Plan: Tekken 3 on the Analogue Pocket

Started 2026-10-24. Sources: MAME `src/mame/namco/namcos12.cpp` (master, read 2026-10-24) and the System 11 Pocket port
(`../NamcoSystem11`, v0.1.2).

## Hardware (Tekken 3 board set, from MAME)

| Part | Tekken 3 (System 12, COH-700) | System 11 (for comparison) |
|---|---|---|
| Main CPU | Sony CXD8661R (R3000A), 100 MHz crystal, about 48-50 MHz | 33.8688 MHz |
| Main RAM | 4 MB | 4 MB |
| GPU | CXD8654Q, 2 MB SGRAM | 1 MB VRAM |
| Sound + inputs | Hitachi H8/3002 at 16.9344 MHz (MAME's value; board notes say 16.737 MHz), 512 KB program `tet1vere.11s` | C76 (M37702) |
| Sound chip | Namco C352 (MAME: 25.4016 MHz / 288) | C352 |
| PlayStation SPU | not used | not used |
| Boards | COH-700 CPU, SYSTEM12 MOTHER or MOTHER(B), M8F2F ROM board, KC006 keycus | |
| EEPROM / RTC | AT28C16 2 KB, Epson R4543 RTC | |

Memory map points that differ from System 11 (MAME):
- `0x1f000000` bank select; the 28 MB graphics ROM appears through the window `0x1fa00000-0x1fbfffff` in 2 MB pages.
- `0x1f700000` ROM DMA offset; its top bit picks main ROM or banked ROM (Tekken 3 sets it).
- `0x1f080000-0x1f083fff` RAM shared with the H8.
- MAME has no KC006 code; Tekken 3 runs without it.

## Memory fit (Tekken 3)

| Contents | Size | Pocket memory |
|---|---|---|
| Main RAM | 4 MB | SDRAM |
| Program ROM (`tet2vere1.2e/.2j`) | 4 MB | SDRAM |
| Graphics/data ROM (`tet1rom0-2`, `tet1fl3`) | 28 MB | SDRAM |
| Wave ROM (`tet1wave0/1`) | 8 MB | SDRAM |
| H8 program | 0.5 MB | SDRAM or block RAM |
| VRAM | 2 MB | the two PSRAMs (as on System 11) |

About 44.5 MB of the 64 MB SDRAM. The PSRAMs stay dedicated to VRAM, as on System 11.

## MAME profile of Tekken 3 (2026-10-24, MAME 0.289, `tekken3` = TET2/VER.E1, `tools/mame/t3_profile.lua`)

- Boots and runs attract mode: demo fight around frame 4,800 (80 s), then an FMV (Jin) from frame ~8,580 (143 s).
- **MDEC is needed:** the attract FMV feeds MDEC by DMA (30 MDEC DMA starts per second while it plays).
- **ROM access is by DMA only:** no bank-select writes (`0x1f000000`) and no CPU reads of the bank window during 160 s of
  attract. The game writes the ROM offset (`0x1f700000-0x1f70ffff`, low bits in the address) and then starts DMA channel 5.
  Peak ~1 MB/s (fight load), ~250 KB/s while the FMV streams. Trivial for SDRAM.
- **CPU load (demo fight, 3 traced frames from frame 4,900):** 418k instructions per frame, 13% in the vsync wait loop
  (`0x801BBC28-0x801BBC74` plus `0x801B2468-0x801B2484`: it stirs two random seeds until the vblank flag at `0x8021F8A4` is set).
  About **363k instructions of game work per frame**.
- For comparison, Tekken 1 (`tekkenac`) demo fight in the same MAME: 283k instructions per frame, 22% idle (wait loop
  `0x8004B5C4-0x8004B5D4`), about 220k of work. **Tekken 3 does ~1.65x the work per frame.** MAME's instruction timing is
  approximate, so treat this as a ratio, not as a cycle count.

## Open problems

1. **CPU speed.** A 48-50 MHz CPU would need the core's 2x clock near 100 MHz. On the Pocket's slowest-grade Cyclone V, the
   System 11 core only just meets timing at 67.7 MHz. Plan: keep 33.8688 MHz and recover throughput with PSX_MiSTer's turbo modes
   (`TURBO_MEM`, `TURBO_COMP`; `TURBO_CACHE` stays off, as the System 11 author found it corrupts reads). Target: game work must
   finish about 1.42x (48 / 33.87) faster than on an unturboed core.
2. **H8/3002 CPU.** No open-source H8/300H HDL core was found. Closest: `rgwan/chimera` (H8/300, Python HDL). With no upstream
   source coming, we write one and check it against MAME's `h83002` in simulation, as was done for the C352 on System 11.
3. **FPGA area.** System 11 uses about 18,070 of 18,480 ALMs. System 12 swaps the C76 (M37702) for the H8 and adds banking and
   2 MB VRAM addressing. MDEC must stay (the attract FMV uses it); the C76 and its 512 B RAM go.
4. **No upstream source.** XelaNotPu's SYSTEM12 MiSTer core runs Tekken 3 but is not published
   (github.com/XelaNotPu/SYSTEM12_MiSTer holds only a README). As of 2026-11-06 they will not publish it for now, so this
   port is built without it: every System 12 part (H8, banking, memory map) comes from MAME and our own HDL.

## Steps

1. **Turbo measurement on the System 11 core as imported here** (build `turbo1`: diagnostic recipe, seed 99,
   `S11_PROBES=s11_cpuload`, 18,185 ALMs, clk2x setup -0.81 ns on the known VRAM -> `vram_BURSTCNT` path). A "CPU turbo" core setting
   (Off / Memory / Memory + compute) drives `status[80:79]`, and the `s11_cpuload` probe shows on the diagnostic screen how many
   clocks per frame Tekken (tekkenac) spends outside its vsync wait loop (0x8004B5C4). In MAME's attract fight that loop takes only
   ~22% of the instructions, so the game already uses most of the System 11 CPU. Result: the busy-clock ratio between turbo off and on.
2. **MAME profile of Tekken 3** (needs the `tekken3` romset in `roms/`): CPU load per frame (vsync wait loop, as above), MDEC use,
   H8 <-> MIPS shared-RAM protocol, bank switching pattern.
3. **H8/300H core** (needed: no upstream source). Write it and check it in simulation against MAME's `h83002`, as was done for
   the C352 on System 11. Starting points: MAME `h8` CPU sources, `rgwan/chimera` (H8/300 only).
4. **Core tree:** System 11 tree + System 12 memory map, banking, 2 MB VRAM, H8 in place of the C76.
