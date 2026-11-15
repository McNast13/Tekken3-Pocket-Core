#!/usr/bin/env python3
"""Compare the core's H8 C352 writes (tb_h8_sys output) with MAME's (tests/h8/ref/c352.log).
For each C352 register, the sequence of values written must be MAME's; the order between registers and the exact
timing may differ (the core's H8 is not cycle-exact) by up to 2 frames. Reports per register the first difference,
and how far the writes drift in frames. Usage: compare.py MAME_LOG SIM_LOG [frames]"""
import sys
from collections import defaultdict


def load(path, sim, frames):
    seq = defaultdict(list)
    n = 0
    for line in open(path):
        f, a, v, m = line.split()
        f, a, v = int(f), int(a, 16), int(v, 16)
        if frames is not None and f >= frames:
            continue
        if sim:                                  # byte lanes as the CPU's bus: 11 word, 10 even byte, 01 odd byte
            m = {"3": 0xFFFF, "2": 0xFF00, "1": 0x00FF}[m.lstrip("0") or "0"]
        else:
            m = int(m, 16)
        seq[a].append((f, v & m, m))
        n += 1
    return seq, n


def main():
    frames = int(sys.argv[3]) if len(sys.argv) > 3 else None
    last = max(int(line.split()[0]) for line in open(sys.argv[1]))     # MAME's recording may end first
    frames = last if frames is None else min(frames, last)
    ref, nr = load(sys.argv[1], False, frames)
    sim, ns = load(sys.argv[2], True, frames)
    print("MAME %d C352 writes, core %d, %d / %d registers" % (nr, ns, len(ref), len(sim)))
    bad, drift = 0, []
    for a in sorted(set(ref) | set(sim)):
        r, s = ref.get(a, []), sim.get(a, [])
        k = 0
        while k < min(len(r), len(s)) and (r[k][1], r[k][2]) == (s[k][1], s[k][2]):
            drift.append(s[k][0] - r[k][0])
            k += 1
        if k < len(r) or k < len(s):
            # the last few writes may fall either side of the end of the run
            tail = all(w[0] >= frames - 2 for w in r[k:] + s[k:])
            if not tail:
                bad += 1
                if bad <= 15:
                    print("  %06X: %d MAME / %d core writes, same for %d; then MAME %s, core %s" % (
                        a, len(r), len(s), k, r[k] if k < len(r) else "-", s[k] if k < len(s) else "-"))
    late = 0
    if drift:
        print("frame drift (core - MAME): min %d, max %d" % (min(drift), max(drift)))
        late = sum(1 for d in drift if abs(d) > 2)          # the tempo timers and vblank must keep MAME's timing
        if late:
            print("  %d writes more than 2 frames from MAME's" % late)
    ok = bad == 0 and late == 0
    print("RESULT: %s (%d registers differ, %d writes off time)" % ("MATCH" if ok else "DIFFER", bad, late))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
