#!/bin/bash
set -euo pipefail
project_dir=$(cd "$(dirname "$0")/.." && pwd)
build_dir="$project_dir/build"
app_dir="$build_dir/SleepDock.app"
cache_dir="$project_dir/.build/module-cache"
sdk=$(/bin/bash "$project_dir/scripts/select-sdk.sh")
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$cache_dir"
/usr/bin/swiftc -sdk "$sdk" -target arm64-apple-macosx14.0 -swift-version 5 -O -whole-module-optimization \
    -module-cache-path "$cache_dir" \
    "$project_dir"/Sources/*.swift -o "$app_dir/Contents/MacOS/SleepDock" \
    -framework AppKit -framework SwiftUI -framework IOKit -framework ServiceManagement -lsqlite3
cp "$project_dir/Resources/lid-watchdog.sh" "$project_dir/Resources/sleepdock-run" "$project_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/"
cp "$project_dir/使用说明.md" "$project_dir/验证记录.md" "$app_dir/Contents/Resources/"
cp "$project_dir/../LICENSE" "$project_dir/../THIRD_PARTY_NOTICES.md" "$app_dir/Contents/Resources/"
chmod 755 "$app_dir/Contents/Resources/sleepdock-run" "$app_dir/Contents/Resources/lid-watchdog.sh"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SleepDock</string>
<key>CFBundleIdentifier</key><string>dev.phecda.SleepDock</string>
<key>CFBundleName</key><string>SleepDock</string>
<key>CFBundleDisplayName</key><string>SleepDock</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleShortVersionString</key><string>1.1.1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$app_dir"
/usr/bin/codesign --verify --deep --strict "$app_dir"
printf 'Built: %s\n' "$app_dir"
