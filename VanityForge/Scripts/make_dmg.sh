#!/bin/bash
# Собирает распространяемый .dmg: .app (со встроенным Python-рантаймом и
# ethvanity, см. make_app.sh) + симлинк на /Applications, с оформленным
# окном Finder (фон, стрелка, иконка тома) вместо голого чёрного окна.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/VanityForge.app"
DMG="$ROOT/VanityForge.dmg"
STAGING="$ROOT/.dmg_staging"
FINAL_VOLNAME="VanityForge"
# Временный, заведомо уникальный том для сборки: если у пользователя уже
# смонтирован(а) старый(ая)/чужой(ая) диск/образ с именем "VanityForge" (не
# отмонтирован после предыдущей сборки, скачан отдельно и т.п.), Finder's
# `tell disk "VanityForge"` в AppleScript-стилизации ниже может задеть не
# тот том — отдельное имя на время сборки полностью исключает коллизию.
BUILD_VOLNAME="VanityForge Installer $$"
TMP_DMG="$ROOT/.VanityForge_rw.dmg"
MOUNT_DIR="/Volumes/$BUILD_VOLNAME"

echo "==> Building .app"
"$ROOT/Scripts/make_app.sh"

echo "==> Generating background artwork"
swift "$ROOT/Scripts/generate_dmg_background.swift" "$ROOT/Resources/dmg_background.png"

echo "==> Assembling staging folder"
rm -rf "$STAGING" "$DMG" "$TMP_DMG"
mkdir -p "$STAGING/.background"
cp -R "$APP" "$STAGING/VanityForge.app"
cp "$ROOT/Resources/dmg_background.png" "$STAGING/.background/background.png"
cp "$ROOT/Resources/AppIcon.icns" "$STAGING/.VolumeIcon.icns"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating writable image"
# APFS, не HFS+: на этой версии macOS у Finder сломан рендер background
# picture конкретно для HFS+-образов (проверено эмпирически — тот же
# .DS_Store/та же картинка отлично показываются на APFS-томе и остаются
# сплошным чёрным на HFS+). APFS — и так дефолт для новых образов на
# современном macOS, так что это ещё и просто более естественный выбор.
hdiutil create -srcfolder "$STAGING" -volname "$BUILD_VOLNAME" -fs APFS \
    -format UDRW -size 300m -ov "$TMP_DMG" >/dev/null

echo "==> Styling Finder window"
# Девайс-нода (не путь /Volumes/...) — стабильный идентификатор для detach:
# diskutil rename ниже меняет путь монтирования (он производится от имени
# тома), а нода остаётся той же. -plist даёт её однозначно, без парсинга
# текстового вывода hdiutil info.
ATTACH_PLIST="$(mktemp)"
hdiutil attach "$TMP_DMG" -mountpoint "$MOUNT_DIR" -noautoopen -plist > "$ATTACH_PLIST"
DEVICE="$(/usr/libexec/PlistBuddy -c "Print :system-entities:0:dev-entry" "$ATTACH_PLIST")"
rm -f "$ATTACH_PLIST"
SetFile -a C "$MOUNT_DIR" || true

osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$BUILD_VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 520}
        -- "a reference to" — без него присвоения вроде icon size/background
        -- picture молча уходят в отсоединённую копию свойств и не долетают
        -- до настоящего окна (тоже проверено эмпирически).
        set theViewOptions to a reference to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "VanityForge.app" of container window to {180, 210}
        set position of item "Applications" of container window to {480, 210}
        close
        open
        -- Повторно после close/open: реоткрытие иногда возвращает окну
        -- системный размер по умолчанию, а не тот, что был выставлен выше
        -- (тоже проверено эмпирически: без повтора получалось окно шире
        -- фоновой картинки — с белой полосой сбоку).
        set the bounds of container window to {200, 120, 860, 520}
        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT

# Финальное имя тома, которое увидит пользователь, выставляем в последний
# момент — до этой строки том жил под BUILD_VOLNAME специально ради
# уникальности (см. комментарий выше).
diskutil rename "$MOUNT_DIR" "$FINAL_VOLNAME" >/dev/null

sync
if ! hdiutil detach "$DEVICE" >/dev/null 2>&1; then
    sleep 2
    hdiutil detach "$DEVICE" -force >/dev/null
fi

echo "==> Converting to compressed image"
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null

rm -rf "$STAGING" "$TMP_DMG"

echo "==> Done: $DMG"
