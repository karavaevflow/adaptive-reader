# Installed candidate references

Six application-window captures from the passed production-package test at source `ef968c8ca1fb7be9f6e7f0ad03e55189479b1590`, [CI 44144951311](https://github.com/karavaevflow/adaptive-reader/actions/runs/44144951311). All five jobs passed in this pinned-source run; the remaining stable-platform/accessibility gates are tracked in the parent acceptance report. These are actual installed Release app windows, with synthetic authored books and no storage override. English shell, system Light appearance, 1120×760 pt window; they supplement the inherited RU/EN × 800/1440 × Light/Dark matrices rather than replacing them.

All six were visually reviewed. The frozen PDF's page-2 position and 1.2 zoom are retained, including native horizontal panning in the narrower split pane; the screenshot is not a fit-to-width rendering promise. Notes/cards and EPUB content remain legible; the new import and restart retain the source passage. [Checksums/provenance](../../Research/v1.0/visual-references.json).

- [Empty production library](v1-release-clean-library.png).
- [Restored study card](v1-release-upgraded-study.png).
- [Restored PDF with independent EPUB](v1-release-upgraded-pdf-epub.png).
- [Reader after successful native backup export](v1-release-backup-export.png).
- [New offline PDF import](v1-release-offline-import.png).
- [Imported source reopened after quit](v1-release-restored.png).

## Long-session reference

[Mini Reader after the completed 25-minute session](v1-long-session-complete.png) is a separate reviewed capture from the optimized Release diagnostic test identity in the same final-source CI run. It shows page 55/600 after continuous scrolling; raw timer/driver/RSS data and post-close assertion scope are in the [long-session report](../../Research/v1.0/README.md). It is not a production-identity screenshot or a GPU/energy measurement.
