#!/bin/sh
set -eu
# Optimized app and runner; fixtures are enabled only in this benchmark build.
xcodebuild -project AdaptiveReader.xcodeproj -scheme AdaptiveReader \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/adaptive-foundation-benchmark \
  -resultBundlePath "${1:-/private/tmp/adaptive-foundation-benchmark.xcresult}" \
  ADAPTIVE_TEST_BUNDLE_SUFFIX=.UITesting SWIFT_ACTIVE_COMPILATION_CONDITIONS=FOUNDATION_BENCHMARK \
  -only-testing:AdaptiveReaderUITests/LaunchTests/testPhase0ReleaseMeasurements test
