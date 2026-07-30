#!/bin/zsh

set -euo pipefail

fail() {
  echo "Distribution verification failed: $1" >&2
  exit 1
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: ${0:t} /path/to/Ledge.app [/path/to/Ledge.dmg]" >&2
  exit 64
fi

APP="${1:A}"
DMG="${2:-}"
EXPECTED_TEAM_ID="${APPLE_TEAM_ID:-M7PFX75L8L}"

[[ -d "$APP" && "$APP" == *.app ]] || fail "expected a Ledge app bundle."
[[ -f "$APP/Contents/MacOS/Ledge" ]] || fail "the main executable is missing."
[[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]] || fail "Sparkle.framework is missing."

plutil -lint \
  "$APP/Contents/Info.plist" \
  "$APP/Contents/Resources/PrivacyInfo.xcprivacy" >/dev/null

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == "com.aramrahimi.Ledge" ]] || \
  fail "the production bundle identifier is incorrect."
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")" ]] || \
  fail "the Sparkle public key is missing."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist")" == https://github.com/aramr/Ledge/releases/latest/download/appcast.xml ]] || \
  fail "the Sparkle feed URL is incorrect."

ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/Ledge")"
[[ " $ARCHITECTURES " == *" arm64 "* ]] || fail "arm64 architecture is missing."
[[ " $ARCHITECTURES " == *" x86_64 "* ]] || fail "x86_64 architecture is missing."

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
SIGNED_COMPONENTS=(
  "$SPARKLE/XPCServices/Installer.xpc"
  "$SPARKLE/XPCServices/Downloader.xpc"
  "$SPARKLE/Autoupdate"
  "$SPARKLE/Updater.app"
  "$APP/Contents/Frameworks/Sparkle.framework"
  "$APP"
)

for component in "${SIGNED_COMPONENTS[@]}"; do
  [[ -e "$component" ]] || fail "signed component is missing: $component"
  codesign --verify --strict --verbose=2 "$component"
  SIGNATURE_INFO="$(codesign --display --verbose=4 "$component" 2>&1)"
  [[ "$SIGNATURE_INFO" == *"Authority=Developer ID Application:"* ]] || \
    fail "$component is not signed with Developer ID Application."
  [[ "$SIGNATURE_INFO" == *"Timestamp="* ]] || \
    fail "$component does not include a secure timestamp."
  [[ "$SIGNATURE_INFO" == *"flags="*"runtime"* ]] || \
    fail "Hardened Runtime is not enabled for $component."
  [[ "$SIGNATURE_INFO" == *"TeamIdentifier=$EXPECTED_TEAM_ID"* ]] || \
    fail "$component is signed by an unexpected team."
done

codesign --verify --deep --strict --verbose=2 "$APP"

ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/LedgeEntitlements.XXXXXX")"
cleanup() {
  rm -f "$ENTITLEMENTS"
}
trap cleanup EXIT
codesign --display --entitlements :- "$APP" > "$ENTITLEMENTS" 2>/dev/null
plutil -lint "$ENTITLEMENTS" >/dev/null

for entitlement in \
  com.apple.security.automation.apple-events \
  com.apple.security.device.audio-input \
  com.apple.security.personal-information.calendars; do
  [[ "$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$ENTITLEMENTS" 2>/dev/null)" == "true" ]] || \
    fail "required entitlement $entitlement is missing."
done

for entitlement in \
  com.apple.security.get-task-allow \
  com.apple.security.cs.disable-library-validation \
  com.apple.security.cs.allow-unsigned-executable-memory \
  com.apple.security.cs.allow-jit \
  com.apple.security.cs.debugger; do
  if /usr/libexec/PlistBuddy -c "Print :$entitlement" "$ENTITLEMENTS" >/dev/null 2>&1; then
    fail "unsafe release entitlement $entitlement is present."
  fi
done

spctl --assess --type execute --verbose=4 "$APP"
xcrun stapler validate "$APP"

if [[ -n "$DMG" ]]; then
  DMG="${DMG:A}"
  [[ -f "$DMG" && "$DMG" == *.dmg ]] || fail "expected a disk image."
  codesign --verify --verbose=2 "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
  xcrun stapler validate "$DMG"
fi

echo "Distribution verification passed."
