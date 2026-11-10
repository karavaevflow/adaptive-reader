# Foundation accessibility review

Reviewed on 2026-11-10, macOS 15.8.2, Xcode 26.3, MacBookAir10,1. The standard contrast audit reports failures directly; no ignored contrast exceptions are used. Named controls and selected library rows are also checked independently.

## VoiceOver

VoiceOver was enabled on the control Mac. Native XCTest kept Reader active while reviewing the actual speech caption panel, avoiding focus changes caused by the computer-control window-sharing session. Observed reading order: Appearance heading, Appearance radio group, System (1 of 3), Light (selected, 2 of 3). The caption explicitly announced the selected state. Sidebar visibility was announced as Shown. After the focus fix, the native keyboard ring and VoiceOver cursor returned to the Appearance command after dismissal.

The review used the public [VoiceOver orientation commands](https://support.apple.com/guide/voiceover/orientation-commands-cpvokys03/mac) for cursor/focus descriptions. Full-desktop diagnostic captures remain in temporary local xcresult bundles and are excluded from the repository because they may include unrelated windows.

## Keyboard and reduced effects

The opt-in `testReducedAccessibilityAndFocus` passed with actual Reduce Motion and Reduce Transparency settings enabled. It asserts both NSWorkspace settings, opens/closes the inspector, checks the opaque layout, dismisses Appearance, waits for the actual native keyboard-focus state, and activates that same command with Space. Waiting for content disappearance alone is insufficient because native popover dismissal and key-window restoration finish separately.

System keyboard navigation was enabled for that review. The implementation uses explicit SwiftUI focusable controls, standard Space activation, Escape handling and a public AppKit focus bridge after the parent window becomes key. It has no fixed focus-restoration delay. Wide panels use the Adaptive motion token; Reduce Motion supplies no transition animation. Compact panels retain native presentation.

Reproduce the reduced-effects review after enabling those settings and Keyboard navigation:

```sh
xcodebuild -project AdaptiveReader.xcodeproj -scheme AdaptiveReader \
  -destination 'platform=macOS,arch=arm64' \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG ACCESSIBILITY_REVIEW' \
  -only-testing:AdaptiveReaderUITests/LaunchTests/testReducedAccessibilityAndFocus test
```

The opt-in `VOICEOVER_REVIEW` flag enables the native focus/caption capture review when VoiceOver is already on. These machine-specific tests are skipped in ordinary CI; their control-Mac results supplement the repeatable functional suite and visual matrix.

## Restored preferences

VoiceOver, Reduce Motion, Reduce Transparency and Keyboard navigation were all restored to their original Off values. VoiceOver's Speak instructions preference was restored to its original On value. Caption-panel visibility and hint delay were not changed. Screen Recording permission was already granted when the authorized preflight ran; no new permission was required.
