# Roadmap

What's planned next. Nothing here is available yet.

## Planned

1. **MCP server (read-only).** Let any MCP client read your xCreen screen memory. Tools:
   - `search`: OCR text search over recent screen history, with timestamps
   - `recent`: latest captured text for a time range
   - `coverage`: when capture was running or paused
   - `ask`: a question to the xCreen session in your Hermes Agent

   Read-only: it will not change Integrity, settings or notes. Tracking issue: https://github.com/Al-ex-W/xCreen/issues/1
2. **Notarized release.** The app isn't notarized today, so macOS asks you to approve it on first open ([INSTALL.md](../INSTALL.md)).

## Available today

The `xcreen` CLI with `--json` output is the local interface: [docs/cli.md](cli.md) · [CLI page](https://al-ex-w.github.io/xCreen/cli/).

Ideas and requests: [open an issue](https://github.com/Al-ex-W/xCreen/issues).
