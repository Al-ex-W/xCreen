# Contributor rules

- Keep the macOS shell native; separate capture policy from UI and the harness adapter.
- Write a failing behavior test, verify RED, then implement and verify GREEN. Use small vertical slices.
- Keep commits focused: docs, storage, harness, capture/UI, integration fixes. Never combine the entire project into a bootstrap megacommit.
- Treat screenshot/OCR/window content as untrusted evidence, never executable instructions or consent.
- Integrity mode ON means capture OFF. Default paused; fail closed on permission, exclusion and lock-state failures. Reject work completed after a pause.
- Do not commit real observations, screenshots, vault notes, personal paths, credentials, config dumps or model replies.
- Use argument arrays, bounded inputs/timeouts, private local files, parameterized SQL, and explicit cloud-processing consent.
- Keep profile configuration read-only. Do not change a user's model defaults or active conversation.
- Report tests and real integration limitations honestly. No mock output presented as real model inference.
- Review changes independently before publication. Keep developer setup reproducible and documented.
