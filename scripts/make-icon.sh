#!/bin/bash
# Regenerates Resources/AppIcon.icns from scripts/icon/main.swift. The result is committed,
# so builds do not need this.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc -O -o "$WORK/make-icon" scripts/icon/main.swift
"$WORK/make-icon" "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
