#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
PROJECT="$ROOT/MacDynamicIsland.xcodeproj"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/LedgeSecurityCheck.XXXXXX")"

cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

run_tests() {
  local name="$1"
  shift
  local derived_data="$WORK/$name"
  mkdir -p "$derived_data/ProfileData"

  LLVM_PROFILE_FILE="$derived_data/ProfileData/%p.profraw" xcodebuild \
    -quiet \
    -project "$PROJECT" \
    -scheme Ledge \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    ENABLE_CODE_COVERAGE=NO \
    CODE_SIGNING_ALLOWED=NO \
    "$@" \
    test
}

xcodebuild \
  -quiet \
  analyze \
  -project "$PROJECT" \
  -scheme Ledge \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$WORK/Analyze" \
  CODE_SIGNING_ALLOWED=NO

run_tests MemorySafety \
  ENABLE_ADDRESS_SANITIZER=YES \
  ENABLE_UNDEFINED_BEHAVIOR_SANITIZER=YES

run_tests ThreadSafety \
  ENABLE_THREAD_SANITIZER=YES

echo "Security checks passed: static analysis, ASan, UBSan, and TSan."
