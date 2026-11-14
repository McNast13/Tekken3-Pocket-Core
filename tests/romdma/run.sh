#!/usr/bin/env bash
# Simulate the System 12 ROM DMA fetcher (pocket/core/s12/s12_romdma.vhd) with nvc.
set -euo pipefail
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
nvc --std=2008 --work="$work/work" -a ../../pocket/core/s12/s12_romdma.vhd tb_s12_romdma.vhd -e tb_s12_romdma -r
