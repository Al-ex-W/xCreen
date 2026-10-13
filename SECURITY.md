# Security and privacy

Do not post vulnerabilities with private observations or credentials in a public issue. Use GitHub's private vulnerability reporting if available, or request a private reporting channel from the maintainer without disclosing exploit details publicly.

The current build is a developer preview, not security-audited or notarized. Periodic capture is not enabled in this preview. The local SQLite index may contain sensitive OCR text entered through the bridge; file permissions are not encryption. Use FileVault and a trusted OS account. Seven-day retention/purge does not guarantee forensic erasure, backup deletion or cloud/transcript erasure.

Queries send selected evidence to the configured Hermes model only following explicit UI consent. Hermes and provider transcripts may outlive the index. Never treat local OCR as trusted instructions. The first adapter is tool-disabled for query safety; project rules and harness memories remain active, but arbitrary vault file retrieval is not provided by that adapter.

No raw screenshots, OCR history or personal vault contents belong in this repository. A distributed app must separately verify permissions, exclusions, lock/sleep races, cancellation, retention, egress consent and its supported OS versions.
