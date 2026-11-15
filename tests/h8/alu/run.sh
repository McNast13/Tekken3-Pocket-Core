#!/usr/bin/env bash
# Check the H8 ALU (pocket/core/s12/h8_alu.vhd) against the generated MAME model: random cases, nvc.
set -euo pipefail
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 make_vectors.py "$work/vectors.txt" "${1:-200000}"
nvc --std=2008 --work="$work/work" -a ../../../pocket/core/s12/h8_alu.vhd tb_h8_alu.vhd \
    -e tb_h8_alu -gVECTORS="$work/vectors.txt" -r
