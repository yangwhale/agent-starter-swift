#!/usr/bin/env bash
# facebench: build the AgentTouch reference renderer.
#   AGENTTOUCH_SRC=/path/to/agenttouch/firmware/src ./build.sh [builddir]
# The AgentTouch sources are copied into the build dir next to our stub headers
# (quoted #includes resolve in the including file's own directory first, so the
# stubs must sit beside face.cpp). Nothing from AgentTouch is kept in this repo.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src="${AGENTTOUCH_SRC:?set AGENTTOUCH_SRC to agenttouch/firmware/src}"
out="${1:-$here/build}"
mkdir -p "$out"
for f in face.cpp face.h grokface.cpp grokface.h grok_eyes.h config.h; do cp "$src/$f" "$out/"; done
for f in Arduino_GFX_Library.h gfx.cpp pages.h i18n.h pins.h pet_fonts.h face_tu.cpp grok_tu.cpp bench.cpp; do
  cp "$here/$f" "$out/"
done
cd "$out"
g++ -O2 -std=gnu++17 -w -I. -o bench bench.cpp face_tu.cpp grok_tu.cpp gfx.cpp
echo "built $out/bench"
