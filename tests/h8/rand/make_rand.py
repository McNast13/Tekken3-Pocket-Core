#!/usr/bin/env python3
"""Random-instruction test for the VHDL H8 (pocket/core/s12/h8_cpu.vhd): a random straight-line program built from
MAME's opcode table (tools/h8model/h8ops.py OPCODES), run by the generated MAME model to give the expected state before
every instruction. Covers what the Tekken 3 recording does not. Memory is "flat" on both sides: from 0x080000 up every
address is the 64 KB RAM (address mod 64 KB), so random pointers always land somewhere.
Left out: control flow (branches, jmp, jsr, bsr, rts, rte: covered by the recording), sleep, trapa (not in the VHDL
yet) and movfpe/movtpe (E-clock moves, unused). eepmov gets a small count in R4 just before it.
Writes rom.hex, ram.hex, start.txt, expect.txt, expect_ram.hex (RAM at the end), reads.txt (empty), irqs.txt
(empty) to OUT; then run
REF=OUT FLAT=true tests/h8/cpu/run.sh. Usage: make_rand.py OUT [instructions] [seed]
"""
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "tools/h8model"))
import h8cpu  # noqa: E402
import h8ops  # noqa: E402

SKIP = {"bt", "bf", "bhi", "bls", "bcc", "bcs", "bne", "beq", "bvc", "bvs", "bpl", "bmi", "bge", "blt", "bgt", "ble",
        "jmp", "jsr", "bsr", "rts", "rte", "sleep", "trapa", "movfpe", "movtpe"}


class Flat(h8cpu.H8):
    """h8cpu.H8 with flat memory, and the one deliberate difference from MAME: divxu.w sets N from the divisor's bit 15
    (Hitachi's H8/300H manual), where MAME tests bit 7 (h8.lst 5300: m_TMP2 & 0x80). The VHDL follows the manual."""

    def step(self):
        w = self.read16i(self.NPC)
        divisor = self.r16_r(w >> 4) if (w >> 8) == 0x53 else None
        name = super().step()
        if divisor is not None:
            self.CCR = (self.CCR & ~0x08) | (0x08 if divisor & 0x8000 else 0)
        return name
    def outside(self, a):
        return False

    def mem8(self, a):
        return self.rom[a] if a < 0x80000 else self.ram[a & 0xffff]

    def write8(self, a, v):
        a &= 0xffffff
        if a >= 0x80000:
            self.ram[a & 0xffff] = v & 0xff

    def write16(self, a, v):
        a &= 0xfffffe
        if a >= 0x80000:
            self.ram[a & 0xffff] = (v >> 8) & 0xff
            self.ram[(a & 0xffff) + 1] = v & 0xff


def extra_words(am1, am2, skip):
    n = 0
    if (am1 in ("abs16", "abs16e", "abs22e", "abs24e") or am2 == "abs16") and skip == 0:
        n += 1
    if (am1 == "abs32" or am2 == "abs32") and skip == 0:
        n += 2
    if am1 in ("imm16", "rel16", "r16d16h", "r32d16h") or am2 in ("r16d16h", "r32d16h"):
        n += 1
    if am1 in ("imm32", "r32d32hh") or am2 == "r32d32hh":
        n += 2
    return n


def main():
    out = Path(sys.argv[1])
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 20000
    rng = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 1)
    ops = [o for o in h8ops.OPCODES if o[4] not in SKIP]
    rom = bytearray(0x80000)
    probe = Flat(rom)
    pc, prog, picked = 0x100, [], {}

    def put(words):
        nonlocal pc
        for w in words:
            rom[pc], rom[pc + 1] = w >> 8, w & 0xff
            pc += 2

    while len(prog) < count and pc < 0x7f000:
        val, mask, skip, fn, name, am1, am2 = rng.choice(ops)
        words = []
        for i in range(0, len(val), 4):
            v, m = int(val[i:i + 4], 16), int(mask[i:i + 4], 16)
            words.append(v | (rng.getrandbits(16) & ~m & 0xffff))
        # displacements of 32-bit forms hold a 24-bit value; other extra words are free
        extra = [rng.getrandbits(16) for _ in range(extra_words(am1, am2, skip))]
        if am1 == "r32d32hh" or am2 == "r32d32hh" or am1 == "abs32" or am2 == "abs32" or am1 == "abs24e":
            if extra:
                extra[0] &= 0x00ff
        # the decode must give back this instruction
        save = bytes(rom[pc:pc + 16])
        put(words[:1] + [0] * skip + words[1:] + extra)
        pc -= 2 * (len(words) + skip + len(extra))
        probe.IR = [0] * 8
        probe.IR[0] = words[0]
        probe.PC = pc + 2
        try:
            got = probe.decode()
        except RuntimeError:
            rom[pc:pc + 16] = save
            continue
        if got[0] is not fn:
            rom[pc:pc + 16] = save
            continue
        if name.startswith("eepmov"):
            put([0x7904, rng.randrange(0, 12)])                 # mov.w #n, r4: a short block move
        put(words[:1] + [0] * skip + words[1:] + extra)
        prog.append(name)
        picked[name] = picked.get(name, 0) + 1
    put([0x0000] * 4)                                           # nops at the end

    cpu = Flat(rom)
    for i in range(8):
        cpu.r32_w(i, rng.choice([0x00080000 | rng.getrandbits(16), rng.getrandbits(32)]))
    cpu.CCR = rng.getrandbits(8) & 0x3f                         # interrupts masked or not: nothing raises one
    ram = bytearray(rng.getrandbits(8) for _ in range(0x10000))
    cpu.ram[:] = ram
    start = [0x100, cpu.CCR, 0x09] + [cpu.er(i) for i in range(8)]
    cpu.start_at(0x100)
    expect, listing = [], []
    while cpu.NPC < pc - 8:
        a = cpu.NPC
        listing.append("%d %06X %s" % (len(expect), a, " ".join("%02X%02X" % (rom[i], rom[i + 1]) for i in range(a, a + 10, 2))))
        expect.append("%06X %02X %s" % (cpu.NPC, cpu.CCR, " ".join("%08X" % cpu.er(i) for i in range(8))))
        listing[-1] += "  " + cpu.step()
    expect.append("%06X %02X %s" % (cpu.NPC, cpu.CCR, " ".join("%08X" % cpu.er(i) for i in range(8))))

    out.mkdir(parents=True, exist_ok=True)
    with open(out / "rom.hex", "w") as f:
        for i in range(0, 0x80000, 2):
            f.write("%02X%02X\n" % (rom[i], rom[i + 1]))
    with open(out / "ram.hex", "w") as f:
        f.writelines("%02X\n" % b for b in ram + bytes(0x200))
    (out / "start.txt").write_text(" ".join("%08X" % v for v in start) + "\n")
    (out / "expect.txt").write_text("\n".join(expect) + "\n")
    (out / "reads.txt").write_text("")
    (out / "listing.txt").write_text("\n".join(listing) + "\n")
    with open(out / "expect_ram.hex", "w") as f:              # RAM at the end: memory writes are checked too
        f.writelines("%02X\n" % b for b in cpu.ram)
    (out / "irqs.txt").write_text("")
    print("%d instructions (%d kinds) in %d states" % (len(prog), len(picked), len(expect)))


if __name__ == "__main__":
    main()
