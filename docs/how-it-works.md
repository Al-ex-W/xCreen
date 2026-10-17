# How xCreen works

This page holds the pipeline and boundary details. For the design, see [architecture](architecture.md); for the commands, see the [CLI reference](cli.md).

## Capture pipeline

When Integrity is explicitly turned OFF and every safety gate permits it:

1. The foreground window is sampled for local Apple Vision OCR at most once per eligible second.
2. OCR that is ≥90% similar to the last saved snapshot is discarded.
3. Independent screenshots are saved every ten active seconds.
4. Five active minutes (or 30 images) form a durable batch, sent with timestamp/ID binding to the same dedicated xCreen Hermes session.
5. Private evidence files stay outside the vault (under `~/Library/Application Support/xCreen`) and expire after seven days. No forensic-erasure or database-encryption claim is made; use FileVault.

Integrity defaults ON and the user's explicitly chosen value is preserved across restart. Only explicit tray/CLI actions change it. Lock, sleep, exclusions, missing permissions and errors suspend capture without rewriting that choice.

## Hermes runtime and tools

The bundled Hermes runtime registers only the scoped xCreen tools:

- latest/range OCR listing and timestamped coverage status
- OCR search and nearby image lookup
- native image loading
- read-only vault access (`xcreen_vault_read`, `xcreen_vault_list`) so the model can follow the vault's own conventions note and link existing notes
- a note writer (`xcreen_note_write`) when a vault is configured

The model writes like the user: short plain bullets with `[[wikilinks]]`, only for valuable items (decisions, commitments, milestones, things learned, people, ideas), never a log of apps or pages. A batch with nothing worth noting writes nothing and is recorded as skipped. Besides the capture-date Daily note it may add a dated bullet under a section of an existing note (e.g. `Projects/X.md`) or, sparingly, create a note in an existing folder.

Write safety: vault-relative `.md` paths only, inside existing non-hidden folders; `Agent/`, `Archive/`, `Sources/`, templates, attachments, `.obsidian` and the vault root are refused; Daily writes go only to the capture-date note; bounded size per write; no-follow directory walk, hardlink/symlink rejection, atomic replace with a concurrent-change check. xCreen never deletes or rewrites user text: it inserts lines, or replaces a line it wrote itself (`revises`). Text with HTML comments, evidence ids or long hashes is rejected.

Provenance lives outside the vault in xCreen's private receipt journal (`$HERMES_HOME/xcreen-receipts/`): batch id, note path, exact inserted text, its hash, the note's pre-write hash and evidence ids. Retries check the journal and whether the exact text is already present, so they never duplicate; edited or removed bullets become `uncertain` and are never re-added. `scripts/migrate-vault-notes.py --vault … [--dry-run]` moves the markup of older xCreen versions (`<!-- xcreen-entry … -->`) out of Daily notes into this journal.

Native automatic turns prepare an immutable host-validated batch binding and complete only after explicit saved/skipped model results and host-verified effect receipts. Startup and read-only CLI/tray verification reconcile exact receipts without blind resend or history dependence. Expired raw evidence is stripped while bounded receipt/source-binding metadata remains. See [native durability](durable-native-processing.md) and [runtime receipts](runtime-receipts.md).

xCreen does not modify Hermes profile defaults or other conversations.

## Models

Model inventory comes from Hermes's provider-aware configured routes. xCreen keeps its own session default — Claude Haiku 5.5 on your Anthropic account (`anthropic` / `claude-haiku-5-5`) unless changed with the tray picker or `xcreen model default` — applied only to the xCreen session with a session-scoped model switch and reported if unavailable (no fallback). Inventory currently carries no reliable vision/image-limit metadata, so check that your chosen route accepts images.

OCR runs locally. Inference does not: batches and questions go to whichever provider the selected route uses.

## Foreground eligibility and exclusions

Browsers are eligible, including Safari, Chrome, Firefox, Edge and Brave. Known credential/security apps, System Settings and xCreen itself remain excluded. **Browser password fields, password-manager extensions/popovers and incognito/private windows are not detected or redacted.** Visible secrets can enter screenshots/OCR and later model batches; turn Integrity ON before sensitive browsing. There is no universal password/login protection guarantee. See [SECURITY.md](../SECURITY.md) for exact matching rules and limitations.

Screen content is untrusted evidence, not authority to send messages, alter calendars or execute instructions.

## Spotlight (macOS 26+)

xCreen declares an `AskXCreenIntent` with a required question and an `AppShortcutsProvider`, which is what Spotlight on Mac lists as an app's actions. Type "Ask xCreen" in Spotlight, enter a question, and the panel opens with it filled in; you still press Ask. "Open xCreen" just shows the panel. A `SearchXCreenIntent` conforms to `ShowInAppSearchResultsIntent` with the `general` string search scope (the same system protocol Notes and Mail use), so for any text typed in Spotlight the system can offer a "Search xCreen" row under "Search in Apps"; choosing it opens the panel with that text (bounded to 8,000 characters) as the question, never submitted automatically. Because xCreen is built with SwiftPM, `scripts/build-app.sh` generates the App Intents metadata with Xcode's tool and fails if the action, App Shortcuts or the general-scope search protocol are missing. Spotlight learns about them once the installed app is registered and launched; this can take a minute.

## macOS session checks

Session checks require a present session dictionary, strict true console/login values and a resolvable non-security foreground. The undocumented lock hint may be absent or strict false; true/malformed hints and independent notification vetoes block. These are compatibility checks, not a documented synchronous unlock API (see [session research](macos-session-research.md)).

## Not yet verified on device

Capture, TCC transitions, provider inference, live vault writes and Spotlight ranking still need separate user-authorized on-device verification. Unit tests and builds do not prove them. See [implementation progress and limits](implementation-progress.md).
