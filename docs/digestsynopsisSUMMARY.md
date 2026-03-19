# WaitTicket — Project Digest Synopsis

> Generated: 2026-03-17 | Last Updated: 2026-03-19 | Three-Pass Deep Digest | Canonical Reference for All Future Sessions

---

## 1. High-Level Summary

WaitTicket (repo folder: Whisper, Xcode target: WhisperTicket) is an iOS app for restaurant waitstaff. Its core loop: the server selects a table, holds a mic button and speaks the order aloud, live speech-to-text populates a structured ticket draft in real time, the draft is reviewed and confirmed, then sent to kitchen. The app operates entirely on-device — no backend is required to run. A Supabase backend integration is deliberately deferred via protocol abstraction: every service (audio, transcription, menu store, parser, upsell engine, ticket repository) is injected as a protocol; swapping concrete types in `WhisperTicketApp.swift` is the only change needed for Phase 2.

The implemented feature set spans MVP, low-complexity, and medium-complexity tiers: table selection grid, hold-to-talk ASR, fuzzy menu order parsing, allergy guardrails, repeat-back coaching, noise detection, auto abbreviations, rule-based upsell engine with playbook scripts, seat map with drag-and-drop, course pacing controls (Fire/Hold per course), kitchen note templates, and voice macros. The project is at Swift 5.9 / iOS 17.0 minimum. No third-party dependencies. CI builds via GitHub Actions on push to `main`/`develop`, producing TestFlight uploads (main) or IPA artifacts (PRs).

---

## 2. Architecture & Major Components

### Pattern [DIRECTLY SUPPORTED]
Protocol-abstracted MVVM with `@Observable` ViewModels (Swift Observation framework, iOS 17+). Services are value-type protocols injected at app startup via SwiftUI `@Environment`. Views never reference concrete service types.

### Layer Stack
```
WhisperTicketApp.swift          ← App entry; wires concrete types into AppServices container
      │
      ▼
AppServices (struct)            ← Environment value; propagated to all views via @Entry
      │
      ├── AudioCaptureService           (AVAudioEngine, PassthroughSubject<AVAudioPCMBuffer>)
      ├── SFSpeechTranscriptionService  (SFSpeechRecognizer, on-device, partial+final results)
      ├── LocalBundleMenuStore          (MenuV1 JSON decode, in-memory index)
      ├── FuzzyMenuOrderParser          (token-overlap scoring, course/seat/modifier/allergy detection)
      ├── RuleBasedUpsellEngine         (condition matching against menu upsell_rules)
      └── SwiftDataTicketRepository     (ModelContext wrap, CRUD, DraftItem → Ticket graph)

Views (SwiftUI)
      ├── ContentView              ← TabView root (Tables / Tickets / Menu)
      ├── TableSelectView          ← Preset grid + custom entry + recent tables
      ├── LiveSessionView          ← Hold-to-talk, live transcript, draft, upsell, alerts
      ├── TicketEditorView         ← Full ticket edit, course pacing, seat sections
      ├── TicketsListView          ← List of all tickets, open/completed split
      ├── MenuAdminView            ← Read-only menu browse, reload button
      └── Components/SeatMapView  ← Drag-and-drop seat card grid (sheet from TicketEditor)

ViewModels (@Observable)
      ├── LiveSessionViewModel     ← Recording state, draft state, upsell, allergy, macro
      ├── TableSelectViewModel     ← Table selection, recent tables
      ├── TicketEditorViewModel    ← Ticket mutations, send/deliver, course pacing, seat moves
      └── TicketsListViewModel     ← Fetch all tickets, open/completed split, delete

Data Models
      ├── MenuV1 (Codable structs, in-memory)
      └── Ticket / GuestSeat / TicketItem / TicketModifier (SwiftData @Model, persisted)
          + TicketDraft / DraftItem / VoiceMacro (in-memory intermediates)
```

### Technology Stack [DIRECTLY SUPPORTED]
- Swift 5.9, SwiftUI, SwiftData
- AVAudioEngine, AVAudioSession (audio capture)
- Speech.framework SFSpeechRecognizer (on-device ASR, `requiresOnDeviceRecognition = true`)
- Combine (publisher pipeline: audio buffers → transcription segments)
- Foundation (JSON decoding, Regex, Timer)
- UniformTypeIdentifiers (drag payload in SeatMapView)
- No third-party dependencies

### Deployment Target [DIRECTLY SUPPORTED]
- iOS 17.0 minimum (required for `@Observable`, SwiftData, `@Entry` `EnvironmentValues`)
- iPhone + iPad (TARGETED_DEVICE_FAMILY = "1,2")
- Bundle ID: `com.whisperticket.app`
- Team ID: `M37X5J35F8`
- Xcode project generated via `xcodegen` from `project.yml`

---

## 3. Data Models (All Fields, All Types, All Relationships)

### 3.1 MenuV1 (Codable, in-memory, loaded from bundle JSON)

```
MenuV1
  restaurantId: String         (JSON: "restaurant_id")
  version: Int                 (JSON: "version") — currently 1
  currency: String             (JSON: "currency") — ISO 4217, e.g. "USD"
  categories: [MenuCategory]
  upsellRules: [UpsellRule]   (JSON: "upsell_rules")

MenuCategory: Identifiable, Codable
  id: String
  name: String
  items: [MenuItem]

MenuItem: Identifiable, Codable
  id: String
  name: String
  price: Double
  description: String
  tags: [String]              — dietary/category tags (e.g. "gluten_free", "beverage", "side")
  modifierGroups: [ModifierGroup]  (JSON: "modifier_groups")
  upsellLinks: [UpsellLink]        (JSON: "upsell_links")
  kitchenNoteTemplate: String?     (JSON: "kitchen_note_template") — pre-filled note string
  [computed] abbreviation: String  — first-letter acronym or first-4 for single-word names

ModifierGroup: Identifiable, Codable
  id: String
  name: String
  required: Bool
  maxSelect: Int               (JSON: "max_select")
  modifiers: [ModifierOption]

ModifierOption: Identifiable, Codable
  id: String
  name: String
  priceDelta: Double           (JSON: "price_delta")

UpsellLink: Codable
  type: String                 — e.g. "suggest"
  targetItemId: String         (JSON: "target_item_id")
  reason: String

UpsellRule: Identifiable, Codable
  id: String
  condition: UpsellCondition   (JSON: "if")
  suggest: [UpsellSuggestion]
  playbookScript: String?      (JSON: "playbook_script") — scripted line for server to say

UpsellCondition: Codable
  hasEntree: Bool?             (JSON: "has_entree")
  hasDrink: Bool?              (JSON: "has_drink")

UpsellSuggestion: Codable
  tag: String?                 — match items by tag
  itemId: String?              (JSON: "item_id") — match specific item
```

**Demo menu items** (from MenuV1.sample.json):
- Appetizers: Mozzarella Sticks ($9.99), Caesar Salad ($11.99)
- Entrees: Classic Burger ($14.99), Grilled Salmon ($22.99), Ribeye Steak ($34.99)
- Sides: French Fries ($4.99), Side Salad ($5.99)
- Beverages: Coca-Cola ($2.99), Water ($0.00), IPA Draft Beer ($7.99)

**Demo upsell rules**:
1. `rule_drink_if_none`: if has_entree=true AND has_drink=false → suggest soft_drink + beer tags
2. `rule_fries_with_burger`: if has_entree=false AND has_drink=false → suggest item_fries specifically

### 3.2 SwiftData Persistent Models

```
@Model Ticket
  id: String                   — UUID().uuidString default
  restaurantId: String         — "local" default (Supabase restaurant ID in Phase 2)
  tableNumber: String
  serverId: String             — "local_server" default
  openedAt: Date               — set in init() to Date()
  sentToKitchenAt: Date?
  deliveredAt: Date?
  closedAt: Date?
  status: String               — TicketStatus.rawValue ("OPEN"/"SENT"/"DELIVERED"/"CLOSED")
  rawTranscript: String
  notes: String
  guests: [GuestSeat]          — @Relationship(deleteRule: .cascade)
  coursePacingStates: [String: String]  — CourseFlag.rawValue → CoursePacingState.rawValue
  [computed] ticketStatus: TicketStatus
  [computed] timeToSend: TimeInterval?  — sentToKitchenAt - openedAt
  [computed] timeToDeliver: TimeInterval?  — deliveredAt - sentToKitchenAt
  [computed] totalTime: TimeInterval?  — closedAt - openedAt  [added 2026-03-19]
  [computed] allItems: [TicketItem]  — guests.flatMap { $0.items }

@Model GuestSeat
  seatNumber: Int
  items: [TicketItem]          — @Relationship(deleteRule: .cascade)

@Model TicketItem
  id: String                   — UUID().uuidString default
  menuItemId: String           — references MenuItem.id
  name: String
  quantity: Int                — default 1
  course: String               — CourseFlag.rawValue, default ".entree"
  notes: String                — kitchen notes (editable)
  confidence: Double           — parser match score (1.0 = manual add)
  hasAllergyFlag: Bool         — set by parser on allergy keyword detection
  allergyConfirmed: Bool       — set true when server taps confirm
  modifiers: [TicketModifier]  — @Relationship(deleteRule: .cascade)
  [computed] courseFlag: CourseFlag
  [computed] ticketAbbreviation: String  — first-letter acronym

@Model TicketModifier
  name: String                 — e.g. "No Onion", "Medium Rare"
  priceDelta: Double
  isNegation: Bool             — true for "no X" / "without X" modifiers
```

### 3.3 In-Memory Draft Models

```
struct TicketDraft
  tableNumber: String
  items: [DraftItem]
  rawTranscript: String
  consumedCursor: Int          — character offset; parser only processes text after this index
  [mutating] addItem(_ item: DraftItem)  — dedup check: same menuItemId + same modifierNames

struct DraftItem: Identifiable
  id: String                   — UUID().uuidString
  menuItemId: String
  name: String
  quantity: Int
  modifierNames: [String]      — all modifier names including negations (e.g. "No Onion")
  negations: [String]          — subset of modifierNames that are removals
  course: CourseFlag
  seatNumber: Int?
  notes: String
  confidence: Double
  hasAllergyFlag: Bool
  kitchenNoteTemplate: String?

enum VoiceMacro: String, CaseIterable
  repeatLastOrder = "repeat last order"
  addSideSalad = "add side salad"
  splitCheck = "split check"
  [computed] displayName: String

enum TicketStatus: String, Codable
  open = "OPEN"
  sent = "SENT"
  delivered = "DELIVERED"
  closed = "CLOSED"

enum CourseFlag: String, Codable, CaseIterable, Hashable
  appetizer = "APP"
  entree = "ENT"
  dessert = "DES"
  beverage = "BEV"
  side = "SIDE"
  [computed] displayName: String
  [computed] fireCommand: String  — "Fire Apps" / "Fire Entrees" / "Fire Desserts" / "Fire"

enum CoursePacingState: String, Codable
  holding = "HOLDING"
  fired = "FIRED"
  delivered = "DELIVERED"
```

---

## 4. Service & Protocol Layer (All Protocols, All Implementations)

### 4.1 Protocol Definitions (Services/Protocols.swift)

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
    func stopTranscribing()
}

struct TranscriptionSegment {
    let text: String     // full cumulative text (SFSpeechRecognizer replaces, not appends)
    let isFinal: Bool
}

protocol OrderParserProtocol {
    func parseDraft(transcript: String, existingDraft: TicketDraft, menu: MenuV1) -> TicketDraft
    func detectMacro(in text: String) -> VoiceMacro?
    func repeatBackSummary(for draft: TicketDraft) -> String
}

protocol MenuStoreProtocol: AnyObject {
    var menu: MenuV1? { get }
    func loadMenu() async throws
    func findBestMatches(text: String, maxResults: Int) -> [(item: MenuItem, score: Double)]
    func item(byId id: String) -> MenuItem?
}

protocol TicketRepositoryProtocol {
    func fetchAll() async throws -> [Ticket]
    func fetchOpen() async throws -> [Ticket]
    func save(_ ticket: Ticket) async throws
    func delete(_ ticket: Ticket) async throws
    func deleteItem(_ item: TicketItem) async throws   // added 2026-03-19
    func createTicket(from draft: TicketDraft, serverId: String) async throws -> Ticket
}

// Added 2026-03-19: menu import scaffolding
enum MenuImportResult {
    case success(MenuV1)
    case failure(String)
}

protocol MenuImportServiceProtocol {
    func importMenu(from fileURL: URL, fileType: MenuImportFileType) async -> MenuImportResult
}

enum MenuImportFileType: String {
    case pdf
    case image
}

protocol UpsellEngineProtocol {
    func suggestions(for draft: TicketDraft, menu: MenuV1) -> [UpsellSuggestionResult]
}

struct UpsellSuggestionResult: Identifiable {
    let id: String           // UUID
    let menuItem: MenuItem
    let reason: String
    let playbookScript: String?
}
```

### 4.2 Concrete Implementations

| Protocol | Concrete Type | File |
|----------|---------------|------|
| AudioCaptureServiceProtocol | AudioCaptureService | Services/AudioCaptureService.swift |
| TranscriptionServiceProtocol | SFSpeechTranscriptionService | Services/SFSpeechTranscriptionService.swift |
| OrderParserProtocol | FuzzyMenuOrderParser | Services/FuzzyMenuOrderParser.swift |
| MenuStoreProtocol | LocalBundleMenuStore | Services/LocalBundleMenuStore.swift (now `@Observable`) |
| TicketRepositoryProtocol | SwiftDataTicketRepository | Services/SwiftDataTicketRepository.swift |
| UpsellEngineProtocol | RuleBasedUpsellEngine | Services/RuleBasedUpsellEngine.swift |
| MenuImportServiceProtocol | StubMenuImportService | Services/MenuImportService.swift (Phase 2: OpenAIMenuImportService) |

### 4.3 Placeholder Implementations (WhisperTicketApp.swift)

Two placeholder stubs exist as `@Entry` defaults for the `appServices` environment key:
- `PlaceholderTicketRepository` — returns empty arrays, `fatalError` on `createTicket`
- `PlaceholderMenuStore` — returns nil menu, empty match results

These are never reached in production because real services are always injected before any view renders. They exist only to satisfy the `@Entry` default value requirement.

### 4.4 AppServices Container

```swift
struct AppServices {
    let audioCapture: AudioCaptureServiceProtocol
    let transcriptionService: TranscriptionServiceProtocol
    let menuStore: MenuStoreProtocol
    let parser: OrderParserProtocol
    let upsellEngine: UpsellEngineProtocol
    let repository: TicketRepositoryProtocol
    let menuImporter: MenuImportServiceProtocol   // added 2026-03-19; stub impl in Phase 1
}
```

Propagated via `extension EnvironmentValues { @Entry var appServices: AppServices }`.

---

## 5. Critical Flows & Behaviors (Step-by-Step)

### 5.1 App Startup & Service Wiring

1. `WhisperTicketApp.init()` runs:
   a. `ModelContainer(for: Ticket.self, GuestSeat.self, TicketItem.self, TicketModifier.self)` — if this throws, the app crashes with `fatalError` (no recovery).
   b. `SFSpeechTranscriptionService.requestPermission {}` — async permission request; prints warning if denied but does not block UI.
   c. `AVAudioSession.sharedInstance().requestRecordPermission {}` — same pattern.
2. `WhisperTicketApp.body` creates `WindowGroup` containing `ContentView`.
3. `.modelContainer(container)` injects SwiftData context into environment.
4. `.environment(\.appServices, AppServices(...))` injects all concrete service instances.
5. `.task { try? await menuStore.loadMenu() }` — async menu load fires immediately; `try?` swallows errors silently.
6. `ContentView` renders `TabView` with three tabs.

**Risk**: The `try?` on `menuStore.loadMenu()` silently drops the error if `MenuV1.sample.json` is missing from the bundle. The app will show no menu in `MenuAdminView` and the parser will find zero matches.

### 5.2 Audio Capture & ASR Pipeline

1. User taps hold-to-talk button in `LiveSessionView` → `vm.startRecording()` called.
2. `AudioCaptureService.startCapture()`:
   a. Sets `AVAudioSession` category to `.playAndRecord`, mode `.measurement`, options `[.defaultToSpeaker, .allowBluetooth]`.
   b. Activates `AVAudioSession`.
   c. Gets `inputNode` from `AVAudioEngine`.
   d. Installs tap on bus 0, buffer size 1024, with input node's native format.
   e. Tap closure: sends `AVAudioPCMBuffer` to `bufferSubject` (PassthroughSubject) + calls `updateNoiseLevel`.
   f. `audioEngine.prepare()` then `audioEngine.start()`.
   g. Sets `isRecording = true`.
3. `SFSpeechTranscriptionService.startTranscribing(audioPublisher:)`:
   a. Checks recognizer availability; throws `TranscriptionError.recognizerUnavailable` if not.
   b. Creates `SFSpeechAudioBufferRecognitionRequest` with `shouldReportPartialResults = true` and `requiresOnDeviceRecognition = true`.
   c. Starts `recognitionTask` on recognizer.
   d. Task callback fires on every partial/final result:
      - Creates `TranscriptionSegment(text: bestTranscription.formattedString, isFinal: result.isFinal)`.
      - Sends to `transcriptionSubject` (PassthroughSubject).
      - On error OR `isFinal`, calls `stopTranscribing()`.
   e. Subscribes to `audioPublisher`, appending each buffer to the recognition request.
4. `LiveSessionViewModel.startRecording()`:
   a. Calls both `startCapture()` and `startTranscribing()`.
   b. Resets `draft.consumedCursor = 0`.
   c. Subscribes to `transcriptionService.transcriptionPublisher()` → `handleTranscriptionSegment`.
   d. Starts `Timer.publish(every: 0.5)` to poll noise level → `checkNoiseLevel()`.
5. Noise level computation (`updateNoiseLevel`): RMS of float channel data, scaled ×10, clamped to 1.0, dispatched to main thread.
6. User releases button → `vm.stopRecording()` [FIXED 2026-03-19]:
   a. Calls `audioCapture.stopCapture()`: removes tap, stops engine, deactivates session, resets flags.
   b. Sets `isRecording = false`, `isFinalizingTranscription = true`.
   c. Cancels noise-timer and other subscriptions — but keeps `transcriptionCancellable` alive so `isFinal=true` can still arrive.
   d. Starts 3-second safety timer → calls `finalizeTranscription()` on expiry.
7. When `isFinal=true` segment arrives (or safety timeout fires) → `finalizeTranscription()`:
   a. Cancels safety timer, cancels `transcriptionCancellable`.
   b. Calls `transcriptionService.stopTranscribing()`.
   c. Clears `isFinalizingTranscription = false`.

**Critical bug fixed (2026-03-19)**: Prior to the fix, `stopRecording()` called `cancellables.removeAll()` synchronously, killing the transcription subscription before the recognizer could emit its final `isFinal=true` segment. This meant the parser never ran and the transcript was never parsed into a draft.

**Note on SFSpeechRecognizer behavior**: The recognizer sends a new cumulative `formattedString` on every partial result (it does not stream deltas). This means `transcript` in the VM always shows the full utterance so far. The cursor-based approach in the parser prevents double-counting.

### 5.3 Speech → Ticket Parsing (FuzzyMenuOrderParser)

Called only on `segment.isFinal == true` (intentional — avoids cursor confusion during partial results).

```
Input: segment.text (full final transcript), existingDraft, menu

Step 1: Slice new text
  newText = transcript[draft.consumedCursor...]
  If cursor >= transcript.count → return unchanged draft

Step 2: normalizeText(newText)
  → lowercased
  → filler words removed (\b word \b regex): "um","uh","like","so","and","the","a","an","for"
  → number words replaced: "one"→"1", "two"→"2", ..., "ten"→"10"
  → trimmed whitespace

Step 3: splitIntoSegments(normalized)
  → split on CharacterSet(",.") → array of trimmed non-empty strings

Step 4: For each segment:
  a. detectCourse(segment):
     - Check each courseKeyword against segment using .contains
     - Keywords: "app"/"apps"/"appetizer"/"appetizers"/"starter" → .appetizer
                 "entree"/"entrees"/"main"/"mains" → .entree
                 "dessert"/"desserts"/"sweet" → .dessert
                 "drink"/"drinks"/"beverage"/"beverages" → .beverage
                 "side"/"sides" → .side
     - If found: update currentCourse, continue to next segment
  b. detectSeat(segment):
     - Regex: #"seat\s+(\d+)"#
     - If found: update currentSeat, continue to next segment
  c. findBestItem(segment, allItems):
     - For each MenuItem: tokenOverlapScore(queryTokens, itemNameTokens)
     - Filter tokens < 3 chars (stops common words affecting score)
     - Score = |intersection| / |query tokens|  (where both sets include only tokens ≥ 3 chars)
     - Return best if score > 0.4
  d. extractQuantity(segment):
     - Regex: #"(\d+)\s+\w"# — matches digit(s) followed by a word character
     - Returns Int or 1 default
  e. extractModifiers(segment, matchedItem):
     - Temperature detection (sorted longest-phrase-first to prevent "medium" matching before "medium rare"):
       "medium rare" > "medium well" > "well done" > "rare" > "medium" > "med rare" > etc.
     - ModifierOption matching: tokenOverlapScore(segmentWords, modifierTokens) > 0.5
       with isNegation = negationPrefixes.contains("no "/"without "/"hold "/"remove "/"skip ") + modifier first token
  f. allergyDetection: segment.contains any of ["allergy","allergic","anaphylactic","epipen","cannot eat"]
  g. Build DraftItem and call draft.addItem() (dedup by menuItemId + modifierNames)

Step 5: draft.consumedCursor = transcript.count
```

#### Voice Macro Detection (`detectMacro`)
- Runs on every segment (partial + final) in `handleTranscriptionSegment`
- Normalizes text, checks `.contains` for each macroPattern key:
  - "repeat last order" / "same as last time" → `.repeatLastOrder`
  - "add side salad" / "side salad" → `.addSideSalad`
  - "split check" / "split the check" / "split bill" → `.splitCheck`
- First match wins

#### Repeat-Back Summary (`repeatBackSummary`)
- Generates human-readable string: "Table N: Qx ItemName (mod1, mod2) ⚠️ ALLERGY; ..."
- Empty draft returns "No items yet."

### 5.4 Ticket Lifecycle (create → edit → send → deliver)

```
Phase 1 — Draft (in LiveSessionViewModel)
  TicketDraft created in LiveSessionViewModel.init() with tableNumber
  Items added by parser on each final ASR segment
  User can remove items (vm.removeItem)
  User can add upsell suggestions directly to draft
  User can apply voice macros

Phase 2 — Confirm & Create Ticket (SwiftDataTicketRepository.createTicket)
  Triggered by "Edit" button → confirmAndNavigate(vm:)
  1. services.repository.createTicket(from: vm.draft, serverId: "local_server")
  2. Creates Ticket @Model object
  3. Groups DraftItems by seatNumber:
     - If no seatNumbers present: all items → GuestSeat(seatNumber: 1)
     - If seatNumbers present: one GuestSeat per unique seat; unseated items → seat 1
  4. For each DraftItem → buildTicketItem → TicketItem + TicketModifiers
  5. modelContext.insert(ticket) → modelContext.save()
  6. Returns Ticket, LiveSessionView navigates to TicketEditorView

Phase 3 — Edit (TicketEditorViewModel)
  TicketEditorViewModel.init loads coursePacingStates from ticket.coursePacingStates dict
  Available mutations:
  - sendToKitchen(): sets sentToKitchenAt = Date(), status = "SENT", saves
  - markDelivered(): sets deliveredAt = Date(), status = "DELIVERED", saves
  - closeTicket(): sets closedAt = Date(), status = "CLOSED", saves  [added 2026-03-19]
  - fireCourse(_ course): coursePacingStates[course] = .fired, saves
  - holdCourse(_ course): coursePacingStates[course] = .holding, saves
  - removeItem(_ item, from seat): removes from relationship, calls repository.deleteItem(item), saves  [FIXED 2026-03-19: now deletes from SwiftData context]
  - updateItemNotes(_ item, notes:): item.notes = notes, saves
  - confirmAllergyItem(_ item): item.allergyConfirmed = true, saves
  - moveItem(_ item, fromSeat:, toSeatNumber:): removes from source, appends to target (creates new GuestSeat if needed), saves

Phase 4 — Ticket List (TicketsListViewModel)
  fetchAll() sorts by openedAt descending
  Split into openTickets (OPEN/SENT) and completedTickets (DELIVERED/CLOSED)
  Pull-to-refresh available
  Swipe-delete on completed tickets only
```

### 5.5 Upsell & Coaching Pipeline

#### Upsell Engine (RuleBasedUpsellEngine)
```
Input: TicketDraft, MenuV1

1. Compute state:
   hasEntree = draft.items.contains { $0.course == .entree }
   hasDrink  = draft.items.contains { $0.course == .beverage }
   draftItemIds = Set of all draft.items.menuItemId

2. For each rule in menu.upsellRules:
   a. Check condition:
      - If rule.condition.hasEntree != nil: conditionMet &&= (hasEntree == rule.condition.hasEntree!)
      - If rule.condition.hasDrink != nil:  conditionMet &&= (hasDrink == rule.condition.hasDrink!)
   b. If conditionMet:
      For each suggestion in rule.suggest (max 2 candidates per suggestion):
        - If suggestion.tag: find allItems where tags.contains(tag)
        - If suggestion.itemId: find allItems where id == itemId
        - Filter out items already in draft
        - Append UpsellSuggestionResult(menuItem, reason: "Suggested pairing", playbookScript: rule.playbookScript)

3. Deduplicate by menuItem.id (first occurrence wins)
4. Return results
```

Upsell refresh is triggered after every: final ASR segment, item removal, macro application.

#### Repeat-Back Coaching
- User taps "Confirm" button in LiveSessionView (disabled if draft.items is empty)
- `vm.triggerRepeatBack()` → `parser.repeatBackSummary(for: draft)` → sets `repeatBackText`
- `showRepeatBack = true` → sheet presents `RepeatBackSheet` with the text
- Sheet is read-only with a "Done" button

#### Allergy Guardrail
- Parser sets `hasAllergyFlag = true` on DraftItem if any allergy keyword found in segment
- `handleTranscriptionSegment` checks for new allergy items → appends to `allergyItemsPendingConfirm`
- `AllergyAlertBanner` renders for each pending item (red banner, "ALLERGY: ItemName", "Confirm" button)
- `vm.confirmAllergyItem(_)` removes from pending list (draft item retains `hasAllergyFlag = true`)
- In TicketEditor: `TicketItemRow` shows red "ALLERGY" capsule button if `hasAllergyFlag && !allergyConfirmed`; tapping calls `vm.confirmAllergyItem` which sets `allergyConfirmed = true` on the SwiftData object

### 5.6 Seat Map & Course Pacing Flows

#### Seat Map (SeatMapView)
- Accessed via "View Seat Map" button in TicketEditorView → sheet presentation
- Renders visual table (brown rectangle) above a LazyVGrid of SeatCard views
- Each SeatCard shows seat number, item chips (draggable), drop zone
- Drag payload encoding: `"\(item.id)|\(seat.seatNumber)"` (pipe-delimited string)
- Drop handler: parses payload, finds item in source seat, calls `vm.moveItem(item, fromSeat:, toSeatNumber:)`
- "Add Seat" button: creates new `GuestSeat` with next number, inserts into modelContext and appends to ticket.guests
- Note: add-seat save is direct modelContext.insert without going through vm.save; relies on SwiftData auto-persist or next save from another action

#### Course Pacing (TicketEditorViewModel + TicketEditorView)
- Courses displayed: derived from `Set(ticket.allItems.map { $0.courseFlag })`; only courses actually present in ticket are shown
- Each `CourseControlRow` shows: course name, current state (Holding/Fired), "Fire [CourseName]" button, "Hold" button
- `fireCourse`: sets `coursePacingStates[course] = .fired` in both VM dict and `ticket.coursePacingStates[course.rawValue]` String dict, saves
- `holdCourse`: sets `coursePacingStates[course] = .holding` in both, saves
- No real-time sync to kitchen (local state only until Supabase Phase 2)

### 5.7 Voice Macro System

Three macros defined in `VoiceMacro` enum and matched in `FuzzyMenuOrderParser.macroPatterns`:

| Macro | Trigger Phrases | Action |
|-------|----------------|--------|
| repeatLastOrder | "repeat last order", "same as last time" | Copy items from `previousDraft` (passed as nil in current UI — feature is half-wired) |
| addSideSalad | "add side salad", "side salad" | Find menu item with "side salad" in name, create DraftItem, call draft.addItem |
| splitCheck | "split check", "split the check", "split bill" | No-op (`break`) — flagging only, no implementation |

Macro detection runs on every ASR segment (partial + final) in `handleTranscriptionSegment`.
UI renders blue banner when `vm.detectedMacro != nil` with "Apply"/"Dismiss" buttons.
"Apply" calls `vm.applyMacro(macro, previousDraft: nil)` — `previousDraft` is always nil, so `repeatLastOrder` effectively does nothing.

---

## 6. EXHAUSTIVE FILE & FUNCTION MAP

### 6.1 WhisperTicketApp.swift

```
struct WhisperTicketApp: App
  ├── let container: ModelContainer
  ├── let audioCapture: AudioCaptureServiceProtocol  (= AudioCaptureService())
  ├── let transcriptionService: TranscriptionServiceProtocol  (= SFSpeechTranscriptionService())
  ├── let menuStore: MenuStoreProtocol  (= LocalBundleMenuStore())
  ├── let parser: OrderParserProtocol  (= FuzzyMenuOrderParser())
  ├── let upsellEngine: UpsellEngineProtocol  (= RuleBasedUpsellEngine())
  ├── init()
  │     Initializes ModelContainer for [Ticket, GuestSeat, TicketItem, TicketModifier]
  │     Requests SFSpeech authorization
  │     Requests AVAudio record permission
  └── var body: some Scene
        WindowGroup → ContentView
          .modelContainer(container)
          .environment(\.appServices, AppServices(...))
          .task { try? await menuStore.loadMenu() }

struct AppServices
  ├── audioCapture: AudioCaptureServiceProtocol
  ├── transcriptionService: TranscriptionServiceProtocol
  ├── menuStore: MenuStoreProtocol
  ├── parser: OrderParserProtocol
  ├── upsellEngine: UpsellEngineProtocol
  └── repository: TicketRepositoryProtocol

private final class PlaceholderTicketRepository: TicketRepositoryProtocol
  ├── fetchAll() async throws -> [Ticket]   — returns []
  ├── fetchOpen() async throws -> [Ticket]  — returns []
  ├── save(_ ticket: Ticket) async throws   — no-op
  ├── delete(_ ticket: Ticket) async throws — no-op
  └── createTicket(from:serverId:) async throws -> Ticket  — fatalError

private final class PlaceholderMenuStore: MenuStoreProtocol
  ├── var menu: MenuV1? = nil
  ├── loadMenu() async throws  — no-op
  ├── findBestMatches(text:maxResults:) -> [(item:score:)]  — returns []
  └── item(byId:) -> MenuItem?  — returns nil

extension EnvironmentValues
  └── @Entry var appServices: AppServices  — default uses placeholder impls
```

### 6.2 Models/MenuV1.swift

```
struct MenuV1: Codable
  CodingKeys: restaurantId="restaurant_id", upsellRules="upsell_rules"

struct MenuCategory: Codable, Identifiable

struct MenuItem: Codable, Identifiable
  CodingKeys: modifierGroups="modifier_groups", upsellLinks="upsell_links", kitchenNoteTemplate="kitchen_note_template"

struct ModifierGroup: Codable, Identifiable
  CodingKeys: maxSelect="max_select"

struct ModifierOption: Codable, Identifiable
  CodingKeys: priceDelta="price_delta"

struct UpsellLink: Codable
  CodingKeys: targetItemId="target_item_id"

struct UpsellRule: Codable, Identifiable
  CodingKeys: condition="if", playbookScript="playbook_script"

struct UpsellCondition: Codable
  CodingKeys: hasEntree="has_entree", hasDrink="has_drink"

struct UpsellSuggestion: Codable
  CodingKeys: itemId="item_id"

extension MenuItem
  static let abbreviationOverrides: [String: String] = [:]  — empty; no custom overrides defined
  var abbreviation: String
    Single-word name → first 4 chars uppercased
    Multi-word → first char of each word, joined, uppercased
```

### 6.3 Models/Ticket.swift

```
enum TicketStatus: String, Codable
  open, sent, delivered, closed

enum CourseFlag: String, Codable, CaseIterable, Hashable
  appetizer, entree, dessert, beverage, side
  var displayName: String — switch on self
  var fireCommand: String — "Fire Apps"/"Fire Entrees"/"Fire Desserts"/else "Fire"

enum CoursePacingState: String, Codable
  holding, fired, delivered

@Model final class Ticket
  init(id:restaurantId:tableNumber:serverId:notes:rawTranscript:)
    Sets openedAt = Date(), status = "OPEN", guests = [], coursePacingStates = [:]
  var ticketStatus: TicketStatus  — TicketStatus(rawValue: status) ?? .open
  var timeToSend: TimeInterval?   — sentToKitchenAt - openedAt
  var timeToDeliver: TimeInterval? — deliveredAt - sentToKitchenAt
  var allItems: [TicketItem]      — guests.flatMap { $0.items }

@Model final class GuestSeat
  init(seatNumber: Int) — sets items = []

@Model final class TicketItem
  init(id:menuItemId:name:quantity:course:notes:confidence:hasAllergyFlag:)
    Sets allergyConfirmed = false, modifiers = [], course = course.rawValue
  var courseFlag: CourseFlag  — CourseFlag(rawValue: course) ?? .entree
  var ticketAbbreviation: String  — first-letter acronym (same algorithm as MenuItem.abbreviation)

@Model final class TicketModifier
  init(name:priceDelta:isNegation:)
```

### 6.4 Models/TicketDraft.swift

```
struct TicketDraft
  init(tableNumber: String) — items=[], rawTranscript="", consumedCursor=0
  mutating func addItem(_ item: DraftItem)
    Dedup: checks existing.menuItemId == item.menuItemId && existing.modifierNames == item.modifierNames
    If not exists: items.append(item)

struct DraftItem: Identifiable
  (all fields are var; mutable after creation)

enum VoiceMacro: String, CaseIterable
  repeatLastOrder, addSideSalad, splitCheck
  var displayName: String
```

### 6.5 Services/Protocols.swift

```
protocol AudioCaptureServiceProtocol: AnyObject — 4 methods + 2 properties
protocol TranscriptionServiceProtocol: AnyObject — 3 methods
struct TranscriptionSegment — text: String, isFinal: Bool
protocol OrderParserProtocol — 3 methods (value type protocol, not AnyObject)
protocol MenuStoreProtocol: AnyObject — 1 property, 3 methods
protocol TicketRepositoryProtocol — 5 methods (value type protocol)
protocol UpsellEngineProtocol — 1 method (value type protocol)
struct UpsellSuggestionResult: Identifiable — id (UUID), menuItem, reason, playbookScript?
```

### 6.6 Services/AudioCaptureService.swift

```
final class AudioCaptureService: AudioCaptureServiceProtocol
  private let audioEngine = AVAudioEngine()
  private let bufferSubject = PassthroughSubject<AVAudioPCMBuffer, Never>()
  private var cancellables = Set<AnyCancellable>()

  func startCapture() throws
    CALLS: session.setCategory, session.setActive, inputNode.installTap, audioEngine.prepare, audioEngine.start
    SETS: isRecording = true

  func stopCapture()
    CALLS: inputNode.removeTap, audioEngine.stop, session.setActive(false)
    SETS: isRecording = false, noiseLevel = 0.0

  func audioBufferPublisher() -> AnyPublisher<AVAudioPCMBuffer, Never>
    RETURNS: bufferSubject.eraseToAnyPublisher()

  private func updateNoiseLevel(buffer: AVAudioPCMBuffer)
    READS: buffer.floatChannelData?[0], buffer.frameLength
    COMPUTES: RMS of frame data, scaled ×10, clamped to 1.0
    CALLS: DispatchQueue.main.async { self.noiseLevel = ... }
    NOTE: noiseLevel is a stored property (not published); read by VM via timer poll
```

### 6.7 Services/SFSpeechTranscriptionService.swift

```
final class SFSpeechTranscriptionService: TranscriptionServiceProtocol
  private let recognizer = SFSpeechRecognizer(locale: Locale("en-US"))
  private var recognitionTask: SFSpeechRecognitionTask?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private let transcriptionSubject = PassthroughSubject<TranscriptionSegment, Never>()
  private var cancellables = Set<AnyCancellable>()

  static func requestPermission(completion: @escaping (Bool) -> Void)
    CALLS: SFSpeechRecognizer.requestAuthorization
    DISPATCHES: to DispatchQueue.main

  func transcriptionPublisher() -> AnyPublisher<TranscriptionSegment, Never>
    RETURNS: transcriptionSubject.eraseToAnyPublisher()

  func startTranscribing(audioPublisher: AnyPublisher<AVAudioPCMBuffer, Never>) throws
    GUARD: recognizer != nil && recognizer.isAvailable, else throw .recognizerUnavailable
    CREATES: SFSpeechAudioBufferRecognitionRequest (partialResults=true, onDevice=true)
    STARTS: recognizer.recognitionTask(with: request) { result, error in ... }
      On result: sends TranscriptionSegment to transcriptionSubject
      On error || isFinal: calls stopTranscribing()
    SUBSCRIBES: audioPublisher → request.append(buffer)

  func stopTranscribing()
    CALLS: recognitionRequest?.endAudio(), recognitionTask?.cancel()
    NILS: recognitionRequest, recognitionTask
    CLEARS: cancellables

enum TranscriptionError: Error
  recognizerUnavailable, permissionDenied
  NOTE: permissionDenied is defined but never thrown (permission handled in App.init)
```

### 6.8 Services/FuzzyMenuOrderParser.swift

```
final class FuzzyMenuOrderParser: OrderParserProtocol

  CONSTANTS:
  private let allergyKeywords = ["allergy","allergic","anaphylactic","epipen","cannot eat"]
  private let fillerWords = Set(["um","uh","like","so","and","the","a","an","for"])
  private let temperatureMap: [String: String]  — 10 entries, longest-to-shortest sorted for matching
  private let numberWords: [String: Int]         — "one"→1 ... "ten"→10
  private let negationPrefixes = ["no","without","hold","remove","skip"]
  private let courseKeywords: [String: CourseFlag]  — 16 entries
  private let macroPatterns: [String: VoiceMacro]   — 7 entries

  STRUCT:
  struct ParsedModifier { let name: String; let isNegation: Bool }

  PUBLIC METHODS:

  func parseDraft(transcript: String, existingDraft: TicketDraft, menu: MenuV1) -> TicketDraft
    CALLED BY: LiveSessionViewModel.handleTranscriptionSegment (on isFinal only)
    CALLS: normalizeText, splitIntoSegments, detectCourse, detectSeat, findBestItem,
           extractQuantity, extractModifiers, draft.addItem
    RETURNS: updated TicketDraft with new items and consumedCursor = transcript.count
    STATE: maintains currentCourse (default .entree), currentSeat (nil) as local vars per call

  func detectMacro(in text: String) -> VoiceMacro?
    CALLED BY: LiveSessionViewModel.handleTranscriptionSegment (every segment)
    CALLS: normalizeText, macroPatterns.contains (dictionary .contains)
    RETURNS: first matching VoiceMacro or nil

  func repeatBackSummary(for draft: TicketDraft) -> String
    CALLED BY: LiveSessionViewModel.triggerRepeatBack
    RETURNS: "Table N: Qx Item (mod1, mod2) ⚠️ ALLERGY; ..."

  PRIVATE METHODS:

  private func normalizeText(_ text: String) -> String
    CALLED BY: parseDraft, detectMacro
    OPS: lowercased → filler word regex removal → number word regex substitution → trimmed

  private func splitIntoSegments(_ text: String) -> [String]
    CALLED BY: parseDraft
    SPLITS ON: CharacterSet(",.")

  private func detectCourse(in segment: String) -> CourseFlag?
    CALLED BY: parseDraft per-segment
    STRATEGY: courseKeywords dictionary, segment.contains(keyword)

  private func detectSeat(in segment: String) -> Int?
    CALLED BY: parseDraft per-segment
    REGEX: #"seat\s+(\d+)"# — captures trailing digits

  private func findBestItem(in segment: String, from items: [MenuItem]) -> (MenuItem, Double)?
    CALLED BY: parseDraft per-segment
    STRATEGY: tokenOverlapScore for each item; returns best score > 0.4
    NOTE: uses segment tokens (from normalized text) against normalizeText(item.name) tokens

  private func extractQuantity(from segment: String) -> Int
    CALLED BY: parseDraft per-segment
    REGEX: #"(\d+)\s+\w"# — finds first digit sequence followed by word char
    DEFAULT: 1

  private func extractModifiers(from segment: String, item: MenuItem) -> [ParsedModifier]
    CALLED BY: parseDraft per-segment
    STEP 1: Temperature detection (sortedTemps by key.count desc → segment.contains → break on first)
    STEP 2: ModifierGroup matching (tokenOverlapScore on segment words vs modifier name > 0.5)
            isNegation = negationPrefixes.contains { segment.contains("\($0) " + modFirstToken) }
    RETURNS: array of ParsedModifier (name includes "No " prefix if negation)

  private func tokenOverlapScore(query: [String], candidate: [String]) -> Double
    CALLED BY: findBestItem, extractModifiers
    FILTERS: tokens with count <= 2 from query (stops "no", "a", "to" etc. from scoring)
    SCORE: |qSet ∩ cSet| / |qSet|   where qSet = Set(query.filter { $0.count > 2 })
    EDGE: returns 0 if qSet is empty
```

### 6.9 Services/LocalBundleMenuStore.swift

```
final class LocalBundleMenuStore: MenuStoreProtocol
  private(set) var menu: MenuV1?
  private var itemIndex: [String: MenuItem] = [:]          — keyed by item.id
  private var searchIndex: [(tokens: [String], item: MenuItem)] = []  — flat list with plural variants

  func loadMenu() async throws
    CALLED BY: WhisperTicketApp.body task
    READS: Bundle.main.url(forResource: "MenuV1.sample", withExtension: "json")
    THROWS: MenuStoreError.fileNotFound if URL not found
    DECODES: JSONDecoder().decode(MenuV1.self, from: data)
    CALLS: buildIndex(from: loaded)

  func findBestMatches(text: String, maxResults: Int = 3) -> [(item: MenuItem, score: Double)]
    CALLED BY: [INFERRED] could be used by UI for future search; currently not called from any View
    STRATEGY: normalize → tokenize → tokenOverlapScore vs searchIndex → filter > 0.2 → sort desc → prefix(maxResults)
    NOTE: This threshold is 0.2 (lower than parser's 0.4) — finds more candidates

  func item(byId id: String) -> MenuItem?
    CALLED BY: [INFERRED] not currently called from any Swift file
    RETURNS: itemIndex[id]

  private func buildIndex(from menu: MenuV1)
    CALLED BY: loadMenu
    FOR each item: adds (tokens, item) + plural variant (appends "s" to tokens without "s")
    CREATES: itemIndex dict

  private func normalize(_ text: String) -> String
    STRIPS: non-alphanumeric except spaces (regex [^a-z0-9 ])
    NOTE: Different from FuzzyMenuOrderParser.normalizeText (no filler removal here)

  private func tokenOverlapScore(query: [String], candidate: [String]) -> Double
    DIFFERENT from parser version: does NOT filter short tokens
    SCORE: |querySet ∩ candidateSet| / |querySet|

enum MenuStoreError: Error
  fileNotFound, decodingFailed
  NOTE: decodingFailed is defined but never thrown (JSONDecoder throws its own errors on failure)
```

### 6.10 Services/RuleBasedUpsellEngine.swift

```
final class RuleBasedUpsellEngine: UpsellEngineProtocol

  func suggestions(for draft: TicketDraft, menu: MenuV1) -> [UpsellSuggestionResult]
    CALLED BY: LiveSessionViewModel.refreshUpsells
    COMPUTES: hasEntree, hasDrink, allItems, draftItemIds
    FOR each rule:
      - Evaluates condition (hasEntree, hasDrink)
      - For each suggestion: resolve by tag OR itemId (prefix 2 candidates)
      - Filters out items already in draft
      - Appends UpsellSuggestionResult(menuItem, reason: "Suggested pairing", playbookScript: rule.playbookScript)
    DEDUPLICATES: by menuItem.id (first occurrence wins via Set.insert().inserted)
    RETURNS: deduplicated results
```

### 6.11 Services/SwiftDataTicketRepository.swift

```
final class SwiftDataTicketRepository: TicketRepositoryProtocol
  private let modelContext: ModelContext

  init(modelContext: ModelContext)

  func fetchAll() async throws -> [Ticket]
    DESCRIPTOR: sortBy openedAt descending, no predicate
    RETURNS: modelContext.fetch(descriptor)

  func fetchOpen() async throws -> [Ticket]
    DESCRIPTOR: predicate { status == "OPEN" || status == "SENT" }, sortBy openedAt descending
    CALLED BY: [INFERRED] not currently called from any ViewModel (TicketsListViewModel uses fetchAll)

  func save(_ ticket: Ticket) async throws
    CALLS: modelContext.save()
    NOTE: Does NOT insert — caller must ensure ticket is already in context

  func delete(_ ticket: Ticket) async throws
    CALLS: modelContext.delete(ticket), modelContext.save()

  func deleteItem(_ item: TicketItem) async throws   // added 2026-03-19
    CALLS: modelContext.delete(item), modelContext.save()

  func createTicket(from draft: TicketDraft, serverId: String) async throws -> Ticket
    CALLED BY: LiveSessionView.confirmAndNavigate
    LOGIC:
      1. Creates Ticket(tableNumber:, serverId:, rawTranscript:)
      2. seatNumbers = Set(draft.items.compactMap { $0.seatNumber })
      3. If empty seats: all items → one GuestSeat(1)
      4. If has seats: per-seat grouping + unseated → reuses existing seat 1 if present, else creates new GuestSeat(1)  [FIXED 2026-03-19: was creating duplicate seat 1]
      5. Each DraftItem → buildTicketItem → TicketItem + TicketModifiers
      6. modelContext.insert each item, seat, ticket; modelContext.save()
    RETURNS: inserted Ticket

  private func buildTicketItem(from draft: DraftItem) -> TicketItem
    CALLED BY: createTicket
    CREATES: TicketItem, then for each modName: TicketModifier(isNegation = draft.negations.contains(modName))
    RETURNS: TicketItem (not yet inserted — caller inserts)
```

### 6.12 ViewModels/LiveSessionViewModel.swift

```
@Observable final class LiveSessionViewModel

  OBSERVABLE STATE:
  var transcript: String = ""
  var draft: TicketDraft
  var upsellSuggestions: [UpsellSuggestionResult] = []
  var isRecording = false
  var isFinalizingTranscription = false   // added 2026-03-19: true between mic release and isFinal arrival
  var noiseLevel: Float = 0.0
  var showNoisyEnvironmentWarning = false
  var repeatBackText: String = ""
  var showRepeatBack = false
  var detectedMacro: VoiceMacro? = nil
  var errorMessage: String? = nil
  var allergyItemsPendingConfirm: [DraftItem] = []

  CONSTANTS:
  let noiseWarningThreshold: Float = 0.75

  DEPENDENCIES (injected via init):
  private let audioCapture: AudioCaptureServiceProtocol
  private let transcriptionService: TranscriptionServiceProtocol
  private let parser: OrderParserProtocol
  private let menuStore: MenuStoreProtocol
  private let upsellEngine: UpsellEngineProtocol
  private var cancellables = Set<AnyCancellable>()
  private var transcriptionCancellable: AnyCancellable? = nil   // added 2026-03-19: kept alive after stopRecording
  private var finalizationTimer: AnyCancellable? = nil          // added 2026-03-19: 3s safety timeout

  init(tableNumber:audioCapture:transcriptionService:parser:menuStore:upsellEngine:)

  PUBLIC METHODS:

  func startRecording()
    CALLS: audioCapture.startCapture(), transcriptionService.startTranscribing(audioPublisher:)
    RESETS: draft.consumedCursor = 0
    SETS: isRecording = true
    SUBSCRIBES: transcriptionService.transcriptionPublisher → handleTranscriptionSegment
    STARTS: Timer.publish(0.5) → checkNoiseLevel
    ERROR PATH: sets errorMessage on catch

  func stopRecording()  [FIXED 2026-03-19]
    CALLS: audioCapture.stopCapture() ONLY — does NOT stop transcription service yet
    SETS: isRecording = false, isFinalizingTranscription = true, noiseLevel = 0.0
    CLEARS: cancellables (stops timer etc.) — transcriptionCancellable kept alive
    STARTS: finalizationTimer (3-second safety timeout → finalizeTranscription)

  private func finalizeTranscription()
    CANCELS: finalizationTimer, transcriptionCancellable
    CALLS: transcriptionService.stopTranscribing()
    SETS: isFinalizingTranscription = false

  func triggerRepeatBack()
    CALLS: parser.repeatBackSummary(for: draft)
    SETS: repeatBackText, showRepeatBack = true

  func confirmAllergyItem(_ item: DraftItem)
    MUTATES: allergyItemsPendingConfirm (removes by id)
    NOTE: does NOT set allergyConfirmed on the DraftItem; that flag lives on TicketItem after creation

  func removeItem(_ item: DraftItem)
    MUTATES: draft.items (removes by id)
    CALLS: refreshUpsells()

  func applyMacro(_ macro: VoiceMacro, previousDraft: TicketDraft?)
    .repeatLastOrder: if let prev = previousDraft → draft.items = prev.items (prev always nil from UI)
    .addSideSalad: finds "side salad" item in menu, creates DraftItem, draft.addItem
    .splitCheck: break (no-op)
    SETS: detectedMacro = nil
    CALLS: refreshUpsells()

  PRIVATE METHODS:

  private func handleTranscriptionSegment(_ segment: TranscriptionSegment)
    CALLED BY: transcriptionPublisher subscription
    ALWAYS: transcript = segment.text; checks for macros
    IF isFinal && menu available: parseDraft → update draft; check allergy items; refreshUpsells

  private func checkNoiseLevel()
    CALLED BY: timer every 0.5s while recording
    READS: audioCapture.noiseLevel
    SETS: noiseLevel, showNoisyEnvironmentWarning (noiseLevel > 0.75)

  private func refreshUpsells()
    CALLED BY: handleTranscriptionSegment, removeItem, applyMacro
    CALLS: upsellEngine.suggestions(for: draft, menu: menu)
    SETS: upsellSuggestions
```

### 6.13 ViewModels/TableSelectViewModel.swift

```
@Observable final class TableSelectViewModel
  var tableNumber: String = ""
  var recentTables: [String] = []
  var isStartingSession = false  — set but never read from any view

  init(repository: TicketRepositoryProtocol)

  func loadRecentTables() async
    CALLED BY: TableSelectView.task
    CALLS: repository.fetchAll()
    LOGIC: maps tickets to tableNumber, deduplicates preserving order, takes first 10

  func selectTable(_ number: String)
    CALLED BY: TableSelectView button actions
    SETS: tableNumber = number
```

### 6.14 ViewModels/TicketEditorViewModel.swift

```
@Observable final class TicketEditorViewModel
  var ticket: Ticket
  var isSaving = false
  var errorMessage: String? = nil
  var coursePacingStates: [CourseFlag: CoursePacingState] = [:]  — mirrors ticket.coursePacingStates

  init(ticket:repository:)
    Deserializes ticket.coursePacingStates (String:String) → coursePacingStates (CourseFlag:CoursePacingState)

  func sendToKitchen() async
    SETS: ticket.sentToKitchenAt = Date(), ticket.status = "SENT"
    CALLS: save()

  func markDelivered() async
    SETS: ticket.deliveredAt = Date(), ticket.status = "DELIVERED"
    CALLS: save()

  func closeTicket() async   // added 2026-03-19
    GUARD: ticket.ticketStatus == .delivered (only closeable from DELIVERED)
    SETS: ticket.closedAt = Date(), ticket.status = "CLOSED"
    CALLS: save()

  func fireCourse(_ course: CourseFlag) async
    SETS: coursePacingStates[course] = .fired, ticket.coursePacingStates[course.rawValue] = "FIRED"
    CALLS: save()

  func holdCourse(_ course: CourseFlag) async
    SETS: coursePacingStates[course] = .holding, ticket.coursePacingStates[course.rawValue] = "HOLDING"
    CALLS: save()

  func removeItem(_ item: TicketItem, from seat: GuestSeat) async  [FIXED 2026-03-19]
    MUTATES: seat.items.removeAll { $0.id == item.id }
    CALLS: repository.deleteItem(item), save()
    NOTE: now explicitly deletes the TicketItem from modelContext (R8 fixed)

  func updateItemNotes(_ item: TicketItem, notes: String) async
    SETS: item.notes = notes
    CALLS: save()

  func confirmAllergyItem(_ item: TicketItem) async
    SETS: item.allergyConfirmed = true
    CALLS: save()

  func moveItem(_ item: TicketItem, fromSeat: GuestSeat, toSeatNumber: Int) async
    REMOVES: item from fromSeat.items
    FINDS or CREATES: GuestSeat with toSeatNumber in ticket.guests
    APPENDS: item to target seat
    CALLS: save()

  private func save() async
    SETS: isSaving = true
    CALLS: repository.save(ticket)
    ON ERROR: errorMessage = error.localizedDescription
    SETS: isSaving = false
```

### 6.15 ViewModels/TicketsListViewModel.swift

```
@Observable final class TicketsListViewModel
  var openTickets: [Ticket] = []
  var completedTickets: [Ticket] = []
  var isLoading = false

  init(repository: TicketRepositoryProtocol)

  func loadTickets() async
    CALLED BY: TicketsListView.task, .refreshable, after deleteTicket
    CALLS: repository.fetchAll()
    SPLITS: open (OPEN/SENT), completed (DELIVERED/CLOSED)

  func deleteTicket(_ ticket: Ticket) async
    CALLS: repository.delete(ticket), loadTickets()
```

### 6.16 Views/ContentView.swift

```
struct ContentView: View
  body: TabView with 3 tabs
    Tab 1: TableSelectView — icon "tablecells", label "Tables"
    Tab 2: TicketsListView — icon "doc.text", label "Tickets"
    Tab 3: MenuAdminView   — icon "menucard", label "Menu"
```

### 6.17 Views/TableSelectView.swift

```
struct TableSelectView: View
  @Environment(\.appServices) var services
  @State private var vm: TableSelectViewModel?
  @State private var navigateToSession: Bool = false
  @State private var customTable: String = ""

  private let presetTables = ["1"..."12","Bar","Patio"]  — 14 presets

  body:
    NavigationStack
      VStack:
        TextField + "Go" button  — custom table entry
        LazyVGrid(adaptive min:70) — preset table buttons
        ScrollView horizontal — recent tables (if vm.recentTables not empty)
      .navigationDestination(isPresented: $navigateToSession):
        if tableNumber not empty → LiveSessionView(tableNumber: tableNumber)
      .task: creates TableSelectViewModel, loads recent tables
```

### 6.18 Views/LiveSessionView.swift

```
struct LiveSessionView: View
  let tableNumber: String
  @Environment(\.appServices) var services
  @State private var vm: LiveSessionViewModel?
  @State private var navigateToEditor: Ticket? = nil

  body:
    NavigationStack
      if vm:
        VStack:
          [noise warning banner if vm.showNoisyEnvironmentWarning]
          [ForEach allergy banners → AllergyAlertBanner]
          [voice macro prompt banner if vm.detectedMacro != nil]
          ScrollView:
            GroupBox "Live Transcript" — transcript text or placeholder
            GroupBox "Ticket Draft — Table N" — DraftItemRow list (if items exist)
            UpsellSuggestionsView (if suggestions exist)
          Divider
          Controls VStack:
            [noise level ProgressView bar if recording]
            ["Processing speech…" ProgressView if vm.isFinalizingTranscription]  // added 2026-03-19
            HStack: Confirm button | HoldToTalkButton | Edit button
              Edit button enabled if transcript not empty OR draft has items  // FIXED 2026-03-19 (was: only if items exist)
        .sheet: RepeatBackSheet when vm.showRepeatBack
        .alert: error display for createTicket failures  // FIXED 2026-03-19 (was: errors swallowed)
        .navigationDestination(item: $navigateToEditor): TicketEditorView
      else: ProgressView("Setting up...")
    .task: create LiveSessionViewModel from services

  private func confirmAndNavigate(vm: LiveSessionViewModel) async
    CALLS: services.repository.createTicket(from: vm.draft, serverId: "local_server")
    SETS: navigateToEditor = ticket (triggers navigation to TicketEditorView)
    ON ERROR: sets errorMessage (do/catch, was try? before 2026-03-19 fix)

Sub-views in this file:
  struct HoldToTalkButton: View
    Circle button, red when recording (pulsing animation), accent color otherwise
    Toggles via action closure

  struct DraftItemRow: View
    Shows Qx ItemName [allergy icon if flagged] [confidence warning if < 0.7]
    Modifier list (caption), course badge (capsule), remove button (xmark.circle.fill)
    Row background red.opacity(0.08) if hasAllergyFlag

  struct AllergyAlertBanner: View
    Red banner with item name and Confirm button
    onConfirm closure triggers vm.confirmAllergyItem

  struct RepeatBackSheet: View
    NavigationStack with ScrollView showing repeatBackText
    "Done" dismiss button in toolbar

  struct UpsellSuggestionsView: View
    GroupBox "Suggestions"
    ForEach suggestions: item name + (playbookScript or reason) + "Add" button
    onAdd creates DraftItem and calls vm.draft.addItem directly (bypasses VM method)
```

### 6.19 Views/TicketEditorView.swift

```
struct TicketEditorView: View
  let ticket: Ticket
  @Environment(\.appServices) var services
  @State private var vm: TicketEditorViewModel?
  @State private var showSeatMap = false

  body:
    if vm:
      List:
        Section (header): table, opened, status, timeToSend (if present), timeToDeliver (if present)
          ElapsedTimeLabel (live-updating every 1s; color-coded orange >10m, red >20m)  // added 2026-03-19
          Total Time display (if ticket.totalTime present, i.e. closed)  // added 2026-03-19
        Section "Course Pacing": CourseControlRow for each unique course in ticket.allItems
        ForEach seats (sorted by seatNumber):
          Section "Seat N": TicketItemRow for each item + .onDelete (calls vm.removeItem)
        Section "Notes": ticket.notes (if not empty)
        Section: "Send to Kitchen" (disabled unless OPEN) + "Mark Delivered" (disabled unless SENT)
          + "Close Ticket" button (disabled unless DELIVERED)  // added 2026-03-19
        Section: "View Seat Map" button → showSeatMap = true
      .sheet(showSeatMap): SeatMapView(ticket:vm:)
    else:
      ProgressView → .task { vm = TicketEditorViewModel(...) }

  private func formatInterval(_ interval: TimeInterval) -> String
    Returns "Nm Ns" format

Sub-views in this file:
  struct ElapsedTimeLabel: View  // added 2026-03-19
    let since: Date
    @State elapsed: TimeInterval — updated every 1s via Timer
    Color: red >20m, orange >10m, primary otherwise

  struct TicketItemRow: View
    @State editingNotes, notesText
    Shows: Qx ItemName [abbreviation] | allergy capsule button (if flagged and not confirmed)
    ForEach modifiers: red for negations, secondary for others
    notes text (orange italic if not empty)
    "Low confidence — verify" label if confidence < 0.7
    "Edit Note" button → editingNotes sheet
    "Move Seat" Menu (if seatCount > 1) → ForEach seats → onMoveSeat callback

  struct CourseControlRow: View
    Shows: course displayName | state (Fired/Holding colored) | "Fire X" button | "Hold" button
    Fire disabled if already fired; Hold disabled if already holding
```

### 6.20 Views/TicketsListView.swift

```
struct TicketsListView: View
  @Environment(\.appServices) var services
  @State private var vm: TicketsListViewModel?

  body:
    NavigationStack
      List:
        Section "Open": NavigationLink → TicketEditorView for each open ticket
        Section "Completed": NavigationLink + .onDelete for completed
        ContentUnavailableView if both empty
      .refreshable: await vm.loadTickets()
      .task: create vm, load tickets

struct TicketRow: View
  VStack: "Table N" bold + StatusBadge | item count caption | timeToSend caption (if set)

struct StatusBadge: View
  Capsule badge with status text; color: open=blue, sent=orange, delivered=green, closed=secondary
```

### 6.21 Views/MenuAdminView.swift  [UPDATED 2026-03-19]

```
struct MenuAdminView: View
  @Environment(\.appServices) var services
  @State isLoading, errorMessage, importResult, isImporting, showImportPicker

  body:
    if menu loaded:
      List:
        Section "Restaurant": ID, version, category count, total item count
        ForEach categories: Section with item name, description, price
    else if loading: ProgressView
    else: ContentUnavailableView ("Add MenuV1.sample.json to the app bundle.")
    .toolbar:
      "Reload" button → loadMenu() with error capture  // FIXED: Reload now shows errors
      "Import" button → showImportPicker = true  // added 2026-03-19
    .fileImporter: PDF/image file picker → triggers services.menuImporter.importMenu  // added 2026-03-19
    .alert: error display (FIXED: now uses real Binding, not .constant())  // FIXED R10 2026-03-19
    .alert: import result display  // added 2026-03-19
    import progress overlay (ProgressView) when isImporting  // added 2026-03-19
```

### 6.22 Views/Components/SeatMapView.swift

```
struct SeatMapView: View
  let ticket: Ticket
  let vm: TicketEditorViewModel
  @Environment(\.dismiss) var dismiss
  @Environment(\.modelContext) var modelContext
  @State draggedItemId: String? = nil
  @State draggedFromSeatNumber: Int? = nil  — set nowhere; state variable unused

  body:
    NavigationStack
      ScrollView:
        VStack: "Table N" title + brown rectangle + LazyVGrid of SeatCard + "Add Seat" button
      .toolbar: "Done" dismiss button
    "Add Seat": increments (seats.last?.seatNumber ?? 0) + 1, modelContext.insert(newSeat), ticket.guests.append

struct SeatCard: View
  let seat: GuestSeat
  let draggedItemId: String? — received but not used in card rendering
  let onDrop: (String, Int) -> Void
  @State isTargeted: Bool

  body:
    VStack: "Seat N" header + ForEach items as draggable chips + "Empty seat" if no items
    .draggable: payload = "\(item.id)|\(seat.seatNumber)"
    .dropDestination(for: String.self):
      Parse payload: split on "|", extract itemId and sourceSeatNum
      Call onDrop(itemId, sourceSeatNum)
    .isTargeted: sets isTargeted for blue highlight feedback
```

### 6.23 Services/MenuImportService.swift  [NEW 2026-03-19]

```
final class StubMenuImportService: MenuImportServiceProtocol
  func importMenu(from fileURL: URL, fileType: MenuImportFileType) async -> MenuImportResult
    SIMULATES: 1.5s async delay
    RETURNS: .failure("Menu import is not yet connected…")
    NOTE: Phase 2 — replace with OpenAIMenuImportService that calls Vision API
              and parses response into strict MenuV1 JSON

// Phase 2 placeholder (not yet implemented):
// final class OpenAIMenuImportService: MenuImportServiceProtocol
//   Sends PDF/image to OpenAI Vision API
//   Parses structured response → MenuV1
//   Returns .success(menuV1) or .failure(errorMessage)
```

---

## 7. Data Flow & State Management

### 7.1 Service Injection Chain
```
App.init → concrete services created
App.body → AppServices struct containing all services → .environment(\.appServices, ...)
View.@Environment(\.appServices) → reads AppServices
View.init ViewModel using services.audioCapture, services.repository, etc.
ViewModel stores service references (never concrete types, only protocol types)
```

### 7.2 Audio → Transcript → Draft Flow (Combine Pipeline)
```
AVAudioEngine (inputNode tap at 1024 frames)
  → AVAudioPCMBuffer pushed to PassthroughSubject<AVAudioPCMBuffer, Never> (bufferSubject)
  → erased to AnyPublisher<AVAudioPCMBuffer, Never> (audioBufferPublisher)
  → sink in SFSpeechTranscriptionService: request.append(buffer)
  → SFSpeechRecognitionTask fires callback (recognition thread)
  → TranscriptionSegment pushed to PassthroughSubject<TranscriptionSegment, Never>
  → .receive(on: DispatchQueue.main) in LiveSessionViewModel
  → handleTranscriptionSegment → updates @Observable state
  → SwiftUI re-renders affected views
```

### 7.3 State Ownership
| State | Owner | Persistence |
|-------|-------|-------------|
| Recording state | LiveSessionViewModel | Session-scoped |
| Transcript text | LiveSessionViewModel | Session-scoped |
| TicketDraft | LiveSessionViewModel | Session-scoped |
| Upsell suggestions | LiveSessionViewModel | Session-scoped (recomputed) |
| Allergy pending | LiveSessionViewModel | Session-scoped |
| Detected macro | LiveSessionViewModel | Session-scoped |
| Noise level | AudioCaptureService (polled) | Recording-scoped |
| Selected table | TableSelectViewModel | Ephemeral (lost on navigation) |
| Recent tables | TableSelectViewModel | Loaded from DB each time |
| Ticket list | TicketsListViewModel | Loaded from DB |
| Open tickets | TicketsListViewModel | Loaded from DB |
| Course pacing states | TicketEditorViewModel + Ticket | Both VM dict + SwiftData String dict |
| Menu | LocalBundleMenuStore | App-lifetime (loaded once) |
| SwiftData objects | ModelContainer | Disk (SQLite via SwiftData) |

### 7.4 @Observable vs Combine
- ViewModels use `@Observable` (Swift Observation framework, iOS 17)
- Services use Combine publishers for streaming data (audio buffers, transcription segments)
- `@Observable` eliminates need for `@Published`; SwiftUI tracks accessed properties automatically
- Timer uses Combine `.publish` in LiveSessionViewModel

---

## 8. CI/CD Pipeline (build.yml Walkthrough, Secrets, setup-signing.py)

### 8.1 Trigger Conditions
- Push to `main` or `develop` branches → full build + conditional upload
- Pull request targeting `main` → build + export only (no TestFlight upload)

### 8.2 Build Steps (GitHub Actions, macos-latest runner)

1. **Checkout** (actions/checkout@v4)
2. **Select Xcode** (maxim-lobanov/setup-xcode@v1, latest-stable)
3. **Install xcodegen** (brew install xcodegen)
4. **Generate Xcode project** (`xcodegen generate --spec project.yml`)
5. **Install Distribution Certificate**:
   - Writes `DIST_PRIVATE_KEY_PEM` secret to temp file (private key)
   - Decodes `DIST_CERT_DER_B64` from base64 → DER file
   - `openssl x509 -inform DER` → converts to PEM
   - `openssl pkcs12 -export` → assembles P12 using native LibreSSL (avoids cross-platform PKCS12 issues)
   - Creates temp keychain, imports P12, sets partition list for codesign access
6. **Install Provisioning Profile**:
   - Decodes `PROV_PROFILE_BASE64` → .mobileprovision file
   - Copies to `~/Library/MobileDevice/Provisioning Profiles/<PROFILE_UUID>.mobileprovision`
   - Exports `PROFILE_UUID` to GITHUB_ENV
7. **Write App Store Connect API Key**:
   - Writes `ASC_API_KEY` secret to `~/.private_keys/AuthKey_<ASC_KEY_ID>.p8`
8. **Archive** (`xcodebuild archive`):
   - Scheme: WhisperTicket, destination: generic/platform=iOS
   - Configuration: Release
   - DEVELOPMENT_TEAM from `APPLE_TEAM_ID` secret, CODE_SIGN_STYLE=Manual
   - Output: `$RUNNER_TEMP/WhisperTicket.xcarchive`
   - Logs to `build.log` via tee
9. **Export & Upload** (main push only):
   - ExportOptions.plist: method=app-store-connect, destination=upload
   - `xcodebuild -exportArchive` with ASC API auth
10. **Export IPA** (PR only):
    - Same as above but destination=export (no upload)
11. **Artifacts**:
    - On failure: upload `build.log`
    - On success: upload `*.ipa` from export path (if-no-files-found: ignore)

### 8.3 Required GitHub Secrets
| Secret | Purpose |
|--------|---------|
| `DIST_PRIVATE_KEY_PEM` | RSA-2048 distribution private key (PEM) |
| `DIST_CERT_DER_B64` | iOS Distribution certificate (DER, base64-encoded) |
| `DIST_CERT_P12_PASSWORD` | Password for P12 assembly |
| `PROV_PROFILE_BASE64` | App Store provisioning profile (base64) |
| `PROV_PROFILE_UUID` | Profile UUID for install path |
| `ASC_API_KEY` | App Store Connect API private key (.p8 content) |
| `ASC_KEY_ID` | App Store Connect API key ID |
| `ASC_ISSUER_ID` | App Store Connect API issuer ID |
| `APPLE_TEAM_ID` | Apple Developer Team ID (M37X5J35F8) |

### 8.4 setup-signing.py (One-Time Setup Script)

Python script run locally to bootstrap CI secrets. Does NOT run in CI.

**Flow (5 steps)**:
1. Revokes all existing `IOS_DISTRIBUTION` certs and `IOS_APP_STORE` profiles via ASC API
2. Generates RSA-2048 key pair + CSR using `cryptography` library
3. Submits CSR to ASC API → receives signed cert DER
4. Looks up bundle ID resource in ASC, creates new App Store provisioning profile
5. Sets 5 GitHub secrets via `gh secret set` (piped via stdin to avoid Windows CLI limits)

**Dependencies**: `PyJWT`, `cryptography`, `requests`, `gh` CLI

**Auth**: App Store Connect JWT (`ES256` signed, 1100s expiry, audience `appstoreconnect-v1`)

**Note**: Private key stored as unencrypted PEM in GitHub secret — acceptable tradeoff since GitHub secrets are encrypted at rest.

### 8.5 .gitattributes
- `* text=auto eol=lf` — forces LF line endings for all text files (critical for Swift/Xcode on macOS CI)
- PNG, JPG, PDF, ZIP, xcodeproj marked as binary (no line ending conversion)

---

## 9. Risks, Gaps, and Open Questions

### 9.0 Changes Landed (2026-03-19)

| Area | Change |
|------|--------|
| ASR finalization | `stopRecording()` no longer kills transcription subscription prematurely; `finalizeTranscription()` runs after `isFinal=true` or 3s timeout |
| Menu observability | `LocalBundleMenuStore` now `@Observable`; menu display now triggers SwiftUI re-render after async load |
| Ticket close | `closeTicket()` added to `TicketEditorViewModel`; `TicketStatus.closed` now reachable from UI |
| Order timing | `ElapsedTimeLabel` (live, color-coded) + `totalTime` computed property + total time display in TicketEditorView |
| SwiftData orphans (R8) | `removeItem` now calls `repository.deleteItem` → explicit `modelContext.delete` |
| Duplicate seat 1 (R6) | `createTicket` now reuses existing seat 1 for unseated items |
| MenuAdminView error alert (R10) | Fixed `.constant()` binding; Reload now captures errors; import progress + result alerts added |
| Menu import scaffold | `MenuImportServiceProtocol` + `StubMenuImportService` + file picker UI in `MenuAdminView`; Phase 2 = OpenAI Vision |
| App icons | Placeholder green icons added to `Assets.xcassets/AppIcon.appiconset`; all required sizes present |
| CI/CD pipeline | Full end-to-end pipeline working: push → archive → sign → export → TestFlight upload (~4m) |

### 9.1 Critical Risks [DIRECTLY SUPPORTED BY CODE]

**R1: Silent menu load failure** — PARTIALLY FIXED 2026-03-19
- `WhisperTicketApp.body` now logs menu load errors via `do/catch` + print (was `try?`).
- Still no visible user-facing alert if menu fails to load at startup; `MenuAdminView` shows "No Menu Loaded".
- **Remaining**: Add a visible alert/splash error for missing bundle JSON.

**R2: `repeatLastOrder` macro is non-functional**
- `LiveSessionView.confirmAndNavigate` calls `vm.applyMacro(macro, previousDraft: nil)`.
- `applyMacro(.repeatLastOrder, previousDraft: nil)` — since `previousDraft` is always nil, the `if let prev = previousDraft` guard always fails.
- No previous draft is ever passed; the macro appears to work (banner shows, Apply dismisses it) but does nothing.
- **Fix**: Wire previousDraft from repository (fetch most recent completed ticket's rawTranscript and re-parse, or store last draft in UserDefaults/SwiftData).

**R3: `splitCheck` macro is a no-op**
- The macro is detected and displayed, but `applyMacro(.splitCheck)` has `break` — no action taken.
- No split-check flag on Ticket model, no UI affordance.
- **Fix**: Add `isSplitCheck: Bool` field to Ticket (or TicketDraft), set it here, show indicator in TicketEditor.

**R4: `fetchOpen()` is never called**
- `TicketRepositoryProtocol.fetchOpen()` is implemented in `SwiftDataTicketRepository` and defined in the protocol, but `TicketsListViewModel.loadTickets()` calls `fetchAll()` and filters in memory.
- Dead code in the protocol and implementation.
- **Fix**: Either use `fetchOpen()` for the open section or remove it from the protocol.

**R5: `item(byId:)` and `findBestMatches` on MenuStore are never called from views**
- `LocalBundleMenuStore.item(byId:)` and `findBestMatches` — both implemented but no caller found in any Swift file.
- `findBestMatches` could be useful for a future search UI. `item(byId:)` could be used to look up a MenuItem from a TicketItem's `menuItemId` field.
- **Observation**: These are forward-looking protocol methods not yet consumed.

**R6: Duplicate seat 1 risk in createTicket** — FIXED 2026-03-19
- Fixed in `SwiftDataTicketRepository.createTicket`: unseated items now reuse existing `GuestSeat(seatNumber: 1)` if already created in the per-seat loop, instead of creating a second seat-1 object.

**R7: SeatMapView directly inserts into modelContext without vm.save**
- "Add Seat" button in SeatMapView calls `modelContext.insert(newSeat)` and `ticket.guests.append(newSeat)` without calling `vm.save()`. The new seat exists in the context but may not be persisted until the next `repository.save()` call.
- **Fix**: Call `try? modelContext.save()` after insert, or route through vm.

**R8: TicketEditorViewModel.removeItem does not delete from modelContext** — FIXED 2026-03-19
- `removeItem` now calls `repository.deleteItem(item)` which explicitly calls `modelContext.delete(item)` and saves. No more orphaned TicketItem entities.

**R9: draggedFromSeatNumber state variable is set nowhere in SeatMapView**
- `@State private var draggedFromSeatNumber: Int? = nil` is declared in `SeatMapView` but never assigned. The drop handler in `SeatCard.dropDestination` extracts the source seat from the payload string directly, so this is effectively dead state.

**R10: MenuAdminView error alert never fires** — FIXED 2026-03-19
- FIXED: `.alert` now uses a real `Binding<Bool>` derived from `errorMessage != nil`, and `errorMessage` is now set on Reload failures. Import error alert also added.

### 9.2 Architecture Observations [INFERRED]

**O1: TicketRepositoryProtocol is not AnyObject-constrained**
- `OrderParserProtocol`, `TicketRepositoryProtocol`, `UpsellEngineProtocol` are value-type protocols (no `AnyObject` constraint), while `AudioCaptureServiceProtocol`, `TranscriptionServiceProtocol`, `MenuStoreProtocol` are `AnyObject`. The stored properties in AppServices hold these as concrete existentials. Inconsistent: if a future non-class implementation of `TicketRepositoryProtocol` is desired, it won't work with `let` storage without boxing.

**O2: Noise level polling vs publishing**
- `AudioCaptureService.noiseLevel` is a `private(set) var` updated via `DispatchQueue.main.async` from the audio tap. The VM polls it via `Timer.publish(every: 0.5)`. A cleaner approach would be a `noiseLevelPublisher() -> AnyPublisher<Float, Never>` on the protocol, similar to `audioBufferPublisher()`. The current polling introduces up to 0.5s latency for noise display.

**O3: No error type for TicketRepositoryProtocol**
- Repository methods throw generic `Error`. A typed `TicketRepositoryError` enum would improve error handling in callers.

**O4: No unit tests**
- No test targets visible in project.yml or file tree. The implementation plan mentions `Cmd+U` as verification but no test files were created. The parser, upsell engine, and repository are all highly testable with dependency injection.

**O5: TranscriptionError.permissionDenied is never thrown**
- Defined in the enum, never referenced in `SFSpeechTranscriptionService`. Permission is handled at app startup, not in the service.

**O6: App name inconsistency**
- CLAUDE.md/MEMORY.md call it "WaitTicket". Xcode target, bundle ID, and all code use "WhisperTicket". The folder is "Whisper". This creates confusion for new contributors.

---

## 10. Edge Cases, Failure Modes, Resilience

### 10.1 ASR / Audio Edge Cases

**EC1: recognizer.isAvailable = false**
- `startTranscribing` throws `TranscriptionError.recognizerUnavailable`.
- `LiveSessionViewModel.startRecording` catches and sets `errorMessage` — displayed nowhere in the UI (errorMessage is observed but no error view in LiveSessionView).
- **Gap**: No UI displays `errorMessage`.

**EC2: SFSpeechRecognizer timeout (60-second limit)**
- Apple's SFSpeechRecognizer enforces a ~60-second per-utterance limit. On timeout, it sends a final result with `isFinal = true` and an error.
- `SFSpeechTranscriptionService.recognitionTask` callback calls `stopTranscribing()` on error.
- The recording session appears to continue (`isRecording` is still true in VM because `stopRecording()` is not called), but no more transcription events will fire.
- **Gap**: Stale recording state after timeout. Should call `vm.stopRecording()` from the service or surface to VM.

**EC3: AVAudioSession interrupted (phone call, Siri)**
- `AVAudioSession.interruptionNotification` is not observed. An incoming call will silently stop audio. `isRecording` stays `true` in VM; no UI feedback.
- **Gap**: No interruption handling.

**EC4: Device microphone denied**
- `startCapture()` will still run (no guard on permission). `audioEngine.start()` may succeed but produce no input data, or fail with an error that gets caught by `startCapture()` throw → `vm.errorMessage` set.

**EC5: Empty transcript segment**
- If SFSpeechRecognizer produces an empty `formattedString`, `normalizeText("")` returns `""`, `splitIntoSegments("")` returns `[]`, no items are processed. Safe.

**EC6: Very long transcript (cursor overflow)**
- `draft.consumedCursor = transcript.count` after each final parse. String count is character count. `transcript.index(startIndex, offsetBy: cursor)` could crash if cursor > transcript.count. Protected by the `if draft.consumedCursor < transcript.count` guard. Safe.

**EC7: Allergy keyword in item name itself**
- e.g. "allergy-free bread" — the allergy keyword `"allergy"` would match and flag the item. This is a false positive. The keyword check is `segment.contains($0)` with no word-boundary constraint.

### 10.2 Parser Edge Cases

**EC8: Course keyword is also a food item name**
- "App" (as in app course) vs "App" as part of another context. The `detectCourse` check runs before `findBestItem`, so a segment containing only course keywords will be consumed and not matched for items.

**EC9: Segment ordering matters**
- The parser maintains `currentCourse` and `currentSeat` as local variables per `parseDraft` call. These reset to `.entree` and `nil` on every call. So "Apps:" from one speech session sets currentCourse, but if the transcript is re-parsed (cursor reset to 0), the course context is re-established. If the transcript spans calls and the course marker was in an earlier segment, it will be correctly re-parsed.

**EC10: Token filter removes short meaningful tokens**
- `tokenOverlapScore` filters tokens with `count > 2` from the query. This means "ale" (3 chars, passes), but "IPA" (3 chars, passes), "ok" (2 chars, filtered). The IPA item name would tokenize to ["ipa","draft","beer"]. All pass the 3-char filter.

**EC11: Temperature "medium" vs "medium rare" — ordering**
- `extractModifiers` sorts `temperatureMap` by key length descending before checking. This ensures "medium rare" is checked before "medium". Correct.

**EC12: Quantity regex mismatch**
- `#"(\d+)\s+\w"#` requires a digit followed by space followed by a word character. "2x burger" → would match "2x" (digit "2", space, then "x"). "2 burgers" → matches. "burger 2" → does not match (digit not at start of pattern). Default of 1 is returned for non-matching segments.

### 10.3 SwiftData Edge Cases

**EC13: ModelContainer fatalError on schema mismatch**
- If SwiftData models change (fields added/removed) without migration, `ModelContainer` may throw on init, causing `fatalError`. No migration policy defined.

**EC14: Concurrent save operations**
- Multiple `Task { await vm.saveOperation() }` can run concurrently from the UI. `SwiftDataTicketRepository.save()` calls `modelContext.save()` each time. Concurrent saves on the main `ModelContext` may be safe (sequential on main actor by default) but this is not explicitly synchronized.

**EC15: GuestSeat created in SeatMapView not saved**
- See R7 above. The new seat is inserted into context but a `modelContext.save()` never fires from the add-seat action.

---

## 11. Refactor, Extension & Testing Opportunities

### 11.1 High-Priority Fixes

**FIX1: Wire `repeatLastOrder` macro properly**
```swift
// In LiveSessionView.confirmAndNavigate or LiveSessionViewModel:
// Store previousDraft from most recent completed session
// Pass to applyMacro(.repeatLastOrder, previousDraft: lastDraft)
```

**FIX2: Populate `errorMessage` UI**
```swift
// In LiveSessionView: add .alert for vm.errorMessage
// In MenuAdminView: fix .constant() binding, set errorMessage on loadMenu failure
```

**FIX3: Prevent duplicate seat 1** — DONE 2026-03-19
- Unseated items now reuse existing seat 1 instead of creating a new GuestSeat.

**FIX4: Add save after "Add Seat" in SeatMapView** — still open (R7)
```swift
// After modelContext.insert(newSeat), ticket.guests.append(newSeat):
// try? modelContext.save()
// Or: route through vm with a new addSeat(_ seatNumber: Int) method
```

**FIX5: Delete orphaned TicketItems in removeItem** — DONE 2026-03-19
- `removeItem` now calls `repository.deleteItem(item)` → explicit `modelContext.delete` + save.

### 11.2 Testing Opportunities

**T1: FuzzyMenuOrderParser unit tests** — most critical
- Test `parseDraft` with each PARSING.md scenario
- Test allergy keyword detection
- Test temperature ordering (medium vs medium rare)
- Test `detectMacro` for all 7 patterns
- Test `tokenOverlapScore` edge cases (empty query, short tokens)
- Input: transcript String + MenuV1 fixture; Output: DraftItem array assertions

**T2: RuleBasedUpsellEngine unit tests**
- Test `rule_drink_if_none`: draft with entree, no drink → should suggest drinks
- Test `rule_fries_with_burger`: draft with no entree, no drink → should suggest fries
- Test deduplication
- Test empty draft

**T3: SwiftDataTicketRepository integration tests**
- Test `createTicket` with 0 seats, 1 seat, multiple seats, unseated+seated mix
- Test `fetchAll` returns correct sort order
- Test `delete` cascade

**T4: LocalBundleMenuStore unit tests**
- Test `loadMenu` with valid JSON
- Test `findBestMatches` threshold behavior
- Test plural variant construction in `buildIndex`

**T5: TicketEditorViewModel unit tests**
- Test `sendToKitchen` sets correct timestamp and status
- Test `fireCourse`/`holdCourse` correctly syncs both `coursePacingStates` dict and `ticket.coursePacingStates`
- Test `moveItem` creates new seat when target not found

### 11.3 Extension Opportunities

**EX1: Add `noiseLevelPublisher()` to AudioCaptureServiceProtocol**
- Replace timer polling in LiveSessionViewModel
- More reactive; eliminates 0-0.5s noise display lag

**EX2: Add `TicketRepositoryError` typed enum**
- Replace `Error` in protocol throws with typed enum
- Enables specific error handling in callers

**EX3: Add search UI using `MenuStoreProtocol.findBestMatches`**
- Manual menu item search in LiveSessionView
- Already implemented in service; needs View + VM wiring

**EX4: Persist splitCheck flag on Ticket**
- `var isSplitCheck: Bool = false` on Ticket @Model
- Set in `applyMacro(.splitCheck)`
- Display indicator in TicketEditorView header

**EX5: Menu version migration strategy**
- When `version` field in JSON increments, existing SwiftData TicketItems reference old `menuItemId` values
- Need a mapping strategy or version compatibility layer

**EX6: Add `@ModelActor` for background SwiftData operations**
- All SwiftData operations currently run on main context (main thread)
- For large ticket histories, `fetchAll` on main could cause jank
- Migrate to `@ModelActor` background context for repository

**EX7: Keyboard avoidance in LiveSessionView**
- If custom table entry keyboard is shown (in TableSelectView) while navigating, keyboard may persist
- Standard SwiftUI keyboard handling (`.ignoresSafeArea(.keyboard)` if needed)

---

## 12. Future Goals Cross-Reference (from FUTURE_GOALS.md)

All 7 future goals are in `docs/FUTURE_GOALS.md`. Summary with current architecture impact:

| # | Feature | Protocol Gap | New Service Needed | Trigger |
|---|---------|-------------|-------------------|---------|
| 1 | Multilingual | None (parser is swappable) | `NLLanguageRecognizer`/translator adapter | Non-English market |
| 2 | POS Integration | Add `POSExportServiceProtocol` | Toast/Square/Clover adapters | First POS request |
| 3 | Fraud/Void Analytics | TicketItem needs `voidedAt`, `voidReason`, `isComped` | Manager role, Supabase queries | Manager reporting need |
| 4 | Training Mode | Needs `TrainingEvaluatorService` protocol | Scoring rubric, overlay coaching | Staff onboarding tool |
| 5 | QR/NFC Table Select | None (UI-only addition to TableSelectView) | AVFoundation QR / CoreNFC session | Sub-2-second table select |
| 6 | Kitchen Display Mode | None (read-only Supabase Realtime subscriber) | `KitchenDisplayView` (iPad) | Restaurant has display screen |
| 7 | Printer Support | Add `PrinterServiceProtocol` | Star/Epson SDK adapter | Paper ticket request |

### Phase 2 (Supabase) Migration Path
The architecture is explicitly Supabase-ready. To migrate:
1. `WhisperTicketApp.swift` — swap `SwiftDataTicketRepository` for `SupabaseTicketRepository`
2. `WhisperTicketApp.swift` — swap `LocalBundleMenuStore` for `SupabaseMenuStore`
3. Keep all ViewModels, Views, protocols unchanged
4. Add `restaurantId` and `serverId` population from Supabase auth profile
5. `SupabaseTicketRepository.save()` would sync to Supabase + local SwiftData for offline support

---

## Appendix A: Detailed Module & File Map

| File | Layer | Role | Key Exports |
|------|-------|------|-------------|
| `WhisperTicketApp.swift` | App | Entry point, DI wiring | `WhisperTicketApp`, `AppServices`, `EnvironmentValues.appServices` |
| `Models/MenuV1.swift` | Model | Menu domain types | `MenuV1`, `MenuItem`, `ModifierGroup`, `UpsellRule`, `MenuItem.abbreviation` |
| `Models/Ticket.swift` | Model | Persisted order types | `Ticket`, `GuestSeat`, `TicketItem`, `TicketModifier`, `TicketStatus`, `CourseFlag`, `CoursePacingState` |
| `Models/TicketDraft.swift` | Model | In-memory parsing types | `TicketDraft`, `DraftItem`, `VoiceMacro` |
| `Services/Protocols.swift` | Protocol | All service contracts | 6 protocols, `TranscriptionSegment`, `UpsellSuggestionResult` |
| `Services/AudioCaptureService.swift` | Service | AVAudio capture + noise | `AudioCaptureService` |
| `Services/SFSpeechTranscriptionService.swift` | Service | On-device ASR | `SFSpeechTranscriptionService`, `TranscriptionError` |
| `Services/FuzzyMenuOrderParser.swift` | Service | NLP order parsing | `FuzzyMenuOrderParser` (inner: `ParsedModifier`) |
| `Services/LocalBundleMenuStore.swift` | Service | Bundle JSON menu | `LocalBundleMenuStore`, `MenuStoreError` |
| `Services/RuleBasedUpsellEngine.swift` | Service | Upsell suggestions | `RuleBasedUpsellEngine` |
| `Services/SwiftDataTicketRepository.swift` | Service | SwiftData CRUD | `SwiftDataTicketRepository` |
| `ViewModels/LiveSessionViewModel.swift` | ViewModel | Voice session state | `LiveSessionViewModel` |
| `ViewModels/TableSelectViewModel.swift` | ViewModel | Table selection state | `TableSelectViewModel` |
| `ViewModels/TicketEditorViewModel.swift` | ViewModel | Ticket edit state | `TicketEditorViewModel` |
| `ViewModels/TicketsListViewModel.swift` | ViewModel | Ticket list state | `TicketsListViewModel` |
| `Views/ContentView.swift` | View | TabView root | `ContentView` |
| `Views/TableSelectView.swift` | View | Table grid + nav | `TableSelectView` |
| `Views/LiveSessionView.swift` | View | Voice session UI | `LiveSessionView`, `HoldToTalkButton`, `DraftItemRow`, `AllergyAlertBanner`, `RepeatBackSheet`, `UpsellSuggestionsView` |
| `Views/TicketEditorView.swift` | View | Full ticket edit | `TicketEditorView`, `TicketItemRow`, `CourseControlRow` |
| `Views/TicketsListView.swift` | View | Ticket list | `TicketsListView`, `TicketRow`, `StatusBadge` |
| `Views/MenuAdminView.swift` | View | Menu browse | `MenuAdminView` |
| `Views/Components/SeatMapView.swift` | View/Component | Drag-drop seat map | `SeatMapView`, `SeatCard` |
| `Resources/MenuV1.sample.json` | Resource | Demo menu data | 4 categories, 9 items, 2 upsell rules |
| `project.yml` | Config | xcodegen spec | iOS 17.0, iPhone+iPad, bundle: com.whisperticket.app |
| `.github/workflows/build.yml` | CI | Build + TestFlight | 9 secrets, archive + export + upload |
| `scripts/setup-signing.py` | Script | CI secrets bootstrap | 5-step ASC API + GitHub secret setup |
| `docs/FUTURE_GOALS.md` | Docs | Deferred features | 7 features with implementation approaches |
| `docs/PARSING.md` | Docs | Parser pipeline spec | Pipeline overview, fuzzy matching, macro table, demo scenarios |
| `docs/SCHEMAS.md` | Docs | Data schema reference | MenuV1, TicketV1, TicketDraft field tables |
| `docs/UX_FLOWS.md` | Docs | Screen flow reference | Primary, secondary, allergy, noise, macro, upsell, seat map flows |
| `docs/plans/2026-03-02-whisperticket.md` | Docs | Full implementation plan | All code for MVP + low + medium complexity |

---

## Appendix B: Key Constants & Thresholds

| Constant | Value | Location | Meaning |
|----------|-------|----------|---------|
| `noiseWarningThreshold` | 0.75 | LiveSessionViewModel | Noise level at which orange warning shows |
| Item match threshold | 0.4 | FuzzyMenuOrderParser.findBestItem | Minimum token overlap to add item to draft |
| Modifier match threshold | 0.5 | FuzzyMenuOrderParser.extractModifiers | Minimum overlap to detect modifier |
| MenuStore match threshold | 0.2 | LocalBundleMenuStore.findBestMatches | Minimum overlap to return in findBestMatches |
| Low confidence display | < 0.7 | DraftItemRow, TicketItemRow | Show warning chip below this score |
| Noise level scale | ×10, clamped 1.0 | AudioCaptureService.updateNoiseLevel | RMS scaled for UI display |
| Token min length | > 2 chars | FuzzyMenuOrderParser.tokenOverlapScore | Tokens ≤ 2 chars excluded from scoring |
| Recent tables max | 10 | TableSelectViewModel.loadRecentTables | Max entries in recent list |
| Upsell per suggestion max | 2 | RuleBasedUpsellEngine | Max candidates per UpsellSuggestion |
| Timer interval | 0.5s | LiveSessionViewModel.startRecording | Noise level poll frequency |
| ASR buffer size | 1024 frames | AudioCaptureService.startCapture | Audio engine tap buffer |
| Preset tables | 14 | TableSelectView | ["1"-"12", "Bar", "Patio"] |

---

*End of Digest — Generated 2026-03-17*
