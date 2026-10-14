# CLI / tray parity and local-control contract

The app is authoritative. `bin/xcreen` is a standalone Python 3 client, installed by copying rather than symlinking. It never writes app preferences or Hermes records. Native `AppState.control` runs on the main actor; its `SharedSessionController` is also used by tray settings and Integrity changes. The controller owns FIFO lifecycle transactions across awaits and a separate ordered Integrity lane. The capture service remains native and app-owned.

| Action | Tray / native behavior | CLI |
|---|---|---|
| Live state | Current published state | `status`, optionally `--json` |
| Integrity | User's desired switch; persisted, default ON; actual safety status separate | `integrity get/on/off` |
| Connection | Connect / Disconnect | `connection connect/disconnect/reconnect` |
| Models | Provider-aware session picker | `models list`, `model select PROVIDER MODEL` |
| Paths | Local settings Save | `settings show/set python/root/vault VALUE` |
| Detection | Auto-detect | `settings autodetect` or `autodetect` |
| Question | Ask / Enter | `ask QUESTION [--wait-ms N]` |
| Cancellation | Cancel | `cancel` |
| Durable history | Existing xCreen conversation in Hermes | `history` reads `session.history` |
| Reply images | Resolved attachment cards / Open | `images list/open ID` |
| Panel | Status item / handoff | `panel show/hide` |
| Lifecycle | Quit | `start/stop/restart/quit` |
| Diagnostics | Activity and gateway logs | `logs [-n N] [--no-follow] [--gateway]` |

Model selection uses literal configured provider/model identifiers and session-scoped `/model ... --session`; no global defaults change. A CLI model change updates the published picker without triggering a second model request. Asking from either surface uses the same manual action and dedicated persisted session. Only one manual turn is admitted at a time; a second gets a busy error rather than mixing replies. Automatic turns remain serialized by `HermesSessionRuntime`.

Settings persistence, frozen launch settings, teardown and reconnect are one ordered transaction; auto-detection is inside that same gate. CLI single-key writes merge at their transaction's turn. A reconnect failure is reported explicitly as settings saved / reconnect failed, not suppressed as success. Reconnect preserves the session record. UI and runtime event observers are generation-bound, so old EOF/events cannot disconnect a replacement.

`ask QUESTION --wait-ms N` limits response waiting, not inference lifetime; expiry leaves the admitted turn running and returns no reply. A completed wait returns that turn's complete output collected by the runtime, not whichever text the independent UI observer last displayed. A question gets an identity before any connection/task await. `cancel` removes that question if queued, prevents later admission if still connecting, and interrupts the runtime only if that exact question is current. It does not cancel an unrelated automatic batch, and fails explicitly when there is no admitted manual question. Use history/cancel to follow up. History is bounded to 500 KB and fails explicitly when larger (no invented totals). Images expose only IDs/timestamps for the current reply appendix; Open resolves the app-owned evidence path, not a caller-supplied path.

Global `--json` must precede the command (`xcreen --json status`). Values such as `xcreen ask "--json"` and `xcreen settings set vault "--json"` remain literal arguments. The optional wait flag follows the question, so `xcreen ask "--wait-ms"` is also a literal question.

## Security / limits

- `~/.xcreen-control` must be owned by the current UID, a real directory, mode 0700. Unsafe/symlinked directories are rejected, not silently repaired.
- `control.sock` is mode 0600. Server uses `getpeereid`, client uses macOS `LOCAL_PEERCRED`; both require same UID. This protects against other users, **not malicious processes already running as the same user**.
- A no-follow private lock file with nonblocking `flock` is acquired before constructing app state. A second instance exits without spawning another session owner. A stale owned socket is removed only after taking that lifetime lock. Lock files are retained to avoid inode replacement races.
- Newline-delimited JSON: one request/connection, maximum 64 KB; individual fields bounded by `LocalControlCommand.decode`. Unknown commands, malformed frames and invalid wait values are rejected.
- Maximum eight simultaneous clients. Input framing has a two-second absolute deadline; handler response waits at most 35 seconds; output writes have a two-second socket timeout. CLI has a bounded absolute response deadline. A timed-out state-changing command may already have applied: inspect live state before retrying.
- Responses are capped at 1 MB. Private paths, history and reply data are foreground CLI output only, not IPC request/response logging. Activity logs are diagnostic events, not a live state database; gateway stderr may need careful handling before sharing.
- Integrity OFF is explicit capture consent through the actual native service. No socket command bypasses TCC/state/exclusion policy. Startup, stop and restart do not re-enable capture.

## Verification boundary

Synthetic Swift tests exercise the actual shared controller: rapid Integrity epochs, queued/current/pre-admission manual cancellation, paused lifecycle interleavings, overlapping settings and discovery, old observer invalidation, and terminal turn-bound output. Separate socket tests exercise real Unix-socket roundtrips (including the actual Python client and peer credentials), permissions, exclusive locking, symlink rejection and malformed frames. Gateway history routing uses a fake gateway with exact runtime-session assertion. CLI parser tests preserve literal option-shaped arguments without launching the app. No verification enables capture, requests permission, invokes inference or writes a real vault. MainActor/AppKit action integration still requires separate capture-disabled installed-app QA and independent security review; passing these synthetic tests is not a full UI/provider integration claim.
