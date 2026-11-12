# Tekken 3 (Namco System 12) for Analogue Pocket (openFPGA)

**Status:** feasibility study. Nothing builds yet.

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

Licensed GPL-2.0 (upstream sources are GPL-2.0/3.0; see LICENSE).
