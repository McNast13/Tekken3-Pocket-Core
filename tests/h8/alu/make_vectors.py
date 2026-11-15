#!/usr/bin/env python3
"""Random test cases for pocket/core/s12/h8_alu.vhd, with the expected results from the generated MAME model
(tools/h8model/h8ops.py: the do_* / set_nz* helpers and the daa.b / das.b instruction bodies).
Line: op sz a b ccr expected_res expected_ccr (op and sz decimal, the rest hex). Usage: make_vectors.py OUT [n]
"""
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "tools/h8model"))
import h8cpu  # noqa: E402
import h8ops  # noqa: E402

MASK = {0: 0xff, 1: 0xffff, 2: 0xffffffff}
SUF = {0: "8", 1: "16", 2: "32"}
EDGE = [0, 1, 2, 0x7f, 0x80, 0xff, 0x0f, 0x10, 0x7fff, 0x8000, 0xffff, 0x0fff, 0x1000, 0x7fffffff, 0x80000000,
        0xffffffff, 0x0fffffff, 0x10000000, 0x09, 0x99, 0x9a, 0x66]


def val(rng, sz):
    v = rng.choice(EDGE) if rng.random() < 0.35 else rng.getrandbits(32)
    return v & MASK[sz] if rng.random() < 0.8 else v      # sometimes leave bits above the size set: they must be ignored


def main():
    out = Path(sys.argv[1])
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 20000
    rng = random.Random(12)
    cpu = h8cpu.H8(bytes(0x80000))
    lines = []

    def case(op, sz, a, b, ccr, fn):
        cpu.CCR = ccr
        r = fn()
        lines.append("%d %d %08X %08X %02X %08X %02X" % (op, sz, a & 0xffffffff, b & 0xffffffff, ccr, r & 0xffffffff, cpu.CCR))

    for i in range(n):
        ccr = rng.getrandbits(8)
        sz = rng.randrange(3)
        a, b = val(rng, sz), val(rng, sz)
        s = SUF[sz]
        op = rng.randrange(19)
        if op == 0:
            case(op, sz, a, b, ccr, lambda: getattr(h8ops, "do_add" + s)(cpu, a, b))
        elif op == 1:
            case(op, 0, a, b, ccr, lambda: h8ops.do_addx8(cpu, a, b))
        elif op == 2:
            case(op, sz, a, b, ccr, lambda: getattr(h8ops, "do_sub" + s)(cpu, a, b))
        elif op == 3:
            case(op, 0, a, b, ccr, lambda: h8ops.do_subx8(cpu, a, b))
        elif op in (4, 5):
            b = rng.choice([1, 2])
            case(op, sz, a, b, ccr, lambda: getattr(h8ops, ("do_inc" if op == 4 else "do_dec") + s)(cpu, a, b))
        elif op == 6:
            def nzv():
                getattr(h8ops, "set_nzv" + s)(cpu, b)
                return b & MASK[sz]
            case(op, sz, a, b, ccr, nzv)
        elif op == 7:
            sz = rng.choice([1, 2])
            def nz():
                getattr(h8ops, "set_nz" + SUF[sz])(cpu, b)
                return b & MASK[sz]
            case(op, sz, a, b, ccr, nz)
        elif 8 <= op <= 15:
            name = ["shal", "shar", "shll", "shlr", "rotl", "rotr", "rotxl", "rotxr"][op - 8]
            case(op, sz, a, b, ccr, lambda: getattr(h8ops, "do_%s%s" % (name, s))(cpu, a))
        elif op in (16, 17):
            def bcd():
                cpu.R[0] = (cpu.R[0] & 0xff00) | (a & 0xff)        # r0l
                cpu.IR[0] = (0x0f00 if op == 16 else 0x1f00) | 0x8
                (h8ops.op_daa_b_r8l_x if op == 16 else h8ops.op_das_b_r8l_x)(cpu)
                return cpu.R[0] & 0xff
            case(op, 0, a, b, ccr, bcd)
        else:
            case(op, sz, a, b, ccr, lambda: b & MASK[sz])
    out.write_text("\n".join(lines) + "\n")
    print("%d cases" % len(lines))


if __name__ == "__main__":
    main()
