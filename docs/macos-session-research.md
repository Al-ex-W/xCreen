# macOS practical session gating research

Research only. No implementation changes, no commit, no capture, no permission requests, and no change to user-selected Integrity. Source revisions below were resolved through GitHub's API and the actual raw files were read. This is selected-source inspection, not a build or security audit of those applications.

## Finding: absent is not explicit false, but it is normal compatibility input

The current `MacSessionState.swift` requires a present Boolean `CGSSessionScreenIsLocked=false`; `CaptureSessionEvidence.isSafe` implements `locked == false`. Its test explicitly rejects nil. Thus an otherwise eligible console session remains permanently blocked when this undocumented key is absent. This is a compatibility bug in the chosen policy, not evidence that macOS has denied capture.

A minimal Swift invocation of `CGSessionCopyCurrentDictionary()` was run from scratch storage. It printed key names and Boolean values only, never names, IDs, UUID values, windows, or pixels. The dictionary existed, `kCGSSessionOnConsoleKey=true`, `kCGSessionLoginDoneKey=true`, and **`CGSSessionScreenIsLocked` was absent**. This single current-session probe corroborates the reported failure mode; it is not a lock/unlock transition test or independent proof that the session was unlocked. No personal dictionary values are included in this public report.

Screenpipe's actual implementation treats a missing lock key as false, while querying initial state and maintaining notification/polling recovery. Its nil-dictionary branch also returns false; xCreen should NOT copy that weaker fallback.[10] An older developer Swift gist treats key presence as locked and absence as unlocked, without checking its Boolean value; this is illustrative developer evidence, not production capture code or a recommended parser.[14] The distinction matters: support an explicitly false Boolean too, and do not silently convert a malformed value into absence.

## Documented API versus compatibility behavior

| Signal | Verified scope | Practical interpretation |
|---|---|---|
| `CGSessionCopyCurrentDictionary()` | Public API: returns information about the caller's WindowServer session; nil when outside a Quartz GUI session or WindowServer disabled.[1] | Nil is unsafe/unknown, not unlocked. |
| `kCGSessionOnConsoleKey` | Public CFBoolean: whether the session is on a console.[2] | Require true, but console ownership is not authentication/unlock proof. |
| `kCGSessionLoginDoneKey` | Public CFBoolean: whether the login operation has been done.[3] | Require true, but completed login does not say the screen cannot subsequently lock. |
| `CGSSessionScreenIsLocked` | String consumed by real applications; no public Apple lock-state contract was found in the inspected documentation.[10] | Undocumented compatibility hint: true blocks; absent can be normal. No universal missing-key guarantee. |
| Workspace session active/inactive | Public notifications: session switches in/out. Apple's inactive-session launch notification occurs between app will/did-finish-launching.[4][5] | Handle fast-user-switch/session eligibility. Do not call these full screen-lock or unlock proof. Register on `NSWorkspace.shared.notificationCenter`. |
| Workspace screens sleep/wake | Public notifications for screens sleeping/waking.[6][7] | Sleep blocks. Wake prompts resampling, not proof of authentication. |
| Distributed `com.apple.screenIsLocked`, `.screenIsUnlocked`, `com.apple.screensaver.didstart`, `.didstop` | Concrete compatibility names in Retrace; lock/unlock names also used by screenpipe.[9][10] | Notification center APIs are public; these specific notification names have no public Apple guarantee established here. Treat as transition hints, not trustworthy authorization tokens. |
| `NSWorkspace` frontmost app / loginwindow | Useful independent heuristic; screenpipe also recognizes lock-screen app names.[11] | Known loginwindow/screensaver foreground blocks; absent/unresolvable foreground stays pending. Stale non-loginwindow state cannot prove unlock. |
| ScreenCaptureKit stop/error | Documented delegate callback when a stream stops with an error.[8] | Safety/availability veto; successful enumeration or capture is NOT a substitute unlock test. |

## Real application evidence (pinned, line-specific)

### Retrace: notifications, not an initial-state query

Revision `5e53440c33dd86852c34df4e32955983eadbfe1b`, `Capture/ScreenCapture/ScreenLockStateMonitor.swift`: lines 10–16 initialize lock/screensaver false and declare the four distributed names; lines 24–54 set/reset flags from notifications; lines 71–81 return capture-block reasons.[9]

**Lesson:** useful event-driven stop signals. **Do not copy its startup default** for privacy-sensitive xCreen: this selected monitor does not query the current lock state, so starting after a lock notification was emitted is not covered by this file. Source existence does not demonstrate notification delivery reliability.[9]

Exact code: https://github.com/haseab/retrace/blob/5e53440c33dd86852c34df4e32955983eadbfe1b/Capture/ScreenCapture/ScreenLockStateMonitor.swift#L10-L81

### Screenpipe: initial query + notifications + actual five-second fallback

Revision `a71e821de98615c9bafde1574298cb592b664634`, `crates/screenpipe-engine/src/sleep_monitor.rs`: lines 177–231 read the private key. `value.is_null()` returns false; otherwise it reads CFBoolean. Lines 282–288 perform an initial query before capture. Lines 361–394 register **the distributed CFNotificationCenter**, despite an earlier comment calling it Darwin. Lines 403–420 actually poll every **five seconds**, despite other comments mentioning 2 or 30 seconds. Lines 575–618 recheck on wake and again after five seconds to recover missed unlocks.[10]

**Lesson:** actual production code does not require a present false lock key. It avoids an indefinitely stale locked flag through resampling. Its comments claiming all lock methods are caught are application claims, not Apple guarantees, and a five-second fallback admits a transition-detection gap.[10]

Exact parser: https://github.com/screenpipe/screenpipe/blob/a71e821de98615c9bafde1574298cb592b664634/crates/screenpipe-engine/src/sleep_monitor.rs#L177-L231

Exact startup/notifications/poll: https://github.com/screenpipe/screenpipe/blob/a71e821de98615c9bafde1574298cb592b664634/crates/screenpipe-engine/src/sleep_monitor.rs#L282-L420

`event_driven_capture.rs` lines 2830–2839 recognize `loginwindow`, `screensaverengine`, and `lockscreen`; lines 1346–1367 release capture streams on pause. This supports layered checks and teardown, not a guarantee that foreground-app heuristics independently detect every lock.[11]

Exact foreground heuristic: https://github.com/screenpipe/screenpipe/blob/a71e821de98615c9bafde1574298cb592b664634/crates/screenpipe-engine/src/event_driven_capture.rs#L2830-L2839

### OBS: actual capture-error recovery, not claimed lock proof

Revision `6069331d3c225f736e60455a9f9f22323c020408`: `plugins/mac-capture/mac-sck-common.m` lines 29–48 implement `didStopWithError`, distinguish user-stopped/no-source, and set `capture_failed=true`. `mac-sck-video-capture.m` lines 591–594 expose a restart control when failed.[12][13]

**Lesson:** handle capture failure explicitly and recover deliberately; the inspected OBS files are not evidence of a synchronous screen-lock detector. Apple's callback documents failure, not that every lock produces a particular error.[8][12]

Exact callback: https://github.com/obsproject/obs-studio/blob/6069331d3c225f736e60455a9f9f22323c020408/plugins/mac-capture/mac-sck-common.m#L29-L48

## Recommended concrete patch (not applied)

### 1. Separate parsing from eligibility

Replace the optional Boolean's overloaded semantics with a typed hint: `locked`, `notReportedLocked` (absent or explicit false, provenance retained), `invalid`. Preserve dictionary-unavailable, missing/false onConsole, missing/false loginDone, and unknown foreground as distinct unsafe/pending reasons. Use strict CFBoolean parsing, not truthiness of arbitrary strings/numbers. Missing PRIVATE lock key alone must not produce “current lock-state signal unavailable” forever.

Rename the resulting status to `eligibleByCompatibilityChecks` or equivalent rather than claiming universally proven `unlocked`. The intended predicate is:

```text
present GUI-session dictionary
AND onConsole == true AND loginDone == true
AND private lock hint is absent OR explicitly false (not malformed)
AND resolvable eligible non-security foreground
AND no session/sleep/display/screensaver/lock/error veto
AND desired Integrity OFF and existing capture consent/permission
```

Parenthesize the absent-or-false clause in implementation. This is an intentionally pragmatic policy, not a new documented Apple guarantee.

### 2. Register first; initialize paused; sample before acquisition

Install observers before reading startup state. Start actual safety as pending, preserving desired Integrity exactly. Sample the dictionary and current foreground, then reconcile with the observer epoch so a lock arriving during initialization cannot be overwritten by a stale sample. On an otherwise coherent startup snapshot, permit absent-key compatibility eligibility; do not require waiting for a future unlock notification that might never occur.

For **truly ambiguous startup** (nil dictionary, malformed hint, unresolved foreground, contradictory signals, uncertain display availability), remain paused with a specific reason and a bounded metadata-only resampling path. Offer an explicit user retry after returning to an eligible desktop; retry is not a bypass or a change to Integrity. If sleep-state initialization cannot be established, keep that uncertainty explicit rather than presuming awake from onConsole alone. A supported display-state check would need separate implementation/source verification; this research did not probe displays.

### 3. Retain independent vetoes; make restoration a reevaluation

Keep the existing workspace session/sleep/display and distributed lock/screensaver observers, but replace the independently queued restore `Task`s with ordered epoch-aware transitions. A delayed unlock/wake must not erase a later lock/sleep. A screen wake never clears a lock veto merely because the screen woke. Screensaver-stop never clears lock. Unlock can trigger a current snapshot, not immediately authorize acquisition.

Use a short metadata-only periodic check while pending/paused and just-in-time checks on each capture attempt to recover missed events and avoid stale state. Treat a coherent fresh console/login/foreground/absent-or-false snapshot as practical recovery evidence after a bounded settling period; report that it is heuristic. If a previously seen lock contradicts the snapshot, resample before recovery, not a forever-latched flag or immediate notification-only unlock. Do not copy screenpipe's nil-dictionary=false behavior or its five-second polling interval as a privacy guarantee.

Maintain known display/system-sleep vetoes independently. Recheck current foreground/session before capture, after await and before ingestion/transmission; invalidate epochs and reject old work on any adverse transition. Stop/release streams and pause active time. Never rewrite desired Integrity or let events grant capture consent.

### 4. Treat ScreenCaptureKit errors as vetoes, not lock classifiers

Acquisition failures and stream-stop errors discard work and trigger teardown. No-source/unavailable display may be retryable after metadata gates recover; permission denial stays blocked and does not trigger unsolicited permission prompts. Unknown errors stay conservative with an explicit retry path. Do not label every SCK error “locked,” and do not treat capture success as unlocking. For user-stopped streams, show stopped state and require deliberate restart instead of automatically fighting the user's OS stop action. Apple calls this expected/recoverable, not mandatory automatic retry.[8]

### 5. Update policy tests and user-facing claims together

Change `CaptureIntentState.swift` / `CaptureSessionEvidence`, `MacSessionState.swift`, lifecycle handling in `CaptureService.swift`, and the nil-lock regression assertion in `CaptureFailurePolicyTests.swift` as one reviewed slice. Align README, architecture and progress wording with a compatibility policy. Keep all existing Integrity, consent, foreground exclusion, epoch-bound storage/transmission and clock-gap protections. No such edits were made by this research.

## Test matrix for the implementation

| Case | Expected result |
|---|---|
| Valid console/login + absent private key + eligible foreground + awake gates | Eligible by compatibility checks, not permanently blocked; Integrity ON still invokes no screenshot API. |
| Same with explicit false | Same eligibility. |
| Private key true | Block, invalidate/cancel old work, stop stream; no active-clock increment. |
| Key wrong type; dictionary nil; console/login missing or false | Pending/blocked with exact reason and retry; never coerced to unlocked. |
| loginwindow/screensaver or nil foreground | Block/pending even if lock key absent/false. |
| Cold launch while actually locked; unlocked; switched-out | No capture before coherent initialization; confirm behavior across supported OS versions without presuming private-key presence. |
| Manual lock, hot corner, auto-lock, screensaver with/without password delay | Stop on negative signals; screensaver-stop alone does not unlock. |
| Fast-user-switch away/back | Inactive session blocks; switch-in resamples all gates, not universal unlock. |
| System sleep, display-only sleep, lid close/external displays, wake into login screen | Separate vetoes; wake cannot authorize a locked desktop; reinitialize stale streams. |
| Rapid lock/unlock/lock, queued restores, lock during initial sample/capture await | Last adverse epoch wins; no stale save/OCR/transmission/finalization. |
| Lost unlock notification; coherent later snapshot | Bounded practical recovery, no restart or Integrity toggle required, no permanent false-negative from absent key. |
| SCK no-source, permission revoked, user stop, unknown failure | Discard/teardown; differentiated recovery; no prompt or auto-fighting user stop. |
| Desired Integrity ON/OFF across all transitions and restart | Never mutated by automatic safety state; OFF resumes only when gates permit. |

Unit tests should use injected typed snapshots, an ordered event source, a fake clock, and capture-call counters. Real transition tests require separate user authorization; do not enable Integrity OFF or change it for testing. Metadata-only lock/session observation can be tested separately from any screenshots. No capture integration tests, app builds, or source-app tests were run here.

## Limits and retrieval notes

No inspected Apple source promises an atomic universal “this screen is unlocked” oracle from these combined signals. Dictionary/foreground reads can race transitions; undocumented names/keys can change or be delayed; distributed notifications are not an authentication boundary. This design trades an unusable absent-key false-negative for a layered practical policy with explicit remaining risks. If the product requires absolute pre-acquisition lock proof, these sources do not satisfy that requirement: remain paused on ambiguity and state the limitation rather than claiming proof.

The configured web extractor was unavailable. Apple documentation was therefore read through Apple's own DocC JSON (`https://developer.apple.com/tutorials/data/documentation/<symbol>.json`), and repository source through pinned GitHub raw URLs. Python HTTPS initially failed local certificate validation; system `curl` successfully retrieved the same primary sources without disabling TLS checks. One attempted Apple error-enum URL returned 404 and is not cited or used to assert error-code semantics.

## Sources

[1] https://developer.apple.com/documentation/coregraphics/cgsessioncopycurrentdictionary%28%29
[2] https://developer.apple.com/documentation/coregraphics/kcgsessiononconsolekey
[3] https://developer.apple.com/documentation/coregraphics/kcgsessionlogindonekey
[4] https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidresignactivenotification
[5] https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidbecomeactivenotification
[6] https://developer.apple.com/documentation/appkit/nsworkspace/screensdidsleepnotification
[7] https://developer.apple.com/documentation/appkit/nsworkspace/screensdidwakenotification
[8] https://developer.apple.com/documentation/screencapturekit/scstreamdelegate/stream%28_:didstopwitherror:%29
[9] https://github.com/haseab/retrace/blob/5e53440c33dd86852c34df4e32955983eadbfe1b/Capture/ScreenCapture/ScreenLockStateMonitor.swift
[10] https://github.com/screenpipe/screenpipe/blob/a71e821de98615c9bafde1574298cb592b664634/crates/screenpipe-engine/src/sleep_monitor.rs
[11] https://github.com/screenpipe/screenpipe/blob/a71e821de98615c9bafde1574298cb592b664634/crates/screenpipe-engine/src/event_driven_capture.rs
[12] https://github.com/obsproject/obs-studio/blob/6069331d3c225f736e60455a9f9f22323c020408/plugins/mac-capture/mac-sck-common.m
[13] https://github.com/obsproject/obs-studio/blob/6069331d3c225f736e60455a9f9f22323c020408/plugins/mac-capture/mac-sck-video-capture.m
[14] https://gist.github.com/macshome/8ad9456806a6501ef7dba20a2ec856e3/b83753ba0d8968f0ef89bbce5a7cd9c7e7f12cec
