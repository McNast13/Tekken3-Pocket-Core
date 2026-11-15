#!/usr/bin/env python3
"""Control-flow test for the VHDL H8 (pocket/core/s12/h8_cpu.vhd): what make_rand.py leaves out. A random program of
forward Bcc (d8 and d16, taken or not, after a compare), bsr / jsr (d8, d16, @ERn, @aa:24, @@aa:8) to subroutines that
return with rts, jmp (@ERn, @aa:24, @@aa:8) and trapa #0-3 into handlers that return with rte, mixed with register
ALU instructions that set the flags. ER7 is the stack (never a filler operand). Run by the generated MAME model, with
the core's deliberate differences from MAME applied (docs/H8.md): trapa stacks the address of the next instruction and
sets I (SYSCR.UE = 1 here). Same output files as make_rand.py; then run
REF=OUT FLAT=true tests/h8/cpu/run.sh. Usage: make_flow.py OUT [blocks] [seed]
"""
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_rand  # noqa: E402
from make_rand import h8ops  # noqa: E402

MAIN, SUBS, HANDLERS, STACK = 0x100, 0x40000, 0x7E000, 0x08F000
IND = 0x80                                       # @@aa:8 pointers at 0x80-0xFF (vectors 32-63, not used here)


class Flow(make_rand.Flat):
    """make_rand's flat-memory model, with trapa as the core does it (Hitachi's manual)."""

    def step(self):
        w = self.read16i(self.NPC)
        if (w >> 8) == 0x57:
            nxt = self.NPC + 2
            sp = (self.er(7) - 2) & 0xffffffff
            self.r32_w(7, sp)
            self.write16(sp, nxt & 0xffff)
            sp = (sp - 2) & 0xffffffff
            self.r32_w(7, sp)
            self.write16(sp, (self.CCR << 8) | ((nxt >> 16) & 0xff))
            self.CCR |= h8ops.F_I                                # UE = 1: I only
            v = 8 + ((w >> 4) & 3)
            self.start_at(((self.read16i(4 * v) << 16) | self.read16i(4 * v + 2)) & 0xffffff)
            return "trapa"
        return super().step()


def main():
    out = Path(sys.argv[1])
    blocks = int(sys.argv[2]) if len(sys.argv) > 2 else 3000
    rng = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 1)
    rom = bytearray(0x80000)
    at = {"main": MAIN, "subs": SUBS, "hnd": HANDLERS}

    def put(area, words):
        for w in words:
            a = at[area]
            rom[a], rom[a + 1] = (w >> 8) & 0xff, w & 0xff
            at[area] = a + 2

    def r8(keep=()):                             # byte registers but R7H / R7L (and keep)
        return rng.choice([i for i in range(16) if i & 7 != 7 and i not in keep])

    def r16(keep=()):
        return rng.choice([i for i in range(16) if i & 7 != 7 and i not in keep])

    def filler(loop=False):                      # loop: R0L is the loop count (R8 index 8, R16 index 0)
        k8, k16 = ((8,), (0,)) if loop else ((), ())
        k = rng.randrange(9)
        if k == 0:
            return [0x0800 | r8() << 4 | r8(k8)]                  # add.b
        if k == 1:
            return [0x0900 | r16() << 4 | r16(k16)]                # add.w
        if k == 2:
            return [0x1800 | r8() << 4 | r8(k8)]                  # sub.b
        if k == 3:
            return [0x1C00 | r8() << 4 | r8()]                  # cmp.b
        if k == 4:
            return [0x1D00 | r16() << 4 | r16()]                # cmp.w
        if k == 5:
            return [0xA000 | r8() << 8 | rng.getrandbits(8)]    # cmp.b #imm
        if k == 6:
            return [0xF000 | r8(k8) << 8 | rng.getrandbits(8)]    # mov.b #imm
        if k == 7:
            return [0x0700 | rng.getrandbits(4)]                # ldc #imm, ccr: random N Z V C, I clear
        return [0x1500 | r8() << 4 | r8(k8)]                      # xor.b

    def fill(area, n, loop=False):
        for _ in range(n):
            put(area, filler(loop))

    def mov_l_imm(reg, v):                                       # mov.l #v, ERreg
        return [0x7A00 | reg, (v >> 16) & 0xffff, v & 0xffff]

    def sub():                                                   # a subroutine: filler, rts
        a = at["subs"]
        fill("subs", rng.randrange(0, 4))
        put("subs", [0x5470])
        return a

    # @@aa:8 pointers: 16 to fixed subroutines (jsr), 16 handed out once each to forward jmp targets
    ind_sub = []
    for n in range(16):
        rom[IND + 4 * n:IND + 4 * n + 4] = sub().to_bytes(4, "big")
        ind_sub.append(IND + 4 * n)
    ind_free = [IND + 4 * n for n in range(16, 32)]

    def ind(target):                                             # a fresh @@aa:8 pointer to target
        slot = ind_free.pop(0)
        rom[slot:slot + 4] = (target & 0xffffff).to_bytes(4, "big")
        return slot

    # trapa handlers (vectors 8-11): filler, rte
    for n in range(4):
        a = at["hnd"]
        fill("hnd", rng.randrange(0, 4))
        put("hnd", [0x5670])
        rom[4 * (8 + n):4 * (8 + n) + 4] = a.to_bytes(4, "big")

    kinds = {}
    for _ in range(blocks):
        fill("main", rng.randrange(0, 3))
        k = rng.randrange(12)
        if k == 9 and not ind_free:
            k = 8
        name = ["bcc8", "bcc16", "bsr8", "bsr16", "jsr_er", "jsr_abs", "jsr_ind", "jmp_er", "jmp_abs", "jmp_ind",
                "trapa", "bra_back"][k]
        kinds[name] = kinds.get(name, 0) + 1
        if k == 0:                                               # Bcc d8 over 0-3 filler words
            skip = [filler() for _ in range(rng.randrange(0, 4))]
            put("main", [0x4000 | rng.randrange(16) << 8 | (2 * sum(len(s) for s in skip))])
            for s in skip:
                put("main", s)
        elif k == 1:                                             # Bcc d16
            skip = [filler() for _ in range(rng.randrange(0, 4))]
            put("main", [0x5800 | rng.randrange(16) << 4, 2 * sum(len(s) for s in skip)])
            for s in skip:
                put("main", s)
        elif k in (2, 3):                                        # bsr: a subroutine close by, in main, jumped over
            put("main", [0x4000 | 0x0 << 8 | 0])                 # bra placeholder (patched below)
            bra = at["main"] - 2
            s = at["main"]
            fill("main", rng.randrange(0, 3))
            put("main", [0x5470])
            rom[bra + 1] = at["main"] - (bra + 2)
            if k == 2:
                put("main", [0x5500 | ((s - (at["main"] + 2)) & 0xff)])
            else:
                put("main", [0x5C00, (s - (at["main"] + 4)) & 0xffff])
        elif k == 4:                                             # jsr @ERn
            reg = rng.randrange(7)
            put("main", mov_l_imm(reg, sub()) + [0x5D00 | reg << 4])
        elif k == 5:                                             # jsr @aa:24
            s = sub()
            put("main", [0x5E00 | s >> 16, s & 0xffff])
        elif k == 6:                                             # jsr @@aa:8
            put("main", [0x5F00 | rng.choice(ind_sub)])
        elif k in (7, 8, 9):                                     # jmp forward over 0-3 filler words
            reg = rng.randrange(7)
            if k == 7:
                put("main", mov_l_imm(reg, 0))
                imm_at = at["main"] - 4
                put("main", [0x5900 | reg << 4])
            elif k == 8:
                put("main", [0x5A00, 0])
                imm_at = at["main"] - 4
            else:
                put("main", [0x5B00])
                imm_at = at["main"] - 2
            fill("main", rng.randrange(0, 4))
            t = at["main"]
            if k == 7:
                rom[imm_at:imm_at + 4] = t.to_bytes(4, "big")
            elif k == 8:
                rom[imm_at + 1:imm_at + 4] = t.to_bytes(3, "big")
            else:
                rom[imm_at + 1] = ind(t)
        elif k == 10:                                            # trapa #n
            put("main", [0x5700 | rng.randrange(4) << 4])
        else:                                                    # a short loop: count down R0L, bne back
            n = rng.randrange(1, 5)
            put("main", [0xF800 | n])                            # mov.b #n, r0l
            top = at["main"]
            fill("main", rng.randrange(0, 2), loop=True)
            put("main", [0x1A08])                                # dec.b r0l
            put("main", [0x4600 | ((top - (at["main"] + 2)) & 0xff)])
    end = at["main"]
    put("main", [0x0000] * 4)

    cpu = Flow(rom)
    for i in range(7):
        cpu.r32_w(i, rng.getrandbits(32))
    cpu.r32_w(7, STACK)
    cpu.CCR = rng.getrandbits(8) & 0x3f
    ram = bytearray(rng.getrandbits(8) for _ in range(0x10000))
    cpu.ram[:] = ram
    start = [MAIN, cpu.CCR, 0x09] + [cpu.er(i) for i in range(8)]
    cpu.start_at(MAIN)
    expect, listing = [], []
    while cpu.NPC != end:
        assert len(expect) < 10 * blocks + 1000, "runaway"
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
    with open(out / "expect_ram.hex", "w") as f:
        f.writelines("%02X\n" % b for b in cpu.ram)
    (out / "irqs.txt").write_text("")
    print("%d blocks %s, %d instructions" % (blocks, " ".join("%s:%d" % kv for kv in sorted(kinds.items())), len(expect)))


if __name__ == "__main__":
    main()
