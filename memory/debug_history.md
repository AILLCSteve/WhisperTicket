# WaitTicket — Project Debug History

> Project: WaitTicket (repo: Whisper/) | Stack: Swift 5.9 + SwiftUI + SwiftData + SFSpeechRecognizer + AVAudioEngine
> Started: 2026-01 | Format: §15 of global CLAUDE.md
> MANDATORY: Read this before forming any debugging hypothesis (§5 Gate 1).

---

## [2026-07-03] — Transcript drop-after-pause RECURRED in build 56 — Root Cause = SFSpeech file recognition ALSO endpoints on silence — FIXED (segment rotation + reset stitching)

**Area:** `Services/AudioCaptureService.swift`, `Services/SFSpeechTranscriptionService.swift`, `Services/Protocols.swift`, `ViewModels/LiveSessionViewModel.swift`
**Type:** Architecture (recognition side). Supersedes the recognition claim of the 2026-07-01 build-56 entry below; that entry's CAPTURE insight (record-to-file) still stands.

### Symptom
Build 56 (record-then-transcribe) still lost everything before a pause on the
*initial* recording: "I want a steak … [5s pause] … some mashed potatoes" → only
"some mashed potatoes". (Adding to an existing transcript worked correctly.)

### True root cause (the part all FOUR prior fixes missed)
`SFSpeechRecognizer` runs an utterance endpointer in EVERY mode — streaming AND
file-based (`SFSpeechURLRecognitionRequest`). On a long internal silence (~2s
on-device) it resets its transcription context; hypotheses after the reset no
longer contain pre-reset text. Build 56 used `shouldReportPartialResults = false`
and resumed on the first `isFinal`, so it received exactly ONE string — which,
after a mid-file reset, covers only the LAST utterance. The audio file had
everything; the recognizer's *reported output* discarded the pre-pause text.
Build 56 fixed CAPTURE but not RECOGNITION — the endpointer moved from mic to file.

### The fix — two independent layers
1. **Silence-gated segment rotation (capture, primary).** AudioCaptureService
   watches its meter; after speech is heard and the level stays below
   `speechLevelThreshold` (0.18) for `silenceRotationThreshold` (1.3s, < SFSpeech's
   ~2s endpoint), it closes the current .m4a, emits it via `onSegmentReady`, and
   starts a new file — during silence, so no speech is lost. Every file handed to
   recognition is thus a short, pause-free utterance. No length cap; long segments
   rotate on a 0.35s dip after 45s. Segments transcribe while recording continues.
2. **Reset-stitching transcription (recognition, safety net).** For loud rooms
   where the meter never dips, `shouldReportPartialResults = true` is used as an
   OBSERVATION channel (still a finished file — NOT streaming ASR). `TranscriptStitcher`
   keeps the epoch high-water hypothesis (kills the down-revision bug too), detects
   a reset (new hypothesis < half the epoch best AND not a prefix), commits the
   epoch, starts a new one; final = all epochs joined. Errors-after-text return the
   stitched text; a `max(15s, 2.5×duration)` watchdog prevents a hung spinner.

### Assembly (ViewModel — build-56 invariants preserved)
`onSegmentReady` yields into an `AsyncStream<URL>`; a single serial consumer task
transcribes segments in arrival order while recording continues; on stop the final
URL is yielded and the stream finished; the consumer joins all segment texts and
calls the EXISTING `appendTranscript(_:)` exactly ONCE per mic press — parse-once /
append-only / no-duplication path untouched.

### Hard rules (see transcriptiondebughandoff/TRANSCRIPTION FIX IMPLEMENTATION.md)
- Do NOT set `shouldReportPartialResults = false` — that IS the build-56 bug.
- Do NOT consume the first `isFinal` without the stitcher — same bug.
- Do NOT add a second accumulation layer in the ViewModel, and do NOT cancel the
  serial consumer in `finishRecording` (it must drain). No recording length cap.

### Global?
**Yes** — "SFSpeech FILE recognition also segments on internal silence; never
consume only its final result — split audio at pauses and/or stitch over partials."
A general, non-obvious iOS speech lesson. Rejected escape hatch if this ever fails
on device: on-device Whisper (WhisperKit) — immune to the endpointer, but breaks
the zero-dependency constraint. iOS 26 `SpeechAnalyzer` is the long-term fix once
the deployment target moves off iOS 17.

### Status
Code complete; CI-verified build. Device verification pending (§8 checklist in the
handoff doc): pause / multi-pause / no-limit / add-more / multi-seat / loud-room /
interruption / silence.

---

## [2026-07-01] — Transcript Erasing FINALLY Fixed by Abandoning Streaming ASR — ARCHITECTURE CHANGE (SUPERSEDED 2026-07-03: capture insight stands; recognition claim was wrong — file recognition also endpoints on silence)

**Area:** `Services/AudioCaptureService.swift`, `Services/SFSpeechTranscriptionService.swift`, `Services/Protocols.swift`, `ViewModels/LiveSessionViewModel.swift`
**Type:** Architecture (the definitive fix; supersedes all prior transcript-reset entries)

### Context
The transcript-erase-on-pause bug survived THREE fixes to the streaming design
(single-source-of-truth, continuous-task rewrite, generation-guarded high-water).
Per the debugging rule (3+ failed fixes = wrong architecture), the streaming
`SFSpeechRecognizer` approach itself was the root cause: live partials + silence
endpointing + multi-segment reconciliation is inherently erase-prone.

### The fix — record-then-transcribe (build 56, v1.5.0)
Streaming was **torn out entirely** and replaced with the simplest possible design:
- **AudioCaptureService** = `AVAudioRecorder` writing mic audio to a temp .m4a
  FILE continuously until `stopRecording() -> URL?`. No recognition during
  recording, no timers. Metering drives the waveform. Audio in a file can't be lost.
- **SFSpeechTranscriptionService** = one async `transcribe(fileURL:) -> String`
  running on-device recognition over the COMPLETE file once
  (`shouldReportPartialResults = false`, `requiresOnDeviceRecognition = true`).
- **LiveSessionViewModel** = on stop, transcribe the file and APPEND the result to
  the active seat (pure concatenation); parse only that chunk once. Erasing is now
  structurally impossible; duplication path removed (no re-parse of prior text).

### Protocol changes (do NOT revert to streaming)
- `AudioCaptureServiceProtocol`: `startRecording() throws` / `stopRecording() -> URL?`
  (removed `audioBufferPublisher`, `startCapture`/`stopCapture`).
- `TranscriptionServiceProtocol`: single `func transcribe(fileURL:) async throws -> String`
  (removed the streaming publisher, `startTranscribing(seed:)`, `endAudioInput`,
  `stopTranscribing`, and the `TranscriptionSegment` struct).

### UX trade-off (intended)
Transcript no longer streams word-by-word while speaking. User sees waveform +
"Recording…" during capture, "Processing…" briefly after stop, then the full text.
The user explicitly chose reliability over live streaming.

### Watch out
- **Do NOT resurrect streaming `SFSpeechRecognizer` partials.** Every prior
  transcript-reset entry below refers to the ABANDONED streaming design.
- If `transcribe` never calls back on empty/silent audio, the continuation could
  hang (isFinalizingTranscription stuck). SFSpeech normally returns an empty final
  or errors; add a timeout if a stuck spinner is ever observed.
- Not yet device-verified (Windows dev box). User must confirm pause-then-resume
  no longer erases on build 56.

### Global?
Yes — "for reliable dictation, prefer record-file-then-transcribe over streaming
partial reconciliation" is a broadly useful iOS speech lesson.

---

## [2026-07-01] — SFSpeechTranscriptionService — Transcript Reset RECURRED — Root Cause = Double Accumulation — RESOLVED

**Area:** `Services/SFSpeechTranscriptionService.swift`, `ViewModels/LiveSessionViewModel.swift`, `Services/Protocols.swift`
**Type:** Bug (ASR session management) — regression of the [2026-05] entry below

### Context
The [2026-05] `lastNonEmptyText` fix did NOT fully resolve the reset — user reported it still intermittently drops pre-pause words.

### Root cause (confirmed)
The full transcript was reconstructed from TWO independent accumulation layers:
1. Service `accumulatedBase` (across ASR task restarts within a session).
2. ViewModel `priorSeatTranscript` + a **length-monotonic guard** (`candidate.count >= existing.count ? candidate : existing`) across mic presses.

The length guard only rejected *shorter* candidates. When `SFSpeechRecognizer` **down-revised** a partial (e.g. "I want a steak" → "I want"), `lastNonEmptyText`/base committed the shorter text, and the next task appended to it — pre-pause words lost. The guard could not catch this because the replacement was still *longer* than the existing display once new speech arrived.

### Fix applied — single source of truth in the service
- `Protocols.TranscriptionServiceProtocol.startTranscribing` now takes a `seed: String` (the seat's existing transcript).
- Service: `committedText` = seed + all confirmed prior-task text; **only ever grows**. `taskBest` = per-task high-water mark (longest partial this task) so an empty/shorter isFinal cannot erase displayed text. Emitted = `committedText (+ " " + taskBest)`.
- ViewModel: passes the seed and now assigns `seatTranscripts[seat] = segment.text` directly — the second accumulation layer + length guard are GONE.
- Added `os.Logger(subsystem: "com.whisperticket.app", category: "ASR")` — capture on device via Console.app / Xcode to verify committed/base growth across restarts.

### Architectural facts confirmed
- Cursor alignment preserved: `consumedCursor = seedLength + 1` still points past the joining space to the first new char, so `parseDraft` stays incremental.
- Only ONE implementor (SFSpeechTranscriptionService) and ONE caller (LiveSessionViewModel) of the protocol — no test mocks — so the signature change is safe.

### Verification status
- CI-verified: compiles, archives, exports signed IPA (GitHub Actions run 28491855388, green).
- NOT yet device-verified: the reset behavior itself requires a physical device + mic + speech. **User must confirm on-device.** Logs are in place to help.

### Watch out
Do NOT reintroduce a ViewModel-side transcript accumulation or length guard. The service is the sole owner of the transcript now. Any "never go backward" logic belongs in the service (`committedText` monotonic + `taskBest` high-water).

### Global?
Yes — "single source of truth for the accumulated transcript; never split accumulation across service + view layer" is a general streaming-ASR lesson. Worth copying to global if it recurs elsewhere.

---

## [2026-07-01] — CI/CD — TestFlight Pipeline Broke After macos-latest → macOS 26 Migration — RESOLVED

**Area:** `.github/workflows/build.yml`
**Type:** Bug (CI/CD — environment drift, NOT code)

### Context
After ~6 weeks (last green 2026-05-20), a push failed. No code cause — the `macos-latest` runner label **migrated to macOS 26 on 2026-06-15** (GitHub runner-images #14167), changing the toolchain.

### Three sequential failures, each a distinct root cause
1. **`Install Distribution certificate`** → `security: SecKeychainItemImport: MAC verification failed during PKCS12 import (wrong password?)`. Cause: bare `openssl` now resolves to **Homebrew OpenSSL 3.x**, which writes a PKCS#12 MAC/PBE that Apple's `security import` (LibreSSL) can't verify. **Fix: pin to `/usr/bin/openssl` (system LibreSSL)** for both the DER→PEM and `pkcs12 -export` calls. Immune to brew drift.
2. **`Upload to TestFlight`** → `altool ... Cannot determine the Apple ID from Bundle ID 'com.whisperticket.app' ... (19)`. Cause: **a pending ASC agreement** the account holder had to accept (account in restricted state; NOT a code/bundle problem). **Fix: user accepted new terms in App Store Connect.** No workflow change. (Project history `a42c7a9` shows agreements have blocked this pipeline before.)
3. **`Set compliance & distribute`** → `curl: (56) ... error: 403`. Cause: `curl -sSf` app-lookup got a 403 while the freshly-accepted agreement was still propagating; HTTP/2 masked it as exit 56 and `set -e` killed the step. **Fix: `continue-on-error: true` on this optional post-upload step (IPA already uploaded, compliance via Info.plist) + convert the apps lookup to the documented `--http1.1 -o -w` pattern with graceful `exit 0` on non-200.**

### Architectural facts confirmed
- `macos-latest` is a MOVING target — expect toolchain regressions on each monthly image rotation. Pin system binaries (`/usr/bin/openssl`) where keychain/LibreSSL compatibility matters.
- Post-upload ASC bookkeeping (compliance PATCH, betaGroups add) is OPTIONAL — must never fail a build whose `altool` upload already succeeded. Compliance is set via `Info.plist` (`ITSAppUsesNonExemptEncryption=false`).
- Build often isn't visible in ASC within the 3-min wait window → API group-add skips; internal testers still get the build via TestFlight auto-delivery (if an Internal Testing group exists).
- altool error 19 on a previously-working pipeline ≈ account-state (agreements/membership), not code.

### Watch out
Next macOS image rotation may break signing again. If P12 import fails, confirm which `openssl` is in PATH. If `altool` errors 19, check ASC agreements + membership before touching code.

### Global?
Partially — the `/usr/bin/openssl` P12 fix and "altool 19 = agreements" are general iOS-CI lessons. curl/HTTP2/403 masking already in global CLAUDE.md.

---

## [2026-05] — SFSpeechTranscriptionService — Transcript Resets on Long Pause — RESOLVED

**Area:** `Services/SFSpeechTranscriptionService.swift`
**Type:** Bug (ASR session management)

### Context
Users reported that when they paused mid-sentence (e.g., to look at a menu), the previously spoken words disappeared from the transcript and only the post-pause words were shown. Persistent across multiple fix attempts over several sessions.

### Symptoms
"I want a steak and... [pause]... some mashed potatoes" → transcript shows only "some mashed potatoes". The full text from before the pause is gone.

### Approaches tried
- Initial implementation with `accumulatedBase` and restart-on-isFinal — looked correct in theory but bug persisted.
- Adding `priorSeatTranscript` to the ViewModel to accumulate across sessions — helps for multi-tap but not within a single recording session.
- Restart logic on `isFinal` — correct but incomplete.

### Root cause (confirmed two-part)

**Part 1 — isFinal with empty result:**
`SFSpeechRecognizer` fires `isFinal = true` after detecting silence. At this moment, `bestTranscription.formattedString` can return an **empty string** (recognizer completed with no final text — a known edge case on on-device mode). The code computed `fullText = base.isEmpty ? "" : "\(base) \(currentText)"` = `"" \(= "")` when base = "" (first task). The segment with `text = ""` was sent to the ViewModel, which wrote `seatTranscripts[seat] = ""`, **visually clearing the transcript** already displayed. New task started with `accumulatedBase = ""`.

**Part 2 — Errors silently ignored:**
When `isFinal` fires due to a recognizer timeout/error (e.g., kAFAssistantErrorDomain 209 = no audio/silence), sometimes ONLY an error fires (no result). The old code: `if let error, !self.isSessionActive { stopTranscribing() }`. Since `isSessionActive = true` during active recording, the error was COMPLETELY IGNORED. The recognition task died, future audio was appended to a dead request, and the transcript never updated again.

### Fix applied
1. Added `lastNonEmptyText: String` — tracks the last non-empty full transcript seen in the current task.
2. On every partial/final result: use `lastNonEmptyText` as fallback if `computed` is empty — transcript NEVER regresses below the last good value.
3. On `isFinal`: `accumulatedBase = lastNonEmptyText` (not `fullText` which could be empty).
4. On ANY error during active session: restart `beginRecognitionTask()` immediately with `accumulatedBase = lastNonEmptyText`.
5. Added `return` after `isFinal` restart to prevent double-restart if both result and error fire simultaneously.

### Architectural facts confirmed
- `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true` fires `isFinal = true` after silence (typically 2-4 seconds). The final result CAN be empty or shorter than the last partial.
- Errors during active sessions MUST trigger a restart, not be ignored. Silence timeout errors are the most common cause of dead recognition chains.
- The `lastNonEmptyText` pattern prevents any form of transcript regression regardless of what the recognizer returns.

### Watch out
- The recognizer callback fires on a background thread. `isSessionActive` has no synchronization — read/write races are possible but rare in practice since the main thread only writes it during explicit start/stop.
- `try? beginRecognitionTask()` silently swallows failures (recognizer unavailable). A noisy environment can cause the recognizer to be temporarily unavailable — add exponential backoff if this becomes an issue.

### Global?
Yes — this is a general `SFSpeechRecognizer` gotcha (isFinal with empty result, errors silently ignored) applicable to any iOS app using streaming on-device ASR. Copied to `~/.claude/memory/debug_history.md`.

---

## [2026-03] — Swift/SwiftUI — Smart Quotes in String Literals — RESOLVED

**Area:** All Swift source files
**Type:** Bug (codegen mistake — Claude-specific)

### Context
Claude repeatedly generated curly/typographic quotes (`"` U+201C, `"` U+201D) inside Swift string literals when writing human-readable strings containing item names (e.g., `"Removed \"\(item.name)\"`).

### Symptoms
`error: expected ',' separator` at the position of the opening curly quote. Misleading — does not say "unexpected character". Hit CI multiple times before root cause was identified.

### Approaches tried
- ❌ Fixed only what CI reported (surface symptom) — curly quotes reappeared in subsequent edits
- ✅ Scan every new Swift file for U+201C/U+201D before committing

### Root cause
AI training data includes rich-text/markdown which normalizes to typographic quotes. Claude generates them naturally when writing quoted strings inside Swift code.

### Fix
After writing any Swift string literal containing quoted names, scan for curly quotes:
```bash
python3 -c "import re,sys; [print(f'{i+1}: {l.rstrip()}') for i,l in enumerate(open(sys.argv[1]).readlines()) if re.search(r'[“”‘’]', l)]" <file>
```

### Architectural facts confirmed
- Curly quotes are almost never the only problem — always look deeper after fixing them
- The compiler error message "expected ',' separator" is the canonical symptom; do not be misled

### Watch out
Every Swift edit by Claude is a curly-quote risk. Check any file Claude touches that contains string literals with embedded item names, seat names, or quoted values.

### Global?
No — this is a Claude codegen pattern; not recorded globally because it's already in the global CLAUDE.md as a general rule.

---

## [2026-03] — SwiftUI — TicketEditorView Body Expression-Too-Complex — RESOLVED

**Area:** `Views/TicketEditorView.swift`
**Type:** Bug (compiler limit — architecture consequence)

### Context
`TicketEditorView.body` accumulated sections incrementally: transcript, ticket info, timeline, course pacing, per-seat items, edit history, actions, seat map button — all inline in one `var body: some View`. Hit build-breaking compiler error in CI run #36.

### Symptoms
`error: the compiler is unable to type-check this expression in reasonable time; try breaking up the expression into distinct sub-expressions`

### Approaches tried
- ❌ Adding more inline content to body — made it worse
- ✅ Decomposing into `@ViewBuilder` private functions and separate `View` structs

### Root cause
Swift type-checker has a fixed budget per expression. A monolithic `body` with 6+ sections, `ForEach` loops, and conditional blocks exceeds it. Deterministic once a threshold is crossed.

### Fix
Any `body` with more than ~4 sections must be decomposed into `@ViewBuilder` private functions or child `View` structs before committing. Decompose proactively — do not wait for CI to reject it.

### Architectural facts confirmed
- Xcode 26 has a strict type-checker budget — this will recur on any view that grows large
- `TicketEditorView` is the most complex view and the most likely to hit this again

### Watch out
Any new section added to `TicketEditorView` or `LiveSessionView` may push it over the limit. Always decompose when adding sections to these views.

### Global?
No — Swift-specific but not novel; standard Swift knowledge.

---

## [2026-03] — SwiftUI — `vm.` Scope Confusion (@State vs ViewModel) — RESOLVED

**Area:** `Views/TicketEditorView.swift`
**Type:** Bug (codegen mistake — Claude-specific)

### Context
When writing interaction code inside a View body, Claude used `vm.editingSeatTranscript = ...` for a property that lives on the View as `@State`, not on the ViewModel. The reverse also occurred: ViewModel methods written to set view-level state.

### Symptoms
Type error (caught by compiler after expression-too-complex errors clear). Difficult to spot during review because `vm.` prefix looks plausible.

### Root cause
When the ViewModel is the dominant state store in a View, `vm.` becomes habitual. Transient UI state (sheet open/close, editing selection, popover state) belongs on the View, not the ViewModel.

### Fix
Before committing View code that sets `vm.X`, verify `X` is an `@Observable` property on the ViewModel. Properties driving sheet presentation or temporary selection → `@State` on the View, no `vm.` prefix.

### Architectural facts confirmed
- WaitTicket uses `@Observable` (not `ObservableObject`) — no `@Published` anywhere
- Transient UI state: `@State` on View | Business/persistence state: `@Observable` ViewModel
- `editingSeatTranscript` is `@State` on TicketEditorView (not ViewModel property)

### Watch out
Any new interactive element in a View — especially sheets and selection state — will trigger this mistake. Always verify scope before committing.

### Global?
No — project-specific pattern; general Swift/SwiftUI knowledge.

---

## [2026-03] — CI/CD — curl HTTP/2 Exit-56 Masking ASC API Errors — RESOLVED

**Area:** `.github/workflows/build.yml`, ASC API integration
**Type:** Bug (CI/CD)

### Context
ASC (App Store Connect) API calls using `curl -sSf` with HTTP/2 were returning exit code 56 (network error) when the actual response was a 4xx HTTP error. This masked the real error body, making six consecutive CI runs fail with no actionable information.

### Symptoms
`curl: (56) HTTP/2 stream 1 was not closed cleanly: CANCEL (err 8)` — no response body visible, exit code always 56 regardless of HTTP status.

### Approaches tried
- ❌ Multiple guesses at the fix without reading the actual response body (six rounds)
- ✅ Switching to `--http1.1 -o /tmp/resp.json -w "%{http_code}"` to capture body and status separately

### Root cause
curl's `-f` flag causes exit 56 when HTTP/2 cancels the stream after a 4xx response. The actual error (`"'id' is not a valid field name"`) was in the JSON body that `-f` suppressed.

### Fix
For ALL ASC API calls in CI:
```bash
HTTP_STATUS=$(curl -s --http1.1 -o /tmp/resp.json -w "%{http_code}" ...)
if [ "$HTTP_STATUS" != "200" ]; then cat /tmp/resp.json; exit 1; fi
```
Never use `-f` for ASC API calls.

### Architectural facts confirmed
- JSON:API `id` is never valid in `fields[]` — only real attribute names
- ASC JWT: Python `cryptography` library only for signing — bash+openssl produces DER format, not R‖S format required by ASC
- YAML `run:` blocks: column-0 content terminates block scalars — move long scripts to `scripts/` files
- HTTP 409 on compliance PATCH (`ITSAppUsesNonExemptEncryption`) = already set via Info.plist — expected, non-fatal, use `|| true`
- betaGroups distribution failure should not block upload — use `|| exit 0` fallback

### Watch out
Any new ASC API call added to CI must use the `--http1.1 -o /tmp/X.json -w "%{http_code}"` pattern. Never use `-sSf` for ASC.

### Global?
Partially — curl/HTTP2/ASC pattern is in global CLAUDE.md. This entry retains the WaitTicket-specific CI facts (JWT, YAML scalars, 409 behavior).

---

## [2026-03] — SwiftData — Schema Migration Crash on Device — RESOLVED

**Area:** `WhisperTicketApp.swift`, `Models/Ticket.swift`
**Type:** Bug (architecture)

### Context
Any SwiftData `@Model` schema change (new property, new relationship, renamed field) causes `ModelContainer` init to throw on a device that has the old schema. Without recovery, this hits `fatalError` before any UI renders — instant crash on launch.

### Symptoms
App crashes immediately on launch after a schema change. No UI shown. Crash log shows `ModelContainer` init failure.

### Root cause
SwiftData does not auto-migrate between incompatible schemas in development. A `VersionedSchema` + `MigrationPlan` is required for production, but in dev the simplest fix is store-wipe recovery.

### Fix
`WhisperTicketApp.init()` catches `ModelContainer` init failures, wipes the `.sqlite`, `.sqlite-wal`, `.sqlite-shm` files, and retries. This is in place and working.

### Architectural facts confirmed
- **Dev device always has a previous version installed** — schema changes WILL hit this code path
- Production will need `VersionedSchema` + `MigrationPlan` before shipping to real users (data preservation)
- The store-wipe recovery is intentionally dev-only; it must be replaced before production launch
- `WhisperTicketApp.swift` init() is the canonical location for store-wipe recovery logic

### Watch out
Every new `@Model` property or relationship triggers this. The recovery handles it automatically, but data is wiped — don't test with seed data you care about.

### Global?
No — SwiftData migration behavior is documented; this entry retains the project-specific recovery location.

---

## [2026-03] — Debug Protocol — Always Get Crash Log Before Reading Source — RESOLVED

**Area:** All crash debugging
**Type:** Architecture (process rule)

### Context
A full analysis cycle was wasted reading source files and forming hypotheses for a runtime crash when the crash log would have confirmed root cause in seconds.

### Root cause
Treating "the crash location seems obvious" as a reason to skip the crash log. It never is.

### Fix / Rule
For any "app crashes" report: get the crash log FIRST.
- On-device: Settings → Privacy & Security → Analytics & Improvements → Analytics Data → `WhisperTicket-<date>.ips`
- Xcode: Window → Devices and Simulators → select device → View Device Logs
- TestFlight: 3-dot menu → Send Beta Feedback
- CI: `gh run view <id> --log`

### Watch out
Do not read source code or form hypotheses for a crash until the crash log is in hand. This is non-negotiable.

### Global?
No — crash log protocol is general knowledge; this entry documents the WaitTicket-specific crash log locations.

---

## [2026-03] — Architecture — Deprecated iOS APIs in AudioCaptureService — OPEN

**Area:** `Services/AudioCaptureService.swift`, `WhisperTicketApp.swift`
**Type:** Architecture (deprecation debt)

### Context
Two deprecated APIs were introduced early and carried forward. They are warnings now, not errors, but accumulate noise that buries real errors.

### Active deprecated calls
- `AVAudioSession.CategoryOptions.allowBluetooth` → use `.allowBluetoothHFP` (`AudioCaptureService.swift`)
- `AVAudioSession.sharedInstance().requestRecordPermission` → use `AVAudioApplication.requestRecordPermission()` (`WhisperTicketApp.swift:69` — **already fixed as of 2026-03-30 based on digest**)

### Status
`requestRecordPermission` appears fixed in the digest (WhisperTicketApp uses `AVAudioApplication.requestRecordPermission()`). `allowBluetooth` → `allowBluetoothHFP` status: verify on next AudioCaptureService touch.

### Watch out
Fix `.allowBluetooth` → `.allowBluetoothHFP` on the next edit to `AudioCaptureService.swift`. Do not carry forward.

### Global?
No — iOS API version specifics; not cross-project.

---

## [2026-05] — PDFMenuImportService — Upsell Tag Mismatch — RESOLVED

**Area:** `Services/PDFMenuImportService.swift`
**Type:** Bug (logic)

### Context
`defaultUpsellRules()` generated for PDF-imported menus used tag `"drink"` for beverage upsell condition. The tag convention across the rest of the project (MenuV1.sample.json, RuleBasedUpsellEngine) is `"beverage"`. PDF-imported items also get `tags: []`, so upsell rules would never fire regardless.

### Root cause
Tag convention mismatch — `"drink"` vs `"beverage"`. Introduced when PDFMenuImportService was first written without cross-referencing the existing tag taxonomy.

### Fix
Changed `"drink"` → `"beverage"` in `defaultUpsellRules()`. Note: upsell rules still won't fire for PDF-imported menus until items get proper tags (PDF parser sets `tags: []`). This is a Phase 2 improvement.

### Architectural facts confirmed
- Tag convention in this project: `"beverage"` (not `"drink"`) — defined in MenuV1.sample.json
- PDF-imported items always have `tags: []` — upsell by tag cannot work without a tagging pass
- `RuleBasedUpsellEngine` matches on `item.tags.contains(suggestion.tag)` — empty tags array means no tag-based upsell ever fires

### Watch out
Any future upsell rule additions must use the tag taxonomy from `MenuV1.sample.json`, not freeform strings. Tag mismatch fails silently.

### Global?
No — project-specific tag taxonomy.

---

## [2026-07-03] — MenuTextParser — Menu import garbage (title/fine-print/headings as items) — RESOLVED

**Area:** `Services/MenuTextParser.swift` (shared by PDF + Photo import)
**Type:** Bug cluster (heuristics) — full rewrite

### Symptoms (user-reported, reproduced on real menus)
1. Menu title imported as an item ("Applebee's Menu Prices 2024").
2. Fine print imported as items ("A la carte.", "Served with a breadstick.",
   table headers "PRICE"/"FOOD ITEM", copyright/disclaimer prose).
3. Real item names became unselectable CATEGORY headings with other items
   nested under them.
4. Prices wildly mispaired.

### Root causes (confirmed against extracted PDF text)
- `isLikelyCategoryHeader` treated ANY Title-Case line as a header when no
  price appeared within 3 lines. Real-world PDFs (Applebee's) extract as
  COLUMN RUNS — a block of 12-16 price lines followed by a block of name
  lines — so most item names had no nearby price and became categories.
- Line-adjacent name+price pairing cannot work on column-run layouts at all.
- Noise filtering only knew URLs/page numbers; nothing for table headers,
  nav rows ("Appetizers | Soups | ..."), titles, or fine-print sentences.

### Fix (rewrite, validated via Python mirror on real corpora)
- Headers: only (a) ALL-CAPS ending in "MENU" (brand possessive stripped,
  "APPLEBEE'S APPETIZERS MENU" → "Appetizers"), or (b) ALL meaningful tokens
  in a category vocabulary (~90 words; stopwords and/of/the/house ignored).
  Vocab headers are demoted if followed by a description-like line ("Pizza
  Sub" + ingredient list) and, in priced docs, ignored while prices are
  queued (headers never consume a price; "Chicken Quesadilla" is all-vocab).
- Priced pairing: FIFO price queue + name queue. Handles prices-first column
  runs (queue persists ACROSS category headers — required) and name-first
  layouts (name, desc lines, price). Categories where nothing got a price
  are dropped as title junk.
- Priceless (Yelp-style): name → wrapped-description state machine; desc
  continues until sentence-terminal punctuation (max 3 name-like lines).
- Noise/fine-print lists greatly expanded (priced-mode-only for sentence
  fine print — in priceless docs sentences are descriptions).

### Verification
Python mirror (scratchpad parser_proto.py) on pypdf-extracted text:
- Applebee's PDF: 93 items / 15 correct categories, zero junk items.
- Subway Yelp PDF (priceless, 25pp): 198 items / 8 correct categories, with
  descriptions.
- Synthetic taco menu (name-first, ALL-CAPS names) + classic inline-price
  menu: exact.

### Watch out / traps hit during tuning
- DESC_STARTERS word lists silently DROP real items: "The Classic Combo",
  "Fresh Brewed Coffee", "Crispy Chicken Tender Salad" — never reject a
  name candidate solely for starting with "the/fresh/crispy". Every dropped
  name also SHIFTS FIFO price alignment for the rest of the document.
- Calorie/fine-print regexes must not kill PRICE lines like
  "4.68 taco (438 cal.)" — check for a price before classifying as noise.
- Vocabulary must not contain common item words ("beef", "classic", "bacon")
  or the all-vocab rule promotes real items to headers.

### Global?
Partially — the "column-run PDF extraction breaks line-adjacent pairing"
insight applies to any PDFKit/pypdf text extraction of tabular layouts.
