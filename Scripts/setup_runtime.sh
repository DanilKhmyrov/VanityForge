#!/bin/bash
# Готовит самодостаточный, переносимый Python-рантайм для упаковки в .app —
# без венва (у venv/pyvenv.cfg есть абсолютный путь "home", который ломается
# при переносе в другое место), пакеты ставятся прямо в site-packages
# самого standalone-интерпретатора. Такое дерево можно скопировать куда
# угодно и оно продолжит работать (проверено вручную: только системные
# фреймворки/dylib в зависимостях, никаких абсолютных путей к месту сборки).
#
# Источник интерпретатора — python-build-standalone (astral-sh), это тот же
# проект, на котором построен uv. Тег и версия зафиксированы, чтобы сборка
# была воспроизводимой и не зависела от того, что сейчас "latest" на GitHub.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PBS_TAG="20260728"
PBS_PYVER="3.10.20"
OUT_DIR="$ROOT/build_cache"
RUNTIME_DIR="$OUT_DIR/python"

case "$(uname -m)" in
    arm64)   PBS_ARCH="aarch64-apple-darwin" ;;
    x86_64)  PBS_ARCH="x86_64-apple-darwin" ;;
    *)       echo "Неизвестная архитектура: $(uname -m)" >&2; exit 1 ;;
esac

ASSET="cpython-${PBS_PYVER}+${PBS_TAG}-${PBS_ARCH}-install_only_stripped.tar.gz"
URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${ASSET}"

mkdir -p "$OUT_DIR"

if [ -x "$RUNTIME_DIR/bin/python3" ]; then
    echo "==> Python-рантайм уже готов: $RUNTIME_DIR"
else
    echo "==> Скачиваю standalone Python ($PBS_ARCH, $PBS_PYVER)"
    curl -fL --progress-bar -o "$OUT_DIR/cpython.tar.gz" "$URL"
    rm -rf "$RUNTIME_DIR"
    tar -xzf "$OUT_DIR/cpython.tar.gz" -C "$OUT_DIR"
    rm "$OUT_DIR/cpython.tar.gz"
fi

echo "==> Устанавливаю зависимости из requirements.txt"
"$RUNTIME_DIR/bin/pip3" install --quiet --upgrade pip
"$RUNTIME_DIR/bin/pip3" install --quiet -r "$ROOT/requirements.txt"

echo "==> Готово: $RUNTIME_DIR ($("$RUNTIME_DIR/bin/python3" --version))"
