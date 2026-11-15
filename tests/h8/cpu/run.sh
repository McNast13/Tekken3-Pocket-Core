#!/usr/bin/env bash
# Replay MAME's recording of Tekken 3's H8 into the VHDL CPU (pocket/core/s12/h8_cpu.vhd) with nvc.
# Needs tests/h8/ref/ from tools/mame/h8_ref.lua + tests/h8/make_replay.py. usage: run.sh [max_instructions]
# REF=dir FLAT=true: a random-instruction test made by tests/h8/rand/make_rand.py
set -euo pipefail
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
nvc --std=2008 --work="$work/work" -a --relaxed ../../../pocket/core/s12/h8_alu.vhd ../../../pocket/core/s12/h8_cpu.vhd tb_h8_cpu.vhd \
    -e tb_h8_cpu -gREF="$(cd "${REF:-../ref}" && pwd)" -gMAXINS="${1:-200000}" -gFLAT="${FLAT:-false}" -r
