#!/usr/bin/env bash
# H8 system test (tb_h8_sys.vhd): the core's H8 CPU + peripherals run Tekken 3's sound program from reset for FRAMES
# frames (default 240 = 4 s; 960 = 16 s takes a while) and its C352 writes are compared with MAME's.
# Needs tests/h8/ref: rom.hex (tests/h8/make_replay.py) and, from tools/mame/h8_shared.lua run on an initialised NVRAM
# (tests/h8/ref/nvram, made by one 40 s MAME run), main_shared.log, c352.log, c352_reads.log (-> c352_ends.log).
# usage: run.sh [frames]
set -euo pipefail
cd "$(dirname "$0")"
frames=${1:-240}
python3 c352_ends.py ../ref/c352_reads.log ../ref/c352_ends.log
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
nvc --std=2008 --work="$work/work" -a --relaxed ../../../pocket/core/s12/h8_alu.vhd ../../../pocket/core/s12/h8_cpu.vhd \
    ../../../pocket/core/s12/h8_periph.vhd tb_h8_sys.vhd \
    -e tb_h8_sys -gREF="$(cd ../ref && pwd)" -gOUTF="$work/c352_sim.log" -gFRAMES="$frames" -r 2>&1 | grep -v "^\s*|" |
    grep -E "tb_h8_sys|Error|Fatal|Failure|unmapped|> " || true
[ -s "$work/c352_sim.log" ] || { echo "simulation failed (no C352 log)"; exit 1; }
python3 compare.py ../ref/c352.log "$work/c352_sim.log" "$frames"
