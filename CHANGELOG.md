# Changelog

## 1.0.0-rc.2 — 2026-11-20

Fix repeated/stale PDF page images in selected palettes and incorrect Original fallback by moving page cache/eligibility state out of PDFKit-created page subclasses. Fix Next/Previous in two-page modes across Reader, Mini Reader and Split, including separate-cover layouts and end bounds. Adds native page-pixel and spread-navigation regressions. Existing source files and library schemas are preserved.

## 1.0.0-rc.1 — 2026-11-17

Release-candidate validation for the existing PDF/EPUB reading workspace. Adds native library backup/restore with integrity validation, an empty-library guard and retained recovery folder; frozen-library upgrade checks, installed production-package acceptance, repeat long-session checks, verified package metadata/licenses and public contribution/privacy/security documentation. The candidate is not yet declared v1.0 stable; the acceptance report records open platform/accessibility checks.

The candidate retains independent Split Reading, source-aligned reader translations/vocabulary, local page OCR with confidence/source links, optional Replay/Insights, Study/Recall/local speech, Knowledge boards/search and the opt-in AI integration. No model is installed or enabled by this update. Bilingual translations are reader-authored; arbitrary editions are not automatically aligned.

Archives are universal arm64/x86_64, require macOS 15+, and use a local ad-hoc signature. No Developer ID or notarization is claimed.

## 0.6.0 — 2026-11-16

Independent PDF/EPUB split engines, saved second position, reader translations/vocabulary, local cancellable Vision OCR and revision-keyed scan search, separately opt-in Replay/Insights. Fixed primary-anchor preservation when entering Split, adaptive panel access and native Knowledge drawing on virtual GPUs. See docs/v0.6.md for pinned-source acceptance.

## 0.5.0

Connected knowledge: source-linked Memory cards, Canvas relations, cross-book search, Timeline and editable reading paths. See docs/v0.5.md.

## 0.4.0

EPUB reflow, notes, persistent highlights, cards/Recall, portable exports and local Listen & Read. See docs/v0.4.md.

## 0.3.0

Optional grounded AI provider integration and reviewed reader actions. Real-model evaluation deferred by the owner. See docs/v0.3.md.

## 0.2.0

Daily reading controls, Smart Back, scheduled appearance, Spotlight, sessions, Mini Reader and Command Center. See docs/v0.2.md.

## 0.1.0 / Foundation

Offline PDF library, managed/linked imports, page palettes, bookmarks, Focus and Keep Awake; native Adaptive shell and shared source anchors. See docs/phase-0.md and docs/v0.1.md.
