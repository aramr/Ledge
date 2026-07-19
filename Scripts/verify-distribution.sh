#!/bin/zsh

set -euo pipefail

fail() {
  echo "Distribution verification failed: $1" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  echo "Usage: ${0:t} /path/to/Ledge.app" >&2
  exit 64
fi

APP="${1:A}"
[[ -d "$APP" && "$APP" == *.app ]] || fail "expected an app bundle."
[[ -f "$APP/Contents/MacOS/Ledge" ]] || fail "the Ledge executable is missing."

for resource in \
  Info.plist \
  Resources/PrivacyInfo.xcprivacy \
  Resources/PRIVACY.md \
  Resources/THIRD_PARTY_NOTICES.md; do
  [[ -f "$APP/Contents/$resource" ]] || fail "missing $resource."
done

plutil -lint \
  "$APP/Contents/Info.plist" \
  "$APP/Contents/Resources/PrivacyInfo.xcprivacy" >/dev/null

ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/Ledge")"
[[ " $ARCHITECTURES " == *" arm64 "* ]] || fail "arm64 architecture is missing."
[[ " $ARCHITECTURES " == *" x86_64 "* ]] || fail "x86_64 architecture is missing."

codesign --verify --deep --strict --verbose=2 "$APP"
SIGNATURE_INFO="$(codesign --display --verbose=4 "$APP" 2>&1)"
[[ "$SIGNATURE_INFO" == *"Authority=Developer ID Application:"* ]] || \
  fail "the app is not signed with Developer ID Application."
[[ "$SIGNATURE_INFO" == *"flags="*"runtime"* ]] || \
  fail "Hardened Runtime is not enabled."
[[ "$SIGNATURE_INFO" == *"TeamIdentifier="* ]] || \
  fail "the signature has no team identifier."
[[ "$SIGNATURE_INFO" != *"TeamIdentifier=not set"* ]] || \
  fail "the signature has no valid team identifier."

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

echo "Distribution verification passed."
echo "SHA-256: $(shasum -a 256 "$APP/Contents/MacOS/Ledge" | awk '{print $1}') (Ledge executable)"
