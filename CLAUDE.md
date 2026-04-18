# CLAUDE.md — WhisperTicket Unified Knowledge Base

> **For Claude Code:** Read this entire file at the start of every session. It contains
> your engineering principles, project architecture, known bugs, debugging protocols,
> and CI procedures. Do not skip sections. The WhisperTicket-specific section begins
> at `## 8. PROJECT: WhisperTicket` and is the most critical context for this repo.

-----

## TABLE OF CONTENTS

1. [Engineering Principles](#1-engineering-principles)
1. [Code Quality Standards](#2-code-quality-standards)
1. [Architecture Guidelines](#3-architecture-guidelines)
1. [Git Workflow](#4-git-workflow)
1. [Brainstorming Protocol](#5-brainstorming-protocol)
1. [Configuration Management](#6-configuration-management)
1. [Documentation Standards](#7-documentation-standards)
1. [PROJECT: WhisperTicket](#8-project-whisperticket)
- 8.1 App Overview & Purpose
- 8.2 Full Stack Map
- 8.3 Data Flow Architecture
- 8.4 Transcription Service — Critical Knowledge
- 8.5 Per-Seat State Management
- 8.6 Order Parser — Known Limitations & Fixes
- 8.7 Menu Store & Matching
- 8.8 SwiftData — Known Pitfalls
- 8.9 SwiftUI Patterns in This Codebase
- 8.10 CI/CD Pipeline
- 8.11 Debugging Protocols
- 8.12 Priority Bug List
- 8.13 Phase 2 Roadmap
- 8.14 Files You Must Read Before Touching Each Subsystem

-----

## 1. ENGINEERING PRINCIPLES

### SOLID Principles

- **S — Single Responsibility:** Every class, struct, and function has one reason to change. Services handle one domain. ViewModels handle one screen’s state. Parsers parse; they do not persist.
- **O — Open/Closed:** Extend behavior via protocol conformance and new types. Do not modify existing working implementations to add new behavior — add a new conformer.
- **L — Liskov Substitution:** Any protocol conformer must be fully substitutable. Never add preconditions that the protocol does not specify.
- **I — Interface Segregation:** Protocols in `Protocols.swift` are already narrow. Keep them that way. Do not add methods to a protocol that only one conformer needs.
- **D — Dependency Inversion:** All services are injected via `AppServices` / environment. Never instantiate a concrete service inside a ViewModel or View.

### DRY / KISS / YAGNI

- **DRY:** If you write the same logic twice, extract it. Token overlap scoring appears in both `FuzzyMenuOrderParser` and `LocalBundleMenuStore` — this is a known duplication to resolve.
- **KISS:** Prefer the simpler solution. The fuzzy parser is intentionally simple. Do not reach for ML or embedding-based matching until the simple approach is proven insufficient.
- **YAGNI:** Do not build Phase 2 features during Phase 1 work. The `StubMenuImportService` exists precisely so Phase 2 wiring does not creep into Phase 1 sessions.

### Clean Code

- Functions under 20 lines where possible. If a function is longer, it is doing something inherently complex and deserves a clear comment explaining why.
- No magic numbers. Named constants or enums only.
- Error paths must be explicit. Never silently swallow errors with bare `try?` in production paths — only in genuinely non-critical fallbacks (e.g., `FloorPlanStore.save()`).
- Comments explain **why**, not **what**. The code shows what. Comments show intent.

### Domain-Driven Design

The domain language is: **Ticket, GuestSeat, DraftItem, MenuItem, ModifierGroup, CourseFlag, SeatConfig, FloorTable, ServerSection**.

Use these exact terms everywhere — in variable names, function names, comments, and log messages. Do not invent synonyms.

- A **Ticket** is a persisted order sent or being sent to the kitchen.
- A **TicketDraft** is the in-memory working state before confirmation.
- A **DraftItem** becomes a **TicketItem** when the draft is committed.
- A **GuestSeat** is a persisted per-seat record inside a Ticket.

-----

## 2. CODE QUALITY STANDARDS

### Swift-Specific

- Use `@Observable` (Swift 5.9 macro) for all ViewModels. Do not use `ObservableObject` / `@Published`.
- Use `async/await` throughout. No completion handlers in new code.
- Use `@MainActor` isolation for any property or function that touches UI state from a background context.
- Prefer `struct` over `class` for value types. Use `class` only for reference-semantic objects (services, SwiftData models).
- SwiftData models (`@Model`) are always `final class`. Never `struct`.
- Use `private(set)` for properties that are externally readable but only internally writable.
- Cancellables: always store in `Set<AnyCancellable>` and cancel explicitly in cleanup paths.

### Naming

- ViewModels: `[Screen]ViewModel` — e.g., `LiveSessionViewModel`
- Services: `[Domain]Service` or `[Domain]Store` — e.g., `AudioCaptureService`, `LocalBundleMenuStore`
- Protocols: descriptive with `Protocol` suffix — e.g., `TranscriptionServiceProtocol`
- Views: `[Feature]View` — e.g., `FloorView`, `SeatMapView`
- Avoid abbreviations except established domain terms (`VM` for ViewModel in comments only, never in code).

### Testing Mindset

- All services implement protocols. This means every service is mockable. Before adding a feature, ask: “Can I test this without the real microphone / real SwiftData store?”
- `FuzzyMenuOrderParser` is a pure function — test it with static transcripts before changing any logic.
- `SFSpeechTranscriptionService` cannot be unit-tested on CI (no microphone). Keep logic thin here and push complexity into the parser which can be tested.

-----

## 3. ARCHITECTURE GUIDELINES

### Service Injection Pattern

All services live in `AppServices` struct, injected via `@Entry var appServices` environment key. The pattern is:

```
WhisperTicketApp.init()
  → builds ModelContainer
  → constructs all concrete services
  → injects via .environment(\.appServices, AppServices(...))
    → every View accesses via @Environment(\.appServices) var services
      → ViewModels receive services via init() parameters
```

Never break this chain. Never reach for a service via a singleton or shared instance.

### ViewModel Lifecycle

ViewModels are created inside `.task {}` blocks on the View, passed concrete services from the environment. They are `@Observable` and stored in `@State` on the View. This means:

- The ViewModel lives as long as the View is in the hierarchy.
- When the View disappears, the ViewModel is deallocated and cancellables are cancelled.
- Do not store ViewModels in the environment — they are per-screen.

### Protocol Boundaries

The five core protocol boundaries are:

1. `AudioCaptureServiceProtocol` → `LiveSessionViewModel`
1. `TranscriptionServiceProtocol` → `LiveSessionViewModel`
1. `OrderParserProtocol` → `LiveSessionViewModel` + `TicketEditorViewModel`
1. `MenuStoreProtocol` → `LiveSessionViewModel` + `TicketEditorViewModel` + `MenuAdminView`
1. `TicketRepositoryProtocol` → `TicketsListViewModel` + `TicketEditorViewModel` + `WelcomeView`

Do not add cross-boundary calls. A parser does not call the repository. A repository does not call the parser.

### Multi-Approach Rule (Before Writing Code)

Before implementing any non-trivial feature, enumerate at least two approaches and state the tradeoffs. Document the chosen approach in a comment at the top of the relevant function. This prevents the single-path tunnel vision that causes debugging sessions to drag.

-----

## 4. GIT WORKFLOW

### Branch Naming

- `feature/[short-description]` — new capability
- `fix/[short-description]` — bug fix
- `refactor/[short-description]` — no behavior change
- `ci/[short-description]` — CI/build changes only

### Commit Messages

Format: `[type]: [imperative verb] [object]`

- `feat: add phonetic modifier matching to FuzzyMenuOrderParser`
- `fix: prevent recognition task restart after stopTranscribing called`
- `refactor: extract token overlap scoring into shared utility`
- `ci: cache xcodegen install between runs`

### Before Every Commit

1. Build succeeds locally (`xcodegen generate && xcodebuild build`)
1. No new SwiftLint warnings introduced
1. Any new public function has at least a one-line doc comment
1. `CLAUDE.md` updated if you changed an architectural decision

### PR Rules

- One PR per concern. Do not mix feature work with CI fixes.
- Every PR description states: what changed, why, and what to test manually.
- CI must pass before merge to `main`.

-----

## 5. BRAINSTORMING PROTOCOL

When tackling any problem with multiple viable solutions, follow this protocol before writing code:

**Step 1 — State the problem precisely.** One sentence. If you cannot, the problem is not understood yet.

**Step 2 — Generate at least 3 approaches.** Label them A, B, C. Include “do nothing / minimal change” as a candidate when appropriate.

**Step 3 — Evaluate each on:** correctness, complexity, testability, reversibility, CI impact.

**Step 4 — State the recommendation and rationale.** One paragraph.

**Step 5 — Implement the recommendation only.** Do not partially implement alternatives.

This protocol is mandatory for: any change to `SFSpeechTranscriptionService`, any change to `FuzzyMenuOrderParser`, any change to `LiveSessionViewModel.startRecording()` or `stopRecording()`, and any CI workflow change.

-----

## 6. CONFIGURATION MANAGEMENT

### Centralized Config

- `project.yml` is the single source of truth for bundle ID, version, deployment target, team ID, and signing config. Do not hardcode these values anywhere in Swift source.
- GitHub Secrets are the single source of truth for all credentials: `DIST_PRIVATE_KEY_PEM`, `DIST_CERT_DER_B64`, `DIST_CERT_P12_PASSWORD`, `PROV_PROFILE_BASE64`, `PROV_PROFILE_UUID`, `ASC_API_KEY`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `APPLE_TEAM_ID`.
- Never commit secrets. Never log secrets. Never print secrets in CI output.

### Environment Tiers

- **Local dev:** `LocalBundleMenuStore` + embedded fallback menu. No network required.
- **CI:** `macos-latest` runner, real signing, real TestFlight upload on `main` push.
- **Phase 2:** Supabase backend replaces `SwiftDataTicketRepository` and `LocalBundleMenuStore` for cloud sync.

### Feature Flags

Phase 2 features are gated by stub implementations conforming to the same protocols. To enable a Phase 2 feature, swap the concrete type in `WhisperTicketApp.init()`. No `#if` flags, no runtime feature toggles in MVP.

-----

## 7. DOCUMENTATION STANDARDS

### In-Code Documentation

- Every `protocol` definition gets a one-line `///` comment stating its responsibility.
- Every `@Model` class gets a comment stating what it persists and its relationship to other models.
- Every non-obvious algorithm (token overlap scoring, cursor management, finalization timer) gets a block comment explaining the invariant it maintains.
- `// MARK: -` sections are required in any file over 100 lines.

### docs/ Folder

- `SCHEMAS.md` — canonical data shape reference. Update when adding fields to any model.
- `PARSING.md` — parser pipeline and known limitations. Update when changing `FuzzyMenuOrderParser`.
- `UX_FLOWS.md` — user-facing flows. Update when changing navigation or adding new flows.
- `FUTURE_GOALS.md` — deferred features with implementation approaches. Update when a feature moves from future to active.
- `research/` — domain research that informed architectural decisions. Do not modify historical research files; add new ones.

-----

## 8. PROJECT: WhisperTicket

> **Claude Code directive:** When working in this repository, read sections 8.1
> through 8.14 completely before touching any file. The bugs described in section
> 8.12 are active and their root causes are documented. Do not attempt fixes without
> reading the relevant subsection first. Many past debugging sessions failed because
> the transcription lifecycle and cursor management contracts were not understood
> upfront.

-----

### 8.1 App Overview & Purpose

WhisperTicket is an iOS waitstaff voice ordering application. A server taps a table on the floor plan, selects a seat, presses a record button, speaks the order aloud, and the app:

1. Captures audio via `AVAudioEngine`
1. Transcribes speech via Apple’s `SFSpeechRecognizer` (on-device, no cloud cost)
1. Parses the transcript against the loaded menu using fuzzy token matching
1. Builds a `TicketDraft` with per-seat `DraftItem` records
1. Allows the server to review, edit, and confirm
1. Persists as a `Ticket` (SwiftData) with `GuestSeat` children
1. Displays on a live floor plan with status-colored table tiles

**Core UX contract:** The server looks at the guest, not the screen. Voice capture must be reliable, forgiving, and non-destructive. Transcripts must accumulate — never reset — between button presses for the same seat.

**Deployment target:** iOS 17.0. Swift 5.9. Xcode 15+. `project.yml` → xcodegen → `.xcodeproj`.

**Note on recording model:** The app uses a tap-to-start / tap-to-stop model (not hold-to-talk). The server presses once to begin, speaks the full order for a seat, then presses again to stop. Multiple presses for the same seat accumulate transcript — they do not reset it.

-----

### 8.2 Full Stack Map

```
┌─────────────────────────────────────────────────────────┐
│                    WhisperTicketApp                      │
│  Builds ModelContainer + all services → injects via env  │
└───────────────────┬─────────────────────────────────────┘
                    │ @Environment(\.appServices)
        ┌───────────┼────────────────┐
        │           │                │
   FloorView   TicketsListView  MenuAdminView
        │
   TableOrderEntryView  ──→  LiveSessionViewModel
        │                         │
        │              ┌──────────┼──────────────┐
        │         AudioCapture  Transcription   Parser
        │         Service       Service         (Fuzzy)
        │              │              │
        │         AVAudioEngine  SFSpeechRecognizer
        │
   TicketEditorView  ──→  TicketEditorViewModel
        │                         │
        │                    Repository (SwiftData)
        │
   SeatMapView (drag-drop seat reassignment)
```

**Services and their concrete implementations (Phase 1):**

|Protocol                      |Concrete Class                |Notes                         |
|------------------------------|------------------------------|------------------------------|
|`AudioCaptureServiceProtocol` |`AudioCaptureService`         |AVAudioEngine tap             |
|`TranscriptionServiceProtocol`|`SFSpeechTranscriptionService`|On-device ASR                 |
|`OrderParserProtocol`         |`FuzzyMenuOrderParser`        |Token overlap                 |
|`MenuStoreProtocol`           |`LocalBundleMenuStore`        |UserDefaults + bundle fallback|
|`TicketRepositoryProtocol`    |`SwiftDataTicketRepository`   |SwiftData/SQLite              |
|`UpsellEngineProtocol`        |`RuleBasedUpsellEngine`       |Rule-based suggestions        |
|`MenuImportServiceProtocol`   |`PDFMenuImportService`        |PDFKit text extraction        |

-----

### 8.3 Data Flow Architecture

#### Recording Session Data Flow (Happy Path)

```
[Record Button Pressed]
        ↓
LiveSessionViewModel.startRecording()
  → captures priorSeatTranscript = seatTranscripts[activeSeatNumber] ?? ""
  → sets draft.consumedCursor
  → AudioCaptureService.startCapture()
  → SFSpeechTranscriptionService.startTranscribing(audioPublisher)
  → subscribes to transcriptionPublisher()
        ↓
[User speaks]
        ↓
AVAudioEngine tap fires → bufferSubject.send(buffer)
        ↓
SFSpeechAudioBufferRecognitionRequest.append(buffer)
        ↓
SFSpeechRecognizer fires result callback
  → builds fullText = accumulatedBase + currentText
  → sends TranscriptionSegment(text: fullText, isFinal: false/true)
        ↓
LiveSessionViewModel.handleTranscriptionSegment(_:)
  → builds fullText = priorSeatTranscript + segment.text
  → seatTranscripts[activeSeatNumber] = fullText
  → FuzzyMenuOrderParser.parseDraft(transcript: fullText, existingDraft: draft, menu: menu)
  → stamps new DraftItems with activeSeatNumber
  → refreshUpsells()
        ↓
[Record Button Pressed Again]
        ↓
LiveSessionViewModel.stopRecording()
  → AudioCaptureService.stopCapture()
  → isRecording = false
  → starts 3-second finalizationTimer
        ↓
[3 seconds later]
LiveSessionViewModel.finalizeTranscription()
  → transcriptionService.stopTranscribing()
  → if no items parsed for seat: adds cleaned transcript as fallback item
```

#### Ticket Creation Flow

```
[Server taps "Confirm" / "Review & Send"]
        ↓
SwiftDataTicketRepository.createTicket(from: draft, serverId:)
  → creates Ticket @Model
  → for each seatNumber in draft.items:
      creates GuestSeat @Model
      creates TicketItem @Model for each DraftItem
      creates TicketModifier @Model for each modifier
  → unseated items go to seat 1
  → sets ticket.rawTranscript = draft.aggregateTranscript
  → modelContext.insert(ticket)
  → modelContext.save()
```

-----

### 8.4 Transcription Service — Critical Knowledge

> **This is the most important section. Read it before touching anything related to recording.**

#### SFSpeechRecognizer Constraints (Apple Platform Limits)

1. **~60 second hard limit per recognition task.** Apple terminates the task and fires `isFinal = true`. This is not an error — it is expected behavior. The service handles this with `accumulatedBase` accumulation and auto-restart via `beginRecognitionTask()`.
1. **On-device recognition is set** (`requiresOnDeviceRecognition = true`). This means: no network required, no data leaves the device, but accuracy is slightly lower than cloud recognition and the on-device model must be downloaded on first use (iOS handles this automatically).
1. **The recognizer emits partial results continuously** (`shouldReportPartialResults = true`). Every word fires a new segment. The `isFinal` flag only fires when the task ends (time limit or silence detection).
1. **Silence detection is built into SFSpeechRecognizer.** After approximately 1-2 seconds of silence, the recognizer may finalize the current result and restart. This is the root cause of the “stops and starts” issue reported during development. The restart is handled in `SFSpeechTranscriptionService` via `accumulatedBase`, but the ViewModel’s `priorSeatTranscript` is only captured at `startRecording()` — creating a staleness gap described in BUG-2.

#### The Race Condition (Active Bug — See BUG-1 in 8.12)

```
Timeline of the bug:

T=0:   Server presses Record
T=0:   startRecording() captures priorSeatTranscript = "burger fries"
T=45:  SFSpeechRecognizer auto-fires isFinal (60s limit approaching)
T=45:  accumulatedBase = "burger fries coke" (correct in service)
T=45:  beginRecognitionTask() restarts (correct)
T=60:  Server presses Record again (stop)
T=60:  stopRecording() → audioCapture.stopCapture() (engine stops)
T=60:  finalizationTimer starts (3 seconds)
T=63:  finalizeTranscription() → transcriptionService.stopTranscribing()
                                             ↑
                              BUG: new recognition task started at T=45
                              may still be running. Its isFinal callback
                              fires after stopTranscribing(), calling
                              beginRecognitionTask() again on dead audio.
```

#### The Fix (Implement This)

In `SFSpeechTranscriptionService`, `isSessionActive` must be set to `false` as the FIRST operation in `stopTranscribing()`, and checked at the top of the `isFinal` handler:

```swift
// In stopTranscribing():
func stopTranscribing() {
    isSessionActive = false          // MUST be first — gates the isFinal handler
    storedAudioPublisher = nil
    audioCancellable?.cancel()
    audioCancellable = nil
    recognitionRequest?.endAudio()   // triggers final drain
    recognitionTask?.cancel()
    recognitionRequest = nil
    recognitionTask = nil
    accumulatedBase = ""
}

// In the recognition task callback, isFinal branch:
if result.isFinal {
    guard self.isSessionActive else { return }  // ADD THIS LINE
    self.accumulatedBase = fullText
    self.recognitionRequest = nil
    self.recognitionTask = nil
    try? self.beginRecognitionTask()
}
```

#### AVAudioSession Configuration

Current config in `AudioCaptureService.startCapture()`:

```swift
session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
```

This is correct for restaurant environments. `.measurement` mode minimizes audio processing (no noise reduction, no AGC) which gives SFSpeechRecognizer the cleanest possible signal. Do not change this to `.voiceChat` or `.default` — those modes apply processing that degrades transcription accuracy in ambient noise environments.

**Known issue with Bluetooth:** `.allowBluetoothHFP` enables Bluetooth headsets but forces 8kHz sample rate on some devices. If a server uses AirPods, transcription quality may degrade. Consider adding `.allowBluetoothA2DP` or removing Bluetooth options if this becomes a reported problem.

-----

### 8.5 Per-Seat State Management

#### The Seat State Contract

Every seat has exactly one transcript string. That transcript is the complete accumulated speech for that seat across all recording sessions. It must never be reset by pauses, by the recognizer auto-restarting, or by switching to another seat and back.

**Three places that hold seat transcript state (must always be in sync):**

|Location                              |Type           |Owner      |Purpose                |
|--------------------------------------|---------------|-----------|-----------------------|
|`LiveSessionViewModel.seatTranscripts`|`[Int: String]`|ViewModel  |UI display, live source|
|`draft.seatTranscripts`               |`[Int: String]`|TicketDraft|Parser input           |
|`GuestSeat.rawTranscript`             |`String`       |SwiftData  |Persisted after confirm|

After every call to `handleTranscriptionSegment`, all three must reflect the same value for the active seat. The current code does this correctly:

```swift
seatTranscripts[activeSeatNumber] = fullText          // ViewModel
draft.seatTranscripts[activeSeatNumber] = fullText    // Draft
draft.rawTranscript = fullText                         // Aggregate (legacy compat)
```

After `parseDraft` replaces the draft struct, the code re-syncs:

```swift
draft.seatTranscripts = seatTranscripts   // Re-sync after struct replace
draft.rawTranscript = fullText            // Re-sync
```

**Do not remove these re-sync lines.** `parseDraft` returns a new `TicketDraft` value and the seat transcripts must be manually restored because the parser replaces the entire struct.

#### Seat Switching

When `activeSeatNumber` changes (server taps a different seat chip), recording must be stopped first. The UI should enforce this — do not allow seat switching while `isRecording == true`. If the seat changes during recording, `priorSeatTranscript` will be captured for the wrong seat on the next `startRecording()` call.

#### Clearing a Seat

`clearSeat(_ seatNumber:)` in `LiveSessionViewModel`:

- Removes all draft items for that seat
- Removes the seat’s transcript from `seatTranscripts` and `draft.seatTranscripts`
- Resets `priorSeatTranscript = ""` and `draft.consumedCursor = 0` if the active seat is being cleared

This is correct. Do not skip the cursor reset — if you clear the active seat without resetting the cursor, the parser will skip the next recording entirely because `consumedCursor` points past the new (empty) transcript.

-----

### 8.6 Order Parser — Known Limitations & Fixes

#### How FuzzyMenuOrderParser Works

```
Input: transcript string, existingDraft, menu
Output: updated TicketDraft

1. Skip already-processed text using consumedCursor
2. normalizeText(): lowercase, strip fillers, convert number words to digits
3. splitIntoSegments(): split on commas and periods
4. For each segment:
   a. detectCourse(): check for course keywords → updates currentCourse state
   b. detectSeat(): check for "seat N" pattern → updates currentSeat state
   c. findBestItem(): token overlap against all menu items (threshold 0.4)
   d. extractQuantity(): first digit in segment
   e. extractModifiers(): temperature phrases + modifier group option names
   f. build DraftItem, call draft.addItem() (dedup by menuItemId+modifiers+seat)
5. Set consumedCursor = transcript.count
```

#### The consumedCursor Contract

`consumedCursor` is the character index in the transcript string up to which the parser has already processed. On each call to `parseDraft`, only `transcript[consumedCursor...]` is processed. After processing, `consumedCursor` is set to `transcript.count`.

**The invariant that must hold:** `consumedCursor` must always reflect the length of text that has been fully parsed. It must be reset to 0 when the transcript is reset (new recording session for a fresh seat), and it must be set to `priorSeatTranscript.count + 1` when resuming a seat that already has text.

**Bug risk:** If `startRecording()` sets `consumedCursor` incorrectly (too high → new words skipped; too low → old text re-parsed and items duplicated), the entire order will be wrong. The safe fix: always derive `consumedCursor` from `seatTranscripts[activeSeatNumber]?.count ?? 0` — the actual stored transcript length — not from `priorSeatTranscript.count` which was captured before any mid-session restarts.

#### Known Parser Limitations

1. **Seat detection requires explicit “seat N” phrasing.** The server must say “seat two, the burger” — not “for her, the burger.” Pronoun resolution is not implemented.
1. **Course detection is positional and sticky.** Once “entrees:” is detected, all subsequent items are classified as entrees until a new course keyword appears. The parser does not infer course from menu item category.
1. **Token overlap scoring (0.4 threshold) can produce false positives** with short menu item names. “Soup” correctly matches “Soup of the Day” but also risks matching non-order phrases containing the word “soup.”
1. **Temperature detection checks multi-word phrases first** (longest-first sort) to avoid “medium” matching before “medium rare” is checked. Do not change this sort order.
1. **Modifier extraction only captures options defined in the item’s modifierGroups.** If “bacon” is not a modifier option on the Classic Burger, “add bacon” is silently dropped. The embedded demo menu has minimal modifier groups — this needs expansion.
1. **The parser does not handle negation-with-substitution** (“no onion, add bacon instead”). “No onion” is captured as a negation. “Add bacon instead” depends entirely on whether “bacon” is a modifier option.

#### Improving Modifier Parsing (Recommended Next Step)

**Approach A (extend current parser):** Add a pre-pass that identifies negation chains. “No X, Y, Z” should negate all of X, Y, Z until the chain breaks. Add substitution detection: “instead of X, Y” → negate X, add Y.

**Approach B (OpenAI structured output):** Implement `AIOrderParser` conforming to `OrderParserProtocol`. Send transcript + menu item name + modifier options to GPT-4o with structured JSON schema output. Use as fallback when fuzzy confidence < 0.6. The schema is defined in `docs/research/restaurant-server-workflow.md` section 10.

Recommended: implement Approach A first (free, fast, offline), add Approach B as an opt-in “AI Fill” button (already stubbed in UX_FLOWS.md).

#### Deduplication Logic

`TicketDraft.addItem()` deduplicates by `menuItemId + modifierNames + seatNumber`. Key edge case: if `seatNumber == nil` (unseated) and a new item arrives with `seatNumber == 1`, they will NOT be deduped — this is correct, different seats. But if the same item is parsed twice from the same transcript segment (cursor bug), you get a duplicate — this IS a bug caused by cursor mismanagement, not the dedup logic.

-----

### 8.7 Menu Store & Matching

#### Load Strategy (3-tier fallback)

`LocalBundleMenuStore.loadMenu()` tries in order:

1. **Bundle file** — `MenuV1.sample.json` (or any JSON with “menu” in the name)
1. **UserDefaults** — previously imported/saved menu
1. **Embedded Swift string** — `embeddedMenuJSON` hardcoded in `LocalBundleMenuStore.swift`

Strategy 3 means the app always has a working menu even with no bundle file. The embedded menu is a full demo restaurant with Appetizers, Salads, Entrees, Sides, Drinks, and Desserts.

#### Search Index

`buildIndex(from:)` creates two entries per menu item: the item’s own tokens, and pluralized versions (“burgers” matches “Classic Burger”). The index is rebuilt on every `saveMenu()` call.

`findBestMatches(text:maxResults:)` uses token overlap with threshold 0.2 (lower than the parser’s 0.4) because this is used for suggestion/search UI, not for committing items.

#### PDF Menu Import

`PDFMenuImportService` uses PDFKit text extraction — it only works on PDFs with selectable text. Scanned menus (including the Applebee’s PDF in `Menus/`) will fail with the “no readable text” error. For scanned menus, Phase 2 will use OpenAI Vision API (GPT-4o image input). The `StubMenuImportService` placeholder documents the exact implementation steps.

-----

### 8.8 SwiftData — Known Pitfalls

#### Schema and Migration

`WhisperTicketApp.init()` catches `ModelContainer` creation failures and wipes the SQLite store. This is intentional for development velocity — schema changes would otherwise crash on launch. **In production this would cause data loss.** Before shipping to real restaurants, implement `VersionedSchema` and `MigrationPlan`.

The schema: `Ticket`, `GuestSeat`, `TicketItem`, `TicketModifier`, `TicketEditEvent`. All use cascade delete. Deleting a `Ticket` deletes all guests, items, modifiers, and edit events.

#### Threading

`SwiftDataTicketRepository` uses `container.mainContext` — the main actor context. All repository calls are `async` and must be called from `@MainActor` context or with `await`. Do not create a new `ModelContext` on a background thread. SwiftData contexts are not thread-safe.

#### Status Field

`Ticket.status` is stored as `String` (raw value of `TicketStatus` enum). SwiftData cannot store enum types directly. Always use `.rawValue` when writing to `status` and `TicketStatus(rawValue:)` when reading. Use the `ticketStatus` computed property everywhere in UI and business logic — never access `ticket.status` directly outside the repository.

#### SwiftData Crash on Launch

If the app crashes immediately on launch with a SwiftData error:

1. Delete the app from the simulator/device entirely.
1. Clean build folder (`Cmd+Shift+K`).
1. Rebuild and run.

If the wipe logic itself crashes, the `fatalError` message will identify which model is failing. Check if a new `@Model` property was added without a default value — SwiftData requires all properties to have defaults or be optional.

-----

### 8.9 SwiftUI Patterns in This Codebase

#### Chrome Design System

All UI uses the Chrome design system defined in `ChromeStyle.swift`. Color tokens:

- `.chromePrimary` — blue-purple accent, primary interactive elements
- `.chromeTeal` — positive/available states
- `.chromeAmber` — in-progress/sent states
- `.chromeSilverHigh` / `.chromeSilverLow` — border gradients

View modifiers:

- `.chromeCard(cornerRadius:glowColor:glowRadius:)` — glass card background
- `.chromeShimmer()` — animated shimmer for record button / primary CTA
- `.glowRing(color:radius:)` — colored halo for status elements
- `.chromeTabBar()` — frosted chrome tab bar appearance

Do not introduce UIKit color literals or hardcoded hex values in SwiftUI views. Always use the token system.

#### Navigation Pattern

Navigation uses `NavigationStack` with `navigationDestination(item:)` (iOS 16+ pattern). Navigation is driven by optional `@State` items — setting the item triggers navigation, clearing it dismisses.

- `FloorView` → `TableOrderEntryView` (via `navigateToOrder: FloorTable?`)
- `FloorView` → `TicketEditorView` (via `navigateToTicket: Ticket?`)

#### Observable / State Rules

- `@Environment(\.appServices)` — for services (read-only, injected from app root)
- `@Environment(\.modelContext)` — for SwiftData operations in leaf views (SeatMapView)
- `@State` — for view-local state and ViewModels
- `@Binding` — for state owned by a parent (WelcomeView’s `isPresented`)

Do not use `@StateObject` or `@ObservedObject`. This codebase uses Swift 5.9 `@Observable` exclusively.

#### Async Task Pattern

UI-triggered async work uses `.task {}` for lifecycle-bound work and `Task { }` inside button actions. Always use `await`. Never use `DispatchQueue.main.async` for SwiftUI state updates — `@Observable` properties coalesce updates on the main actor automatically.

-----

### 8.10 CI/CD Pipeline

#### Pipeline Overview

`.github/workflows/build.yml` runs on every push to `main` or `develop`, and on PRs to `main`.

Steps:

1. Checkout
1. Select Xcode (latest-stable)
1. `brew install xcodegen` — **SLOW, not cached** (Fix 1 below)
1. `xcodegen generate --spec project.yml` — generates `.xcodeproj`
1. Install distribution certificate (builds P12 from secrets on runner)
1. Install provisioning profile
1. Write ASC API key
1. `xcodebuild archive` — produces `.xcarchive`
1. Verify version and bundle resources in archive
1. Export + upload to TestFlight (main branch only)
1. Set compliance + distribute to internal beta group (main branch only)
1. Export IPA only (PR builds)
1. Upload artifacts

#### CI Time Optimization (Implement These)

**Fix 1 — Cache xcodegen (saves 2-3 min per run):**

```yaml
- name: Cache xcodegen
  uses: actions/cache@v4
  with:
    path: /usr/local/bin/xcodegen
    key: xcodegen-${{ runner.os }}-2.36.0

- name: Install xcodegen
  run: |
    if ! command -v xcodegen &> /dev/null; then
      brew install xcodegen
    fi
```

**Fix 2 — Cache DerivedData (saves 2-5 min on incremental builds):**

```yaml
- name: Cache DerivedData
  uses: actions/cache@v4
  with:
    path: ~/Library/Developer/Xcode/DerivedData
    key: derived-${{ runner.os }}-${{ hashFiles('**/*.swift', 'project.yml') }}
    restore-keys: derived-${{ runner.os }}-
```

**Fix 3 — Verify upload condition covers both upload steps.** The TestFlight upload and the compliance/distribute step should both gate on `github.ref == 'refs/heads/main' && github.event_name == 'push'`. Review the workflow to confirm `develop` branch pushes do not trigger uploads.

#### Signing Architecture

The signing uses a custom pattern (not Fastlane, not match):

- `setup-signing.py` — one-time local run to generate cert + profile and push to GitHub Secrets
- `gen_asc_jwt.py` — generates ES256 JWT for ASC API calls from CI
- CI runner builds the P12 from stored PEM + DER using macOS LibreSSL

**If the certificate expires or is revoked:** Re-run `setup-signing.py` locally with fresh credentials. It revokes existing certs, creates new ones, and updates all GitHub Secrets automatically.

**If the ASC API key expires (180-day limit):** Generate a new key in App Store Connect, update the `ASC_API_KEY` secret in GitHub.

#### Build Number Strategy

`CURRENT_PROJECT_VERSION` = `${{ github.run_number }}` in CI. This auto-increments and never conflicts with Apple. Do not manually set build numbers. `MARKETING_VERSION` is in `project.yml` — bump this manually before a new App Store version.

#### Common CI Failure Reference

|Error                                    |Cause                         |Fix                                  |
|-----------------------------------------|------------------------------|-------------------------------------|
|`xcodegen: command not found`            |Cache miss, brew failed       |Add brew install fallback (Fix 1)    |
|`Code signing identity not found`        |Expired cert or wrong keychain|Re-run `setup-signing.py`            |
|`No profiles for 'com.whisperticket.app'`|Profile expired               |Re-run `setup-signing.py`            |
|`JWT error: 401`                         |ASC key expired               |Generate new key, update secret      |
|`Build input file not found`             |xcodegen not run or wrong path|Check `project.yml` sources path     |
|`Module not found: Speech`               |Missing framework             |Add `Speech.framework` to project.yml|

-----

### 8.11 Debugging Protocols

#### Transcription Not Working / Silent Failures

1. Check console for `⚠️ Speech recognition not authorized` — must be `.authorized`.
1. Check console for `⚠️ Microphone not authorized` — must be `true`.
1. Check `SFSpeechRecognizer(locale:).isAvailable` — can be `false` if on-device model not downloaded yet. Usually resolves on next launch.
1. Temporarily add `print` in `bufferSubject.send(buffer)` to confirm audio is flowing. If this fires but no transcription segments arrive, the recognizer is the issue. If this does not fire, the AVAudioEngine is the issue.
1. Check `audioEngine.isRunning` after `startCapture()`.

#### Items Not Appearing in Draft / Duplicate Items

1. Print `draft.consumedCursor` at the start of each `parseDraft` call. If it equals `transcript.count`, nothing will be parsed — all text is already consumed.
1. Print the `newText` slice being parsed. Confirm it contains the expected new words.
1. Print `findBestItem` results for each segment. If score < 0.4, no item is added even if the spoken word sounds correct. The menu item name and the spoken word must share at least 40% of their tokens after normalization.
1. For duplicates: print `draft.items.map { "\($0.menuItemId)-\($0.seatNumber ?? -1)" }` before and after each parse. Identical entries = dedup failing (cursor bug). Different entries = item is genuinely new.

#### Seat Transcript Not Persisting

1. Confirm `seatTranscripts[activeSeatNumber]` is set in `handleTranscriptionSegment`.
1. Confirm `draft.seatTranscripts = seatTranscripts` re-sync runs after `parseDraft`.
1. Confirm `priorSeatTranscript` is correctly captured before `startCapture()` is called.
1. Confirm `clearSeat()` is not being called inadvertently when switching seats.

#### Floor Plan Not Showing Active Tickets

`FloorView.loadActiveTickets()` fetches all non-closed tickets and maps them by `tableNumber`. If a ticket is not appearing:

1. Confirm `ticket.ticketStatus != .closed`.
1. Confirm `ticket.tableNumber` exactly matches `table.name` (case-insensitive comparison is used in `FloorPlanStore.table(named:)` but the map key in `loadActiveTickets` is case-sensitive).
1. Call `await loadActiveTickets()` manually via the refresh button.

-----

### 8.12 Priority Bug List

These are confirmed bugs with documented root causes. Address in this order.

-----

**BUG-1 (CRITICAL): Recognition task restarts after stopTranscribing()**

**Symptom:** Transcription continues briefly after the server stops recording. New items appear in the draft after recording should have stopped. Occasionally a second recording session picks up artifacts from the previous session.

**Root cause:** `stopTranscribing()` calls `recognitionRequest?.endAudio()` which triggers a final drain callback. If the service’s `isFinal` handler fires during the drain, `isSessionActive` may not have been set to `false` yet, causing `beginRecognitionTask()` to fire again on a dead audio engine.

**Fix:** Set `isSessionActive = false` as the FIRST line of `stopTranscribing()`. Add `guard self.isSessionActive else { return }` at the top of the `isFinal` branch in the recognition task callback.

**File:** `ios/WhisperTicket/Services/SFSpeechTranscriptionService.swift`

-----

**BUG-2 (HIGH): Transcript cursor miscalculation after mid-session recognizer restart**

**Symptom:** In noisy environments or after long recordings (>60s), new words spoken after a recognizer auto-restart may be skipped or old text may be re-parsed, causing duplicate items.

**Root cause:** `consumedCursor` is set from `priorSeatTranscript.count` in `startRecording()`. If the recognizer restarts mid-session, `accumulatedBase` grows in the service but `priorSeatTranscript` remains at the pre-session value. On the next Record press, `consumedCursor` is derived from the stale length.

**Fix:** In `LiveSessionViewModel.startRecording()`, change:

```swift
// Current (fragile):
draft.consumedCursor = priorSeatTranscript.isEmpty ? 0 : priorSeatTranscript.count + 1

// Fixed (derives from authoritative source):
let currentTranscriptLength = seatTranscripts[activeSeatNumber]?.count ?? 0
draft.consumedCursor = currentTranscriptLength == 0 ? 0 : currentTranscriptLength + 1
```

**File:** `ios/WhisperTicket/ViewModels/LiveSessionViewModel.swift`

-----

**BUG-3 (HIGH): Modifier chains not fully captured**

**Symptom:** “burger no onion add bacon” captures the burger but drops “add bacon” if bacon is not defined as a modifier option in the menu’s `modifierGroups`.

**Root cause:** Modifier extraction only checks options in the item’s `modifierGroups`. Items in the embedded demo menu have minimal modifier coverage.

**Fix (immediate):** Expand `modifier_groups` in the embedded menu JSON in `LocalBundleMenuStore.swift` to include common modifiers (bacon, cheese, onion, tomato, lettuce, sauce options) for burger and other items.

**Fix (long-term):** Implement AI modifier parsing via OpenAI GPT-4o structured output as described in section 8.6.

**Files:** `ios/WhisperTicket/Services/LocalBundleMenuStore.swift` (embedded JSON), `ios/WhisperTicket/Services/FuzzyMenuOrderParser.swift`

-----

**BUG-4 (MEDIUM): Allergy flag not visually prominent after ticket is sent**

**Symptom:** Allergy items show correctly in the live session (red banner), but once the ticket is sent and viewed in `TicketEditorView`, the allergy indicator is not prominently visible to the server before sending to the kitchen.

**Root cause:** `TicketItem.hasAllergyFlag` is persisted but `TicketEditorView` does not render a prominent red badge/banner for flagged items.

**Fix:** In `TicketEditorView`, check `item.hasAllergyFlag` and render:

```swift
if item.hasAllergyFlag {
    Label("ALLERGY", systemImage: "exclamationmark.triangle.fill")
        .font(.caption.bold())
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.red)
        .clipShape(Capsule())
}
```

If `!item.allergyConfirmed`, add a pulsing animation to make it unmissable.

**File:** `ios/WhisperTicket/Views/` (TicketEditorView — implement if not already present)

-----

**BUG-5 (MEDIUM): CI xcodegen not cached**

**Symptom:** Every CI run spends 2-3 minutes reinstalling xcodegen via brew.

**Root cause:** No `actions/cache` step for the xcodegen binary.

**Fix:** Add cache step from section 8.10 Fix 1.

**File:** `.github/workflows/build.yml`

-----

**BUG-6 (LOW): Token overlap scoring duplicated**

**Symptom:** The same `tokenOverlapScore` algorithm exists in both `FuzzyMenuOrderParser` and `LocalBundleMenuStore`. Changes to the algorithm in one place do not propagate to the other.

**Fix:** Extract into a shared utility — either a free function in a new `StringMatching.swift` file, or an extension on `[String]`. Both classes import it.

**Files:** `ios/WhisperTicket/Services/FuzzyMenuOrderParser.swift`, `ios/WhisperTicket/Services/LocalBundleMenuStore.swift`

-----

### 8.13 Phase 2 Roadmap

Full details in `docs/FUTURE_GOALS.md`. Implementation priority:

|Priority|Feature                       |Effort|Key Integration Point                                       |
|--------|------------------------------|------|------------------------------------------------------------|
|1       |QR/NFC table select           |Low   |`FloorView` + CoreNFC entitlement                           |
|2       |Printer support (ESC/POS)     |Medium|`TicketEditorView` toolbar                                  |
|3       |AI Order Parser (GPT-4o)      |Medium|`AIOrderParser: OrderParserProtocol`                        |
|4       |POS integration (Toast/Square)|High  |`POSExportServiceProtocol`                                  |
|5       |Kitchen display (iPad)        |Medium|Supabase Realtime                                           |
|6       |Supabase backend              |High  |Replace `SwiftDataTicketRepository` + `LocalBundleMenuStore`|
|7       |Manager fraud analytics       |Medium|Supabase + ManagerDashboardView                             |
|8       |Training mode                 |Medium|`TrainingEvaluatorService`                                  |
|9       |Multilingual support          |High  |`NLLanguageRecognizer` + DeepL                              |

**Phase 2 injection points (where to swap concrete implementations):**

All swaps happen exclusively in `WhisperTicketApp.init()` by changing which concrete type is passed to `AppServices`. No view or ViewModel code changes required for backend swaps — this is the payoff of the protocol architecture.

**OpenAI Vision Menu Import** (immediate Phase 2 unlock): Replace `PDFMenuImportService()` with `OpenAIMenuImportService()` in `AppServices`. The stub in `StubMenuImportService.swift` documents exactly the 5 steps needed.

-----

### 8.14 Files You Must Read Before Touching Each Subsystem

|If you are working on…        |Read these files first                                                                                                                                                                     |
|------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|Transcription (recording, ASR)|`SFSpeechTranscriptionService.swift`, `AudioCaptureService.swift`, `LiveSessionViewModel.swift` (startRecording / stopRecording / handleTranscriptionSegment), **section 8.4 of this file**|
|Order parsing                 |`FuzzyMenuOrderParser.swift`, `Protocols.swift` (OrderParserProtocol), `docs/PARSING.md`, **section 8.6 of this file**                                                                     |
|Seat management               |`LiveSessionViewModel.swift` (full file), `TicketDraft.swift`, `Ticket.swift` (GuestSeat), **section 8.5 of this file**                                                                    |
|Menu loading / matching       |`LocalBundleMenuStore.swift`, `MenuV1.swift`, `docs/SCHEMAS.md`                                                                                                                            |
|Menu import (PDF)             |`PDFMenuImportService.swift`, `MenuImportService.swift` (stub + Phase 2 steps)                                                                                                             |
|Ticket persistence            |`SwiftDataTicketRepository.swift`, `Ticket.swift`, **section 8.8 of this file**                                                                                                            |
|Floor plan                    |`FloorPlanModels.swift`, `FloorPlanStore.swift`, `FloorView.swift`, `FloorPlanEditorView.swift`                                                                                            |
|UI / Design system            |`ChromeStyle.swift`, **section 8.9 of this file**                                                                                                                                          |
|CI / Build                    |`build.yml`, `project.yml`, `gen_asc_jwt.py`, `setup-signing.py`, **section 8.10 of this file**                                                                                            |
|Upsell engine                 |`RuleBasedUpsellEngine.swift`, `MenuV1.swift` (UpsellRule, UpsellCondition)                                                                                                                |
|SwiftData models              |`Ticket.swift`, **section 8.8 of this file**                                                                                                                                               |
|Edit history / audit trail    |`Ticket.swift` (TicketEditEvent), `TicketEditorViewModel.swift` (logEdit)                                                                                                                  |

-----

## MERGE NOTE

> The original `CLAUDE.md` in this repository contains additional content that was
> not accessible during the generation of this document (rate limiting during fetch).
> When you retrieve the original file, compare it against this document section by
> section. Any content in the original that is not covered above should be added to
> the appropriate section. Do not discard any original content — all of it was
> written intentionally. This document is additive, not a replacement.
>
> After merging, remove this note.

-----

*Last updated: April 2026 — Generated from full repository analysis.*
*Update this file whenever a root cause is identified, a bug is fixed, or an architectural decision changes.*
Sent from my iPhone