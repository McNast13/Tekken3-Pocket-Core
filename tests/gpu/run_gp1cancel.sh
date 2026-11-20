#!/usr/bin/env bash
# Simulate GP1(01) arriving while the GPU waits for a command's parameters (tb_t3_gp1cancel, see gen_tb_gp1cancel.py).
# usage: tests/gpu/run_gp1cancel.sh CORE_TREE ALTERA_SIM_LIB
#   CORE_TREE      an assembled core tree (tools/build_core_tree.py; with or without t3_gp1cancel to compare)
#   ALTERA_SIM_LIB a folder holding altera_mf_components.vhd and altera_mf.vhd (Quartus: quartus/eda/sim_lib)
set -euo pipefail
tree=$(cd "$1" && pwd); sim=$(cd "$2" && pwd)
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
n() { nvc --std=2008 -L "$work" "$@"; }
python3 gen_tb_gp1cancel.py "$tree" "$work/tb_t3_gp1cancel.vhd"
n --work=altera_mf:"$work/altera_mf" -a --relaxed "$sim/altera_mf_components.vhd" "$sim/altera_mf.vhd"
(cd "$tree/rtl" && n --work=mem:"$work/mem" -a --relaxed RamMLAB.vhd SyncFifo.vhd SyncFifoFallThrough.vhd \
   SyncFifoFallThroughMLAB.vhd SyncRam.vhd SyncRamDual.vhd SyncRamDualNotPow2.vhd SyncRamDualByteEnable.vhd dpram.vhd)
# simulation-only copies: gpu_poly/gpu_line share the dividers through "inout div_type" record ports and never drive
# .done/.quotient/.remainder; without a port default nvc resolves those fields with the port's 'U' (Quartus does not)
for f in gpu_poly.vhd gpu_line.vhd; do
  sed "s/: inout div_type;/: inout div_type := ('Z', 'Z', (others => 'Z'), (others => 'Z'), (others => 'Z'), (others => 'Z'));/" \
    "$tree/rtl/$f" > "$work/$f"
done
files=""
for f in dpram.vhd psx_gpu_recip_unit.vhd divider.vhd pGPU.vhd mul32u.vhd mul9s.vhd gpu_fillVram.vhd gpu_cpu2vram.vhd gpu_vram2vram.vhd \
         gpu_vram2cpu.vhd gpu_line.vhd gpu_rect.vhd gpu_poly.vhd gpu_pixelpipeline.vhd gpu_overlay.vhd gpu_dither.vhd \
         gpu_videoout_async.vhd gpu_videoout_sync.vhd gpu_crosshair.vhd justifier_sensor.vhd gpu_videoout.vhd gpu.vhd; do
  if [ -f "$work/$f" ]; then files="$files $work/$f"; elif [ -f "$tree/rtl/$f" ]; then files="$files $tree/rtl/$f"; fi
done
n --work="$work/work" -a --relaxed $files "$work/tb_t3_gp1cancel.vhd" -e tb_t3_gp1cancel -r --stop-time=10ms
