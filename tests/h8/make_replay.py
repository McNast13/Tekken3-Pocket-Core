#!/usr/bin/env python3
"""Turn the MAME recording of Tekken 3's H8 (tests/h8/ref, tools/mame/h8_ref.lua) into plain files the VHDL testbench
(tests/h8/tb_h8.vhd) reads, and the reference trace it is compared with. Uses the Python model (tools/h8model) to place
the interrupts by instruction number and to write the first interrupt's stack frame into the RAM snapshot.
Writes to tests/h8/ref/ (git-ignored):
  rom.hex     512 KB program ROM, one 16-bit big-endian word per line (hex)
  ram.hex     RAM 0x080000-0x08FFFF then on-chip RAM 0xFFFD10-0xFFFF0F, one byte per line
  reads.txt   the outside reads in order: address, 16-bit value (one per line, hex)
  irqs.txt    the interrupts: instruction number before which it is taken, vector (decimal)
  start.txt   PC, CCR, SYSCR, ER0-ER7 at the start (hex)
  expect.txt  MAME's state before each instruction: PC CCR ER0..ER7 (hex), the first N instructions
Usage: make_replay.py [N]   (default 200000)
"""
import gzip
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REF = ROOT / "tests/h8/ref"
sys.path.insert(0, str(ROOT / "tools/h8model"))
import h8check  # noqa: E402  (reuses its trace format)
import h8cpu    # noqa: E402
import zipfile  # noqa: E402


def main():
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else 200000
    raw = zipfile.ZipFile(ROOT / "roms/tekken3.zip").read("tet1vere.11s")
    rom = bytearray(len(raw))
    rom[0::2], rom[1::2] = raw[1::2], raw[0::2]
    with open(REF / "rom.hex", "w") as f:
        for i in range(0, len(rom), 2):
            f.write("%02X%02X\n" % (rom[i], rom[i + 1]))

    reads = []
    with h8check.opener(REF / "h8_reads.log") as f:
        for l in f:
            pc, a, d, m = l.split()
            reads.append((int(a, 16), int(d, 16) & 0xffff))
    rp = [0]

    def read_outside(a, size):
        ra, d = reads[rp[0]]
        rp[0] += 1
        if (ra & ~1) != (a & ~1):
            raise SystemExit("read order differs at read %d" % rp[0])
        return d if size == 2 else ((d >> 8) if (a & 1) == 0 else d) & 0xff

    cpu = h8cpu.H8(rom, read_outside)
    snap = bytearray((REF / "h8_ram.bin").read_bytes())
    cpu.ram[:] = snap[:0x10000]
    cpu.iram[:] = snap[0x10000:0x10200]

    # SYSCR and the first interrupt's frame, exactly as h8check.py finds them
    syscr = 0x09
    with h8check.opener(REF / "h8_events.log") as f:
        for l in f:
            p = l.split()
            if int(p[0][1:]) >= 2:
                break
            if p[3] == "W" and p[4] == "FFFFF2" and int(p[8], 16) & 0xff00:
                syscr = (int(p[6], 16) >> 8) & 0xff
    irqs, expect = [], []
    first_irq, pushed_ccr, started, pending, n = None, None, False, None, 0
    lines, n_ins = [], 0
    with h8check.opener(REF / "h8_trace.log") as f:
        for line in f:
            m = h8check.IRQ.match(line)
            if m:
                lines.append(("irq", int(m.group(1), 16)))
                continue
            m = h8check.LINE.match(line)
            if m:
                lines.append(("ins", [int(m.group(i), 16) for i in range(1, 11)], m.group(11)))
                n_ins += 1
                if n_ins > limit + 1:
                    break
            elif ": " in line and n_ins == 0:
                lines = [x for x in lines if x[0] != "irq"]          # an interrupt before the registers start counts only if last
    # the first interrupt (taken between the snapshot and the first line with registers) and the flags it pushed
    if lines and lines[0][0] == "irq":
        first_irq = lines[0][1]
        for i in range(1, len(lines) - 1):
            if lines[i][0] == "ins" and lines[i][2] == "rte" and lines[i + 1][0] == "ins" and lines[i + 1][1][9] == first_irq:
                pushed_ccr = lines[i + 1][1][8]
                break
    for item in lines:
        if item[0] == "irq":
            if started:
                pending = item[1]
            continue
        regs, ccr, pc = item[1][:8], item[1][8], item[1][9]
        if not started:
            for i, v in enumerate(regs):
                cpu.r32_w(i, v)
            cpu.CCR, cpu.syscr = ccr, syscr
            if first_irq is not None:
                cpu.write16(regs[7], (pushed_ccr << 8) | ((first_irq >> 16) & 0xff))
                cpu.write16(regs[7] + 2, first_irq & 0xffff)
            ram_out = bytes(cpu.ram) + bytes(cpu.iram)
            start = [pc, ccr, syscr] + regs
            cpu.start_at(pc)
            started = True
        else:
            if pending is not None:
                v = cpu.vector_of(pc)
                irqs.append((n, v))
                cpu.interrupt(v)
                pending = None
            if [cpu.er(i) for i in range(8)] != regs or cpu.NPC != pc or cpu.CCR != ccr:
                raise SystemExit("model and MAME differ at %d: run tools/h8model/h8check.py" % n)
        expect.append((pc, ccr, regs))
        if n >= limit:
            break
        cpu.step()
        n += 1
    with open(REF / "ram.hex", "w") as f:
        f.writelines("%02X\n" % b for b in ram_out)
    with open(REF / "reads.txt", "w") as f:
        f.writelines("%06X %04X\n" % r for r in reads[:rp[0]])
    with open(REF / "irqs.txt", "w") as f:
        f.writelines("%d %d\n" % x for x in irqs)
    with open(REF / "start.txt", "w") as f:
        f.write(" ".join("%08X" % v for v in start) + "\n")
    with open(REF / "expect.txt", "w") as f:
        for pc, ccr, regs in expect:
            f.write("%06X %02X %s\n" % (pc, ccr, " ".join("%08X" % r for r in regs)))
    print("replay files for %d instructions: %d outside reads, %d interrupts" % (len(expect), rp[0], len(irqs)))


if __name__ == "__main__":
    main()
