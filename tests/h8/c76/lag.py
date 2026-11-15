#!/usr/bin/env python3
"""How late the core's H8 is: the n-th C352 key-on / key-off commit (a write to 0x280404) in the core against the n-th
in MAME, in frames, per second of MAME time. Usage: lag.py MAME_C352_LOG CORE_C352_LOG"""
import sys


def commits(path):
    return [int(l.split()[0]) for l in open(path) if l.split()[1] == "280404"]


m, c = commits(sys.argv[1]), commits(sys.argv[2])
n = min(len(m), len(c))
print("commits: MAME %d, core %d" % (len(m), len(c)))
per = {}
for i in range(n):
    per.setdefault(m[i] // 60, []).append(c[i] - m[i])
for s in sorted(per):
    d = per[s]
    print("second %2d: %4d commits, lag frames avg %5.1f max %3d" % (s, len(d), sum(d) / len(d), max(d)))
