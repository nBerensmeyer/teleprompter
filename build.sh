#!/bin/zsh
# Builds Teleprompter.app and installs it to ~/Applications
set -e
cd "$(dirname "$0")"
APP=build/Teleprompter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -Osize -swift-version 5 -Xlinker -dead_strip Teleprompter.swift -o "$APP/Contents/MacOS/Teleprompter"
strip -x "$APP/Contents/MacOS/Teleprompter"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Teleprompter</string>
  <key>CFBundleIdentifier</key><string>local.teleprompter</string>
  <key>CFBundleExecutable</key><string>Teleprompter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
codesign --force -s - "$APP" >/dev/null 2>&1 || true
mkdir -p ~/Applications
rm -rf ~/Applications/Teleprompter.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/Teleprompter.app"
