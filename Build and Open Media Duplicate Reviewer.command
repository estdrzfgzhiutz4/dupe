#!/bin/zsh
set -euo pipefail

HERE="${0:A:h}"
SOURCE="$HERE/MediaDuplicateReviewer.swift"
APP_ROOT="$HOME/Applications/Media Duplicate Reviewer.app"
CONTENTS="$APP_ROOT/Contents"
MACOS="$CONTENTS/MacOS"
EXECUTABLE="$MACOS/MediaDuplicateReviewer"
TEMP_EXECUTABLE="$MACOS/MediaDuplicateReviewer.building"

if [[ ! -f "$SOURCE" ]]; then
  echo "MediaDuplicateReviewer.swift must be in the same folder as this launcher." >&2
  exit 1
fi

if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
  echo "Apple Command Line Tools are not installed. Run: xcode-select --install" >&2
  exit 1
fi

/bin/mkdir -p "$MACOS" "$CONTENTS/Resources"

echo "Building native Media Duplicate Reviewer 2.6…"
SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
/bin/rm -f "$TEMP_EXECUTABLE"

/usr/bin/xcrun --sdk macosx swiftc \
  -parse-as-library \
  -swift-version 5 \
  -O \
  -target "$(uname -m)-apple-macos12.0" \
  -sdk "$SDK" \
  -framework SwiftUI \
  -framework AppKit \
  -framework QuickLookThumbnailing \
  -framework Vision \
  -framework AVFoundation \
  -framework ImageIO \
  -framework UniformTypeIdentifiers \
  -framework CryptoKit \
  "$SOURCE" \
  -o "$TEMP_EXECUTABLE"

/bin/mv "$TEMP_EXECUTABLE" "$EXECUTABLE"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Media Duplicate Reviewer</string>
  <key>CFBundleDisplayName</key><string>Media Duplicate Reviewer</string>
  <key>CFBundleIdentifier</key><string>local.media-duplicate-reviewer</string>
  <key>CFBundleVersion</key><string>2.6.0</string>
  <key>CFBundleShortVersionString</key><string>2.6.0</string>
  <key>CFBundleExecutable</key><string>MediaDuplicateReviewer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "Opening Media Duplicate Reviewer…"
/usr/bin/open "$APP_ROOT"
