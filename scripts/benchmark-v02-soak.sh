#!/bin/sh
set -eu
# Real elapsed 25-minute session; keep the control Mac available to XCTest.
caffeinate -di xcodebuild -project AdaptiveReader.xcodeproj -scheme AdaptiveReader \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/adaptive-v02-soak \
  -resultBundlePath "${1:-/private/tmp/adaptive-v02-soak.xcresult}" \
  ADAPTIVE_TEST_BUNDLE_SUFFIX=.UITesting \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=FOUNDATION_BENCHMARK COMFORT_SOAK' \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 1800 \
  -only-testing:AdaptiveReaderUITests/OfflineReaderTests/testComfortTwentyFiveMinuteReleaseSession test
