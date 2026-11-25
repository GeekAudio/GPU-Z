#!/bin/bash
set -euo pipefail
FIXTURE_TEST_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
FIXTURE_PROJECT_DIRECTORY="${FIXTURE_TEST_DIRECTORY%/Tests}"
FIXTURE_TEST_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/nvcodec-fixture-tests.XXXXXX")"
trap 'rm -rf "$FIXTURE_TEST_TEMP"' EXIT

FIXTURE_TEST_APP="$FIXTURE_TEST_TEMP/FixedDecodeFixtureTests.app"
mkdir -p "$FIXTURE_TEST_APP/Contents/MacOS" "$FIXTURE_TEST_APP/Contents/Resources/CodecFixtures"
cp "$FIXTURE_TEST_DIRECTORY/FixedDecodeFixtureTests.swift" "$FIXTURE_TEST_TEMP/main.swift"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos11.0" \
  "$FIXTURE_PROJECT_DIRECTORY/Sources/FixedDecodeFixture.swift" \
  "$FIXTURE_TEST_TEMP/main.swift" \
  -o "$FIXTURE_TEST_APP/Contents/MacOS/FixedDecodeFixtureTests" \
  -framework Foundation -framework CoreMedia

cat > "$FIXTURE_TEST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>FixedDecodeFixtureTests</string>
  <key>CFBundleIdentifier</key><string>com.geekaudio.FixedDecodeFixtureTests</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
cp "$FIXTURE_PROJECT_DIRECTORY/Resources/CodecFixtures/h264-1080p-120f.h264" \
  "$FIXTURE_TEST_APP/Contents/Resources/CodecFixtures/"
cp "$FIXTURE_PROJECT_DIRECTORY/Resources/CodecFixtures/hevc-1080p-120f.hevc" \
  "$FIXTURE_TEST_APP/Contents/Resources/CodecFixtures/"
cp "$FIXTURE_PROJECT_DIRECTORY/Resources/CodecFixtures/h264-4k-48f.h264" \
  "$FIXTURE_TEST_APP/Contents/Resources/CodecFixtures/"
cp "$FIXTURE_PROJECT_DIRECTORY/Resources/CodecFixtures/hevc-4k-48f.hevc" \
  "$FIXTURE_TEST_APP/Contents/Resources/CodecFixtures/"

"$FIXTURE_TEST_APP/Contents/MacOS/FixedDecodeFixtureTests" \
  "$FIXTURE_PROJECT_DIRECTORY/Resources/CodecFixtures/h264-1080p-120f.h264" \
  "$FIXTURE_PROJECT_DIRECTORY/Resources/CodecFixtures/hevc-1080p-120f.hevc" \
  "$FIXTURE_PROJECT_DIRECTORY/Resources/CodecFixtures/h264-4k-48f.h264" \
  "$FIXTURE_PROJECT_DIRECTORY/Resources/CodecFixtures/hevc-4k-48f.hevc"
