#!/usr/bin/env python3
"""Runtime for the generated H8/300H model (h8ops.py, from MAME's h8.lst by h8gen.py): registers, memory, decode, and
the MAME prefetch / interrupt conventions the generated instruction bodies rely on. Configured as Tekken 3's H8/3002:
advanced mode (24-bit addresses, 4-byte vectors), H flag present, no EXR.

Memory: the 512 KB program ROM, the 64 KB of RAM at 0x080000 and the on-chip RAM at 0xFFFD10-0xFFFF0F. Every other
address is "outside" and is read through a callback (the checker replays MAME's recorded reads there); writes outside go
to another callback. SYSCR (0xFFFFF2) is tracked, because interrupt entry depends on its UE bit.
"""
import h8ops

OUTSIDE = ((0x080000, 0x083FFF), (0x200000, 0x7FFFFF), (0xFFFF10, 0xFFFFFF))   # shared RAM, devices, on-chip registers


class H8:
    def __init__(self, rom, read_outside=None, write_outside=None):
        self.rom = bytearray(rom)                 # big-endian bytes
        self.ram = bytearray(0x10000)             # 0x080000-0x08FFFF
        self.iram = bytearray(0x200)              # 0xFFFD10-0xFFFF0F
        self.R = [0] * 16                         # R0-R7 low words, E0-E7 high words
        self.CCR = self.EXR = self.PC = self.NPC = self.PPC = self.PIR = 0
        self.IR = [0] * 8
        self.TMP1 = self.TMP2 = 0
        self.has_hc, self.mode_advanced, self.has_mac, self.has_trace = True, True, False, False
        self.taken_irq_vector = 0
        self.syscr = 0x09
        self.read_outside = read_outside or (lambda a, size: 0)
        self.write_outside = write_outside or (lambda a, v, size: None)

    # ------------------------------------------------------------ registers (MAME h8.h / h8h.h)
    def r8_r(self, reg):
        return self.R[reg & 7] & 0xff if reg & 8 else self.R[reg & 7] >> 8

    def r8_w(self, reg, v):
        v &= 0xff
        i = reg & 7
        self.R[i] = (self.R[i] & 0xff00) | v if reg & 8 else (self.R[i] & 0xff) | (v << 8)

    def r16_r(self, reg):
        return self.R[reg & 0xf]

    def r16_w(self, reg, v):
        self.R[reg & 0xf] = v & 0xffff

    def r32_r(self, reg):
        return self.R[reg & 7] | (self.R[(reg & 7) | 8] << 16)

    def r32_w(self, reg, v):
        self.R[reg & 7] = v & 0xffff
        self.R[(reg & 7) | 8] = (v >> 16) & 0xffff

    def er(self, n):
        return self.r32_r(n)

    # ------------------------------------------------------------ memory
    @staticmethod
    def outside(a):
        return any(lo <= a <= hi for lo, hi in OUTSIDE)

    def mem8(self, a):
        if a < 0x80000:
            return self.rom[a]
        if 0x080000 <= a <= 0x08FFFF:
            return self.ram[a - 0x080000]
        if 0xFFFD10 <= a <= 0xFFFF0F:
            return self.iram[a - 0xFFFD10]
        raise RuntimeError("read of unmapped address %06X" % a)

    def read8(self, a):
        a &= 0xffffff
        if self.outside(a):
            return self.read_outside(a, 1) & 0xff
        return self.mem8(a)

    def read16(self, a):
        a &= 0xfffffe
        if self.outside(a):
            return self.read_outside(a, 2) & 0xffff
        return (self.mem8(a) << 8) | self.mem8(a + 1)

    def read16i(self, a):
        a &= 0xfffffe
        return (self.mem8(a) << 8) | self.mem8(a + 1)

    def write8(self, a, v):
        a &= 0xffffff
        v &= 0xff
        if a == 0xFFFFF2:
            self.syscr = v
        if 0x080000 <= a <= 0x08FFFF:
            self.ram[a - 0x080000] = v             # shared RAM too: the H8 reads back what it wrote
        elif 0xFFFD10 <= a <= 0xFFFF0F:
            self.iram[a - 0xFFFD10] = v
        if self.outside(a) or a < 0x80000:
            self.write_outside(a, v, 1)

    def write16(self, a, v):
        a &= 0xfffffe
        v &= 0xffff
        if a == 0xFFFFF2:
            self.syscr = v >> 8
        if 0x080000 <= a <= 0x08FFFF:
            self.ram[a - 0x080000] = v >> 8
            self.ram[a - 0x080000 + 1] = v & 0xff
        elif 0xFFFD10 <= a <= 0xFFFF0F:
            self.iram[a - 0xFFFD10] = v >> 8
            self.iram[a - 0xFFFD10 + 1] = v & 0xff
        if self.outside(a) or a < 0x80000:
            self.write_outside(a, v, 2)

    # ------------------------------------------------------------ MAME hooks with no effect here
    def internal(self, n):
        pass

    def prefetch_done(self):
        pass

    def prefetch_done_noirq(self):
        pass

    def prefetch_done_notrace(self):
        pass

    def update_irq_filter(self):
        pass

    def interrupt_taken(self):
        pass

    def debugger_exception_hook(self, v):
        pass

    def exr_in_stack(self):
        return False

    def prefetch_switch(self, pc, ir):
        self.NPC = pc & 0xffffff
        self.PC = pc + 2
        self.PIR = ir & 0xffff

    def irq_setup(self):                          # h83002_device::irq_setup
        self.CCR |= h8ops.F_I if self.syscr & 0x08 else h8ops.F_I | h8ops.F_UI

    def illegal(self):
        raise RuntimeError("illegal instruction %04X at %06X" % (self.IR[0], self.NPC))

    # ------------------------------------------------------------ decode and run
    def start_at(self, pc):
        """Begin execution at pc, as MAME does after a prefetch (NPC = pc, PIR = its first word, PC = pc + 2)."""
        self.NPC = pc & 0xffffff
        self.PIR = self.read16i(pc)
        self.PC = pc + 2

    def decode(self):
        w0 = self.IR[0]
        best = None
        for val, mask, skip, fn, name, am1, am2 in h8ops.OPCODES:
            v0, m0 = int(val[0:4], 16), int(mask[0:4], 16)
            if (w0 & m0) != v0:
                continue
            if len(val) == 4:
                if best is None:
                    best = (fn, 1, skip, name, am1, am2)
                continue
            w1 = self.read16i(self.PC + 2 * skip)
            if (w1 & int(mask[4:8], 16)) == int(val[4:8], 16):
                return fn, 2, skip, name, am1, am2
        if best is None:
            self.illegal()
        return best

    def step(self):
        """Run one instruction (the one at NPC). Returns its mnemonic."""
        self.PPC = self.NPC
        self.IR = [0] * 8
        self.IR[0] = self.PIR
        fn, words, skip, name, am1, am2 = self.decode()
        if words == 2:
            for i in range(1, 2 + skip):          # MAME's dispatch step: the skipped words, then the second opcode word
                self.IR[i] = self.read16i(self.PC)
                self.PC += 2
        fn(self)
        return name

    def interrupt(self, vector):
        self.taken_irq_vector = vector
        h8ops.state_irq(self)

    def vector_of(self, handler):
        """The vector whose entry (advanced mode: 32-bit) points at handler."""
        for v in range(64):
            if ((self.read16i(4 * v) << 16) | self.read16i(4 * v + 2)) & 0xffffff == handler:
                return v
        raise RuntimeError("no vector points at %06X" % handler)


for _name in dir(h8ops):                          # the generated helpers (do_add8, set_nzv16, ...) become methods
    if _name.startswith(("do_", "set_nz")):
        setattr(H8, _name, getattr(h8ops, _name))
