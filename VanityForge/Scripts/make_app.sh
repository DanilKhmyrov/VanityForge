#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"

APP="$ROOT/VanityForge.app"
ICONSET="$ROOT/Resources/AppIcon.iconset"
ICON_BASE="$ROOT/Resources/icon_1024.png"

echo "==> Building release binary"
swift build -c release

echo "==> Preparing bundled Python runtime"
"$REPO_ROOT/Scripts/setup_runtime.sh"

if command -v cargo >/dev/null 2>&1; then
    echo "==> Building ethvanity accelerator"
    (cd "$REPO_ROOT/ethvanity" && cargo build --release)
    ETHVANITY_BIN="$REPO_ROOT/ethvanity/target/release/ethvanity"
else
    echo "==> cargo не найден — пропускаю сборку ethvanity (приложение всё равно"
    echo "    работает, просто без ускорения ETH-поиска, если не установлен keyhunt)"
    ETHVANITY_BIN=""
fi

if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
    echo "==> Generating app icon"
    swift "$ROOT/Scripts/generate_icon.swift" "$ICON_BASE"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$ICON_BASE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z "$double" "$double" "$ICON_BASE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
fi

echo "==> Assembling .app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/VanityForge" "$APP/Contents/MacOS/VanityForge"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# SPM's сгенерированный resource_bundle_accessor ищет ресурсы (иконки сетей)
# по пути Bundle.main.bundleURL/<Package>_<Target>.bundle — то есть прямо в
# корне .app, рядом с Contents/, а не внутри Contents/Resources.
RESOURCE_BUNDLE="$ROOT/.build/release/VanityForge_VanityForge.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$APP/VanityForge_VanityForge.bundle"
fi

echo "==> Bundling Python runtime + source"
PY_RUNTIME_DEST="$APP/Contents/Resources/PythonRuntime"
mkdir -p "$PY_RUNTIME_DEST"
cp -R "$REPO_ROOT/build_cache/python" "$PY_RUNTIME_DEST/runtime"
for f in bridge.py main.py networks.py patterns.py eth.py; do
    cp "$REPO_ROOT/$f" "$PY_RUNTIME_DEST/$f"
done
if [ -n "$ETHVANITY_BIN" ] && [ -x "$ETHVANITY_BIN" ]; then
    cp "$ETHVANITY_BIN" "$PY_RUNTIME_DEST/ethvanity"
fi

touch "$APP"

echo "==> Done: $APP"
