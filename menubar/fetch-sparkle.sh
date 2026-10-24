#!/bin/zsh
# Download the pinned Sparkle release into menubar/vendor (not committed) and verify its checksum.
# Prints the Sparkle directory. Used by build.sh and scripts/setup-dev.sh.
set -euo pipefail
cd "${0:A:h}"

SPARKLE_VERSION=2.10.0
SPARKLE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c

DIR="vendor/Sparkle-$SPARKLE_VERSION"
if [[ ! -d "$DIR/Sparkle.framework" ]]; then
  mkdir -p vendor
  tarball="vendor/Sparkle-$SPARKLE_VERSION.tar.xz"
  curl -fsSL -o "$tarball" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  actual="$(shasum -a 256 "$tarball" | cut -d' ' -f1)"
  if [[ "$actual" != "$SPARKLE_SHA256" ]]; then
    rm -f "$tarball"
    echo "Sparkle download checksum mismatch ($actual); refusing to use it" >&2
    exit 1
  fi
  rm -rf "$DIR"; mkdir -p "$DIR"
  tar -xJf "$tarball" -C "$DIR"
fi
print -r -- "$PWD/$DIR"
