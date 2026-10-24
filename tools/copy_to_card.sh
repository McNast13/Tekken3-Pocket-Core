#!/usr/bin/env bash
# Copy a Tekken 3 package (pocket/package-<label>) to the Pocket's SD card.
# It writes ONLY the Tekken 3 core's own paths; every other core on the card (the Namco System 11 core included)
# is never read, written or deleted:
#   Cores/McNast13.Tekken3/   Platforms/tekken3.json   Platforms/_images/tekken3.bin   Assets/tekken3/
# usage: tools/copy_to_card.sh pocket/package-<label> [/Volumes/Analogue]
set -eu
pkg=${1:?usage: tools/copy_to_card.sh pocket/package-<label> [card]}
card=${2:-/Volumes/Analogue}
[ -d "$card/Cores" ] || { echo "no Pocket card at $card"; exit 1; }
[ -f "$pkg/Cores/McNast13.Tekken3/bitstream.rbf_r" ] || { echo "$pkg is not a Tekken 3 package"; exit 1; }

# refuse a package that holds anything outside the Tekken 3 paths
extra=$(cd "$pkg" && find Cores Platforms Assets -mindepth 1 -maxdepth 2 \
  ! -path Cores/McNast13.Tekken3 ! -path 'Cores/McNast13.Tekken3/*' \
  ! -path Platforms/tekken3.json ! -path Platforms/_images ! -path Platforms/_images/tekken3.bin \
  ! -path Assets/tekken3 ! -path 'Assets/tekken3/*')
[ -z "$extra" ] || { echo "package holds paths outside Tekken 3, not copying:"; echo "$extra"; exit 1; }

mkdir -p "$card/Cores/McNast13.Tekken3" "$card/Platforms/_images" "$card/Assets/tekken3"
rsync -rt "$pkg/Cores/McNast13.Tekken3/" "$card/Cores/McNast13.Tekken3/"
cp "$pkg/Platforms/tekken3.json" "$card/Platforms/tekken3.json"
cp "$pkg/Platforms/_images/tekken3.bin" "$card/Platforms/_images/tekken3.bin"
rsync -rt "$pkg/Assets/tekken3/" "$card/Assets/tekken3/"

# verify every copied file byte for byte
(cd "$pkg" && find Cores/McNast13.Tekken3 Platforms/tekken3.json Platforms/_images/tekken3.bin Assets/tekken3 -type f) |
  while read -r f; do cmp -s "$pkg/$f" "$card/$f" || { echo "MISMATCH $f"; exit 1; }; done
dot_clean -m "$card/Cores/McNast13.Tekken3" "$card/Assets/tekken3" 2>/dev/null || true
echo "copied and verified $pkg -> $card (Tekken 3 paths only)"
