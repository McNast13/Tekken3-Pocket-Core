#!/usr/bin/env python3
"""Assemble an Analogue Pocket SD-card tree for the System 11 core.

  package_pocket.py --rbf output_files/s11full.rbf --out OUTDIR [--release] [--packed DIR --instance NAME]
--release: for a build without the diagnostic screen (S11_NO_DIAG): its "Diagnostic screen" setting is left out of interact.json.

Writes OUTDIR/Cores/McNast13.Tekken3/{core.json,data.json,video.json,audio.json,input.json,interact.json,bitstream.rbf_r},
OUTDIR/Platforms/tekken3.json and, with --packed (rom_packer.py output made with --instance NAME), the game into
OUTDIR/Assets/tekken3/common/NAME.json plus NAME/rom_*.bin. bitstream.rbf_r is the .rbf with the bits of every byte reversed (APF requirement, same naming as the Dragon 32 core).
Copy OUTDIR onto the Pocket's SD card. ROM images are the user's own; nothing here ships them.
"""
import argparse, json, shutil, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
CORE_DIR = ROOT / "pocket/dist/Cores/McNast13.Tekken3"
REV = bytes(int(f"{i:08b}"[::-1], 2) for i in range(256))


ASSETS_README = """Tekken 3 game files go in this folder. None are included: they are built from your own current-MAME romset.

- tekken3/: rom_0.bin, rom_1.bin, rom_3.bin, rom_3b.bin, rom_6.bin and rom_7.bin, built from MAME's tekken3.zip with
  tools/make_t3_roms.py from https://github.com/McNast13/Tekken3-Pocket-Core (every part's CRC is checked):

      python3 tools/make_t3_roms.py --roms <folder with tekken3.zip> --sd <SD card root>

The game entry is ../McNast13.Tekken3/Tekken 3 (World, TET2-VER.E1).json; pupdate and Pocket Sync show which files it
still needs.
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rbf", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--release", action="store_true", help="build without the diagnostic screen (S11_NO_DIAG)")
    ap.add_argument("--packed", type=Path, help="rom_packer.py output directory")
    ap.add_argument("--instance", help="instance name used with rom_packer.py --instance")
    a = ap.parse_args()

    core = a.out / "Cores/McNast13.Tekken3"
    core.mkdir(parents=True, exist_ok=True)
    plat = a.out / "Platforms"
    plat.mkdir(parents=True, exist_ok=True)
    for f in CORE_DIR.glob("*.json"):
        shutil.copy(f, core / f.name)
    if a.release:   # no diagnostic screen in the bitstream: drop its setting from the menu
        ij = json.loads((core / "interact.json").read_text())
        ij["interact"]["variables"] = [v for v in ij["interact"]["variables"] if v["name"] != "Diagnostic screen"]
        (core / "interact.json").write_text(json.dumps(ij, indent=2) + "\n")
    (core / "bitstream.rbf_r").write_bytes(a.rbf.read_bytes().translate(REV))
    # placeholder artwork: icon 36x36 and platform picture 521x165, RGB565 little-endian, solid colour
    def solid(w, h, rgb565):
        return rgb565.to_bytes(2, "little") * (w * h)
    icon = CORE_DIR / "icon.bin"   # author icon on the core's About screen: pocket/dist/art/author_icon.png, encoded with pocket_image.py
    (core / "icon.bin").write_bytes(icon.read_bytes() if icon.exists() else solid(36, 36, 0xC0A0))
    (a.out / "Platforms/_images").mkdir(parents=True, exist_ok=True)
    banner = ROOT / "pocket/dist/Platforms/_images/tekken3.bin"   # pocket/dist/art/tekken3_banner.png, encoded with
    (a.out / "Platforms/_images/tekken3.bin").write_bytes(           # references/openfpga-PlayStation/scripts/pocket_image.py
        banner.read_bytes() if banner.exists() else solid(521, 165, 0x2104))

    (plat / "tekken3.json").write_text(json.dumps(
        {"platform": {"category": "Arcade", "name": "Tekken 3", "manufacturer": "Namco", "year": 1997}}, indent=2) + "\n")

    # the game entry: Tekken 3's instance JSON as tools/make_t3_roms.py writes it (pupdate / Pocket Sync read the files it names as
    # the game's required files; the md5s are those of the images make_t3_roms.py builds from MAME's tekken3.zip)
    games = a.out / "Assets/tekken3/McNast13.Tekken3"
    games.mkdir(parents=True, exist_ok=True)
    for f in (ROOT / "pocket/dist/Assets/tekken3/McNast13.Tekken3").glob("*.json"):
        shutil.copy(f, games / f.name)

    # where the user's files go, as in the Dragon 32 core's release (a README beside the files it asks for), and the licence
    common = a.out / "Assets" / "tekken3" / "common"
    common.mkdir(parents=True, exist_ok=True)
    (common / "README.md").write_text(ASSETS_README)
    shutil.copy(ROOT / "LICENSE", a.out / "LICENSE.txt")

    if a.packed:
        if not a.instance:
            ap.error("--packed needs --instance")
        common = a.out / "Assets/tekken3/common"
        (common / a.instance).mkdir(parents=True, exist_ok=True)
        shutil.copy(a.packed / f"{a.instance}.json", common / f"{a.instance}.json")
        for f in a.packed.glob("rom_*.bin"):
            shutil.copy(f, common / a.instance / f.name)
    print(f"wrote {a.out}")


if __name__ == "__main__":
    main()
