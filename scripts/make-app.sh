#!/bin/zsh
# 建置並打包成 MeetingCapture.app（選單列 app，不出現在 Dock）
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/MeetingCapture.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MeetingCapture "$APP/Contents/MacOS/"
# 本機預設值（模型、Python 路徑等）：config.local.json 不進 git，有才打包
if [ -f config.local.json ]; then
  mkdir -p "$APP/Contents/Resources"
  cp config.local.json "$APP/Contents/Resources/defaults.json"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>tw.local.meetingcapture</string>
  <key>CFBundleName</key><string>Meeting Capture</string>
  <key>CFBundleExecutable</key><string>MeetingCapture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>勾選「我在會議室現場」時錄下現場的人說話。</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>使用 macOS 內建語音辨識把會議錄音轉成文字。</string>
  <key>NSAppleEventsUsageDescription</key><string>檢查喇叭是否靜音、顯示完成通知。</string>
</dict></plist>
PLIST
# 用固定的本機憑證簽章：簽章條件不隨每次建置改變，螢幕錄音權限才不用每次重新授權。
# 沒有這張憑證（例如別台電腦）就退回臨時簽章，那樣每次重建都要重新授權。
IDENTITY="Meeting Capture Local Signing"
HASH=$(security find-identity -p codesigning | awk -v n="\"$IDENTITY\"" 'index($0, n) {print $2; exit}')
if [ -n "$HASH" ]; then
  codesign --force --sign "$HASH" --identifier tw.local.meetingcapture "$APP"
  echo "signed with $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "signed ad-hoc（沒有 $IDENTITY 憑證，每次重建都要重新授權螢幕錄音）"
fi
echo "built $APP"
