#!/usr/bin/env bash
# facebench: build the CCFaceMotion exporter in docker (no Swift toolchain on the host).
#   REPO=~/agent-starter-swift ./build.sh [workdir]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="${REPO:-$HOME/agent-starter-swift}"
w="${1:-$here/work}"
mkdir -p "$w"
cp "$repo"/VoiceAgent/CloseCrab/{CCPresence,CCFaceMood,CCFaceMotion,CCFaceGrokEyes}.swift "$w/"
cp "$here/export.swift" "$w/main.swift"
docker run --rm -v "$w":/w -w /w swift:6.2-noble bash -c \
  'swiftc -O -swift-version 6 -default-isolation MainActor CCPresence.swift CCFaceMood.swift CCFaceMotion.swift CCFaceGrokEyes.swift main.swift -o export'
echo "built $w/export"
