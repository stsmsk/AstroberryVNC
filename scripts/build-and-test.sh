#!/usr/bin/env bash
# Astroberry VNC: SwiftPM tests + Intel Release build + artifact verification.
# Runs on a Mac with Xcode. Does not install or overwrite an existing app.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  echo "Usage: ./scripts/build-and-test.sh [--test-only|--build-only]"
}

run_tests=true
run_build=true
case "${1:-}" in
  "") ;;
  --test-only) run_build=false ;;
  --build-only) run_tests=false ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
if (( $# > 1 )); then usage >&2; exit 2; fi

BUILD_NUMBER="$(plutil -extract CFBundleVersion raw -o - AstroberryVNC/Info.plist)"
if [[ -z "$BUILD_NUMBER" ]]; then
  echo "Cannot read CFBundleVersion from AstroberryVNC/Info.plist" >&2
  exit 1
fi
OUT="$PWD/.build/Build${BUILD_NUMBER}DerivedData"
mkdir -p "$OUT"
echo "Astroberry VNC build ${BUILD_NUMBER} (Intel x86_64)"

if "$run_tests"; then
  echo '[1/3] SwiftPM unit tests'
  if ! swift test > "$OUT/swift-test.log" 2>&1; then
    tail -n 80 "$OUT/swift-test.log" >&2
    exit 1
  fi
  grep -E 'Executed [0-9]+ tests, with 0 failures|Test Suite .All tests. passed' "$OUT/swift-test.log" | tail -n 4 || true
else
  echo '[1/3] Unit tests skipped (--build-only)'
fi

if "$run_build"; then
  echo '[2/3] Intel x86_64 Xcode Release build (unsigned)'
  if ! xcodebuild -project AstroberryVNC.xcodeproj \
      -scheme AstroberryVNC -configuration Release \
      -destination 'generic/platform=macOS' \
      -derivedDataPath "$OUT" ARCHS=x86_64 CODE_SIGNING_ALLOWED=NO build \
      > "$OUT/release-build.log" 2>&1; then
    grep -n 'error:' "$OUT/release-build.log" | head -n 20 >&2 || true
    tail -n 80 "$OUT/release-build.log" >&2
    exit 1
  fi
  grep -F '** BUILD SUCCEEDED **' "$OUT/release-build.log"

  echo '[3/3] Verify app, architecture and build number'
  APP="$OUT/Build/Products/Release/Astroberry VNC.app"
  EXEC="$APP/Contents/MacOS/Astroberry VNC"
  test -d "$APP" && test -f "$EXEC"
  file "$EXEC"
  ARCHS="$(lipo -archs "$EXEC")"
  if [[ "$ARCHS" != 'x86_64' ]]; then
    echo "Unexpected architectures: $ARCHS (expected only x86_64)" >&2
    exit 1
  fi
  ACTUAL_BUILD="$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")"
  if [[ "$ACTUAL_BUILD" != "$BUILD_NUMBER" ]]; then
    echo "Build number mismatch: expected $BUILD_NUMBER, got $ACTUAL_BUILD" >&2
    exit 1
  fi
  echo "Verification passed: build $ACTUAL_BUILD, arch $ARCHS"
  echo "Build output (NOT installed): $APP"
else
  echo '[2/3] Release build skipped (--test-only)'
  echo '[3/3] Artifact verification skipped (--test-only)'
fi

echo 'Completed successfully.'
