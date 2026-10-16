# xCreen model-callable toolkit contract

The native integration starts a separate, xCreen-exclusive Python child using the same Python environment that contains the installed Hermes source. It must not invoke a shell, edit Hermes configuration, or change a user profile.

```text
<python> <app-resources>/runtime/xcreen_gateway.py \
  --hermes-root <absolute-installed-hermes-source-root> \
  --evidence-root <absolute-xcreen-evidence-root> \
  [--vault <absolute-local-vault-root>] \
  [--timezone Europe/Stockholm]
```

`--hermes-root` is the directory containing `tools/registry.py` and `tui_gateway/entry.py`; it is not a Hermes configuration directory. The launcher inherits `HERMES_HOME`, authentication, model routing, memory, and rules from its parent environment. When `--vault` is supplied, `HERMES_HOME` must name an existing non-symlink directory so the writer can take `HERMES_HOME/vault-write.lock` with `fcntl.flock`.

Before calling `tui_gateway.entry.main()`, the launcher registers six handlers through Hermes’s supported `tools.registry.registry.register(name, toolset, schema, handler, ...)` API and sets the child-only documented `HERMES_TUI_TOOLSETS=xcreen` environment value. This gives sessions created in that child only the `xcreen` toolset, excluding terminal, browser, outbound, and file-editing toolsets. No configuration or profile file is written.

Available tools:

- `xcreen_recent_ocr(limit?, start?, end?)` lists latest OCR without guessed keywords, optionally within an inclusive ISO-8601 range. Newest first, at most 20, with `has_more`, bounded snippets, local offset and UTC timestamps, and coverage information.
- `xcreen_coverage()` reports latest retained OCR/image timestamps in local time and UTC, timestamped capture state/reason, known credential/security app exclusions and browser password/private-window limitations and seven-day retention. This is sparse evidence, not continuous coverage or a live health probe; no match is not proof something was never seen. Missing status is explicitly unknown.

- `xcreen_search_ocr(query, limit?)` searches up to 12,000 persisted OCR characters using Unicode NFKC/casefold normalization, then returns at most 20 fresh records with ID, UTC/local timestamp, bounded match-centered text, truncation flag, app, and title.
- `xcreen_images_near(timestamp, seconds?)` returns at most 20 fresh image IDs around an ISO-8601 timestamp.
- `xcreen_view_image(image_id)` returns Hermes’s native multimodal tool-result envelope. Its `image_url.url` is a bounded `data:image/...;base64,...` value made from the evidence image bytes; this is actual model-visible pixels, not a path or thumbnail claim.
- `xcreen_daily_note(fact, source_ids, batch_id?, entry_id?)` appends a valuable, source-cited insight only when a vault is configured. Empty facts remain a no-op, not a completed-batch receipt. Sources must exist, be within retention, and share the capture date in the configured timezone; caller-supplied dates/paths have no authority. The existing convention is `Daily/YYYY-MM-DD.md`. The writer may exclusively create a missing dated file with only `# YYYY-MM-DD`, never a directory or executable template. It inspects only bounded `Agent/Operating Rules.md` and `Agent/Connections.md`, and reads the target note under the shared lock. Note access walks no-follow directory descriptors, rejects symlink ancestors and hardlinks, appends without rewriting user text, fsyncs and verifies the exact block.

### Daily effect receipts and recovery

The writer keeps a vault-scoped private SQLite **metadata-only** ledger in `HERMES_HOME/xcreen-daily-<vault-hash>-receipts.sqlite3`: stable effect ID, capture day, body digest, pre-append byte position, and `pending/completed/uncertain` state. It stores no fact text, OCR or image bytes. Explicit `batch_id` + semantic `entry_id` determine an effect independently of wording/source reselection. Legacy calls without an entry ID conservatively allow one effect per source set; this is not general semantic deduplication across different identities.

Each note effect has complete begin/end markers and a body digest. A valid committed block is evidence even if its DB receipt was lost; a retry reconstructs completion rather than appending again. An incomplete/edited block, conflicting digest, missing completed block or changed pending byte position becomes `uncertain`, never a blind reappend. These hashes detect accidental/partial corruption, not a malicious same-UID actor able to replace both note and ledger. The writer never repairs user edits automatically.

`VaultDailyWriter.receipts(after="", limit=20)` and `.reconcile(after="", limit=20)` expose bounded metadata pages (maximum 100); advance `after` to the final ID until a short page. Reconcile verifies existing notes without raw evidence, inference or note creation. Entry receipts alone are not a batch inference outbox: the host adds immutable prepared batch/source binding plus explicit `xcreen_batch_result` saved/skipped results. Native startup and CLI/tray `verify` now reconcile exact batch receipts through `xcreen.batch.receipt`, independently of compactable history. Native `completed` requires verified saved effects or explicit zero-effect skip; missing results remain uncertain without blind resend. See [runtime contract](runtime-receipts.md) and [native durability boundary](durable-native-processing.md). No exactly-once inference claim is made.

Evidence index compatibility: `index.json` is read as Swift `JSONEncoder` output. Numeric dates are seconds from the 2001-01-01 UTC Apple reference date. Image records use `{id, timestamp, fileURL}` and OCR records use `{id, timestamp, text, app, title}`. The reader requires an absolute non-symlink evidence root, accepts Swift Codable local `file:///...` URLs with strict percent decoding or legacy absolute paths, rejects hosts/query/fragment/traversal/symlink components, confines images to its direct `images/` directory, and never returns filesystem paths.
