#!/bin/bash
# Builds "AI Sound Design Installer.app" and the ZIP to attach to a GitHub release:
#
#   bash macos/build.sh [version]      # default: the VERSION file
#
# A release does this on GitHub (.github/workflows/release-macos.yml): push a tag v<version>
# and the ZIP is attached to the release; no Mac needed for that.
# Locally it needs a Mac with Apple's command line tools (swiftc); no Xcode project. The
# result, in macos/build/:
#   AI Sound Design Installer.app
#   AI-Sound-Design-Installer-macOS.zip   (what users download)
#
# The app is signed ad hoc only (no Apple developer account): the first time, macOS
# refuses to open it; System Settings > Privacy & Security > "Open Anyway".
# The app needs no new release when the services, the web UI or the plugin change: it
# fetches them from GitHub. A release is due when Installer.swift, install-components.sh
# or askpass.sh change; installed copies then offer to update themselves.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${1:-$(tr -d ' \n' < "$HERE/../VERSION")}"
VERSION="${VERSION#v}"
OUT="$HERE/build"
NAME="AI Sound Design Installer"
APP="$OUT/$NAME.app"

rm -rf "$APP" "$OUT/icon"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT/icon/AppIcon.iconset"

echo "== compiling"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14 \
    -o "$APP/Contents/MacOS/$NAME" "$HERE/Installer.swift"

echo "== icon"
swift "$HERE/make-icon.swift" "$OUT/icon/icon.png"
for px in 16 32 128 256 512; do
    sips -z $px $px "$OUT/icon/icon.png" --out "$OUT/icon/AppIcon.iconset/icon_${px}x${px}.png" >/dev/null
    sips -z $((px * 2)) $((px * 2)) "$OUT/icon/icon.png" --out "$OUT/icon/AppIcon.iconset/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$OUT/icon/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$OUT/icon"

echo "== resources"
cp "$HERE/install-components.sh" "$HERE/askpass.sh" "$APP/Contents/Resources/"
chmod 755 "$APP/Contents/Resources/"*.sh
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>$NAME</string>
    <key>CFBundleDisplayName</key>          <string>$NAME</string>
    <key>CFBundleExecutable</key>           <string>$NAME</string>
    <key>CFBundleIdentifier</key>           <string>com.ai-sound-design.installer</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>$VERSION</string>
    <key>CFBundleVersion</key>              <string>$VERSION</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>       <string>14.0</string>
    <key>LSArchitecturePriority</key>       <array><string>arm64</string></array>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>NSPrincipalClass</key>             <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "== signing (ad hoc)"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "== zip"
rm -f "$OUT/AI-Sound-Design-Installer-macOS.zip"
ditto -c -k --keepParent "$APP" "$OUT/AI-Sound-Design-Installer-macOS.zip"
echo "$APP"
echo "$OUT/AI-Sound-Design-Installer-macOS.zip"
