#!/bin/bash
# Собирает metalvanity (GPU-перебор CREATE2/CREATE3). Шейдер компилируется в
# рантайме, поэтому Metal Toolchain не нужен — хватает swiftc.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$DIR/build"
swiftc -O -framework Metal -framework Security "$DIR/Shader.swift" "$DIR/main.swift" -o "$DIR/build/metalvanity"
echo "$DIR/build/metalvanity"
