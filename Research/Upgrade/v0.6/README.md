# Frozen v0.6 upgrade library

Artificial reader data generated through the exact ReaderCore writer source from accepted application commit `d42b72bb7dfea8e6ec1b8ee1ded79d41a3973e7a`. Before generation every ReaderCore Swift file was byte-compared with `git show` of that revision. `manifest.json` records all writer/source and output checksums; `expected.json` records the decoded counts. ReleaseValidation is an engineering harness, not an app storage schema.

Includes two managed fixture books (PDF/EPUB), positions/palettes/favorites/bookmarks, RU notes, study cards/highlights/listening locators, a two-source Knowledge board/edge/path, translations/vocabulary, a saved split position and explicitly enabled history/statistics. There are no secrets, access bookmarks, private books, real AI answers or disposable caches. Data comes from the repository's original fixture corpus.

Tests reopen a copy with current production readers, check values and byte preservation, then make one note edit and verify neighboring domains are unchanged. Separate cases exercise schema-1/2 Book metadata and future-version rejection without reset. The installed-Release test appends these records to an otherwise disposable CI library without replacing its newly imported book.

Do not regenerate this directory when changing the schema. Add a new dated/versioned corpus. The seed command refuses an existing destination. Reproduction requires the recorded writer source; current writer changes must not be mislabeled as old-version output.

`Library.zip` is a new version-1 backup-codec wrapper around the unchanged v0.6 payload. It was not produced by an old v0.6 backup feature. Every payload checksum was compared with manifest.json after wrapping. The production UI uses its native Restore action; no test process writes into the protected production container.
