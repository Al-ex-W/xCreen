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

Before calling `tui_gateway.entry.main()`, the launcher registers four handlers through Hermes’s supported `tools.registry.registry.register(name, toolset, schema, handler, ...)` API and sets the child-only documented `HERMES_TUI_TOOLSETS=xcreen` environment value. This gives sessions created in that child only the `xcreen` toolset, excluding terminal, browser, outbound, and file-editing toolsets. No configuration or profile file is written.

Available tools:

- `xcreen_search_ocr(query, limit?)` returns at most 20 fresh (seven-day) OCR records with ID, UTC timestamp, bounded text, app, and title.
- `xcreen_images_near(timestamp, seconds?)` returns at most 20 fresh image IDs around an ISO-8601 timestamp.
- `xcreen_view_image(image_id)` returns Hermes’s native multimodal tool-result envelope. Its `image_url.url` is a bounded `data:image/...;base64,...` value made from the evidence image bytes; this is actual model-visible pixels, not a path or thumbnail claim.
- `xcreen_daily_note(fact, source_ids)` makes a bounded, source-cited, idempotent append only when a vault was configured. Empty facts are a no-op. Sources must exist, be within retention, and share the capture date in the configured timezone. The writer reads safe top-level operating-rules/conventions files and the existing `Daily/YYYY-MM-DD.md`, locks, appends a deterministic marker, and reads back. It never creates Daily notes or follows symlinks.

Evidence index compatibility: `index.json` is read as Swift `JSONEncoder` output. Numeric dates are seconds from the 2001-01-01 UTC Apple reference date. Image records use `{id, timestamp, fileURL}` and OCR records use `{id, timestamp, text, app, title}`. The reader requires an absolute non-symlink evidence root, confines image paths to its direct `images/` directory, rejects symlinks, and never returns filesystem paths.
