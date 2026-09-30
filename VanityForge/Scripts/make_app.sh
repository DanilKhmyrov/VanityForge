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
    echo "==> Building metalvanity-evm (GPU-перебор EVM-кошельков)"
    if (cd "$REPO_ROOT/metalvanity/evm" && cargo build --release); then
        METAL_EVM_BIN="$REPO_ROOT/metalvanity/evm/target/release/metalvanity-evm"
    else
        echo "    сборка metalvanity-evm не удалась — кошельки будут считаться на CPU"
        METAL_EVM_BIN=""
    fi
else
    echo "==> cargo не найден — пропускаю сборку ethvanity (приложение всё равно"
    echo "    работает, просто без ускорения ETH-поиска, если не установлен keyhunt)"
    ETHVANITY_BIN=""
    METAL_EVM_BIN=""
fi

echo "==> Building metalvanity (GPU-перебор CREATE2/CREATE3)"
if METALVANITY_BIN="$("$REPO_ROOT/metalvanity/build.sh" | tail -1)"; then :; else
    echo "    сборка metalvanity не удалась — контракты будут считаться на CPU"
    METALVANITY_BIN=""
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

# Старые версии приложения сохраняли находки (с приватными ключами) внутрь
# бандла — rm -rf ниже стёр бы их. Переносим в постоянную папку приложения.
LEGACY_RESULTS="$APP/Contents/Resources/PythonRuntime/results"
if [ -d "$LEGACY_RESULTS" ]; then
    SAFE_RESULTS="$HOME/Library/Application Support/VanityForge/results"
    echo "==> Сохраняю находки из старого .app в $SAFE_RESULTS"
    mkdir -p "$SAFE_RESULTS"
    rsync -a --ignore-existing "$LEGACY_RESULTS/" "$SAFE_RESULTS/"
    # Удаляем бандл, только если каждая находка точно есть в новой папке.
    (cd "$LEGACY_RESULTS" && find . -type f) | while read -r f; do
        if [ ! -f "$SAFE_RESULTS/$f" ]; then
            echo "    не удалось сохранить $f — сборка остановлена, старый .app не тронут" >&2
            exit 1
        fi
    done
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
for f in bridge.py main.py networks.py patterns.py eth.py create2.py splitkey.py tonsub.py; do
    cp "$REPO_ROOT/$f" "$PY_RUNTIME_DEST/$f"
done
if [ -n "$ETHVANITY_BIN" ] && [ -x "$ETHVANITY_BIN" ]; then
    cp "$ETHVANITY_BIN" "$PY_RUNTIME_DEST/ethvanity"
fi
if [ -n "$METALVANITY_BIN" ] && [ -x "$METALVANITY_BIN" ]; then
    cp "$METALVANITY_BIN" "$PY_RUNTIME_DEST/metalvanity"
fi
if [ -n "$METAL_EVM_BIN" ] && [ -x "$METAL_EVM_BIN" ]; then
    cp "$METAL_EVM_BIN" "$PY_RUNTIME_DEST/metalvanity-evm"
fi

touch "$APP"

echo "==> Done: $APP"
