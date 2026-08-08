#!/usr/bin/env bash
#
# Field Lab — Field.metal, rendered off disk, rebuilding on save.
#
#   ios/tools/FieldLab/run.sh
#
# Compiled with swiftc directly rather than SwiftPM. There is one binary, no
# manifest, no resolved-package file and no .build tree to explain; the cost is
# that every build is a full one, and at nine files that is under ten seconds.
# It is also the reason the app's own sources can just be listed here — a
# package would need them inside its own directory or symlinked in.
#
# Those three files are compiled from the app target, not copied:
#
#   Form.swift        the forms and their palettes
#   FieldState.swift  taps, breath, grounding, the colony clock
#   Uniforms.swift    the struct handed to the shader every frame
#
# which is what stops the lab and the app drifting apart. Field.metal is not
# compiled here at all — it is read at runtime, which is the whole point.

set -euo pipefail

cd "$(dirname "$0")"
LAB="$PWD"
APP="$LAB/../../Mycelium/Mycelium/Field"

export FIELD_METAL="$(cd "$APP" && pwd)/Field.metal"

if [[ ! -f "$FIELD_METAL" ]]; then
  echo "Can't find Field.metal at $FIELD_METAL" >&2
  exit 1
fi

mkdir -p .build

SOURCES=(
  Sources/FieldLabApp.swift
  Sources/LabEngine.swift
  Sources/LabRenderer.swift
  Sources/LabCapture.swift
  Sources/LabControls.swift
  Sources/LabFieldView.swift
  Sources/ShaderWatcher.swift
  "$APP/Form.swift"
  "$APP/FieldState.swift"
  "$APP/Uniforms.swift"
)

# Skip the rebuild when nothing here changed. Field.metal is deliberately not in
# that list — it is read at runtime, so a shader edit must never trigger a Swift
# build. Without this, a sweep like
#
#   for v in 0 1 2 3; do run.sh --capture $v.png --lab $v,0,0,0; done
#
# pays forty seconds of swiftc per sample to render half a second of field.
stale=0
for f in "${SOURCES[@]}"; do
  if [[ ! -f .build/FieldLab || "$f" -nt .build/FieldLab ]]; then stale=1; break; fi
done

if [[ $stale -eq 1 ]]; then
echo "building…"
# -swift-version 5 on purpose. The app target builds in 5 too, and strict
# concurrency checking has opinions about MTLDevice that would need answering
# here and nowhere else.
swiftc \
  -swift-version 5 \
  -O \
  -parse-as-library \
  -framework Metal \
  -framework MetalKit \
  -framework AppKit \
  -o .build/FieldLab \
  "${SOURCES[@]}"
fi

# With no arguments this opens the window. With --capture it renders offscreen
# and exits, which is the same code path minus the drawable:
#
#   run.sh --capture /tmp/t.png --form tunnel --at 12
#   run.sh --capture /tmp/t.png --form tunnel --at 12 --lab 0.62,0,0,0
#
if [[ $# -eq 0 ]]; then
  echo "watching $FIELD_METAL"
fi
exec .build/FieldLab "$@"
