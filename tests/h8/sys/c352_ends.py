#!/usr/bin/env python3
"""Sample ends for the H8 system test, from MAME's C352 read log (tools/mame/h8_shared.lua c352_reads.log): a voice's
flags read with KEYOFF set and BUSY clear after a read with BUSY set is a sample that played to its end (MAME c352
fetch_sample); the H8's own key-offs leave both clear. Writes "frame voice" lines. Usage: c352_ends.py IN OUT"""
import sys

last = {}
out = []
for line in open(sys.argv[1]):
    f, a, v = line.split()
    f, a, v = int(f), int(a, 16), int(v, 16)
    off = (a - 0x280000) // 2
    if off >= 0x100 or off % 8 != 3:
        continue
    voice = off // 8
    if last.get(voice, 0) & 0x8000 and v & 0x2000 and not v & 0x8000:
        out.append("%d %d\n" % (f, voice))
    last[voice] = v
open(sys.argv[2], "w").writelines(out)
print("%d sample ends" % len(out))
