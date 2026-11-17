# Privacy and local data

Ordinary PDF/EPUB reading, notes, study, OCR and local search require no account or model. The app includes no analytics, advertising or automatic library-upload service.

Managed books, positions, bookmarks, notes, study cards, highlights, Knowledge boards/paths and optional reading history are under the app's sandbox Application Support/AdaptiveReader directory. Managed imports copy a selected source; linked imports retain a read-only security-scoped bookmark. Source bytes are checked on reopen and are not rewritten. App preferences/window state also use the same application identity's macOS preferences. Derived indexes and OCR live separately under Cache.

Replay and Insights start disabled. Replay contains reading-action/source metadata, not screen recordings or raw questions. Insights estimates active visible reading time and explicit completions. Disable and clear controls are independent of translations and saved knowledge; cleared-generation writes cannot restore old records. There is no monitoring of activity outside Adaptive.

AI is off by default. A local Ollama mode contacts the service explicitly configured on the Mac. Cloud mode sends the question, relevant book titles and bounded selected/retrieved excerpts only after endpoint/model consent and an explicit question. Library comparisons may contain excerpts from multiple selected books. Provider retention/billing is controlled by that provider. Keys are stored in macOS Keychain, separately from library JSON. Opening a document, doing local search or recognizing a PDF page does not itself ask a model. Real-model quality remains a separate evaluation.

Vision OCR runs locally, one requested PDF page at a time. Confidence and source links expose uncertainty; OCR can be inaccurate. Speech starts only on an explicit Listen action and uses installed macOS voices. No microphone, camera or screen recording is needed for ordinary reading.

Study Markdown/cards and Knowledge JSON/Markdown exports can contain private text and source locations. Whole-folder backups can also contain linked-file access bookmarks and provider configuration. Treat them as private; API secrets remain in Keychain. GitHub CI uses only artificial records and redistributable fixtures. Public screenshots never intentionally include a user's library.

To back up, quit Adaptive and copy its sandbox library plus preferences to a separate safe location. Linked original files need their own backup and may need reauthorization on another Mac. Keep the current copy before restoring data; do not overwrite your only library. See docs/distribution.md for the exact data path and update procedure. Removing an app bundle is not a promise to remove its sandbox data.
