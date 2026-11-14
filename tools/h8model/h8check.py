#!/usr/bin/env python3
"""Check the H8 model (h8cpu.py) against MAME's recording of Tekken 3's H8 (tools/mame/h8_ref.lua), instruction by
instruction: from the first trace line with registers, the model starts from MAME's registers and RAM snapshot
(h8_ram.bin) and must then produce the same PC and the same ER0-ER7 / CCR before every instruction. Reads of what the
H8 does not hold itself are fed from MAME's read log (h8_reads.log), in order; interrupts are taken where the trace
shows them.
Usage: h8check.py REF_DIR [max_instructions]   (REF_DIR holds h8_trace.log[.gz], h8_ram.bin, h8_reads.log[.gz])
       H8 ROM: tet1vere.11s from roms/tekken3.zip
"""
import gzip
import re
import sys
import zipfile
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import h8cpu  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
LINE = re.compile(r"^ER0=([0-9A-F]{8}) ER1=([0-9A-F]{8}) ER2=([0-9A-F]{8}) ER3=([0-9A-F]{8}) ER4=([0-9A-F]{8}) "
                  r"ER5=([0-9A-F]{8}) ER6=([0-9A-F]{8}) ER7=([0-9A-F]{8}) CCR=([0-9A-F]{2}) ([0-9A-F]{6}): (\S+)")
IRQ = re.compile(r"^\s*\(interrupted at ([0-9A-F]{6}), IRQ (\d+)\)")


def opener(p):
    p = Path(p)
    if p.exists():
        return open(p)
    return gzip.open(str(p) + ".gz", "rt")


def main():
    ref = Path(sys.argv[1])
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else None
    raw = zipfile.ZipFile(ROOT / "roms/tekken3.zip").read("tet1vere.11s")
    rom = bytearray(len(raw))
    rom[0::2], rom[1::2] = raw[1::2], raw[0::2]          # the file stores each 16-bit word byte-swapped

    reads = []
    with opener(ref / "h8_reads.log") as f:
        for l in f:
            pc, a, d, m = l.split()
            reads.append((int(pc, 16), int(a, 16), int(d, 16), int(m, 16)))
    rp = [0]
    bad_reads = []

    def read_outside(a, size):
        if rp[0] >= len(reads):
            raise RuntimeError("model read %06X beyond the end of the read log" % a)
        pc, ra, d, m = reads[rp[0]]
        rp[0] += 1
        if (ra & ~1) != (a & ~1):
            bad_reads.append((a, ra))
            raise RuntimeError("read order differs: model reads %06X, MAME read %06X (at H8 PC %06X)" % (a, ra, pc))
        if size == 2:
            return d & 0xffff
        return (d >> 8) & 0xff if (a & 1) == 0 else d & 0xff

    cpu = h8cpu.H8(rom, read_outside)
    snap = (ref / "h8_ram.bin").read_bytes()
    cpu.ram[:] = snap[:0x10000]
    cpu.iram[:] = snap[0x10000:0x10200]

    # The RAM snapshot is taken between frames; when the H8 takes an interrupt right there (the vblank one), the trace's
    # first line with registers is already inside the handler, while the snapshot's stack does not yet hold what the
    # interrupt pushed. Find that case, and the flags it pushed: they are the flags on the first line after the
    # handler's rte returns to the interrupted address.
    first_irq, pushed_ccr = None, None
    with opener(ref / "h8_trace.log") as f:
        seen_regs, prev = False, None
        for line in f:
            m = IRQ.match(line)
            if m and not seen_regs:
                first_irq = int(m.group(1), 16)
                continue
            m = LINE.match(line)
            if not m:
                if not seen_regs and ": " in line:            # an instruction without registers (blank lines do not count)
                    first_irq = None
                continue
            seen_regs = True
            if first_irq is None:
                break
            if prev == "rte" and int(m.group(10), 16) == first_irq:
                pushed_ccr = int(m.group(9), 16)
                break
            prev = m.group(11)

    # SYSCR (0xFFFFF2) as the program left it before the trace's registers start: interrupt entry depends on its UE bit
    syscr = 0x09
    with opener(ref / "h8_events.log") as f:
        for l in f:
            p = l.split()
            if int(p[0][1:]) >= 2:
                break
            if p[3] == "W" and p[4] == "FFFFF2" and int(p[8], 16) & 0xff00:   # 16-bit bus: SYSCR is the even (high) lane
                syscr = (int(p[6], 16) >> 8) & 0xff

    started, n, pending_irq = False, 0, None
    used = Counter()
    with opener(ref / "h8_trace.log") as f:
        for line in f:
            m = IRQ.match(line)
            if m:
                if started:
                    pending_irq = int(m.group(1), 16)
                continue
            m = LINE.match(line)
            if not m:
                continue
            regs = [int(m.group(i), 16) for i in range(1, 9)]
            ccr, pc = int(m.group(9), 16), int(m.group(10), 16)
            if not started:                                   # load MAME's state at the first line with registers
                for i, v in enumerate(regs):
                    cpu.r32_w(i, v)
                cpu.CCR = ccr
                cpu.syscr = syscr
                if first_irq is not None:                     # write the frame the interrupt pushed (advanced mode)
                    if pushed_ccr is None:
                        sys.exit("the first interrupt's rte was not found")
                    sp = regs[7]
                    cpu.write16(sp, (pushed_ccr << 8) | ((first_irq >> 16) & 0xff))
                    cpu.write16(sp + 2, first_irq & 0xffff)
                    print("start: inside an interrupt taken at %06X; pushed CCR %02X written at %06X" % (first_irq, pushed_ccr, sp))
                cpu.start_at(pc)
                started = True
            else:
                if pending_irq is not None:
                    if cpu.NPC != pending_irq:
                        sys.exit("instruction %d: interrupt taken at %06X in MAME, model is at %06X" % (n, pending_irq, cpu.NPC))
                    cpu.interrupt(cpu.vector_of(pc))
                    pending_irq = None
                mine = [cpu.er(i) for i in range(8)]
                if cpu.NPC != pc or mine != regs or cpu.CCR != ccr:
                    print("MISMATCH before instruction %d (the previous one was %s at %06X)" % (n, last_name, last_pc))
                    print("  MAME : PC %06X CCR %02X %s" % (pc, ccr, " ".join("%08X" % v for v in regs)))
                    print("  model: PC %06X CCR %02X %s" % (cpu.NPC, cpu.CCR, " ".join("%08X" % v for v in mine)))
                    print("  MAME line:", line.strip()[90:])
                    sys.exit(1)
            last_pc = cpu.NPC
            last_name = cpu.step()
            used[last_name] += 1
            n += 1
            if limit and n >= limit:
                break
    print("OK: %d instructions match MAME (PC, ER0-ER7, CCR before each), %d outside reads replayed" % (n, rp[0]))
    print("instructions used:", " ".join("%s(%d)" % kv for kv in used.most_common()))


if __name__ == "__main__":
    main()
