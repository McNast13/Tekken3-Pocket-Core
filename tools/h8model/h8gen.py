#!/usr/bin/env python3
"""Generate a Python model of the H8/300H (H8/3002, advanced mode) from MAME's own H8 description, so the model behaves
exactly as the MAME build our reference recordings come from (tools/mame/h8_ref.lua).

Inputs (tools/h8model/mame/, BSD-3-Clause, from github.com/mamedev/mame src/devices/cpu/h8/):
  h8.lst  the instruction set: opcode, mask, operands, and each instruction's steps in C
  h8.cpp  the ALU / shift / flag helpers (do_add8, set_nzv16, ...)
Output: tools/h8model/h8ops.py (generated; not edited by hand): one Python function per instruction, the opcode table,
the helpers, and the reset / interrupt sequences. tools/h8model/h8cpu.py runs them.

The C is translated line by line: every value is a Python int, and every assignment is masked to the width of what it
assigns (u8/u16/u32 locals, m_TMP1/2, m_PC, m_IR[], m_CCR ...), which keeps C's unsigned wrap-around. Only H8/300H
entries are kept (no flag, or flag h); H8/300-only (o) and H8S (s20, s26) ones are dropped.
Usage: h8gen.py   (from the repository root)
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LST, CPP = HERE / "mame/h8.lst", HERE / "mame/h8.cpp"
OUT = HERE / "h8ops.py"
UNKNOWN = set()

WIDTH = {"u8": 0xff, "u16": 0xffff, "u32": 0xffffffff, "s8": 0xff, "s16": 0xffff, "s32": 0xffffffff, "int": None,
         "u64": None, "s64": None}
MEMBER_WIDTH = {"TMP1": 0xffffffff, "TMP2": 0xffffffff, "PC": 0xffffffff, "NPC": 0xffffffff, "PPC": 0xffffffff,
                "CCR": 0xff, "EXR": 0xff, "PIR": 0xffff, "IR": 0xffff, "taken_irq_vector": None}


# ---------------------------------------------------------------- C expression -> Python expression
def ternary(e):
    """a ? b : c at the top level of an expression (no nesting in h8.lst) -> (b if a else c)."""
    depth, q = 0, -1
    for i, ch in enumerate(e):
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        elif ch == "?" and depth == 0:
            q = i
            break
    if q < 0:
        # a ternary inside parentheses: convert the innermost parenthesised group that holds one
        m = re.search(r"\(([^()]*\?[^()]*)\)", e)
        if m:
            return e[:m.start()] + "(" + ternary(m.group(1)) + ")" + e[m.end():]
        return e
    depth, c = 0, -1
    for i in range(q + 1, len(e)):
        ch = e[i]
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        elif ch == ":" and depth == 0:
            c = i
            break
    a, b, cc = e[:q].strip(), e[q + 1:c].strip(), e[c + 1:].strip()
    return "((%s) if (%s) else (%s))" % (ternary(b), ternary(a), ternary(cc))


def expr(e):
    e = e.strip()
    e = re.sub(r"\bm_IR\[", "s.IR[", e)
    e = re.sub(r"\bm_([A-Za-z_][A-Za-z_0-9]*)", r"s.\1", e)
    e = re.sub(r"\b(F_[A-Z]+|EXR_[A-Z]+)\b", r"\1", e)
    e = e.replace("&&", " and ").replace("||", " or ")
    e = re.sub(r"!(?!=)", " not ", e)
    e = re.sub(r"\btrue\b", "True", e)
    e = re.sub(r"\bfalse\b", "False", e)
    e = re.sub(r"(0x[0-9a-fA-F]+|\d+)[uUlL]+\b", r"\1", e)
    # helper calls: read8(...) -> s.read8(...); casts s8()/u16() stay as module functions
    e = re.sub(r"(?<![.\w])([a-z_][a-z_0-9]*)\(", lambda m: m.group(1) + "(" if m.group(1) in
               ("s8", "s16", "s32", "u8", "u16", "u32", "u64", "abs", "not") else "s." + m.group(1) + "(", e)
    e = e.replace("s.not (", "not (")
    if "?" in e:
        e = ternary(e)
    # unary minus on a u32 member wraps in C (divxs takes magnitudes this way)
    e = re.sub(r"\(-s\.(TMP[12])\)", r"((-s.\1) & 0xffffffff)", e)
    # C integer division on non-negative operands
    e = re.sub(r"(?<![/])/(?![/=])", "//", e)
    return e


def assignment(stmt, local_widths):
    """'x op= y' / 'x = y' / 'type x = y' -> masked Python assignment."""
    m = re.match(r"^(u8|u16|u32|s8|s16|s32|int|u64|s64)\s+([A-Za-z_][A-Za-z_0-9]*(\s*,\s*[A-Za-z_][A-Za-z_0-9]*)+)$", stmt)
    if m:                                     # int q, r;
        names = [n.strip() for n in m.group(2).split(",")]
        for n in names:
            local_widths[n] = WIDTH[m.group(1)]
        return "; ".join("%s = 0" % n for n in names)
    m = re.match(r"^(u8|u16|u32|s8|s16|s32|int|u64|s64)\s+([A-Za-z_][A-Za-z_0-9]*)\s*(=\s*(.*))?$", stmt)
    if m:
        local_widths[m.group(2)] = WIDTH[m.group(1)]
        if not m.group(3):
            return "%s = 0" % m.group(2)
        stmt = "%s = %s" % (m.group(2), m.group(4))
    m = re.match(r"^([A-Za-z_][A-Za-z_0-9>.\-]*(\[[^\]]+\])?)\s*(\+|-|\*|/|%|&|\||\^|<<|>>)?=\s*(.*)$", stmt)
    if not m or stmt.startswith("=="):
        return None
    target, op, rhs = m.group(1), m.group(3), m.group(4)
    width = None
    tm = re.match(r"^m_([A-Za-z_0-9]+)", target)
    if tm:
        width = MEMBER_WIDTH.get(tm.group(1), "unknown")
        if width == "unknown":                # only in sleep / H8S-MAC paths, which Tekken 3's H8 program does not use
            UNKNOWN.add(tm.group(1))
            width = None
    elif target in local_widths:
        width = local_widths[target]
    else:
        raise SystemExit("assignment to unknown target: " + stmt)
    t = expr(target)
    r = expr(rhs)
    if op:
        r = "(%s) %s (%s)" % (t, "//" if op == "/" else op, r)
    if width is None:
        return "%s = %s" % (t, r)
    return "%s = (%s) & 0x%x" % (t, r, width)


# ---------------------------------------------------------------- C statements -> Python lines
def translate(lines, local_widths=None):
    """C statement lines (one statement per line, braces as in h8.lst / h8.cpp) -> Python lines (4-space indent)."""
    local_widths = dict(local_widths or {})
    out, ind = [], 1
    single = []                       # indents of brace-less if/else bodies still waiting for their statement
    block_has = [True]

    def emit(s):
        out.append("    " * ind + s)

    def close_single():
        nonlocal ind
        while single and single[-1] == ind:
            single.pop()
            ind -= 1

    joined, acc = [], ""
    for raw in lines:                         # join statements and conditions that continue on the next line
        l = re.sub(r"\s*//.*$", "", raw.strip())
        if not l:
            continue
        acc = (acc + " " + l) if acc else l
        if acc.count("(") == acc.count(")"):
            joined.append(acc)
            acc = ""
    if acc:
        joined.append(acc)
    for l in joined:
        m = re.match(r"^\}\s*else\s+if\s*\((.*)\)\s*(\{)?$", l)
        if m:
            ind -= 1
            emit("elif %s:" % expr(m.group(1)))
            ind += 1
            if not m.group(2):
                single.append(ind)
            continue
        if re.match(r"^\}\s*else\s*\{$", l):
            ind -= 1
            emit("else:")
            ind += 1
            continue
        if l == "}":
            ind -= 1
            close_single()
            continue
        m = re.match(r"^else\s+if\s*\((.*)\)\s*(\{)?$", l)
        if m:
            emit("elif %s:" % expr(m.group(1)))
            ind += 1
            if not m.group(2):
                single.append(ind)
            continue
        if l in ("else", "else {"):
            emit("else:")
            ind += 1
            if l == "else":
                single.append(ind)
            continue
        m = re.match(r"^(if|while)\s*\((.*)\)\s*(\{)?$", l)
        if m and l.count("(") == l.count(")"):
            emit("%s %s:" % (m.group(1), expr(m.group(2))))
            ind += 1
            if not m.group(3):
                single.append(ind)
            continue
        m = re.match(r"^(if|while)\s*\((.*)\)\s*(.+;)$", l)          # if(c) stmt;  on one line
        if m:
            emit("%s %s:" % (m.group(1), expr(m.group(2))))
            ind += 1
            single.append(ind)
            l = m.group(3)
        if l.endswith(";"):
            l = l[:-1].strip()
        if l.startswith("return"):
            emit("return " + expr(l[6:]) if l[6:].strip() else "return")
        else:
            a = assignment(l, local_widths)
            if a is None:
                a = expr(l)
            emit(a)
        close_single()
    return out


# ---------------------------------------------------------------- h8.lst
def parse_lst():
    macros, entries, cur = {}, [], None
    for line in LST.read_text().splitlines():
        if line.startswith("#"):
            continue
        if not line.strip():
            continue                  # blank lines also occur inside bodies; an entry ends at the next header
        if line.startswith("macro "):
            parts = line.split()
            cur = {"kind": "macro", "name": parts[1], "params": parts[2:], "body": []}
            macros[parts[1]] = cur
            continue
        if not line[0].isspace():
            parts = line.split()
            if re.match(r"^[0-9a-f]+$", parts[0]) and len(parts[0]) == 5:       # 10000 reset / 10001 irq h ...
                cur = {"kind": "state", "name": parts[1], "flag": parts[2] if len(parts) > 2 else "", "body": []}
            else:
                val, mask, skip, name, am1, am2 = parts[:6]
                flag = parts[6] if len(parts) > 6 else ""
                cur = {"kind": "op", "val": val, "mask": mask, "skip": int(skip), "name": name, "am1": am1, "am2": am2,
                       "flag": flag, "body": []}
            entries.append(cur)
            continue
        cur["body"].append(line)
    return macros, entries


def expand(body, macros):
    out = []
    for line in body:
        s = line.strip()
        parts = s.split()
        if parts and parts[0] in macros and not s.endswith(";") and "(" not in parts[0]:
            mac = macros[parts[0]]
            # one parameter: the rest of the line (a branch condition has spaces); more: split on whitespace
            args = [s[len(parts[0]):].strip()] if len(mac["params"]) == 1 else parts[1:]
            sub = []
            for ml in mac["body"]:
                for p, a in zip(mac["params"], args):
                    ml = ml.replace(p, a)
                sub.append(ml)
            out.extend(expand(sub, macros))
        else:
            out.append(line)
    return out


def extra_words(op):
    am1, am2, skip = op["am1"], op["am2"], op["skip"]
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


def keep(flag):
    return flag in ("", "h")


# ---------------------------------------------------------------- h8.cpp helpers
def parse_helpers():
    src = CPP.read_text()
    funcs = []
    for m in re.finditer(r"^(u8|u16|u32|void) h8_device::((?:do_|set_nz)[a-z0-9_]+)\(([^)]*)\)\n\{\n(.*?)^\}", src, re.S | re.M):
        rtype, name, params, body = m.groups()
        widths, pnames = {}, []
        for p in filter(None, [x.strip() for x in params.split(",")]):
            t, n = p.split()
            widths[n] = WIDTH[t]
            pnames.append(n)
        funcs.append((rtype, name, pnames, body.splitlines(), widths))
    return funcs


def main():
    macros, entries = parse_lst()
    py = ['"""GENERATED by tools/h8model/h8gen.py from MAME\'s h8.lst and h8.cpp (BSD-3-Clause, Olivier Galibert).',
          'Do not edit: regenerate."""', "",
          "F_I, F_UI, F_H, F_U, F_N, F_Z, F_V, F_C = 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01",
          "EXR_I, EXR_NC = 0x07, 0x78", "",
          "def s8(v):\n    v &= 0xff\n    return v - 0x100 if v & 0x80 else v",
          "def s16(v):\n    v &= 0xffff\n    return v - 0x10000 if v & 0x8000 else v",
          "def s32(v):\n    v &= 0xffffffff\n    return v - 0x100000000 if v & 0x80000000 else v",
          "def u8(v):\n    return v & 0xff", "def u16(v):\n    return v & 0xffff", "def u32(v):\n    return v & 0xffffffff",
          "def u64(v):\n    return v", ""]
    for rtype, name, pnames, body, widths in parse_helpers():
        py.append("def %s(s, %s):" % (name, ", ".join(pnames)) if pnames else "def %s(s):" % name)
        lines = translate(body, widths)
        # C converts each argument to its parameter type on entry (set_nzv8(m_IR[0]) sees the low byte only)
        lines = ["    %s &= 0x%x" % (n, widths[n]) for n in pnames if widths[n]] + lines
        if rtype != "void":
            lines = [re.sub(r"^(\s*)return (.*)$", r"\1return (\2) & 0x%x" % WIDTH[rtype], l) for l in lines]
        py.extend(lines or ["    pass"])
        py.append("")
    table = []
    for e in entries:
        if e["kind"] == "macro" or not keep(e["flag"]):
            continue
        if e["kind"] == "state" and e["name"] not in ("reset", "irq"):
            continue                  # on-chip DMA / DTC sequences: not used by Tekken 3's H8 program
        body = expand(e["body"], macros)
        if e["kind"] == "state":
            fname = "state_" + e["name"]
            pre = []
        else:
            fname = "op_%s_%s_%s" % (e["name"].replace(".", "_"), e["am1"].replace("-", "x"), e["am2"].replace("-", "x"))
            base = len(e["val"]) // 4 + e["skip"]
            pre = []
            for i in range(extra_words(e)):
                pre += ["m_IR[%d] = read16i(m_PC);" % (base + i), "m_PC += 2;"]
            table.append((e["val"], e["mask"], e["skip"], fname, e["name"], e["am1"], e["am2"]))
        py.append("def %s(s):" % fname)
        lines = translate(pre + body)
        py.extend(lines or ["    pass"])
        py.append("")
    py.append("OPCODES = [")
    for t in table:
        py.append("    (%r, %r, %d, %s, %r, %r, %r)," % (t[0], t[1], t[2], t[3], t[4], t[5], t[6]))
    py.append("]")
    OUT.write_text("\n".join(py) + "\n")
    compile(OUT.read_text(), str(OUT), "exec")
    print("wrote %s: %d instructions, %d lines" % (OUT, len(table), len(py)))
    if UNKNOWN:
        print("unmasked members (unused paths):", " ".join(sorted(UNKNOWN)))


if __name__ == "__main__":
    main()
