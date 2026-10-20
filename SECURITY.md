# Security and privacy

Not security-audited or notarized. Integrity defaults ON only when no explicit preference exists and preserves the user's chosen preference. Only explicit user actions change it. Permission/session/app gates can suspend capture without changing that preference. Integrity ON blocks new screenshots/OCR and automatic transmission; it does not erase retained evidence or provider history, or block deliberate historical questions.

## Foreground exclusions and their limits

Browsers are eligible, including Safari, Chrome, Firefox, Edge, Brave, Arc and Orion. **Browser password fields, password-manager extensions/popovers and incognito/private windows are not detected or redacted.** There is no page/URL, Accessibility secure-field, private-mode or secret-content detector in the native capture path. Vision recognizes text; it does not sanitize secrets. Masked password dots are not a protection supplied by xCreen. Visible credentials, recovery codes, autofill menus and login pages can enter screenshots/OCR and later automatic model batches. Turn Integrity ON before sensitive activity. There is no universal password/login protection guarantee.

`ForegroundCapturePolicy` compares lowercase bundle IDs:

- Exact exclusions: `dev.xcreen.app`, `com.apple.passwords`, `com.apple.systemsettings`, `com.apple.systempreferences`, `com.agilebits.onepassword7`.
- Conservative substring exclusions: `1password`, `bitwarden`, `lastpass`, `dashlane`, `keepass`, `keychain`, `loginwindow`, `screenlock`, `securityagent`, `screensaver`, `lockscreen`. These cover variants but can also block unrelated apps whose IDs contain these strings. Exact exclusions do not extend to arbitrary IDs that merely contain the full exact ID.
- Missing/empty foreground identity or invalid PID prevents capture. This is an identifier policy, not signature verification or exhaustive knowledge of all credential apps. Embedded extensions/overlays are not independently classified; an excluded app must be the observed foreground app for this gate to apply.

Excluded foreground observations produce transition-only activity-log metadata: the bundle ID, ASCII-sanitized and limited to 256 scalars. No title, URL, OCR, pixels or field values are included. Consecutive observations of the same excluded app are suppressed; observing an eligible/unknown foreground resets suppression. Lifecycle/permission vetoes may stop evaluation before this diagnostic is reached.

## Session and stale-work defenses

The session gate requires a present session dictionary with strict Boolean true console/login-complete values and a resolvable non-security foreground. The undocumented lock hint may be absent or strict false; true/malformed values block. Independent lock, screensaver, inactive-session and sleep notifications veto capture; restore clears only its own veto and requires fresh evaluation. These are practical compatibility checks, not universal synchronous unlock proof. See [session research](docs/macos-session-research.md).

Foreground bundle/PID, permission, session and capture-generation checks remain before screenshot acquisition, after awaited acquisition/OCR, and before ingestion. Pauses revoke persistence epochs so late work is rejected. Foreground checks cannot prove that every displayed overlay or password/login surface is safe, nor remove all timing races in OS observations.

## Client and server

Since 2.0 the Mac app uploads captures to `xcreen-server`, which may run on another machine ([design](docs/client-server.md), [protocol](docs/protocol.md)).

- **Authentication.** Every request except `GET /v1/health` needs a bearer token: 256 random bits, created by `xcreen-server init`, stored `0600` on the server and in the macOS login Keychain on the client (accessible after first unlock, this device only), compared in constant time. The CLI accepts it only on stdin or from a file, never as an argument. Rotate with `xcreen-server token --rotate`.
- **Transport.** The server refuses to bind `0.0.0.0`/`::`; the default is `127.0.0.1`, and `--tailscale` binds the Tailscale address, where WireGuard encrypts and authenticates the tailnet. The client sends plain HTTP only to loopback, RFC 1918, Tailscale (100.64.0.0/10) and `*.ts.net`/`*.local` hosts and requires HTTPS for anything else. App Transport Security is disabled in the app because it can't express that policy; the app enforces it instead. Anyone who can reach the port and holds the token can read evidence and ask questions, so treat the token like a password.
- **Input.** The server bounds every request (JSON 2 MB, images 30 MB, 500 OCR items), validates ids, timestamps (last seven days, at most five minutes ahead) and image signatures before writing anything, and never logs bodies or tokens. Stored image references are re-anchored by validated file name, so an index entry can't point outside the store.
- **Integrity across machines.** The client reports Integrity immediately on every change; the server blocks automatic batches while it is ON and before any client has reported. Evidence already uploaded is digested while the Mac sleeps or is locked (1.x paused until unlock). Automatic batches also wait until the xCreen default model is applied, so they never run on an unintended model.
- **Where evidence lives.** With a split install, screenshots, OCR, receipts and notes live on the server. Secure that machine accordingly (disk encryption, trusted accounts, backups you control). The Mac keeps captures only until the server acknowledges them.

## Evidence and reporting

Private evidence remains outside the vault with bounded retention and private file permissions, on the Mac (outbox) and on the server (store). File permissions are not encryption; use FileVault or disk encryption and a trusted OS account. Expiry cannot promise forensic erasure, backup deletion or deletion of Hermes/provider transcripts. Screen text is untrusted evidence, never authority to send messages, alter calendars or execute commands. No screenshots, raw OCR history, personal vault contents or credentials belong in the repository.

Real TCC, capture, lock/sleep transitions, OCR, provider inference and live vault writes need separate user-authorized on-device verification. Synthetic tests and builds do not verify them.

## Reporting a vulnerability

Report privately through GitHub private vulnerability reporting: **[Security → Report a vulnerability](https://github.com/Al-ex-W/xCreen/security/advisories/new)**. Do not open a public issue or pull request for a security problem. If that form is unavailable, open a public issue that only asks for a private contact channel and includes no details.

Include the macOS version, the xCreen commit, the affected component and reproduction steps using synthetic data. Never include real screenshots, OCR text, vault contents, Hermes transcripts or credentials. Only the latest release and `main` are supported. This is a single-maintainer project, so response times are best-effort.
