#!/bin/sh
set -eu
# Release import-to-visible-window protocol, five independent sandbox sessions.
caffeinate -di xcodebuild -project AdaptiveReader.xcodeproj -scheme AdaptiveReader \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/adaptive-v01-ui-benchmark \
  -resultBundlePath "${1:-/private/tmp/adaptive-v01-ui-benchmark.xcresult}" \
  ADAPTIVE_TEST_BUNDLE_SUFFIX=.UITesting SWIFT_ACTIVE_COMPILATION_CONDITIONS=FOUNDATION_BENCHMARK \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 240 \
  -only-testing:AdaptiveReaderUITests/OfflineReaderTests/testLargeDocumentReleaseMeasurements test
