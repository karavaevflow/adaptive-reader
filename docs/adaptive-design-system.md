# Adaptive for macOS

The shell uses system typography, SF Symbols, the user's accent color and native controls. Page palettes remain part of ReaderCore and do not change when the shell appearance changes.

## Tokens

| Role | Light | Dark |
| --- | --- | --- |
| Background | #F5F5F3 | #17181B |
| Surface | #FFFFFF | #24262A |
| Primary text | #202124 | #E8E9EB |
| Secondary text | #666970 | #B0B3BA |
| Divider | #E5E5E3 | #383A3F |

Secondary colors were strengthened from the vision's proposed palette for small text. Calculated sRGB contrast is 14.75:1 for light primary text against background, 5.04:1 for light secondary text against background, 14.61:1 for dark primary text against background, and 7.22:1 for dark secondary text against surface. Native controls retain system rendering.

Spacing uses 8/12/16/24/32 pt, rounded surfaces use a 12 pt radius, and typography uses semantic system styles. Panel transitions use 220 ms ease-in-out. Reduce Motion disables panel transitions. Reduce Transparency selects an opaque panel surface.

## Components and layout

The More menu opens the component catalogue. It contains title/body/caption styles, search input, toggle, primary and disabled buttons, a selectable book-card preview and progress. Buttons retain native keyboard focus and press feedback. Preview cards expose selection to accessibility and provide hover feedback without changing their dimensions.

Library rows use native buttons and a 14% accent tint for selection, keeping text contrast stable when the list loses focus. Up/down commands move between rows. The 220 pt library sidebar displays inline at content widths of at least 1000 pt. Below that threshold its toolbar action opens a popover. The 260 pt document inspector displays inline from 1200 pt and opens as a sheet in narrower windows. Collapsing a panel for space does not overwrite its saved visibility preference.

The appearance popover and Settings use the same appearance preference. English and Russian translations are bundled with the Xcode application and follow the application's system language. The standalone SwiftPM preview is a development executable; visual acceptance uses the Xcode app bundle.

| Action | Shortcut |
| --- | --- |
| Open PDF | Command-O |
| Toggle library sidebar | Shift-Command-S |
| Appearance | Shift-Command-A |
| Document inspector | Shift-Command-I |
| Dismiss a popover or sheet | Escape |

## Verification

Run the shared scheme with `xcodebuild test`. `testVisualAcceptanceMatrix` attaches Library, Reader, appearance popover and inspector screenshots for en/ru, Light/Dark and requested widths of 800/1440 pt. The Reader specimen is generated in memory by a DEBUG/benchmark-only test flag. It is a layout fixture, separate from the Color Engine corpus. `testAccessibilityDescriptions` verifies accessible names for the main controls and library rows, then runs the XCTest contrast audit. `testWindowAndAppearancePopover` exercises toolbar and menu opening and Escape dismissal. Native keyboard input was separately checked for Shift-Command-A and Shift-Command-I through macOS computer control. XCTest keyboard synthesis did not reproduce those shortcuts with the active input source.

Screenshots are stored inside the `.xcresult` bundle and the CI test-results artifact. Export the complete application-only reference matrix with `python3 scripts/export-design-screenshots.py RESULT.xcresult docs/screenshots`. The exporter validates all 36 expected images before writing. It excludes diagnostic screen recordings and desktop captures.

The control-Mac VoiceOver speech/state, keyboard-focus return and reduced-effects reviews are recorded in [accessibility review](accessibility-review.md). All temporary settings were restored. Machine-specific review tests are opt-in; ordinary CI runs named-control and contrast checks alongside the complete reference matrix.

CI selects an available logical display mode of at least 1440 × 900 with CoreGraphics before UI tests. This step is intended for the disposable macOS runner. Reference windows are explicitly sized in DEBUG builds. The test opens a new window only when the app has not presented one itself.
