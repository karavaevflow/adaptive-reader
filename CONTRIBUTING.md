# Contributing

Use macOS 15+ and full Xcode with its command-line tools selected. Read the README, stable reader contracts and release gates before changing a feature. Work on a branch and keep unrelated changes separate.

```sh
swift test --no-parallel
xcodebuild -project AdaptiveReader.xcodeproj -scheme AdaptiveReader -destination 'platform=macOS' build-for-testing
xcodebuild -project AdaptiveReader.xcodeproj -scheme AdaptiveReader -destination 'platform=macOS' test
```

Core tests are serialized because PDFKit, WebKit and local Vision share native framework state. UI tests manipulate windows; their development launchers silence speech. Production-package tests run only on a disposable GitHub runner and invoke no speech or model action. The 25-minute stability job runs on the public-stable branch. Never bypass macOS automation/security permissions on a contributor's computer.

Preserve PDF/EPUB SourceAnchor semantics and typed commands. Keep original sources, user records and derived caches separate. A schema change needs a previous-version fixture and migration test. Do not discard unfamiliar future-version data. The frozen upgrade corpus under Research/Upgrade uses artificial notes and source fixtures, with writer-source fingerprints.

For UI changes, use Adaptive components, RU/EN strings and compact/wide Light/Dark references. Review keyboard access, focus return, VoiceOver descriptions, Reduce Motion and Reduce Transparency. Do not infer real-model quality from fixture-provider tests.

Before a PR, inspect the diff, run relevant checks and describe the behavior, evidence and limits. Do not commit credentials, private books, generated build directories or local archives. MIT covers code; retain third-party fixture notices and dependency licenses. See SECURITY.md for private reports and PRIVACY.md for data boundaries.
