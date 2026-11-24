# Security policy

This is a pre-1.0 project moving through release-candidate validation. The current candidate is supported for triage; old development snapshots are retained as test evidence, not promised security-maintained releases.

Do not include API keys, Keychain exports, private books, access bookmarks or personal library snapshots in public issues. If GitHub offers **Report a vulnerability** under the repository's Security tab, use that private route. Otherwise open a minimal issue asking the maintainer for a private reporting channel, without exploit details or private data. No response-time guarantee is made.

Useful reports describe the affected version/source revision, platform, trust boundary, minimal non-private reproduction and impact. Avoid running untrusted files against a personal library while investigating; use an isolated test copy.

The app has no model-controlled shell or arbitrary filesystem executor. Cloud calls require explicit provider configuration and consent; secrets use Keychain. EPUB scripts and remote resources are disabled. These are implementation boundaries, not a guarantee that every document or model output is harmless. Do not bypass document protection or macOS security controls.

Published candidate archives use local ad-hoc signing unless the release explicitly says otherwise. They are not Developer ID signed or notarized. Verify the release source and checksum and consult Apple's installation guidance. A checksum verifies downloaded bytes against the published artifact; it does not substitute for trusted signing or notarization.
