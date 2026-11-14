#!/usr/bin/env bash
# Simulate the core's dma.vhd channel 5 with s12_romdma (tb_s12_dma.vhd) with nvc.
# usage: tests/romdma/run_dma.sh CORE_TREE ALTERA_SIM_LIB
#   CORE_TREE      an assembled core tree with t3_s12map applied (tools/build_core_tree.py, S11_PROBES=t3_s12map)
#   ALTERA_SIM_LIB a folder holding altera_mf_components.vhd and altera_mf.vhd (Quartus: quartus/eda/sim_lib)
set -euo pipefail
tree=$(cd "$1" && pwd); sim=$(cd "$2" && pwd)
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
n() { nvc --std=2008 -L "$work" "$@"; }
n --work=altera_mf:"$work/altera_mf" -a --relaxed "$sim/altera_mf_components.vhd" "$sim/altera_mf.vhd"
(cd "$tree/rtl" && n --work=mem:"$work/mem" -a --relaxed RamMLAB.vhd SyncFifo.vhd SyncFifoFallThrough.vhd \
   SyncFifoFallThroughMLAB.vhd SyncRam.vhd SyncRamDual.vhd SyncRamDualNotPow2.vhd SyncRamDualByteEnable.vhd)
n --work="$work/work" -a --relaxed "$tree/rtl/dma.vhd" "$tree/rtl/s12_romdma.vhd" tb_s12_dma.vhd -e tb_s12_dma -r
