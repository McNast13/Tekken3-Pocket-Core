#!/usr/bin/env python3
"""Pack Tekken 3 (MAME set tekken3, System 12) from your own current-MAME zip into the core's data-slot images, and write its
instance JSON. Layout from MAME namcos12.cpp ROM_START( tekken3 ); every part's CRC is checked.

  rom_0.bin   data slot 1  program ROM, 4 MB: tet2vere1.2e (even bytes) / tet2vere1.2j (odd bytes)   -> SDRAM 0x400000
  rom_1.bin   data slot 2  config: platform byte 0x14 (System 11/12 mode), no KEYCUS
  rom_3.bin   data slot 4  banked ROM 0-16 MB: tet1rom0l/u, tet1rom1l/u (byte-interleaved pairs)     -> SDRAM 0x800000
  rom_3b.bin  data slot 5  banked ROM 16-28 MB: tet1rom2l/u, tet1fl3l/u                               -> SDRAM 0x1800000
  rom_6.bin   data slot 6  H8/3002 sound program: tet1vere.11s, its first 256 KB (the rest is 0xFF), bytes swapped in
                           pairs into the H8's order (MAME ROM_LOAD16_WORD_SWAP)                   -> SDRAM 0x2800000 (SPROG)
  rom_7.bin   data slot 7  C352 wave ROM, 8 MB: tet1wave0.5, tet1wave1.4                              -> SDRAM 0x2840000

  make_t3_roms.py --roms DIR --sd OUT     OUT/Assets/tekken3/common/tekken3/ and OUT/Assets/tekken3/McNast13.Tekken3/<title>.json
"""
import argparse, hashlib, json, sys, zipfile, zlib
from pathlib import Path

SET, PLATFORM, CORE = "tekken3", "tekken3", "McNast13.Tekken3"
TITLE = "Tekken 3 (World, TET2-VER.E1)"
CRC = {"tet2vere1.2e": 0x7ded5461, "tet2vere1.2j": 0x25c96e1e,
       "tet1rom0l.6": 0x2886bb32, "tet1rom0u.9": 0xc5705b92, "tet1rom1l.7": 0x0397d283, "tet1rom1u.10": 0x502ba5cd,
       "tet1rom2l.8": 0xe03b1c24, "tet1rom2u.11": 0x75eb2ab3, "tet1fl3l.12": 0x45513073, "tet1fl3u.13": 0x1917d993,
       "tet1wave0.5": 0x77ba7975, "tet1wave1.4": 0xffeba79f, "tet1vere.11s": 0xc92b98d1}


def h8_program(d):
    """tet1vere.11s in the H8's byte order, first 256 KB (the core's slot; the H8 reads 0xFF above it, as the file has)."""
    assert len(d) == 0x80000 and all(b == 0xFF for b in d[0x40000:]), "tet1vere.11s: expected 0xFF above 256 KB"
    out = bytearray(0x40000)
    out[0::2], out[1::2] = d[1:0x40000:2], d[0:0x40000:2]
    return bytes(out)


def interleave(lo, hi):
    """ROM_LOAD16_BYTE pair: lo at even byte offsets, hi at odd."""
    assert len(lo) == len(hi)
    out = bytearray(2 * len(lo))
    out[0::2], out[1::2] = lo, hi
    return bytes(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--roms", type=Path, required=True, help="directory holding tekken3.zip")
    ap.add_argument("--sd", type=Path, required=True, help="SD-card root or staging folder")
    a = ap.parse_args()

    with zipfile.ZipFile(a.roms / f"{SET}.zip") as z:
        part = {}
        for name, crc in CRC.items():
            d = z.read(name)
            if zlib.crc32(d) != crc:
                sys.exit(f"{name}: CRC {zlib.crc32(d):08x}, expected {crc:08x}")
            part[name] = d
    p = part
    images = {
        "rom_0.bin": interleave(p["tet2vere1.2e"], p["tet2vere1.2j"]),
        "rom_1.bin": bytes([0x14, 0x00, 0x00, 0x00]),
        "rom_3.bin": interleave(p["tet1rom0l.6"], p["tet1rom0u.9"]) + interleave(p["tet1rom1l.7"], p["tet1rom1u.10"]),
        "rom_3b.bin": interleave(p["tet1rom2l.8"], p["tet1rom2u.11"]) + interleave(p["tet1fl3l.12"], p["tet1fl3u.13"]),
        "rom_6.bin": h8_program(p["tet1vere.11s"]),
        "rom_7.bin": p["tet1wave0.5"] + p["tet1wave1.4"],
    }
    assert images["rom_6.bin"][:4] == bytes([0, 0, 1, 0]), "H8 reset vector should be 0x000100"
    assert [len(images[k]) for k in ("rom_0.bin", "rom_3.bin", "rom_3b.bin", "rom_7.bin")] == \
        [0x400000, 0x1000000, 0xC00000, 0x800000]
    common = a.sd / "Assets" / PLATFORM / "common" / SET
    common.mkdir(parents=True, exist_ok=True)
    slots = []
    for sid, name in ((1, "rom_0.bin"), (2, "rom_1.bin"), (4, "rom_3.bin"), (5, "rom_3b.bin"), (6, "rom_6.bin"),
                      (7, "rom_7.bin")):
        (common / name).write_bytes(images[name])
        slots.append({"id": sid, "filename": f"{SET}/{name}", "md5": hashlib.md5(images[name]).hexdigest()})
    inst = a.sd / "Assets" / PLATFORM / CORE / f"{TITLE}.json"
    inst.parent.mkdir(parents=True, exist_ok=True)
    inst.write_text(json.dumps({"instance": {"magic": "APF_VER_1", "data_path": "", "data_slots": slots}}, indent=2) + "\n")
    print(f"packed {SET} into {common}; instance {inst}")


if __name__ == "__main__":
    main()
