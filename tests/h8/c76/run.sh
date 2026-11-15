#!/usr/bin/env bash
# The H8 in the C76's place (pocket/core/s12/h8_c76.vhd, bridge and ROM cache included) runs Tekken 3's sound program for
# FRAMES frames (default 240) against a model of the System 11 sound block's bus; its C352 writes are compared with
# MAME's (tests/h8/sys/compare.py). Needs tests/h8/ref as tests/h8/sys/run.sh. usage: run.sh [frames]
set -euo pipefail
cd "$(dirname "$0")"
frames=${1:-240}
work=$(mktemp -d)
[ -n "${KEEP:-}" ] || trap 'rm -rf "$work"' EXIT; echo "work: $work"
S=../../../pocket/core/s12
nvc --std=2008 --work="$work/work" -a --relaxed ../c352_model_pkg.vhd $S/h8_alu.vhd $S/h8_cpu.vhd $S/h8_periph.vhd c76_entity.vhd $S/h8_c76.vhd \
    tb_h8_c76.vhd -e tb_h8_c76 -gREF="$(cd ../ref && pwd)" -gOUTF="$work/c352_sim.log" -gFRAMES="$frames" -r --ieee-warnings=off 2>&1 |
    grep -v "^\s*|" | grep -E "tb_h8_c76|second |Error|Fatal|Failure|> " || true
[ -s "$work/c352_sim.log" ] || { echo "simulation failed (no C352 log)"; exit 1; }
python3 ../sys/compare.py ../ref/c352.log "$work/c352_sim.log" "$frames"
