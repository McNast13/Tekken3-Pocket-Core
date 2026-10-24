#!/usr/bin/env bash
# Most-executed PCs in a MAME trace (tools/mame/t3_profile.lua): the vsync wait loop is normally the top few,
# a tight loop polling a RAM counter. usage: tools/hot_pcs.sh out/trace.log [count]
set -eu
awk -F: '/^[0-9A-F]{8}:/{print $1}' "$1" | sort | uniq -c | sort -rn | head -"${2:-20}"
echo "instructions traced: $(grep -c '^[0-9A-F]\{8\}:' "$1")"
