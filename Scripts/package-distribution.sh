#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: ${0:t} /path/to/Ledge.app [output-directory]" >&2
  exit 64
fi

ROOT="${0:A:h:h}"
APP="${1:A}"
OUTPUT_DIRECTORY="${2:-$ROOT/dist}"
OUTPUT_DIRECTORY="${OUTPUT_DIRECTORY:A}"

"$ROOT/Scripts/verify-distribution.sh" "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
[[ -n "$VERSION" && -n "$BUILD" ]] || {
  echo "Packaging failed: version metadata is missing." >&2
  exit 1
}

mkdir -p "$OUTPUT_DIRECTORY"
ARCHIVE="$OUTPUT_DIRECTORY/Ledge-$VERSION-$BUILD-macOS.zip"
CHECKSUM="$ARCHIVE.sha256"
[[ ! -e "$ARCHIVE" && ! -e "$CHECKSUM" ]] || {
  echo "Packaging failed: output already exists: $ARCHIVE" >&2
  exit 1
}

ditto -c -k --keepParent --sequesterRsrc "$APP" "$ARCHIVE"

EXTRACTED="$(mktemp -d "${TMPDIR:-/tmp}/LedgePackageVerify.XXXXXX")"
cleanup() {
  rm -rf "$EXTRACTED"
}
trap cleanup EXIT
ditto -x -k "$ARCHIVE" "$EXTRACTED"
codesign --verify --deep --strict --verbose=2 "$EXTRACTED/Ledge.app"

DIGEST="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
echo "$DIGEST  ${ARCHIVE:t}" > "$CHECKSUM"

echo "Distribution package created: $ARCHIVE"
echo "SHA-256: $DIGEST"
