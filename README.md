# Tekken 3 (Namco System 12) for Analogue Pocket (openFPGA)

**Status:** feasibility stage. There is no Tekken 3 code yet: the repo builds the System 11 core it started from, with probes
for the speed and fit tests that decide whether Tekken 3 can work (see [docs/STUDY.md](docs/STUDY.md)).

A single-game core for **Tekken 3** on the Analogue Pocket, following the
[Namco System 11 port](https://github.com/McNast13/NamcoSystem11-Pocket). System 12 is a faster System 11
(PlayStation-derived) with a different sound board, so most of the System 11 work (CPU, GPU, GTE, MDEC, DMA, C352, the Pocket
shell, loader and tooling) is meant to carry over.

Why only Tekken 3: each System 12 game sits on its own ROM daughterboard with its own security chip and ROM layout. All ten
Tekken 3 versions use the same one (M8F2F board, KC006 keycus) and MAME runs them with the plain System 12 driver, with no
game-specific hardware. One fixed memory map keeps the core small and the testing focused.

See [docs/PLAN.md](docs/PLAN.md) for the hardware, the open problems and the plan.
[docs/STUDY.md](docs/STUDY.md) (2026-11-07) is the latest paper study: whether it can fit, and the two tests that decide it.

On the Pocket the core is **Tekken 3** (`McNast13.Tekken3`, platform `tekken3`) under openFPGA > Arcade, separate from the
System 11 core. Internal build names (`s11full`, `s11_*` variants) still carry the System 11 prefix of the code they come from.

No ROMs are included. You need your own current MAME `tekken3` romset.

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

## Licence

Licensed GPL-2.0 (upstream sources are GPL-2.0/3.0; see LICENSE).
