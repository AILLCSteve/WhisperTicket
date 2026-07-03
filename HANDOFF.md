# HANDOFF — WaitTicket (2026-07-01)

## TL;DR
Voice ordering was rebuilt from streaming ASR → **record-then-transcribe** (can't
erase by design). Duplication fixed. Haptics added. TestFlight distribution fixed.
**Latest build on TestFlight: v1.5.0 (build 56).** Next action is YOURS: verify on
device.

## Current architecture — voice ordering (build 57+, 2026-07-03)
**Record to rotating files → transcribe each segment → stitch. No live/streaming UI.**
Build 56 (record-whole-file-then-transcribe) still dropped pre-pause text because
`SFSpeechURLRecognitionRequest` ALSO endpoints on internal silence and reports only
the last utterance. Fixed with two independent layers (see
`transcriptiondebughandoff/TRANSCRIPTION FIX IMPLEMENTATION.md` and
`memory/debug_history.md` 2026-07-03):
- `Services/AudioCaptureService.swift` — `AVAudioRecorder`, no length limit, with
  **silence-gated segment rotation**: after speech, 1.3s below the speech threshold
  closes the current .m4a, emits it via `onSegmentReady`, starts a new file (during
  silence → no speech lost). Every file to recognition is a short, pause-free chunk.
- `Services/SFSpeechTranscriptionService.swift` — `shouldReportPartialResults = true`
  as an OBSERVATION channel; `TranscriptStitcher` keeps epoch high-water text,
  detects context resets, and stitches epochs. Errors-after-text return the text;
  `max(15s, 2.5×dur)` watchdog prevents a hung spinner. (Still a finished FILE —
  NOT streaming ASR.)
- `ViewModels/LiveSessionViewModel.swift` — `onSegmentReady` → `AsyncStream<URL>`;
  a single serial consumer transcribes segments in order while recording continues;
  on stop, joins them and calls the EXISTING `appendTranscript(_:)` once per mic
  press (build-56 parse-once / append-only / no-dup invariants preserved).
- **Do NOT revert to streaming SFSpeechRecognizer; do NOT set partials=false; do NOT
  consume the first isFinal without the stitcher; do NOT add a second accumulation
  layer or cancel the serial consumer in finishRecording.**

## ✅ Verify on device (build 56, v1.5.0) — the whole point
1. **Pause test:** mic on → "I want a steak" → **pause ~5s** → "and mashed
   potatoes" → stop. Transcript must show the FULL sentence. (Note: text now
   appears AFTER you stop — waveform while recording, "Processing…", then text.)
2. **Add-more test:** record an item, stop; record again same seat, add another →
   both present, none duplicated, no limit on length.
3. **Multi-seat:** switch seats, record → each seat keeps its own order.
Report PASS/FAIL for each.

## ✅ Done this session (all on main, CI green)
- Transcript erase + duplication: streaming torn out, record-then-transcribe in
  (commit 326611c). Earlier streaming attempts: 13828a6, 53ebda7 (superseded).
- Haptics: record/stop/send/add tactile feedback (0490b70, `Views/Components/Haptics.swift`).
- CI/macOS-26 fixes: P12 → /usr/bin/openssl (6288c54); post-upload non-blocking +
  403 fix (2dbb180). **Pending ASC agreement** was the altool-19 blocker — YOU
  accepted it.
- TestFlight distribution: betaGroups query used illegal filter[isInternalGroup]
  (400 every run) → fixed to client-side filter; added `scripts/asc_report.py`
  diagnostics; extended build-visibility wait (15b758f). Internal group **"Dev1"**
  exists with autoAllBuilds=True → valid builds auto-distribute. v53/v54 confirmed
  VALID in ASC.

## ⚠️ If nothing reaches your phone
Distribution IS wired (Dev1, auto-distribute). If you don't see builds in the
TestFlight app: confirm your Apple ID is an **accepted tester in "Dev1"** (ASC →
TestFlight → Internal Testing → Dev1 → Testers) and that you're signed into
TestFlight with that same Apple ID.

## UI polish status
Haptics shipped. Further visual "stunning" work is blocked on ME being unable to
see the app render (Windows, no sim). When ready: send screenshots of Floor / Live
session / Ticket editor / Tickets list / Menu admin and I'll do targeted
refinements you review on TestFlight. (App already has a deliberate "Dark POS"
design system in `Views/Components/ChromeStyle.swift`.)

## Environment facts
- **PAID Apple Developer** (team M37X5J35F8), app com.whisperticket.app / App ID
  6760738060. TestFlight upload works on every `main` push.
- Windows dev box → **CI (GitHub Actions macOS) is Claude's only build/compile
  verification.** On-device behavior + visuals are user-verified.
- Workflow: commit → push `main` → `gh run watch <id>` → green auto-uploads to TF.
- macos-latest = macOS 26; keep P12 gen pinned to /usr/bin/openssl.
