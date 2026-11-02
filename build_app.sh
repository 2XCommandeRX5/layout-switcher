#!/bin/zsh
# Сборка LayoutSwitcher.app из LayoutSwitcher.swift
set -e
cd "$(dirname "$0")"

APP=LayoutSwitcher.app
BIN=LayoutSwitcher

swiftc -O LayoutSwitcher.swift -o "$BIN"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/LayoutSwitcher"

# Иконка: если icon_1024.png ещё нет — сгенерировать, затем собрать AppIcon.icns.
if [ ! -f icon_1024.png ]; then
    swiftc -O make_icon.swift -o make_icon
    ./make_icon icon_1024.png
fi
ICONSET=AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.stefania.layoutswitcher</string>
    <key>CFBundleName</key>
    <string>LayoutSwitcher</string>
    <key>CFBundleDisplayName</key>
    <string>LayoutSwitcher</string>
    <key>CFBundleExecutable</key>
    <string>LayoutSwitcher</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

# ad-hoc подпись: свой идентификатор приложения
codesign --force --sign - --identifier com.stefania.layoutswitcher "$APP" 2>/dev/null

echo "OK: $APP"
