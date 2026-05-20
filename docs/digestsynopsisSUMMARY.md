# WaitTicket — Project Digest Synopsis

> Generated: 2026-05-19 | Three-Pass Deep Digest | Canonical Reference for All Future Sessions
> Supersedes digest dated 2026-03-30.
> **New in this digest:** PDFMenuImportService active (not stub), ChromeStyle design system, saveMenu protocol method, endAudioInput() drain pattern, version discrepancy flag, TableSelectView superseded, embedded menu fallback, TranscriptCleaner, reparseItems().

---

## 1. High-Level Summary

WaitTicket (repo: `Whisper/`, Xcode target: `WhisperTicket`) is an iOS app for restaurant waitstaff that turns spoken orders into structured, editable ticket records. Core loop: server selects a table on a visual floor plan, holds a mic button, speaks the order — live on-device ASR builds a structured draft in real time (parsing items, seats, courses, modifiers, allergies) — the draft is reviewed, confirmed, manually edited if needed, and sent to kitchen.

Fully on-device. No backend required. Every service is abstracted behind a protocol and injected at startup via an `AppServices` struct in `@Entry` EnvironmentValues. Swapping concrete types in `WhisperTicketApp.swift` is the only change needed for Phase 2 (Supabase backend).

**Implemented:** Floor plan (canvas + list editor), multi-seat voice ordering hub, streaming on-device ASR with auto-restart, fuzzy menu matching, allergy guardrails, noise detection, repeat-back coaching, auto abbreviations, upsell engine with playbook scripts, seat map drag-and-drop, course pacing (Fire/Hold), kitchen note templates, voice macros, full ticket edit + audit trail, PDF menu import, chrome dark design system, CI via GitHub Actions → TestFlight.

**Stack:** Swift 5.9 · SwiftUI (@Observable MVVM) · SwiftData · AVAudioEngine · SFSpeechRecognizer · PDFKit · xcodegen · GitHub Actions. **Zero third-party dependencies.** iOS 17.0 minimum.

---

## 2. Architecture & Major Components

### 2.1 Pattern [DIRECTLY SUPPORTED]

Protocol-abstracted MVVM using Swift's `@Observable` macro (NOT `ObservableObject`/`@Published`). Services are injected via `@Entry` on `EnvironmentValues`. Views reference only protocols, never concrete service classes.

### 2.2 Full Layer Stack

```
WhisperTicketApp.swift              ← @main; wires concrete types; ModelContainer setup with migration-wipe recovery
        │
        ▼
AppServices (struct)                ← EnvironmentValues @Entry; propagated to all views
        │
        ├── AudioCaptureService                (AVAudioEngine + PassthroughSubject<AVAudioPCMBuffer>)
        ├── SFSpeechTranscriptionService       (SFSpeechRecognizer, on-device, auto-restart on isFinal + endAudioInput() drain)
        ├── LocalBundleMenuStore (@Observable) (MenuV1 JSON, 3-level load: bundle → UserDefaults → embedded fallback)
        ├── FuzzyMenuOrderParser               (token-overlap scoring, cursor-based incremental, TranscriptCleaner)
        ├── RuleBasedUpsellEngine              (condition matching against MenuV1.upsellRules)
        ├── SwiftDataTicketRepository          (ModelContext wrapper, CRUD, DraftItem → Ticket object graph)
        ├── PDFMenuImportService               (PDFKit text extraction, heuristic category/item parser) ← ACTIVE (not stub)
        └── FloorPlanStore (@Observable)       (UserDefaults persistence of FloorPlan)

Views (SwiftUI, iOS 17+)
        ├── ContentView                        ← TabView root: FloorView | TicketsListView | MenuAdminView
        ├── WelcomeView                        ← Session-start overlay; shift stats; 1s clock timer
        ├── FloorView                          ← Two-tab: Map (canvas with DraggableTableTile) + Tables (list with sections)
        ├── FloorPlanEditorView                ← List edit + Canvas drag-to-position; table/section CRUD
        ├── TableOrderEntryView                ← PRIMARY multi-seat ordering hub (seat chips, voice, upsell, send)
        ├── LiveSessionView                    ← Legacy single-seat voice view (retained but not primary flow)
        ├── TicketEditorView                   ← Full structured editor; course pacing; audit trail; seat map button
        ├── TicketsListView                    ← Open + Completed splits; swipe-to-delete; clear all
        ├── MenuAdminView                      ← Browse + reload + import (PDF/image) menu
        ├── TableSelectView                    ← typealias TableSelectView = FloorView (superseded, kept for compatibility)
        └── Components/SeatMapView             ← Drag-and-drop seat card grid (sheet from TicketEditorView)

ViewModels (@Observable)
        ├── LiveSessionViewModel               ← Recording state, draft, upsell, allergy, macro, per-seat transcripts
        ├── TableSelectViewModel               ← Recent tables loader (10 most recent unique table numbers)
        ├── TicketEditorViewModel              ← All ticket mutations, audit log, reparseItems(), course pacing state
        └── TicketsListViewModel               ← Fetch all tickets, open/completed split, delete

Design System
        └── ChromeStyle.swift                 ← Color tokens, ChromeCardModifier, ShimmerModifier, GlowRingModifier,
                                                 ChromeSectionHeader, ChromeTabBarModifier, LiveMicButton,
                                                 AudioWaveformView, CourseDot, ChromeAllergyCapsule,
                                                 ConfidenceDot, StatusCapsule, PulseRing (private)

Data Models
        ├── MenuV1 + MenuCategory + MenuItem + ModifierGroup + ModifierOption + UpsellRule (Codable, in-memory)
        ├── FloorPlan + FloorTable + SeatConfig + ServerSection (Codable, UserDefaults, ColorHex parsing)
        ├── TicketDraft + DraftItem + VoiceMacro (in-memory intermediates)
        └── Ticket / GuestSeat / TicketItem / TicketModifier / TicketEditEvent (SwiftData @Model, SQLite)
```

### 2.3 Technology Stack [DIRECTLY SUPPORTED]

| Layer | Technology |
|-------|-----------|
| Language | Swift 5.9 |
| UI | SwiftUI (iOS 17+) |
| Observation | `@Observable` (Swift Observation — NOT Combine/ObservableObject) |
| Persistence | SwiftData (SQLite), UserDefaults (floor plan + imported menu) |
| Audio | AVAudioEngine, AVAudioSession (.playAndRecord, .measurement mode) |
| ASR | Speech.framework — `requiresOnDeviceRecognition = true`, auto-restart on 60s limit |
| PDF parsing | PDFKit (PDFDocument, PDFPage.string extraction) |
| Async pipeline | Combine (`PassthroughSubject<AVAudioPCMBuffer, Never>`) |
| Environment DI | `@Entry` on `EnvironmentValues` extension |
| Project generation | xcodegen from `project.yml` |
| Design system | Custom `ChromeStyle.swift` (dark POS terminal aesthetic) |
| CI/CD | GitHub Actions → xcrun altool → TestFlight (main) / IPA artifact (PRs) |
| Third-party deps | **None** |

### 2.4 Deployment Configuration [DIRECTLY SUPPORTED]

| Key | Value |
|-----|-------|
| Bundle ID | `com.whisperticket.app` |
| Team ID | `M37X5J35F8` |
| Marketing version (project.yml) | **1.5.0** |
| Marketing version (CI archive step) | **1.4.0** ← HARDCODED, CONFLICTS WITH project.yml |
| Build number | `github.run_number` (auto-increments per CI run) |
| Current build (project.yml) | 8 |
| Min OS | iOS 17.0 |
| Devices | iPhone + iPad (`TARGETED_DEVICE_FAMILY = "1,2"`) |
| Orientations | Portrait + Landscape (iPhone), all four (iPad) |
| Encryption | `ITSAppUsesNonExemptEncryption = false` (Info.plist + CI PATCH) |

> ⚠️ **VERSION MISMATCH:** `project.yml` sets `MARKETING_VERSION: "1.5.0"` but `build.yml` archive step hardcodes `MARKETING_VERSION="1.4.0"`. CI value wins at build time. Update CI to match project.yml or remove the hardcode.

---

## 3. Data Models — All Fields, All Types, All Relationships

### 3.1 MenuV1 (Codable, in-memory, loaded at startup)

```
MenuV1
  restaurantId: String          JSON: "restaurant_id"
  version: Int                  JSON: "version"  (1)
  currency: String              JSON: "currency"  ("USD")
  categories: [MenuCategory]
  upsellRules: [UpsellRule]    JSON: "upsell_rules"

MenuCategory: Identifiable, Codable
  id: String
  name: String
  items: [MenuItem]

MenuItem: Identifiable, Codable
  id: String
  name: String
  price: Double
  description: String
  tags: [String]                   dietary/category tags: "fried", "vegetarian", "gluten_free", "beverage", "side", etc.
  modifierGroups: [ModifierGroup]  JSON: "modifier_groups"
  upsellLinks: [UpsellLink]        JSON: "upsell_links"
  kitchenNoteTemplate: String?     JSON: "kitchen_note_template"
  [computed] abbreviation: String  — single-word → first 4 chars; multi-word → initials

ModifierGroup: Identifiable, Codable
  id: String
  name: String
  required: Bool
  maxSelect: Int    JSON: "max_select"
  modifiers: [ModifierOption]

ModifierOption: Identifiable, Codable
  id: String
  name: String
  priceDelta: Double   JSON: "price_delta"

UpsellLink: Codable
  type: String           "suggest"
  targetItemId: String   JSON: "target_item_id"
  reason: String

UpsellRule: Identifiable, Codable
  id: String
  condition: UpsellCondition    JSON: "if"
  suggest: [UpsellSuggestion]
  playbookScript: String?       JSON: "playbook_script"

UpsellCondition: Codable
  hasEntree: Bool?    JSON: "has_entree"
  hasDrink: Bool?     JSON: "has_drink"

UpsellSuggestion: Codable
  tag: String?        — match items by tag
  itemId: String?     JSON: "item_id"
```

**Demo menu (`MenuV1.sample.json`):** restaurant_id `applebees_demo`, 7-8 categories, 20+ items including Boneless Wings (with Sauce/Dipping Sauce modifier groups), Mozzarella Sticks, various burgers with temperature modifiers, salads, beverages. 2 upsell rules:
- `rule_drink_if_none`: hasEntree=true, hasDrink=false → suggest beverages by tag
- `rule_fries_with_burger`: (condition varies) → suggest fries by itemId

**Tag taxonomy (canonical):** `"fried"`, `"vegetarian"`, `"gluten_free"`, `"shareable"`, `"popular"`, `"beverage"` (NOT "drink"), `"dessert"`, `"side"`, `"entree"` — must use these when writing upsell rules.

### 3.2 SwiftData Persistent Models (`Models/Ticket.swift`)

```
@Model final class Ticket
  id: String                        UUID().uuidString default
  restaurantId: String              "local" default
  tableNumber: String
  serverId: String                  "local_server" default
  openedAt: Date                    Date() in init()
  sentToKitchenAt: Date?
  deliveredAt: Date?
  closedAt: Date?
  status: String                    TicketStatus.rawValue ("OPEN"/"SENT"/"DELIVERED"/"CLOSED")
  rawTranscript: String             aggregate transcript
  notes: String
  @Relationship(deleteRule: .cascade) guests: [GuestSeat]
  coursePacingStates: [String: String]   CourseFlag.rawValue → CoursePacingState.rawValue
  @Relationship(deleteRule: .cascade) editHistory: [TicketEditEvent]
  [computed] ticketStatus: TicketStatus
  [computed] timeToSend: TimeInterval?
  [computed] timeToDeliver: TimeInterval?
  [computed] totalTime: TimeInterval?
  [computed] allItems: [TicketItem]   guests.flatMap { $0.items }

@Model final class GuestSeat
  seatNumber: Int
  rawTranscript: String             per-seat voice transcript
  @Relationship(deleteRule: .cascade) items: [TicketItem]

@Model final class TicketItem
  id: String                        UUID().uuidString default
  menuItemId: String                MenuItem.id or "manual_XXXX"
  name: String
  quantity: Int                     default 1
  course: String                    CourseFlag.rawValue, default "ENT"
  notes: String
  confidence: Double                parser score (1.0 = manual add)
  hasAllergyFlag: Bool
  allergyConfirmed: Bool
  @Relationship(deleteRule: .cascade) modifiers: [TicketModifier]
  [computed] courseFlag: CourseFlag
  [computed] ticketAbbreviation: String

@Model final class TicketModifier
  name: String
  priceDelta: Double
  isNegation: Bool                  true for "no X"/"without X"

@Model final class TicketEditEvent
  timestamp: Date
  eventType: String                 "transcript_set" | "item_added" | "item_removed" | "item_moved" | "notes_updated" | "status_changed"
  seatNumber: Int                   0 = table-level
  summary: String
```

**Enums in Ticket.swift:**

```
enum TicketStatus: String  — open / sent / delivered / closed
enum CourseFlag: String    — appetizer("APP") / entree("ENT") / side("SID") / beverage("BEV") / dessert("DES")
  [computed] displayName: String
  [computed] fireCommand: String   ("Fire Apps", "Fire Entrees", etc.)
enum CoursePacingState: String  — holding / fired / delivered
```

**SwiftData schema registration:**
```swift
Schema([Ticket.self, GuestSeat.self, TicketItem.self, TicketModifier.self, TicketEditEvent.self])
```
**Migration strategy:** `ModelContainer` init failure → wipe `.sqlite`/`.sqlite-wal`/`.sqlite-shm` → retry. Dev-only. Production requires `VersionedSchema` + `MigrationPlan`.

### 3.3 In-Memory Draft Models (`Models/TicketDraft.swift`)

```
struct TicketDraft
  tableNumber: String
  items: [DraftItem]
  rawTranscript: String
  seatTranscripts: [Int: String]     per-seat transcript keyed by seatNumber
  consumedCursor: Int                per-seat: character offset; parser only processes new text after this
  [computed] aggregateTranscript: String   builds "Seat X: text\n" multi-line string
  [mutating] addItem(_ item: DraftItem)   dedup: same menuItemId + same modifierNames + same seatNumber → skip
                                          NOTE: nil seatNumbers don't prevent cross-seat adds of same item

struct DraftItem: Identifiable
  id: String               UUID
  menuItemId: String
  name: String
  quantity: Int
  modifierNames: [String]
  negations: [String]
  course: CourseFlag
  seatNumber: Int?         nil = unseated
  notes: String
  confidence: Double
  hasAllergyFlag: Bool
  kitchenNoteTemplate: String?

enum VoiceMacro: String
  repeatLastOrder = "repeat last order"
  addSideSalad = "add side salad"
  splitCheck = "split check"   ← Phase 2, no-op currently
  [computed] displayName: String
```

**DraftItem confidence display thresholds:**
- ≥ 0.7: Normal display
- < 0.7: "Low confidence — verify" chip shown
- `hasAllergyFlag = true`: Red highlight, requires confirmation tap

### 3.4 Floor Plan Models (`Models/FloorPlanModels.swift`, persisted via UserDefaults)

```
struct FloorPlan: Codable
  tables: [FloorTable]
  sections: [ServerSection]
  [static] default: FloorPlan     11-table preset

struct FloorTable: Identifiable, Codable, Hashable
  id: String                       UUID
  name: String
  position: CGSize                 drag offset (canvas mode)
  seats: [SeatConfig]
  sectionId: String?
  Custom Equatable/Hashable: identity-based (id only)

struct SeatConfig: Identifiable, Codable
  id: String                       UUID
  label: String                    customizable ("1", "Mom", "Red shirt")
  [static] numbered(_ count: Int) -> [SeatConfig]

struct ServerSection: Identifiable, Codable
  id: String
  name: String
  colorHex: String                 6-char hex (no #)
  tableIds: [String]
  [computed] color: Color          from hex via Color(hex6:)
  [static] palette: [String]       8 predefined hex colors

Color extension: init?(hex6:) — parses "RRGGBB" to RGBA
```

**UserDefaults key:** `"whisperticket.floorplan.v2"`
**UserDefaults key (imported menu):** `"whisperticket.menu.v1.json"` (set by `LocalBundleMenuStore.saveMenu()`)

---

## 4. Service Layer — All Protocols & Implementations

### 4.1 Protocols (`Services/Protocols.swift`)

```swift
protocol AudioCaptureServiceProtocol: AnyObject {
    var isRecording: Bool { get }
    var noiseLevel: Float { get }
    func startCapture() throws
    func stopCapture()
    func audioBufferPublisher() -> AnyPublisher<AVAudioPCMBuffer, Never>
}

protocol TranscriptionServiceProtocol: AnyObject {
    func transcriptionPublisher() -> AnyPublisher<TranscriptionSegment, Never>
    func startTranscribing(audioPublisher: AnyPublisher<AVAudioPCMBuffer, Never>) throws
    func endAudioInput()       ← seals audio stream, keeps task alive for drain (does NOT cancel)
    func stopTranscribing()    ← full teardown: cancel task + reset accumulators
}

struct TranscriptionSegment { let text: String; let isFinal: Bool }

protocol OrderParserProtocol {
    func parseDraft(transcript: String, existingDraft: TicketDraft, menu: MenuV1) -> TicketDraft
    func detectMacro(in text: String) -> VoiceMacro?
    func repeatBackSummary(for draft: TicketDraft) -> String
}

protocol MenuStoreProtocol: AnyObject {
    var menu: MenuV1? { get }
    func loadMenu() async throws
    func saveMenu(_ newMenu: MenuV1)    ← saves to UserDefaults, rebuilds index
    func findBestMatches(text: String, maxResults: Int) -> [(item: MenuItem, score: Double)]
    func item(byId id: String) -> MenuItem?
}

protocol TicketRepositoryProtocol {
    func fetchAll() async throws -> [Ticket]
    func fetchOpen() async throws -> [Ticket]
    func save(_ ticket: Ticket) async throws
    func delete(_ ticket: Ticket) async throws
    func deleteItem(_ item: TicketItem) async throws
    func deleteAll() async throws
    func createTicket(from draft: TicketDraft, serverId: String) async throws -> Ticket
}

protocol UpsellEngineProtocol {
    func suggestions(for draft: TicketDraft, menu: MenuV1) -> [UpsellSuggestionResult]
}

struct UpsellSuggestionResult: Identifiable {
    let id: String; let menuItem: MenuItem; let reason: String; let playbookScript: String?
}

protocol MenuImportServiceProtocol {
    func importMenu(from fileURL: URL, fileType: MenuImportFileType) async -> MenuImportResult
}
enum MenuImportFileType: String { case pdf; case image }
enum MenuImportResult { case success(MenuV1); case failure(String) }
```

### 4.2 AudioCaptureService (`Services/AudioCaptureService.swift`)

- `AVAudioSession` category: `.playAndRecord`, mode: `.measurement`, options: `[.defaultToSpeaker, .allowBluetoothHFP]`
- Input tap: 1024-sample buffer → `PassthroughSubject<AVAudioPCMBuffer, Never>`
- `updateNoiseLevel(buffer:)`: RMS of PCM samples, capped at 1.0 → `noiseLevel`
- `startCapture()`: activates session, installs tap, starts engine
- `stopCapture()`: removes tap, stops engine, deactivates session
- ⚠️ **Deprecated:** `allowBluetooth` (should be `.allowBluetoothHFP`) — verify in next AudioCaptureService edit

### 4.3 SFSpeechTranscriptionService (`Services/SFSpeechTranscriptionService.swift`)

**Key properties:**
- `recognizer`: `SFSpeechRecognizer(locale: Locale(identifier: "en-US"))`, `requiresOnDeviceRecognition = true`
- `accumulatedBase`: text accumulated across auto-restarts
- `isSessionActive`: controls auto-restart loop
- `priorSeatTranscript`: stores text from previous sessions on same seat
- `storedAudioPublisher`, `audioCancellable`: re-used across restart cycles

**endAudioInput() vs stopTranscribing():**
```
endAudioInput():
  - isSessionActive = false  (prevents auto-restart)
  - audioCancellable?.cancel()  (stops feeding audio to request)
  - recognitionRequest?.endAudio()  (tells ASR "no more audio")
  - Does NOT cancel recognitionTask → final isFinal result can still arrive

stopTranscribing():
  - recognitionTask?.cancel()
  - resets accumulatedBase, isSessionActive, recognitionTask, recognitionRequest
  - Full teardown
```

**Auto-restart cycle:**
```
beginRecognitionTask()
  → create SFSpeechAudioBufferRecognitionRequest
  → capture accumulatedBase at start
  → sink audio publisher → append buffers
  → on isFinal: accumulatedBase += result.text
     → if isSessionActive: cancel task, beginRecognitionTask() [restart]
     → if !isSessionActive: nothing (task completes naturally)
```

**`static func requestPermission(completion: (Bool) -> Void)`** — SFSpeechRecognizer.requestAuthorization

### 4.4 FuzzyMenuOrderParser (`Services/FuzzyMenuOrderParser.swift`)

**Parse pipeline — `parseDraft(transcript:existingDraft:menu:)`:**
1. `newText = transcript[consumedCursor...]`
2. Normalize: lowercase, strip fillers (60+ phrases via `TranscriptCleaner`), expand number-words (1–10), collapse whitespace
3. Split on `,` and `.` → segments
4. Per segment:
   - Detect course keyword → `currentCourse` (20+ keyword→CourseFlag mappings)
   - Detect `seat\s+(\d+)` → `currentSeat`
   - `tokenOverlapScore(query, itemName)` for each MenuItem → best ≥ 0.4
   - Leading quantity: digit or number-word prefix
   - Temperature map: "medium rare" → "Medium Rare" etc. (check longer phrases first)
   - Modifier group options: score against each option name, threshold 0.5
   - Negation prefix detection: "no", "without", "hold", "remove", "skip"
   - `hasAllergyFlag = true` on allergy keywords
   - `DraftItem` built, `draft.addItem()` called (dedup enforced per seat)
5. `consumedCursor = transcript.count`

**TranscriptCleaner (enum in LiveSessionViewModel.swift):**
- 60+ filler phrases ("um", "uh", "like", "you know", "so", etc.) ordered longest-first
- Prevents substring collision (e.g., "kind of" before "of")
- Applied via `normalizeText()` before parsing

**Token overlap scoring:**
```swift
func tokenOverlapScore(_ a: String, _ b: String) -> Double {
    let aTokens = a.lowercased().split(on: " ").filter { $0.count > 2 }
    let bTokens = b.lowercased().split(on: " ").filter { $0.count > 2 }
    let intersection = Set(aTokens).intersection(Set(bTokens))
    return Double(intersection.count) / Double(aTokens.count)
}
// Item match threshold: 0.4 | Modifier match threshold: 0.5
```

**Lookup tables:**
| Table | Contents |
|-------|----------|
| `allergyKeywords` | "allergy", "allergic", "anaphylactic", "epipen", "cannot eat" |
| `fillerWords` | delegated to TranscriptCleaner (60+ phrases) |
| `temperatureMap` | 8 entries: rare, medium rare, medium, medium well, well done + variants |
| `numberWords` | 1–10 (one through ten) |
| `negationPrefixes` | "no", "without", "hold", "remove", "skip" |
| `courseKeywords` | 20+ entries → CourseFlag mapping |
| `macroPatterns` | 7 entries → VoiceMacro |

**detectMacro(in:):** normalize → iterate macroPatterns → first match or nil
**repeatBackSummary(for:):** "Table X: Qty×Name (Mod1, Mod2); ⚠️ ALLERGY" per item

### 4.5 LocalBundleMenuStore (`Services/LocalBundleMenuStore.swift`, `@Observable`)

**3-level load strategy (in order):**
1. `resolveMenuURL()` — 4 search strategies: bundle `.json` by name → `bundlePath + "/MenuV1.sample.json"` → scan bundle JSON with "menu"+"v1" → any JSON with "menu" in name
2. `UserDefaults.standard` key `"whisperticket.menu.v1.json"` — for previously imported/saved menus
3. Embedded fallback JSON string constant — always available, full demo menu

**`saveMenu(_ newMenu: MenuV1)`:**
- JSON-encodes newMenu, stores to UserDefaults `"whisperticket.menu.v1.json"`
- Calls `buildIndex()` to rebuild `itemIndex` and `searchIndex`
- Called by `MenuAdminView` after successful import

**Index structures:**
- `itemIndex: [String: MenuItem]` — O(1) ID lookup
- `searchIndex: [(tokens: [String], item: MenuItem)]` — tokenized for fuzzy search (adds both singular + plural tokens)

**`findBestMatches(text:maxResults:)`:** tokenizes query, scores against `searchIndex` (threshold 0.2), returns top N sorted by score

**`MenuStoreError`:** `.fileNotFound(String)`, `.decodingFailed(String)` with `LocalizedError` conformance

### 4.6 SwiftDataTicketRepository (`Services/SwiftDataTicketRepository.swift`)

**`createTicket(from:serverId:)` — seat assignment logic:**
```
distinct seatNumbers = draft.items.compactMap { $0.seatNumber }

if seatNumbers.isEmpty:
    create GuestSeat(seatNumber: 1)
    all items → seat 1
else:
    for each distinct seatNumber:
        create GuestSeat(seatNumber: N)
        items where seatNumber == N → this seat
    unseated items (seatNumber == nil) → seat 1 (create if not already present)

ticket.rawTranscript = draft.aggregateTranscript (or rawTranscript fallback)
seat.rawTranscript = draft.seatTranscripts[seatNumber] ?? ""
```

**`buildTicketItem(from draft: DraftItem) -> TicketItem`** — private; maps all fields; creates `TicketModifier` per `modifierName`; sets `isNegation` from `draft.negations.contains(name)`.

### 4.7 RuleBasedUpsellEngine (`Services/RuleBasedUpsellEngine.swift`)

```
suggestions(for:draft:menu:):
  hasEntree = draft.items.contains { $0.course == .entree }
  hasDrink = draft.items.contains { $0.course == .beverage }
  for each UpsellRule:
    check condition.hasEntree / hasDrink (both must match if specified)
    for each UpsellSuggestion:
      tag match: filter menu.allItems by tag
      itemId match: menu.item(byId:)
    exclude items already in draft (by menuItemId)
    take top 2 per suggestion, deduplicate by item ID
  return [UpsellSuggestionResult]
```

### 4.8 PDFMenuImportService (`Services/PDFMenuImportService.swift`) ← ACTIVE IMPLEMENTATION

**`importMenu(from:fileType:)`:**
- Guards `fileType == .pdf`, else `.failure`
- Runs `parsePDF(at:)` in `Task.detached(priority: .userInitiated)`

**`parsePDF(at:)`:**
- `PDFDocument(url:)` → iterate pages, collect `.string` → `fullText`
- Guard non-empty text (fails on scanned images)
- Calls `parseTextIntoMenu(fullText, restaurantName:)` — restaurant name from filename

**`parseTextIntoMenu`:**
- Price regex: `#"\$?\s*(\d{1,3}(?:\.\d{2}))"#` — matches `$12.99` or `12.99`
- Per line: has price → `MenuItem`; ALL-CAPS or TitleCase (3–60 chars, no `$`) → category header
- `isLikelyCategoryHeader`: uppercased OR all words start-uppercase AND no `$` AND length 3–60
- Items get `tags: []` — no tag inference from PDF
- Default upsell rules: dessert (tag "dessert") + beverage (tag "beverage") ← uses "beverage" (correct)
- `sanitizeId()`: filename lowercased, non-alphanumeric → `_`

**⚠️ Known limitation:** PDF-imported items have `tags: []` → tag-based upsell rules never fire for imported menus. Phase 2: add tagging pass.

### 4.9 StubMenuImportService (`Services/MenuImportService.swift`) ← DEAD CODE

Still exists in codebase. `importMenu()` sleeps 1.5s, returns `.failure("not yet connected")`. **Not wired up** — `PDFMenuImportService` is the active implementation in both `WhisperTicketApp` and the `@Entry` default. Safe to delete or leave as reference.

### 4.10 FloorPlanStore (`Services/FloorPlanStore.swift`, `@Observable`)

| Method | Purpose |
|--------|---------|
| `load()` | Decode FloorPlan from UserDefaults on `init()` |
| `save()` | JSONEncoder → UserDefaults key `"whisperticket.floorplan.v2"` |
| `resetToDefault()` | FloorPlan.default, save |
| `resetTablePositions()` | Zero all table.position (canvas positions), save |
| `upsertTable(_:)` | Insert or update by ID, save |
| `deleteTable(id:)` | Remove + remove from all section.tableIds, save |
| `moveTable(fromOffsets:toOffset:)` | Reorder (list mode), save |
| `table(named:)` | Case-insensitive name lookup |
| `upsertSection(_:)` | Insert or update section, save |
| `deleteSection(id:)` | Remove section, unassign its tables, save |
| `assignTable(id:toSection:)` | Sync tableIds bidirectionally, save |

**Not protocol-abstracted** — cannot be swapped for testing. Only concrete class used.

---

## 5. ViewModel Layer — Full State & Method Map

### 5.1 LiveSessionViewModel (`ViewModels/LiveSessionViewModel.swift`, `@Observable`)

**Init:** `init(tableNumber:audioCapture:transcriptionService:parser:menuStore:upsellEngine:)`

**Published state:**
| Property | Type | Purpose |
|----------|------|---------|
| `seatTranscripts` | `[Int: String]` | Per-seat live transcript |
| `draft` | `TicketDraft` | Parsed items in progress |
| `upsellSuggestions` | `[UpsellSuggestionResult]` | Active upsell prompts |
| `isRecording` | `Bool` | Mic button state |
| `noiseLevel` | `Float` | 0–1.0 from audioCapture |
| `showNoisyEnvironmentWarning` | `Bool` | `noiseLevel > 0.75` |
| `showRepeatBack` | `Bool` | Sheet trigger |
| `detectedMacro` | `VoiceMacro?` | Pending macro |
| `errorMessage` | `String?` | Error banner |
| `allergyItemsPendingConfirm` | `[DraftItem]` | Drives allergy banners |
| `isFinalizingTranscription` | `Bool` | 1.5s post-stop drain window |
| `activeSeatNumber` | `Int` | Currently active seat |
| `activeSeatLabel` | `String` | Display label |
| `activeSeatTranscript` | `String` [computed] | `seatTranscripts[activeSeatNumber] ?? ""` |

**Private state:**
- `priorSeatTranscript: String` — text accumulated from previous record sessions on this seat
- `noiseWarningThreshold: Float = 0.75`
- `cancellables: Set<AnyCancellable>`, `finalizationTimer: Timer?`, `transcriptionCancellable: AnyCancellable?`

**Public methods:**
| Method | Behavior |
|--------|---------|
| `startRecording()` | captures `priorSeatTranscript` from current seatTranscripts; sets `consumedCursor = priorSeatTranscript.count + (text.isEmpty ? 0 : 1)`; starts capture + transcription; starts noise poll Timer |
| `stopRecording()` | stops capture; `transcriptionService.endAudioInput()` (drain, not cancel); `isFinalizingTranscription = true`; schedules `finalizeTranscription()` after 1.5s |
| `triggerRepeatBack()` | `showRepeatBack = true` |
| `confirmAllergyItem(_ item: DraftItem)` | remove from `allergyItemsPendingConfirm` |
| `removeItem(_ item: DraftItem)` | remove from `draft.items`, call `refreshUpsells()` |
| `addManualItem(name:)` | create `DraftItem(menuItemId: "manual_XXXX", confidence: 1.0)`, append to draft |
| `clearSeat(_ seatNumber:)` | remove all items for seat, clear `seatTranscripts[seatNumber]` |
| `itemsBySeat()` | `[(seatNumber: Int, items: [DraftItem])]` — grouped, sorted |
| `applyMacro(_ macro:previousDraft:)` | `.repeatLastOrder` → copy previous; `.addSideSalad` → find "Side Salad" in menu; `.splitCheck` → no-op |

**Private methods:**
| Method | Behavior |
|--------|---------|
| `handleTranscriptionSegment(_:)` | `seatTranscripts[activeSeatNumber] = priorSeatTranscript + segment.text`; call `parser.parseDraft`; stamp new items with `activeSeatNumber`; detect macro; check allergies; `refreshUpsells()` |
| `finalizeTranscription()` | `transcriptionService.stopTranscribing()`; if no items parsed → create fallback `DraftItem(confidence: 0.5)` from cleaned transcript |
| `checkNoiseLevel()` | poll `audioCapture.noiseLevel`, set `showNoisyEnvironmentWarning` |
| `refreshUpsells()` | `upsellEngine.suggestions(for: draft, menu:)` |

### 5.2 TableSelectViewModel (`ViewModels/TableSelectViewModel.swift`, `@Observable`)

**State:** `tableNumber: String`, `recentTables: [String]`, `isStartingSession: Bool`

**Methods:**
- `loadRecentTables() async` — `repository.fetchAll()`, extract unique tableNumbers (Set dedup), take first 10
- `selectTable(_ number: String)` — set `tableNumber`

### 5.3 TicketEditorViewModel (`ViewModels/TicketEditorViewModel.swift`, `@Observable`)

**Init:** `init(ticket: Ticket, repository: TicketRepositoryProtocol)` — reconstructs `coursePacingStates: [CourseFlag: CoursePacingState]` from `ticket.coursePacingStates` (String→String) on init.

**Public methods:**
| Method | Audit event | Behavior |
|--------|-------------|---------|
| `sendToKitchen() async` | `status_changed` | `sentToKitchenAt = Date()`, status = SENT, log, save |
| `markDelivered() async` | `status_changed` | `deliveredAt = Date()`, status = DELIVERED |
| `closeTicket() async` | `status_changed` | `closedAt = Date()`, status = CLOSED |
| `fireCourse(_ course:) async` | `status_changed` | state FIRED, sync to `ticket.coursePacingStates`, save |
| `holdCourse(_ course:) async` | `status_changed` | state HOLDING, sync, save |
| `removeItem(_ item:from seat:) async` | `item_removed` | remove from `seat.items`, `repository.deleteItem(item)` |
| `updateTranscript(_ text:) async` | `transcript_set` | update `ticket.rawTranscript` + primary seat, call `reparseItems()` |
| `updateSeatTranscript(_ text:for seat:) async` | `transcript_set` | update `seat.rawTranscript`, call `reparseItems()` |
| `reparseItems() async` | — | `parser.parseDraft()` → find new items not in seat → append (dedup by menuItemId+name) |
| `updateItemNotes(_ item:notes:) async` | `notes_updated` | `item.notes = notes`, save |
| `confirmAllergyItem(_ item:) async` | — | `item.allergyConfirmed = true`, save |
| `moveItem(_ item:fromSeat:toSeatNumber:) async` | `item_moved` | remove from source, append to target (create `GuestSeat` if missing), log, save |

**Private:**
- `logEdit(type:seatNumber:summary:)` → creates `TicketEditEvent`, appends to `ticket.editHistory`
- `save() async` → sets `isSaving`, `repository.save(ticket)`, clears `isSaving`

### 5.4 TicketsListViewModel (`ViewModels/TicketsListViewModel.swift`, `@Observable`)

**State:** `openTickets: [Ticket]`, `completedTickets: [Ticket]`, `isLoading: Bool`

**Methods:**
- `loadTickets() async` — fetch all; split: open = OPEN/SENT, completed = DELIVERED/CLOSED
- `deleteTicket(_ ticket:) async` — delete + reload
- `clearAll() async` — `repository.deleteAll()` + reload

---

## 6. View Layer — All Views, Navigation, Key UI Behaviors

### 6.1 ContentView (`Views/ContentView.swift`)
- `TabView` with 3 tabs (SF Symbols)
  - Tab 1: **FloorView** (rectangle.split.3x1)
  - Tab 2: **TicketsListView** (doc.text)
  - Tab 3: **MenuAdminView** (fork.knife)
- `@State private var showWelcome: Bool = true` → `WelcomeView` as `.sheet` once per session
- `.dark` color scheme applied globally
- `ChromeTabBar` appearance configured via `ChromeStyle.chromeTabBar()`

### 6.2 WelcomeView (`Views/WelcomeView.swift`)
- `@Binding isPresented: Bool`
- App logo + 1s clock Timer + shift stats (openCount, inKitchenCount) loaded via `repository.fetchAll()`
- `StatPill` component: value / label / icon / color
- Dismiss → `isPresented = false`

### 6.3 FloorView (`Views/FloorView.swift`) ← PRIMARY ENTRY POINT
**Two-tab structure:**
- **Map tab:** `FloorMapEmbedView` — 900×700 canvas with dot-grid background
  - `MapTableTile` (108×108): name, seat count, status; color-coded by section; glow ring on active
  - Drag: `@GestureState` drag offset, persisted via `floorPlanStore.upsertTable()`
  - Tap: navigate to `TableOrderEntryView` (available) or `TicketEditorView` (active ticket)
  - Custom table entry: alert prompt
- **Tables tab:** section list + "Unassigned" section
  - `ChromeActiveTableCard`: elapsed time, status icon, section color — taps to `TicketEditorView`
  - `ChromeAvailableTableCard`: simple availability — taps to `TableOrderEntryView`
- Toolbar: Refresh, Edit Floor Plan → `FloorPlanEditorView` sheet
- `loadActiveTickets()`: `repository.fetchOpen()`, deduplicate by tableNumber (latest by `openedAt`), filter closed

### 6.4 FloorPlanEditorView (`Views/FloorPlanEditorView.swift`)
- **List mode:** sortable/reorderable tables, inline section indicator, "Add Table" alert
- **Canvas mode:** `CanvasView` with grid; `DraggableTableTile` (@GestureState + local position)
- `TableConfigSheet`: name, seats (add/reorder/remove), section assignment
- `SectionEditorSheet`: add/delete sections, color picker from `ServerSection.palette`
- Toolbar: Add Table, Manage Sections, Reset (destructive confirm), mode switcher

### 6.5 TableOrderEntryView (`Views/TableOrderEntryView.swift`) ← PRIMARY ORDERING HUB
**Layout zones:**
- `seatSelectorStrip()`: horizontal scroll, `SeatChip` per seat (active highlight, dot if has items), context menu (rename/clear), Add Seat button with alert
- `alertsRow()`: noise warning (amber, chromeAmber), allergy banners (chromeRed left border), macro prompt (chromePrimary left border)
- `orderSummarySection()`: `SeatOrderCard` per seat — items with `CourseDot`, `ConfidenceDot`, `ChromeAllergyCapsule`, remove button
- `transcriptSection()`: `SeatTranscriptCard` per seat — live/stored transcript, recording pulse, tap to switch active seat
- `upsellSection()`: add buttons per suggestion with playbook script
- `bottomBar()`: `AudioWaveformView` (when recording/finalizing), `LiveMicButton`, manual entry button, send button
- `RepeatBackSheet`: order summary by seat, optional add item, confirm → `createAndSend()`

**Key interactions:**
- `setupVM()`: creates `LiveSessionViewModel`, subscribes to its state
- `createAndSend()`: calls `repository.createTicket(from:)` → navigates to `TicketEditorView`
- `persistSeats()`: syncs seat configurations back to ticket

### 6.6 LiveSessionView (`Views/LiveSessionView.swift`) ← LEGACY SINGLE-SEAT
- Simpler structure: alerts → transcript card → draft items → upsell suggestions → bottom bar
- No seat selector strip; uses single-seat concept
- Edit → `TicketEditorView`; Confirm → `TicketEditorView`
- **Note [INFERRED]:** Retained for backward navigation compatibility; `TableOrderEntryView` is the active primary flow

### 6.7 TicketEditorView (`Views/TicketEditorView.swift`)
**List sections (decomposed into @ViewBuilder functions):**
- Transcript (edit button → `TranscriptEditorSheet`, reparses on save)
- Ticket Info (table, status, opened time)
- Timeline (with delta: open→sent→delivered→closed)
- Course Pacing (`CourseControlRow` per CourseFlag: Fire/Hold buttons + state indicator)
- Order Items (per GuestSeat: `TicketItemRow` — qty, name, mods with strikethrough-if-negation, notes, allergy confirm, move-seat menu)
- Notes (if present)
- Edit History (sorted by timestamp; `editHistoryIcon()` maps eventType → SF Symbol)
- Actions (Send/Delivered/Close buttons gated by status)
- Seat Map (sheet button → `SeatMapView`)

**`ElapsedTimeLabel`:** 1s Timer, color: green < 10m, orange 10–20m, red > 20m

### 6.8 TicketsListView (`Views/TicketsListView.swift`)
- `TicketRow`: table#, `StatusCapsule`, item count, elapsed/total time (color-coded), transcript indicator
- Swipe → delete; pull-to-refresh; "Clear All" (destructive confirm dialog)
- `ContentUnavailableView` on empty state

### 6.9 MenuAdminView (`Views/MenuAdminView.swift`)
- Read-only browse: category sections, items with price
- Stats: version, category count, item count
- Toolbar: Reload (`menuStore.loadMenu()`), Import (file picker: `.pdf`, `.image`, `.jpeg`, `.png`)
- Import flow: `menuImporter.importMenu(from:fileType:)` → on success: `menuStore.saveMenu(menu)` → reload
- Shows error/result alerts

### 6.10 SeatMapView (`Views/Components/SeatMapView.swift`)
- `LazyVGrid` of `SeatCard` views
- Table card at top (brown)
- `SeatCard`: shows seat number + items (qty/name); draggable payload: `"itemId|sourceSeatNumber"`; drop target with blue border feedback
- `vm.moveItem(_:fromSeat:toSeatNumber:)` called on drop
- Add Seat: creates new `GuestSeat` with `max(seatNumbers) + 1`

### 6.11 Design System (`Views/Components/ChromeStyle.swift`)

**Color tokens:**
| Token | Use |
|-------|-----|
| `.chromeBackground` | App background (deep navy) |
| `.chromeSurface` | Card surface |
| `.chromePrimary` | Primary interactive (blue-purple) |
| `.chromeTeal` | Positive states (available, confirmed) |
| `.chromeAmber` | In-progress / warning |
| `.chromeRed` | Recording / allergy / danger |
| `.chromeSilverHigh` | Highlight |
| `.chromeSilverLow` | Subdued text / inactive |

**ViewModifiers:** `ChromeCardModifier`, `ShimmerModifier` (animated sweep), `GlowRingModifier` (double shadow halo)
**View extensions:** `.chromeCard(cornerRadius:glowColor:glowRadius:)`, `.chromeShimmer()`, `.glowRing(color:radius:)`, `.if(_:transform:)` (conditional modifier)
**Components:** `ChromeSectionHeader`, `ChromeTabBarModifier`, `LiveMicButton` (pulse rings + breathe animation), `AudioWaveformView` (7-bar, phase-driven), `CourseDot`, `ChromeAllergyCapsule`, `ConfidenceDot`, `StatusCapsule`

---

## 7. Critical Flows — Step-by-Step

### 7.1 App Startup
1. `WhisperTicketApp.init()` → build `Schema` → `ModelContainer`. Failure: wipe `.sqlite`/`.sqlite-wal`/`.sqlite-shm`, retry. Second failure: `fatalError`.
2. `ContentView()` rendered. `WelcomeView` sheet appears.
3. `.task{}` fires:
   - `SFSpeechTranscriptionService.requestPermission` → OS dialog
   - `AVAudioApplication.requestRecordPermission()` → OS dialog
   - `menuStore.loadMenu()`: bundle → UserDefaults → embedded fallback; builds `itemIndex` + `searchIndex`
4. `FloorPlanStore.load()` → UserDefaults decode or `.default`

### 7.2 Multi-Seat Voice Order (Happy Path — TableOrderEntryView)
1. Server taps table on `FloorView` → `TableOrderEntryView` pushed
2. `setupVM()` → creates `LiveSessionViewModel(tableNumber:...services)` 
3. Server taps/adds seat chip → `activeSeatNumber` set
4. Holds `LiveMicButton` → `vm.startRecording()`:
   - `priorSeatTranscript` = current `seatTranscripts[activeSeatNumber] ?? ""`
   - `consumedCursor` = `priorSeatTranscript.count + (isEmpty ? 0 : 1)`
   - `audioCapture.startCapture()` → AVAudioEngine running, tap installed
   - `transcriptionService.startTranscribing(audioPublisher:)` → `beginRecognitionTask()`
5. Audio pipeline: `AVAudioEngine` → 1024-sample buffers → `PassthroughSubject` → `SFSpeechAudioBufferRecognitionRequest`
6. Transcription arrives: `SFSpeechRecognizer` → `transcriptionSubject.send(TranscriptionSegment(text, isFinal))`
7. `handleTranscriptionSegment(_:)`:
   - `seatTranscripts[activeSeatNumber] = priorSeatTranscript + " " + segment.text`
   - `parser.parseDraft(transcript: activeSeatTranscript, existingDraft: draft, menu:)` → only processes after `consumedCursor`
   - Detect macro → set `detectedMacro`
   - Stamp new items with `activeSeatNumber`
   - Check `allergyItemsPendingConfirm`
   - `refreshUpsells()`
8. `isFinal = true` → `SFSpeechTranscriptionService` accumulates in `accumulatedBase`, auto-restarts task
9. Server releases button → `vm.stopRecording()`:
   - `audioCapture.stopCapture()`
   - `transcriptionService.endAudioInput()` (seals audio, keeps task alive)
   - `isFinalizingTranscription = true`
   - 1.5s Timer → `finalizeTranscription()`
10. `finalizeTranscription()`:
    - `transcriptionService.stopTranscribing()` (full teardown)
    - If no items parsed: create `DraftItem(confidence: 0.5)` from cleaned transcript
11. Server taps Confirm → `RepeatBackSheet` shows
12. Server taps "Confirm & Send" → `createAndSend()` → `repository.createTicket(from:)` → navigate to `TicketEditorView`

### 7.3 Allergy Detection Flow
1. Parser detects allergy keyword → `DraftItem.hasAllergyFlag = true`
2. `handleTranscriptionSegment` adds to `allergyItemsPendingConfirm`
3. `TableOrderEntryView.alertsRow()` renders `AllergyAlertBanner` per pending item
4. Server taps Confirm → `vm.confirmAllergyItem(_:)` → remove from pending list
5. Ticket creation: `TicketItem.hasAllergyFlag = true`
6. `TicketEditorView` shows `ChromeAllergyCapsule` per flagged item; "Confirm Allergy" button

### 7.4 Ticket Creation — `createTicket(from:serverId:)`
1. `draft.items.compactMap { $0.seatNumber }` → distinct seat numbers
2. If empty: `GuestSeat(seatNumber: 1)` ← all items
3. If seats present: one `GuestSeat` per distinct seatNumber; unseated items → Seat 1 (create if missing)
4. `seat.rawTranscript = draft.seatTranscripts[seatNumber] ?? ""`
5. `ticket.rawTranscript = draft.aggregateTranscript`
6. Each `DraftItem` → `buildTicketItem()` → `TicketItem` + `TicketModifier`s
7. `modelContext.insert(ticket)`, `modelContext.save()`

### 7.5 Course Pacing
1. `TicketEditorView` shows `CourseControlRow` per active CourseFlag
2. Server taps "Fire Entrees" → `vm.fireCourse(.entree)`:
   - `coursePacingStates[.entree] = .fired`
   - `ticket.coursePacingStates["ENT"] = "FIRED"`
   - `logEdit(type: "status_changed", summary: "Fired Entrees")`
   - `save()`

### 7.6 Seat Item Drag-and-Drop (SeatMapView)
1. `TicketEditorView` → Seat Map button → `SeatMapView` sheet
2. Drag: `SeatCard.draggable(String)` payload = `"itemId|sourceSeatNumber"`
3. Drop on target: parse payload, call `vm.moveItem(_:fromSeat:toSeatNumber:)`
4. `removeItem` from source `GuestSeat.items`, append to target (create if missing), `logEdit`, `save()`

### 7.7 PDF Menu Import
1. `MenuAdminView` toolbar Import → file picker (`.pdf`, `.image`, `.jpeg`, `.png`)
2. `menuImporter.importMenu(from: url, fileType: .pdf)` → `PDFMenuImportService`
3. `Task.detached(priority: .userInitiated)` → `parsePDF(at:)`:
   - `PDFDocument(url:)` → iterate pages, collect text
   - Per line: price regex match → `MenuItem`; ALL-CAPS/TitleCase → category header
4. Returns `MenuImportResult.success(MenuV1)` or `.failure(String)`
5. On success: `menuStore.saveMenu(menu)` → stored to UserDefaults + index rebuilt
6. Alert shown to user with result

### 7.8 Voice Macro Execution
1. `FuzzyMenuOrderParser.detectMacro(in:)` matches → `detectedMacro` set
2. `TableOrderEntryView.alertsRow()` shows macro banner
3. Server taps Execute → `vm.applyMacro(macro, previousDraft:)`
4. `.repeatLastOrder` → copy items from `previousDraft` into `draft`
5. `.addSideSalad` → `menuStore.findBestMatches(text: "Side Salad", maxResults: 1)` → `DraftItem`
6. `.splitCheck` → no-op (Phase 2)

---

## 8. Build & CI/CD System

### 8.1 xcodegen (`project.yml`)

```yaml
name: WhisperTicket
options:
  bundleIdPrefix: com.whisperticket
  deploymentTarget: { iOS: "17.0" }
targets:
  WhisperTicket:
    type: application
    platform: iOS
    sources: [ios/WhisperTicket (excludes Resources/**)]
    resources: [ios/WhisperTicket/Resources, ios/WhisperTicket/Assets.xcassets]
settings:
  MARKETING_VERSION: "1.5.0"    ← ⚠️ conflicts with CI hardcode of "1.4.0"
  CURRENT_PROJECT_VERSION: "8"
  DEVELOPMENT_TEAM: M37X5J35F8
  SWIFT_VERSION: "5.9"
  IPHONEOS_DEPLOYMENT_TARGET: "17.0"
  TARGETED_DEVICE_FAMILY: "1,2"
```

### 8.2 GitHub Actions (`.github/workflows/build.yml`)

**Trigger:** push to `main`/`develop`, PR to `main`

| Step | Tool | Notes |
|------|------|-------|
| Checkout | actions/checkout@v4 | |
| Select Xcode | maxim-lobanov/setup-xcode@v1 | latest-stable |
| Cache xcodegen | actions/cache@v4 | key: `xcodegen-{os}-2.36.0` |
| Install xcodegen | brew (if cache miss) | |
| Cache DerivedData | actions/cache@v4 | key hashes `**/*.swift` + `project.yml` |
| Generate project | xcodegen generate | from `project.yml` |
| Install cert | openssl pkcs12 + security import | DER→PEM→P12 via LibreSSL |
| Install profile | base64 decode + copy to MobileDevice/Provisioning Profiles | |
| Write ASC key | printf → `~/.private_keys/AuthKey_<KEY_ID>.p8` | |
| Archive | xcodebuild archive | ⚠️ hardcodes `MARKETING_VERSION="1.4.0"` |
| Verify version | PlistBuddy print + find .json | sanity check |
| Export IPA (main) | `xcodebuild -exportArchive` with `destination:export` | IPA to `$RUNNER_TEMP/export` |
| Upload (main) | `xcrun altool --upload-app` | separate step from export |
| Set compliance + distribute (main) | Python JWT + ASC API | HTTP 409 on compliance = non-fatal |
| Export IPA (PRs) | `xcodebuild -exportArchive` | IPA artifact only |
| Upload artifacts | actions/upload-artifact@v4 | build-log on failure, IPA on success |

**JWT generation:** `scripts/gen_asc_jwt.py` — Python `cryptography` library (required; bash+openssl produces DER, not R‖S)

**ASC API patterns:**
- App lookup: `?filter[bundleId]=com.whisperticket.app&fields[apps]=name` (never include `id` in fields[])
- Build polling: up to 3 min (9×20s), filters by `version=$BUILD_NUMBER`
- betaGroups: uses `--http1.1 -o /tmp/resp.json -w "%{http_code}"` (avoids curl HTTP/2 exit-56 masking)
- Compliance PATCH: HTTP 409 = already set via Info.plist → expected, non-fatal

**Required secrets:** `DIST_PRIVATE_KEY_PEM`, `DIST_CERT_DER_B64`, `DIST_CERT_P12_PASSWORD`, `PROV_PROFILE_BASE64`, `PROV_PROFILE_UUID`, `ASC_API_KEY`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `APPLE_TEAM_ID`

---

## 9. Exhaustive Function Map (All Files)

### Models

| File | Symbol | Signature | Notes |
|------|--------|-----------|-------|
| MenuV1.swift | MenuItem.abbreviation | `var abbreviation: String` (computed) | initials or prefix(4) |
| Ticket.swift | Ticket.ticketStatus | `var ticketStatus: TicketStatus` (computed) | rawValue → enum |
| Ticket.swift | Ticket.timeToSend | `var timeToSend: TimeInterval?` (computed) | |
| Ticket.swift | Ticket.timeToDeliver | `var timeToDeliver: TimeInterval?` (computed) | |
| Ticket.swift | Ticket.totalTime | `var totalTime: TimeInterval?` (computed) | |
| Ticket.swift | Ticket.allItems | `var allItems: [TicketItem]` (computed) | guests flatMap |
| Ticket.swift | TicketItem.courseFlag | `var courseFlag: CourseFlag` (computed) | |
| Ticket.swift | TicketItem.ticketAbbreviation | `var ticketAbbreviation: String` (computed) | |
| Ticket.swift | CourseFlag.displayName | `var displayName: String` (computed) | |
| Ticket.swift | CourseFlag.fireCommand | `var fireCommand: String` (computed) | |
| TicketDraft.swift | TicketDraft.aggregateTranscript | `var aggregateTranscript: String` (computed) | multi-line per-seat |
| TicketDraft.swift | TicketDraft.addItem | `mutating func addItem(_ item: DraftItem)` | dedup by menuItemId+mods+seat |
| TicketDraft.swift | VoiceMacro.displayName | `var displayName: String` (computed) | |
| FloorPlanModels.swift | FloorPlan.default | `static var default: FloorPlan` | 11-table preset |
| FloorPlanModels.swift | SeatConfig.numbered | `static func numbered(_ count: Int) -> [SeatConfig]` | |
| FloorPlanModels.swift | ServerSection.color | `var color: Color` (computed) | hex6 parse |
| FloorPlanModels.swift | ServerSection.palette | `static var palette: [String]` | 8 hex colors |
| FloorPlanModels.swift | Color.init(hex6:) | `init?(hex6: String)` | RRGGBB → RGBA |

### Services

| File | Symbol | Signature | Notes |
|------|--------|-----------|-------|
| AudioCaptureService.swift | startCapture | `func startCapture() throws` | sets up AVAudioSession + tap |
| AudioCaptureService.swift | stopCapture | `func stopCapture()` | removes tap, stops engine |
| AudioCaptureService.swift | audioBufferPublisher | `func audioBufferPublisher() -> AnyPublisher<AVAudioPCMBuffer, Never>` | |
| AudioCaptureService.swift | updateNoiseLevel | `private func updateNoiseLevel(buffer: AVAudioPCMBuffer)` | RMS calculation |
| SFSpeechTranscriptionService.swift | startTranscribing | `func startTranscribing(audioPublisher: AnyPublisher<AVAudioPCMBuffer, Never>) throws` | |
| SFSpeechTranscriptionService.swift | beginRecognitionTask | `private func beginRecognitionTask()` | creates request + task |
| SFSpeechTranscriptionService.swift | endAudioInput | `func endAudioInput()` | seal without cancel |
| SFSpeechTranscriptionService.swift | stopTranscribing | `func stopTranscribing()` | full teardown |
| SFSpeechTranscriptionService.swift | transcriptionPublisher | `func transcriptionPublisher() -> AnyPublisher<TranscriptionSegment, Never>` | |
| SFSpeechTranscriptionService.swift | requestPermission | `static func requestPermission(completion: (Bool) -> Void)` | |
| FuzzyMenuOrderParser.swift | parseDraft | `func parseDraft(transcript:existingDraft:menu:) -> TicketDraft` | cursor-based |
| FuzzyMenuOrderParser.swift | detectMacro | `func detectMacro(in text: String) -> VoiceMacro?` | |
| FuzzyMenuOrderParser.swift | repeatBackSummary | `func repeatBackSummary(for draft: TicketDraft) -> String` | |
| FuzzyMenuOrderParser.swift | normalizeText | `private func normalizeText(_ text: String) -> String` | TranscriptCleaner |
| FuzzyMenuOrderParser.swift | splitIntoSegments | `private func splitIntoSegments(_ text: String) -> [String]` | |
| FuzzyMenuOrderParser.swift | detectCourse | `private func detectCourse(in segment: String) -> CourseFlag?` | |
| FuzzyMenuOrderParser.swift | detectSeat | `private func detectSeat(in segment: String) -> Int?` | regex `seat\s+(\d+)` |
| FuzzyMenuOrderParser.swift | findBestItem | `private func findBestItem(in segment: String, menu: MenuV1) -> (item: MenuItem, score: Double)?` | |
| FuzzyMenuOrderParser.swift | extractQuantity | `private func extractQuantity(from segment: String) -> (qty: Int, remainder: String)` | |
| FuzzyMenuOrderParser.swift | extractModifiers | `private func extractModifiers(from segment: String, item: MenuItem) -> [ParsedModifier]` | |
| FuzzyMenuOrderParser.swift | tokenOverlapScore | `private func tokenOverlapScore(_ a: String, _ b: String) -> Double` | tokens >2 chars |
| LocalBundleMenuStore.swift | loadMenu | `func loadMenu() async throws` | 3-level strategy |
| LocalBundleMenuStore.swift | saveMenu | `func saveMenu(_ newMenu: MenuV1)` | UserDefaults + index rebuild |
| LocalBundleMenuStore.swift | findBestMatches | `func findBestMatches(text: String, maxResults: Int) -> [(item: MenuItem, score: Double)]` | threshold 0.2 |
| LocalBundleMenuStore.swift | item(byId:) | `func item(byId id: String) -> MenuItem?` | O(1) via itemIndex |
| LocalBundleMenuStore.swift | resolveMenuURL | `private func resolveMenuURL() -> URL?` | 4 search strategies |
| LocalBundleMenuStore.swift | buildIndex | `private func buildIndex()` | singular + plural tokens |
| LocalBundleMenuStore.swift | apply | `@MainActor private func apply(_ menu: MenuV1)` | sets menu, builds index |
| SwiftDataTicketRepository.swift | fetchAll | `func fetchAll() async throws -> [Ticket]` | sort by openedAt desc |
| SwiftDataTicketRepository.swift | fetchOpen | `func fetchOpen() async throws -> [Ticket]` | OPEN\|\|SENT predicate |
| SwiftDataTicketRepository.swift | save | `func save(_ ticket: Ticket) async throws` | |
| SwiftDataTicketRepository.swift | delete | `func delete(_ ticket: Ticket) async throws` | |
| SwiftDataTicketRepository.swift | deleteItem | `func deleteItem(_ item: TicketItem) async throws` | |
| SwiftDataTicketRepository.swift | deleteAll | `func deleteAll() async throws` | fetch all, delete each, save once |
| SwiftDataTicketRepository.swift | createTicket | `func createTicket(from draft: TicketDraft, serverId: String) async throws -> Ticket` | seat assignment logic |
| SwiftDataTicketRepository.swift | buildTicketItem | `private func buildTicketItem(from draft: DraftItem) -> TicketItem` | DraftItem → @Model |
| RuleBasedUpsellEngine.swift | suggestions | `func suggestions(for draft: TicketDraft, menu: MenuV1) -> [UpsellSuggestionResult]` | |
| PDFMenuImportService.swift | importMenu | `func importMenu(from fileURL: URL, fileType: MenuImportFileType) async -> MenuImportResult` | |
| PDFMenuImportService.swift | parsePDF | `private func parsePDF(at url: URL) -> MenuImportResult` | PDFDocument text extract |
| PDFMenuImportService.swift | parseTextIntoMenu | `private func parseTextIntoMenu(_ text: String, restaurantName: String) -> MenuImportResult` | heuristic |
| PDFMenuImportService.swift | isLikelyCategoryHeader | `private func isLikelyCategoryHeader(_ line: String) -> Bool` | |
| PDFMenuImportService.swift | extractPrice | `private func extractPrice(from line: String, using regex: NSRegularExpression) -> Double` | capture group 1 |
| PDFMenuImportService.swift | removePriceAndClean | `private func removePriceAndClean(from line: String, using regex: NSRegularExpression) -> String` | |
| PDFMenuImportService.swift | sanitizeId | `private func sanitizeId(_ name: String) -> String` | filename → id |
| PDFMenuImportService.swift | defaultUpsellRules | `private func defaultUpsellRules() -> [UpsellRule]` | dessert + beverage |
| FloorPlanStore.swift | load | `func load()` | UserDefaults decode |
| FloorPlanStore.swift | save | `func save()` | UserDefaults encode |
| FloorPlanStore.swift | resetToDefault | `func resetToDefault()` | FloorPlan.default |
| FloorPlanStore.swift | resetTablePositions | `func resetTablePositions()` | zero all position, save |
| FloorPlanStore.swift | upsertTable | `func upsertTable(_ table: FloorTable)` | |
| FloorPlanStore.swift | deleteTable | `func deleteTable(id: String)` | removes from sections too |
| FloorPlanStore.swift | moveTable | `func moveTable(fromOffsets: IndexSet, toOffset: Int)` | |
| FloorPlanStore.swift | table(named:) | `func table(named name: String) -> FloorTable?` | case-insensitive |
| FloorPlanStore.swift | upsertSection | `func upsertSection(_ section: ServerSection)` | |
| FloorPlanStore.swift | deleteSection | `func deleteSection(id: String)` | unassigns tables |
| FloorPlanStore.swift | assignTable | `func assignTable(id: String, toSection: String?)` | bidirectional sync |

### ViewModels

| File | Symbol | Signature | Notes |
|------|--------|-----------|-------|
| LiveSessionViewModel.swift | startRecording | `func startRecording()` | sets consumedCursor, starts services |
| LiveSessionViewModel.swift | stopRecording | `func stopRecording()` | endAudioInput + 1.5s drain |
| LiveSessionViewModel.swift | triggerRepeatBack | `func triggerRepeatBack()` | |
| LiveSessionViewModel.swift | confirmAllergyItem | `func confirmAllergyItem(_ item: DraftItem)` | |
| LiveSessionViewModel.swift | removeItem | `func removeItem(_ item: DraftItem)` | |
| LiveSessionViewModel.swift | addManualItem | `func addManualItem(name: String)` | confidence 1.0 |
| LiveSessionViewModel.swift | clearSeat | `func clearSeat(_ seatNumber: Int)` | |
| LiveSessionViewModel.swift | itemsBySeat | `func itemsBySeat() -> [(seatNumber: Int, items: [DraftItem])]` | |
| LiveSessionViewModel.swift | applyMacro | `func applyMacro(_ macro: VoiceMacro, previousDraft: TicketDraft?)` | |
| LiveSessionViewModel.swift | handleTranscriptionSegment | `private func handleTranscriptionSegment(_ segment: TranscriptionSegment)` | core ASR → parse pipeline |
| LiveSessionViewModel.swift | finalizeTranscription | `private func finalizeTranscription()` | stopTranscribing + fallback item |
| LiveSessionViewModel.swift | checkNoiseLevel | `private func checkNoiseLevel()` | |
| LiveSessionViewModel.swift | refreshUpsells | `private func refreshUpsells()` | |
| TableSelectViewModel.swift | loadRecentTables | `func loadRecentTables() async` | top 10 unique |
| TableSelectViewModel.swift | selectTable | `func selectTable(_ number: String)` | |
| TicketEditorViewModel.swift | sendToKitchen | `func sendToKitchen() async` | |
| TicketEditorViewModel.swift | markDelivered | `func markDelivered() async` | |
| TicketEditorViewModel.swift | closeTicket | `func closeTicket() async` | |
| TicketEditorViewModel.swift | fireCourse | `func fireCourse(_ course: CourseFlag) async` | |
| TicketEditorViewModel.swift | holdCourse | `func holdCourse(_ course: CourseFlag) async` | |
| TicketEditorViewModel.swift | removeItem | `func removeItem(_ item: TicketItem, from seat: GuestSeat) async` | |
| TicketEditorViewModel.swift | updateTranscript | `func updateTranscript(_ text: String) async` | triggers reparseItems |
| TicketEditorViewModel.swift | updateSeatTranscript | `func updateSeatTranscript(_ text: String, for seat: GuestSeat) async` | triggers reparseItems |
| TicketEditorViewModel.swift | reparseItems | `func reparseItems() async` | parser → merge new items |
| TicketEditorViewModel.swift | updateItemNotes | `func updateItemNotes(_ item: TicketItem, notes: String) async` | |
| TicketEditorViewModel.swift | confirmAllergyItem | `func confirmAllergyItem(_ item: TicketItem) async` | |
| TicketEditorViewModel.swift | moveItem | `func moveItem(_ item: TicketItem, fromSeat: GuestSeat, toSeatNumber: Int) async` | create seat if missing |
| TicketEditorViewModel.swift | logEdit | `private func logEdit(type: String, seatNumber: Int, summary: String)` | appends TicketEditEvent |
| TicketEditorViewModel.swift | save | `private func save() async` | isSaving guard |
| TicketsListViewModel.swift | loadTickets | `func loadTickets() async` | fetchAll, split by status |
| TicketsListViewModel.swift | deleteTicket | `func deleteTicket(_ ticket: Ticket) async` | |
| TicketsListViewModel.swift | clearAll | `func clearAll() async` | |

### ChromeStyle Components

| Symbol | Signature | Notes |
|--------|-----------|-------|
| ChromeCardModifier | `struct ChromeCardModifier: ViewModifier` | `cornerRadius`, `glowColor`, `glowRadius` |
| ShimmerModifier | `struct ShimmerModifier: ViewModifier` | `@State phase: CGFloat` animated sweep |
| GlowRingModifier | `struct GlowRingModifier: ViewModifier` | double shadow halo |
| View.chromeCard | `func chromeCard(cornerRadius:glowColor:glowRadius:) -> some View` | |
| View.chromeShimmer | `func chromeShimmer() -> some View` | |
| View.glowRing | `func glowRing(color:radius:) -> some View` | |
| View.if | `func if(_:transform:) -> some View` | conditional modifier |
| View.chromeTabBar | `func chromeTabBar() -> some View` | UITabBarAppearance config |
| ChromeSectionHeader | `struct ChromeSectionHeader: View` | `title: String`, `systemImage: String` |
| LiveMicButton | `struct LiveMicButton: View` | `isRecording`, `isDisabled`, `action` |
| PulseRing | `private struct PulseRing: View` | `color`, `delay`, `size` |
| AudioWaveformView | `struct AudioWaveformView: View` | `isActive: Bool`, `noiseLevel: Float` |
| CourseDot | `struct CourseDot: View` | `course: CourseFlag` |
| ChromeAllergyCapsule | `struct ChromeAllergyCapsule: View` | no params |
| ConfidenceDot | `struct ConfidenceDot: View` | `confidence: Double` (shows if < 0.6) |
| StatusCapsule | `struct StatusCapsule: View` | `status: TicketStatus` |

---

## 10. Risks, Gaps, and Open Questions

### 10.1 Confirmed Risks [DIRECTLY SUPPORTED]

| Risk | Evidence | Severity |
|------|----------|---------|
| **Version mismatch: project.yml 1.5.0 vs CI 1.4.0** | `project.yml:47` vs `build.yml:117` | Medium — CI wins, app always ships as 1.4.0 |
| **SwiftData migration is dev-only wipe** | `WhisperTicketApp.swift:32-44` | High (production) — loses all data on schema change |
| **Parser accuracy degrades at noise/accent** | tokenOverlapScore 0.4 is empirical, no feedback loop | Medium |
| **`coursePacingStates` is `[String: String]`** | `Ticket.swift` — requires string casts, desync risk on CourseFlag rawValue changes | Low-Medium |
| **`requiresOnDeviceRecognition = true` — hard fail if model not downloaded** | `SFSpeechTranscriptionService.swift` — no user-facing error path | Medium |
| **`FloorPlanStore` not protocol-abstracted** | `Services/FloorPlanStore.swift` — cannot mock or swap | Low |
| **PDF-imported items have `tags: []`** | `PDFMenuImportService.swift:82` — upsell by tag never fires | Low-Medium |
| **No pricing calculation** | `TicketModifier.priceDelta` stored, never summed | Low |
| **`StubMenuImportService` dead code** | `MenuImportService.swift` — `PDFMenuImportService` is active; stub is orphan | Negligible |
| **`AudioWaveformView` animation may not be 60fps** | `withAnimation` + `value:` chaining vs `TimelineView` | Low (cosmetic) |

### 10.2 Inferred Gaps

- No server authentication — `serverId = "local_server"` hardcoded everywhere
- No shift management (start/end time, sections per shift, per-server assignment)
- No concurrent edit conflict resolution (deferred to Supabase Realtime)
- `RepeatBackSheet` manual item entry creates `DraftItem` with raw name, no menu matching
- `SeatMapView` drag payload is `String` — no type-safe `Transferable` conformance
- `TicketEditEvent.eventType` is `String` not enum — typos at call sites would fail silently
- `AudioCaptureService.allowBluetooth` deprecation not yet fixed

### 10.3 Open Questions

1. What is the intended marketing version? project.yml says 1.5.0, CI archives as 1.4.0. Which is canonical?
2. When does `LiveSessionView` get removed vs `TableOrderEntryView` becoming the sole entry point?
3. Should `FloorPlanStore` be protocol-abstracted before Supabase (Phase 2)?
4. Will `VersionedSchema` / `MigrationPlan` be added before any real user data accumulates, or after the Supabase migration?
5. Is `StubMenuImportService` (in `MenuImportService.swift`) intended to stay as a reference or be deleted?

---

## 11. Edge Cases and Failure Modes

| Scenario | Behavior | File/Line |
|----------|---------|-----------|
| ASR 60s limit hit mid-order | Auto-restart: accumulates in `accumulatedBase`, seamless to user | SFSpeechTranscriptionService |
| `endAudioInput()` called before final isFinal | Final segment still arrives (task not cancelled); `finalizeTranscription()` waits 1.5s | stopRecording flow |
| No items parsed after stop | Fallback `DraftItem(confidence: 0.5)` from cleaned full transcript | `finalizeTranscription()` |
| Same item spoken twice (same seat) | Dedup by menuItemId+modifiers+seatNumber prevents duplicate | `TicketDraft.addItem()` |
| Same item spoken on two different seats | Allowed — dedup only within same seat | `TicketDraft.addItem()` |
| Server re-records same seat | `priorSeatTranscript` accumulates; `consumedCursor` advances past prior text | `startRecording()` |
| `ModelContainer` init fails (schema change) | Wipes store files, retries; second failure → `fatalError` | `WhisperTicketApp.init()` |
| `menuStore.loadMenu()` fails | Embedded fallback JSON always available; error only if embedded JSON corrupted | `LocalBundleMenuStore.loadMenu()` |
| PDF has no readable text (scanned image) | `.failure("PDF appears to contain no readable text")` | `parsePDF(at:)` |
| PDF price regex misses 4+ digit prices | `\d{1,3}` — $1000+ not matched | `PDFMenuImportService.swift:44` |
| SeatMap drop payload malformed | `split("|")` — if `|` absent, `sourceSeatNumber` nil → drop silently | `SeatMapView` drop handler |
| No internal beta groups in ASC | Prints warning, `exit 0` — build still in TestFlight, manual distribution | `build.yml` betaGroups step |
| Compliance PATCH returns HTTP 409 | Non-fatal, expected (already set via Info.plist) | `build.yml` compliance step |
| `TokenOverlapScore` on single-character tokens | Tokens ≤2 chars filtered out; empty query → score 0/0 = NaN risk [INFERRED] | `tokenOverlapScore()` |

---

## 12. Phase 2 Readiness & Future Goals

### DI swap points for Supabase
All services swapped in `WhisperTicketApp.swift` lines 10–15, 52–61. Replace:
- `SwiftDataTicketRepository` → `SupabaseTicketRepository`
- `LocalBundleMenuStore` → `SupabaseMenuStore`
- `PDFMenuImportService` → `OpenAIMenuImportService` (Vision API)
- `StubMenuImportService` → can be deleted

### Deferred features (priority order per `docs/FUTURE_GOALS.md`)

| # | Feature | Effort | Trigger |
|---|---------|--------|---------|
| 5 | QR/NFC table auto-select | Low | Restaurant wants sub-2s table select |
| 7 | Printer support (ESC/POS) | Medium | Restaurant requests receipt output |
| 2 | POS integration (Toast/Square/Clover) | High | First partner requests it |
| 6 | Kitchen display mode | Medium | Kitchen wants live ticket screen |
| 3 | Fraud/void analytics | Medium | Manager reporting requested |
| 4 | Training mode | Medium | New staff onboarding needed |
| 1 | Multilingual | High | Non-English market |

### SwiftData production migration plan
Before Phase 2 ship with real data:
1. Add `VersionedSchema` + `MigrationPlan` to `WhisperTicketApp.swift`
2. Remove store-wipe recovery (or gate on debug build flag)
3. Test migration path from current schema on device

---

## 13. Refactor & Extension Opportunities

| Opportunity | Rationale | Risk |
|------------|-----------|------|
| Protocol-abstract `FloorPlanStore` | Needed before Phase 2; currently only concrete class used | Low |
| Enum-type `TicketEditEvent.eventType` | Prevents typo bugs at call sites | Low |
| Remove `StubMenuImportService` | Dead code; `PDFMenuImportService` is active | None |
| Fix CI `MARKETING_VERSION` hardcode | project.yml and CI disagree; use `$(MARKETING_VERSION)` from project.yml | Low |
| Replace `AudioWaveformView` withAnimation+value with `TimelineView` | Frame-accurate waveform | Low |
| Add tag inference to `PDFMenuImportService` | Enables upsell rules for imported menus | Medium |
| Deprecation fix: `allowBluetooth` → `allowBluetoothHFP` | `AudioCaptureService.swift` | Low |
| `TicketDraft.addItem()` dedup across seats | Depends on product decision: allow same item multiple seats or not | Product call |
| Add `VersionedSchema` for SwiftData | Required before production with real user data | Medium |
| `TableSelectView` cleanup | Currently `typealias TableSelectView = FloorView` — dead file if no references remain | Low |

---

## 14. Osmosis Delta — 2026-05-19

> Added by `/osmosis` full pipeline run (2026-05-19). Documents what the analysis confirmed, corrected, and newly discovered. See `@docs/waitticket/` for the full knowledge base generated.

### Confirmed Still True
All facts in §10–§13 verified against current code. No stale entries removed.

### Newly Confirmed Bugs (not in prior digest)

**PDF price regex captures integer only** (`PDFMenuImportService.swift:44`)
`\$?\s*(\d{1,3}(?:\.\d{2}))` — `(?:...)` is non-capturing. `$14.99` → price `14.0`. All PDF-imported menus have integer-dollar prices. Fix: change `(?:\.\d{2})` → `\.\d{2}` (remove `?:`).

**Modifier negation never uses `isNegation: Bool`** (`FuzzyMenuOrderParser.swift` — `extractModifiers()`)
`TicketModifier(name: "No Ranch")` is created instead of `TicketModifier(name: "Ranch", isNegation: true)`. `TicketModifier.isNegation` is never `true` anywhere in the codebase. Display and kitchen note logic that reads `isNegation` never fires.

**No cascade delete on any SwiftData relationship** (`Models/Ticket.swift`, `GuestSeat.swift`, `TicketItem.swift`)
Default `.nullify` on all four relationship levels. Every ticket deletion leaves orphaned `GuestSeat`, `TicketItem`, `TicketModifier`, and `TicketEditEvent` rows. Known bug FB13640004: cascade + explicit `save()` in same transaction = silent orphans — delete children manually before parent.

**No `AVAudioSession.interruptionNotification` observer** (`AudioCaptureService.swift`)
Phone call mid-recording deactivates the session; engine stops but `isRecording` stays `true`. Next recording attempt fails silently. Must fix before production.

**`installTap` buffer not copied before `PassthroughSubject.send()`** (`AudioCaptureService.swift`)
Engine can reuse internal buffer memory before the downstream ASR subscriber processes it. Latent crash under high load.

### New Reference Library
- `@docs/waitticket/ARCHITECTURE.md` — verified stack facts, audio pipeline diagram, library-specific gotchas, CI rules
- `@docs/waitticket/KNOWLEDGE.md` — domain model with all entity fields, feature call paths with line-level accuracy, data contracts, stubs table
- `@docs/waitticket/DEBUG_HISTORY_DIGEST.md` — 17 confirmed architectural facts, 5 recurring failure patterns, 12 active watch-outs (severity-rated), Claude codegen mistake table
