# Security and privacy

The native app currently runs as a **disconnected UI preview**. Its launch, controls, local settings, question submission and URL handoff do not invoke Hermes, the Python bridge, model discovery, capture, SQLite or a vault. Questions are not persisted or sent. Only a few UI preferences are stored in UserDefaults. The Python bridge is not bundled. Dormant Swift backend types may remain linked, but the preview has no path that invokes them.

This build is not security-audited or notarized. It requests no Screen Recording or Accessibility permissions. Turning the preview Integrity toggle OFF changes a local preference only and never starts capture.

## Retained backend code — not connected to the app

Independent bridge/storage/capture source remains in the repository for future reviewed integration. Running that Python CLI separately can create a private local OCR index and send matching evidence through an explicitly selected Hermes harness. File permissions are not encryption; use FileVault and a trusted OS account. Expiry and purge rebuild FTS and truncate WAL when SQLite permits, but cannot promise forensic erasure, backup deletion, or deletion of model/provider transcripts.

Any future UI connection needs separate egress consent tied to the question, model and full harness identity. No-match retrieval must not send unrelated history. Screen text is untrusted evidence, not authority to run tools. Live capture must remain fail-closed until current lock state, foreground identity, permissions, cancellation and retention are verified.

No screenshots, raw OCR history, personal vault contents or credentials belong in the repository. Do not include private data in public vulnerability reports. Use GitHub private vulnerability reporting if available, or request a private reporting channel without publicly disclosing exploit details.
