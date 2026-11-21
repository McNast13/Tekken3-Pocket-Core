# Tekken 3 (Namco System 12) for Analogue Pocket (openFPGA)

**Status:** first preview, v0.0.1. Tekken 3 runs on the Pocket with sound and working controls, through the real H8
sound/input CPU. With the CPU turbo setting "Mem + compute + cache" (the default), fights run at or near 60 fps in some
match-ups but drop towards 30 fps in heavier moments. A larger instruction cache is the next speed step. The sound is close
to MAME's but not yet checked in detail. See [docs/CORE_T3.md](docs/CORE_T3.md) for progress and [docs/H8.md](docs/H8.md)
for the H8.

A single-game core for **Tekken 3** on the Analogue Pocket, following the
[Namco System 11 port](https://github.com/McNast13/NamcoSystem11-Pocket). System 12 is a faster System 11
(PlayStation-derived) with a different sound board, so most of the System 11 work (CPU, GPU, GTE, MDEC, DMA, C352, the Pocket
shell, loader and tooling) is meant to carry over.

Why only Tekken 3: each System 12 game sits on its own ROM daughterboard with its own security chip and ROM layout. All ten
Tekken 3 versions use the same one (M8F2F board, KC006 keycus) and MAME runs them with the plain System 12 driver, with no
game-specific hardware. One fixed memory map keeps the core small and the testing focused.

## Faithful, not accurate

The aim is to play Tekken 3 on the Pocket the way it plays in the arcade: at its speed and with its feel. It is not an
accurate recreation of the System 12 hardware, and cannot be on the Pocket's FPGA. Where it departs from the hardware:

- **CPU speed.** The real board runs its main CPU at about 50 MHz; the core runs it at the PlayStation's 33.9 MHz. The
  CPU, memory, graphics and DMA share one clock with almost no timing margin left in the FPGA, so it cannot simply be
  raised. Instead the CPU turbo settings shorten the original memory and compute waits and add a data cache. That gets
  some fights to the arcade's 60 fps, but the work inside each frame is not timed as on the real board, and heavy moments
  can still drop to 30 fps.
- **Space.** The game build fills 93% of the FPGA's logic. To fit, parts of the graphics chip that Tekken 3 never uses (line
  drawing and reading video memory back to the CPU) are removed, after checking in MAME that the game does not use them.
  This is one more reason the core runs only Tekken 3.
- **Sound and inputs.** The H8 sound/input CPU and its peripherals are rebuilt from the chip's manual and MAME. In
  simulation they drive the sound chip almost exactly as MAME does (157 of its 160 registers follow MAME over 16 s);
  they have not been compared with a real board.
- **Graphics speed.** The graphics chip is slower than the real one. On heavy frames it does not finish before the game
  starts the next frame: the game slows down in places, and a fighter or the HUD can vanish for one frame. Tekken 3
  clears the graphics chip at the start of every frame; a half-received command left by that clear used to freeze the
  core after 2 to 90 minutes. The core now cancels such a command, as the hardware documentation describes.

If you need accuracy rather than playability, MAME is the reference.

See [docs/PLAN.md](docs/PLAN.md) for the hardware, the open problems and the plan.
[docs/STUDY.md](docs/STUDY.md) (2026-11-07) is the latest paper study: whether it can fit, and the two tests that decide it.

On the Pocket the core is **Tekken 3** (`McNast13.Tekken3`, platform `tekken3`) under openFPGA > Arcade, separate from the
System 11 core. Internal build names (`s11full`, `s11_*` variants) still carry the System 11 prefix of the code they come from.

## Installing

1. **The core.** Unzip the release zip onto the root of the SD card. It adds only `Cores/McNast13.Tekken3/`,
   `Platforms/tekken3.json`, `Platforms/_images/tekken3.bin` and `Assets/tekken3/`. The core appears under
   openFPGA > Arcade > Tekken 3.
2. **The game files.** No ROMs are included. Convert your own MAME `tekken3.zip` as described in
   [Converting tekken3.zip](#converting-tekken3zip) below.
3. **Play.** Eject the card, open the core and choose "Tekken 3 (World, TET2-VER.E1)".

## Converting tekken3.zip

The core cannot read a MAME zip directly: the game's ROM chips have to be combined into the files the core loads.
`tools/make_t3_roms.py` does this. It is a single Python script and needs nothing else installed.

**You need:**
- `tekken3.zip` (Tekken 3, World, TET2-VER.E1) from a current MAME romset that you own. Only this version is supported;
  MAME's other Tekken 3 versions are not packed by the tool yet.
- Python 3 (on macOS and Linux it is usually installed already; on Windows get it from python.org).
- `tools/make_t3_roms.py` from this repository (download the repository, or just that one file).

**Steps:**
1. Put `tekken3.zip` in a folder of its own, or note the folder it is in. Do not unzip it.
2. Put the Pocket's SD card in your computer.
3. Open a terminal (Windows: Command Prompt), go to the folder holding `make_t3_roms.py` and run:

       python3 make_t3_roms.py --roms <folder with tekken3.zip> --sd <SD card root>

   For example `python3 make_t3_roms.py --roms ~/roms --sd /Volumes/Pocket` on macOS, or
   `py make_t3_roms.py --roms C:\roms --sd E:\` on Windows (untested; reports welcome). `--sd` can also be any folder:
   then copy the `Assets` folder it creates onto the card's root.
4. The tool prints `packed tekken3 into ...` when it is done. Eject the card.

**What it does:** it reads 13 files from the zip and checks each one's CRC against MAME's, then writes six files (about
40 MB) to `Assets/tekken3/common/tekken3/` on the card:

| File | What it holds | Made from |
|---|---|---|
| `rom_0.bin` | main program, 4 MB | `tet2vere1.2e` and `tet2vere1.2j`, interleaved byte by byte |
| `rom_1.bin` | board settings for the core, 4 bytes | (written by the tool) |
| `rom_3.bin` | graphics and data ROM, first 16 MB | `tet1rom0l.6`, `tet1rom0u.9`, `tet1rom1l.7`, `tet1rom1u.10` |
| `rom_3b.bin` | graphics and data ROM, next 12 MB | `tet1rom2l.8`, `tet1rom2u.11`, `tet1fl3l.12`, `tet1fl3u.13` |
| `rom_6.bin` | sound CPU program, 256 KB | `tet1vere.11s` (byte order swapped for the H8) |
| `rom_7.bin` | sound samples, 8 MB | `tet1wave0.5` and `tet1wave1.4` |

It also writes the game entry, `Assets/tekken3/McNast13.Tekken3/Tekken 3 (World, TET2-VER.E1).json`, which tells the
Pocket which files to load (the release zip has the same file).

**If it fails:**
- *CRC mismatch* (`<file>: CRC ..., expected ...`): that file differs from the one MAME expects. The zip is from a much
  older or newer MAME, is a different Tekken 3 version, or is damaged.
- *"There is no item named ... in the archive"*: the zip is missing a file. A zip from a split romset that holds only a
  clone's files will not work; use the parent `tekken3.zip`.
- *`python3` not found*: on Windows use `py`; otherwise install Python 3.

## Core settings

| Setting | What it does |
|---|---|
| **DIP1 Test** | The board's test switch. On: the game starts in its test menu, where its settings (difficulty, rounds, coinage and so on) are changed. Turn it off again to play normally. |
| **DIP2 Freeze** | The board's freeze switch, passed to the game. Tekken 3 freezes while it is on; turn it off to carry on. |
| **Service button (held)** | The cabinet's service button. Switching it on adds a service credit (a free credit); switch it off and on again for another. |
| **CPU turbo** | How fast the main CPU gets through its work (see below). Default: "Mem + compute + cache". |

The core's CPU runs at the PlayStation's 33.9 MHz, but the real System 12 runs it at about 50 MHz, so at the original
timings Tekken 3 falls to 30 fps in fights. The turbo settings take time out of the CPU's waits instead. Use
**"Mem + compute + cache"**: it is the setting that plays Tekken 3 closest to the arcade game's speed. The others are kept
for testing and are painfully slow.

- **Off** - the PlayStation core's original timings.
- **Memory** - main-RAM reads and writes skip the original memory wait times.
- **Memory + compute** - as Memory, and the CPU no longer stalls for late load results, the geometry coprocessor (GTE)
  runs its faster timing, and DMA does not pause between blocks.
- **Mem + compute + cache** (default, recommended) - as Memory + compute, plus a data cache for main-RAM reads (from the
  PSX_MiSTer core, where it was switched off). The most faithful way to play Tekken 3 on this core: fights run at or near
  the arcade's 60 fps in some match-ups. The data cache is still new here, so if you see wrong graphics or a hang, please
  report it.

## Use of AI

This port is being built with heavy use of AI, and we want to be upfront about that.

- **Who does what.** The project is run by McNast13, who sets the goals, makes the decisions, runs every test on a real Pocket
  and reports what the screen shows. Most of the code, scripts, simulations and documentation in this repository were written by
  Claude (Anthropic's AI model) working through Claude Code, under that direction. Commits made this way carry a
  `Co-Authored-By: Claude` line.
- **Upstream code is not rewritten.** The cores this is built on are included unmodified as git submodules. Every change to them
  is a small, separate patch script (`synth/pocket_probe/variants/*.apply`) with a comment saying what it changes and why.
- **Evidence before fixes.** Problems are tracked down with measurements: simulations, A/B builds with one change left out,
  diagnostic builds photographed on the Pocket, and MAME traces (`tools/mame/`).
- **Limits.** AI-written hardware description code can be wrong in ways that compile and fit cleanly. The checks here are
  simulation and testing on hardware, not an expert line-by-line review, so treat the core as experimental. Bug reports and
  reviews from people who know these systems are very welcome.

## Credits

This core is built on the [Namco System 11 port for the Analogue Pocket](https://github.com/McNast13/NamcoSystem11-Pocket);
without it, and the work it in turn rests on, this project would not exist.

- **[GuardianSoul](https://github.com/GuardianSoul)** - author of [openfpga-PlayStation](https://github.com/GuardianSoul/openfpga-PlayStation),
  the PlayStation core for the Analogue Pocket. The System 11 port, and so this core, builds directly on his work: the
  area-reduction patch chain, the Pocket shell and memory approach, and the proof that a PlayStation-class design can fit
  the Pocket's FPGA. Without it this project would not be feasible.
- **XelaNotPu** - [SYSTEM11_MiSTer](https://github.com/XelaNotPu/SYSTEM11_MiSTer), the Namco System 11 core the System 11
  port comes from, including its C352 sound chip.
- **MiSTer-devel / Robert Peip (FPGAzumSpass)** - [PSX_MiSTer](https://github.com/MiSTer-devel/PSX_MiSTer), the base
  PlayStation core, including the data cache behind the fastest turbo setting.
- **Laxer3a** - [PS-GTE](https://github.com/Laxer3a/PS-GTE), the compact GTE used for area reduction.
- **The MAME team** - MAME's System 12 driver and its H8/3002 and C352 emulation were the reference for this core's memory
  map, the H8 sound/input CPU and its peripherals, and the measurements behind most decisions here.

## Support

[![Support me on Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/mcnast13)

## Licence

Licensed GPL-2.0 (upstream sources are GPL-2.0/3.0; see LICENSE).
