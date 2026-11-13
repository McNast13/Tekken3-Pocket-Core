#!/usr/bin/env bash
# Compile the H8/300H sizing model alone in the same Quartus image as the core (docs/LOCAL_BUILD.md).
set -euo pipefail
cd "$(dirname "$0")"
docker info >/dev/null 2>&1 || { echo "docker daemon not running (open OrbStack)"; exit 1; }
rm -rf output_files db incremental_db
docker run --rm --platform linux/amd64 -v "$PWD:/w" -w /w raetro/quartus:pocket quartus_sh --flow compile h8_size > build.log 2>&1 || true
cat output_files/h8_size.fit.summary
