#!/bin/bash
# Builds Starlight.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"

# llama.cpp, pinned and checksum-verified (SwiftPM's binary cache can't unpack this release's layout).
LLAMA_TAG=b11577
LLAMA_SHA=8b2af91c7a1ffe2b3635ed5241bc30f216e64fa6abc15a6f2cbd2ccaaf8813c0
if [ ! -d Vendor/llama.xcframework ]; then
  mkdir -p Vendor
  curl -sSL -o Vendor/llama.zip "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_TAG/llama-$LLAMA_TAG-xcframework.zip"
  echo "$LLAMA_SHA  Vendor/llama.zip" | shasum -a 256 -c - >/dev/null
  unzip -q Vendor/llama.zip -d Vendor/unzip && mv Vendor/unzip/build-apple/llama.xcframework Vendor/ && rm -rf Vendor/unzip Vendor/llama.zip
fi

mkdir -p .build # a fresh clone has none yet, and the log goes there
# Clerk's string catalog needs Xcode's xcstringstool; with only the command line tools, a small
# stand-in (scripts/xcstringstool) does the same for it. Both PATH and the package folder, since
# the build looks in each.
if ! xcrun --find xcstringstool >/dev/null 2>&1; then
  export PATH="$PWD/scripts:$PATH"
  cp -f scripts/xcstringstool xcstringstool && chmod +x xcstringstool
fi
if ! swift build -c release --arch arm64 > .build/last-build.log 2>&1; then
  grep -E "error:" .build/last-build.log | sort -u
  echo "build failed (full log: .build/last-build.log)"
  exit 1
fi
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

APP=Starlight.app
rm -rf "$APP" Notch.app  # Notch.app: what builds were called before the rename
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/Starlight" "$APP/Contents/MacOS/Starlight"
cp -R "$BIN/llama.framework" "$APP/Contents/Frameworks/"
cp -R "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/"
cp -R "$BIN"/*.bundle "$APP/Contents/Resources/" 2>/dev/null || true
# The version being worked on (VERSION, raised when a release goes out), so a development build
# is never older than a release copy on the same Mac: macOS opens the newest copy it knows
# when it reopens the app by its ID (Quit & Reopen after a permission, `open -b`).
VERSION="${STARLIGHT_VERSION:-$(cat VERSION 2>/dev/null || echo 1.0)}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
# Updates: where the appcast lives, and the public half of the key updates are signed with.
FEED_URL="${STARLIGHT_FEED_URL:-}"
# Accounts (Clerk sign-in, the plan from Convex) and the answer service; empty leaves accounts off.
# Defaults come from account.env, production (not secret: a publishable key and public URLs);
# STARLIGHT_ENV=dev uses account.dev.env instead (test keys, the dev backend, the local website).
ACCOUNT_ENV=account.env
# (NOTCH_ENV=dev, its name before the rename, still works.)
[ "${STARLIGHT_ENV:-${NOTCH_ENV:-}}" = dev ] && ACCOUNT_ENV=account.dev.env
[ -f "$ACCOUNT_ENV" ] && . "./$ACCOUNT_ENV"
CLERK_PUBLISHABLE_KEY="${STARLIGHT_CLERK_PUBLISHABLE_KEY:-}"
CONVEX_URL="${STARLIGHT_CONVEX_URL:-}"
WEBSITE_URL="${STARLIGHT_WEBSITE_URL:-}"
SERVICE_URL="${STARLIGHT_SERVICE_URL:-}"
PUBLIC_KEY="$(cat Resources/SparklePublicKey.txt 2>/dev/null || true)"
# Development builds keep the test settings (STARLIGHT_*) and command-line tools (Sources/Dev.swift);
# releases, which set STARLIGHT_SIGN_IDENTITY, leave them out.
DEV_TOOLS="<key>StarlightDevTools</key><true/>"
[ -n "${STARLIGHT_SIGN_IDENTITY:-}" ] && DEV_TOOLS=""
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/GoldenGate.jpg "$APP/Contents/Resources/"  # Settings' text size preview (CC0, Bernard Spragg)
cp -R Resources/Licenses "$APP/Contents/Resources/"
cp docs/legal/PRIVACY.md "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.starlightnotch.app</string>
  <key>CFBundleName</key><string>Starlight</string>
  <key>CFBundleExecutable</key><string>Starlight</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleDisplayName</key><string>Starlight</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Starlight</string>
  <key>LSMinimumSystemVersion</key><string>14.4</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$PUBLIC_KEY</string>
  <key>StarlightClerkPublishableKey</key><string>$CLERK_PUBLISHABLE_KEY</string>
  <key>StarlightConvexURL</key><string>$CONVEX_URL</string>
  <key>StarlightWebsiteURL</key><string>$WEBSITE_URL</string>
  <key>StarlightServiceURL</key><string>$SERVICE_URL</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
  <key>NSMicrophoneUsageDescription</key><string>Starlight hears you when you dictate, ask, talk with it or take meeting notes. Your voice is turned into text on your Mac.</string>
  <key>NSAppleEventsUsageDescription</key><string>Starlight shows what Spotify, Music or your browser is playing, and does the things you ask in other apps.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Starlight shows your headphones' battery when they connect, and turns Bluetooth on or off when you ask.</string>
  <key>NSAudioCaptureUsageDescription</key><string>During notes, Starlight transcribes the other people in your meeting from your Mac's audio.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>When you ask, Starlight adds reminders to Reminders.</string>
  <key>NSRemindersUsageDescription</key><string>When you ask, Starlight adds reminders to Reminders.</string>
  $DEV_TOOLS
</dict></plist>
PLIST

# Sign with a stable identity when there is one, so macOS keeps the microphone and speech
# permissions across rebuilds. Ad-hoc signatures change every build and re-prompt.
# Releases sign with your Developer ID (scripts/release.sh sets STARLIGHT_SIGN_IDENTITY).
# Development builds use the Developer ID too when it's in the Keychain: macOS then sees every
# rebuild as the same app, so Keychain items (your API key) and permissions don't ask again.
DEVELOPER_ID="$(security find-identity -p codesigning -v 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
SELF_SIGNED="Starlight Dev"
security find-identity -p codesigning 2>/dev/null | grep -q '"Starlight Dev' || SELF_SIGNED="Notch Dev"  # its name before the rename
IDENTITY="${STARLIGHT_SIGN_IDENTITY:-${DEVELOPER_ID:-$SELF_SIGNED}}"
# Self-signed identities count too: codesign doesn't need them trusted, only present.
if ! security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY"; then IDENTITY=-; fi
# Releases: notarization needs the hardened runtime on every executable, and a secure timestamp.
# Only with a Developer ID: the runtime's library check needs a Team ID, which a self-signed
# identity doesn't have, so the bundled llama.framework wouldn't load in a development build.
SIGN=(codesign --force --sign "$IDENTITY")
# The secure timestamp (a round trip to Apple) only for releases, which set STARLIGHT_SIGN_IDENTITY.
if [[ "$IDENTITY" == "Developer ID Application"* ]]; then
  SIGN+=(--options runtime); if [[ -n "${STARLIGHT_SIGN_IDENTITY:-}" ]]; then SIGN+=(--timestamp); else SIGN+=(--timestamp=none); fi
else SIGN+=(--timestamp=none); fi
# Inside out, the way Sparkle documents it (--deep re-signs its helpers wrongly).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SPARKLE/XPCServices/Installer.xpc" >/dev/null
"${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc" >/dev/null
"${SIGN[@]}" "$SPARKLE/Autoupdate" >/dev/null
"${SIGN[@]}" "$SPARKLE/Updater.app" >/dev/null
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework" >/dev/null
"${SIGN[@]}" "$APP/Contents/Frameworks/llama.framework" >/dev/null
"${SIGN[@]}" --entitlements Resources/Starlight.entitlements "$APP" >/dev/null
# Tell macOS about this build now, so reopening the app by its ID finds it.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true
echo "Built $(pwd)/$APP"
