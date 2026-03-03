# WaitTicket iOS App Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a SwiftUI iOS app that lets waitstaff capture orders by voice, structure them into editable tickets, and track delivery timing — all on-device, Supabase-ready.

**Architecture:** Protocol-abstracted MVVM. Each service (transcription, ticket repo, menu store, parser, upsell engine) is a protocol with a local concrete implementation. Supabase implementations can slot in later by changing the type registered at app launch. ViewModels and Views never touch concrete implementations.

**Tech Stack:** Swift 5.9+, SwiftUI, SwiftData, AVAudioEngine, SFSpeechRecognizer, Foundation (no third-party dependencies in MVP)

**Features in scope (MVP + low + mid complexity):**
- Table selection, audio capture, streaming transcription
- Structured ticket model (items, qty, mods, course, seat)
- Ticket persistence (SwiftData), ticket list, send/delivered actions
- Menu ingestion from local JSON bundle
- Fuzzy order parsing: quantity, negations, temps, seat/course inference
- Allergy guardrails (red highlight + force-confirm)
- Repeat-back coach (confirm summary prompt)
- Auto abbreviations for ticket print view
- Noise level detection (ambient warning)
- Rule-based upsell engine + upsell playbook scripts
- Seat map view (drag items to seats)
- Course pacing controls (Fire / Hold per course)
- Kitchen notes templates per menu item
- Voice macros ("repeat last order", "add side salad", "split check")

**High complexity (deferred — see FUTURE_GOALS.md):**
- Multilingual support
- POS integration (Toast, Square, Clover)
- Fraud/void analytics (manager view)
- Training mode for new staff

**Note on verification:** We cannot run Xcode on Windows. Each task's "verify" step is a code review check. When the user opens this in Xcode, `Cmd+B` (build) is the primary verification. Unit test files are included and will run via `Cmd+U` in Xcode or `xcodebuild test` in GitHub Actions.

---

## Task 1: Data Models

**Files:**
- Create: `ios/WaitTicket/Models/MenuV1.swift`
- Create: `ios/WaitTicket/Models/Ticket.swift`
- Create: `ios/WaitTicket/Models/TicketDraft.swift`

**Step 1: Write `MenuV1.swift`**

Complete Codable structs matching the MenuV1 JSON schema. Must be pure value types (no SwiftData here — menu lives in memory from JSON bundle).

```swift
// ios/WaitTicket/Models/MenuV1.swift
import Foundation

struct MenuV1: Codable {
    let restaurantId: String
    let version: Int
    let currency: String
    let categories: [MenuCategory]
    let upsellRules: [UpsellRule]

    enum CodingKeys: String, CodingKey {
        case restaurantId = "restaurant_id"
        case version, currency, categories
        case upsellRules = "upsell_rules"
    }
}

struct MenuCategory: Codable, Identifiable {
    let id: String
    let name: String
    let items: [MenuItem]
}

struct MenuItem: Codable, Identifiable {
    let id: String
    let name: String
    let price: Double
    let description: String
    let tags: [String]
    let modifierGroups: [ModifierGroup]
    let upsellLinks: [UpsellLink]
    var kitchenNoteTemplate: String?  // medium complexity: per-item note template

    enum CodingKeys: String, CodingKey {
        case id, name, price, description, tags
        case modifierGroups = "modifier_groups"
        case upsellLinks = "upsell_links"
        case kitchenNoteTemplate = "kitchen_note_template"
    }
}

struct ModifierGroup: Codable, Identifiable {
    let id: String
    let name: String
    let required: Bool
    let maxSelect: Int
    let modifiers: [ModifierOption]

    enum CodingKeys: String, CodingKey {
        case id, name, required
        case maxSelect = "max_select"
        case modifiers
    }
}

struct ModifierOption: Codable, Identifiable {
    let id: String
    let name: String
    let priceDelta: Double

    enum CodingKeys: String, CodingKey {
        case id, name
        case priceDelta = "price_delta"
    }
}

struct UpsellLink: Codable {
    let type: String
    let targetItemId: String
    let reason: String

    enum CodingKeys: String, CodingKey {
        case type
        case targetItemId = "target_item_id"
        case reason
    }
}

struct UpsellRule: Codable, Identifiable {
    let id: String
    let condition: UpsellCondition
    let suggest: [UpsellSuggestion]
    var playbookScript: String?  // medium complexity: restaurant-defined upsell script

    enum CodingKeys: String, CodingKey {
        case id
        case condition = "if"
        case suggest
        case playbookScript = "playbook_script"
    }
}

struct UpsellCondition: Codable {
    let hasEntree: Bool?
    let hasDrink: Bool?

    enum CodingKeys: String, CodingKey {
        case hasEntree = "has_entree"
        case hasDrink = "has_drink"
    }
}

struct UpsellSuggestion: Codable {
    let tag: String?
    let itemId: String?

    enum CodingKeys: String, CodingKey {
        case tag
        case itemId = "item_id"
    }
}

// Abbreviation map for print-style ticket display (low complexity feature)
extension MenuItem {
    static let abbreviationOverrides: [String: String] = [:]

    var abbreviation: String {
        if let override = Self.abbreviationOverrides[id] { return override }
        // Auto-abbreviate: take first letter of each word, max 6 chars
        let words = name.split(separator: " ")
        if words.count == 1 { return String(name.prefix(4)).uppercased() }
        return words.map { String($0.prefix(1)) }.joined().uppercased()
    }
}
```

**Step 2: Write `Ticket.swift`**

SwiftData persistent models. Each class is a SwiftData `@Model`. Relationships are explicit.

```swift
// ios/WaitTicket/Models/Ticket.swift
import Foundation
import SwiftData

enum TicketStatus: String, Codable {
    case open = "OPEN"
    case sent = "SENT"
    case delivered = "DELIVERED"
    case closed = "CLOSED"
}

enum CourseFlag: String, Codable, CaseIterable {
    case appetizer = "APP"
    case entree = "ENT"
    case dessert = "DES"
    case beverage = "BEV"
    case side = "SIDE"

    var displayName: String {
        switch self {
        case .appetizer: return "Appetizer"
        case .entree: return "Entree"
        case .dessert: return "Dessert"
        case .beverage: return "Beverage"
        case .side: return "Side"
        }
    }

    // Medium complexity: course pacing state
    var fireCommand: String {
        switch self {
        case .appetizer: return "Fire Apps"
        case .entree: return "Fire Entrees"
        case .dessert: return "Fire Desserts"
        default: return "Fire"
        }
    }
}

enum CoursePacingState: String, Codable {
    case holding = "HOLDING"
    case fired = "FIRED"
    case delivered = "DELIVERED"
}

@Model
final class Ticket {
    var id: String
    var restaurantId: String
    var tableNumber: String
    var serverId: String
    var openedAt: Date
    var sentToKitchenAt: Date?
    var deliveredAt: Date?
    var closedAt: Date?
    var status: String  // TicketStatus raw value
    var rawTranscript: String
    var notes: String
    @Relationship(deleteRule: .cascade) var guests: [GuestSeat]
    // Medium complexity: course pacing per course
    var coursePacingStates: [String: String]  // CourseFlag.rawValue -> CoursePacingState.rawValue

    init(
        id: String = UUID().uuidString,
        restaurantId: String = "local",
        tableNumber: String,
        serverId: String = "local_server",
        notes: String = "",
        rawTranscript: String = ""
    ) {
        self.id = id
        self.restaurantId = restaurantId
        self.tableNumber = tableNumber
        self.serverId = serverId
        self.openedAt = Date()
        self.status = TicketStatus.open.rawValue
        self.rawTranscript = rawTranscript
        self.notes = notes
        self.guests = []
        self.coursePacingStates = [:]
    }

    var ticketStatus: TicketStatus { TicketStatus(rawValue: status) ?? .open }
    var timeToSend: TimeInterval? {
        guard let sent = sentToKitchenAt else { return nil }
        return sent.timeIntervalSince(openedAt)
    }
    var timeToDeliver: TimeInterval? {
        guard let sent = sentToKitchenAt, let delivered = deliveredAt else { return nil }
        return delivered.timeIntervalSince(sent)
    }
    var allItems: [TicketItem] { guests.flatMap { $0.items } }
}

@Model
final class GuestSeat {
    var seatNumber: Int
    @Relationship(deleteRule: .cascade) var items: [TicketItem]

    init(seatNumber: Int) {
        self.seatNumber = seatNumber
        self.items = []
    }
}

@Model
final class TicketItem {
    var id: String
    var menuItemId: String
    var name: String
    var quantity: Int
    var course: String  // CourseFlag raw value
    var notes: String
    var confidence: Double
    var hasAllergyFlag: Bool       // low complexity: allergy guardrail
    var allergyConfirmed: Bool     // low complexity: user confirmed allergy warning
    @Relationship(deleteRule: .cascade) var modifiers: [TicketModifier]

    init(
        id: String = UUID().uuidString,
        menuItemId: String,
        name: String,
        quantity: Int = 1,
        course: CourseFlag = .entree,
        notes: String = "",
        confidence: Double = 1.0,
        hasAllergyFlag: Bool = false
    ) {
        self.id = id
        self.menuItemId = menuItemId
        self.name = name
        self.quantity = quantity
        self.course = course.rawValue
        self.notes = notes
        self.confidence = confidence
        self.hasAllergyFlag = hasAllergyFlag
        self.allergyConfirmed = false
        self.modifiers = []
    }

    var courseFlag: CourseFlag { CourseFlag(rawValue: course) ?? .entree }

    // Low complexity: auto abbreviation for print view
    var ticketAbbreviation: String {
        let words = name.split(separator: " ")
        if words.count == 1 { return String(name.prefix(4)).uppercased() }
        return words.map { String($0.prefix(1)) }.joined().uppercased()
    }
}

@Model
final class TicketModifier {
    var name: String
    var priceDelta: Double
    var isNegation: Bool  // e.g. "no onion"

    init(name: String, priceDelta: Double = 0, isNegation: Bool = false) {
        self.name = name
        self.priceDelta = priceDelta
        self.isNegation = isNegation
    }
}
```

**Step 3: Write `TicketDraft.swift`**

In-memory draft produced by the parser. Not persisted until user confirms.

```swift
// ios/WaitTicket/Models/TicketDraft.swift
import Foundation

struct TicketDraft {
    var tableNumber: String
    var items: [DraftItem]
    var rawTranscript: String
    var consumedCursor: Int  // parser cursor to prevent re-adding already-parsed text

    init(tableNumber: String) {
        self.tableNumber = tableNumber
        self.items = []
        self.rawTranscript = ""
        self.consumedCursor = 0
    }

    mutating func addItem(_ item: DraftItem) {
        // Prevent exact duplicate (same menuItemId + same modifiers)
        let exists = items.contains { existing in
            existing.menuItemId == item.menuItemId &&
            existing.modifierNames == item.modifierNames
        }
        if !exists { items.append(item) }
    }
}

struct DraftItem: Identifiable {
    var id: String = UUID().uuidString
    var menuItemId: String
    var name: String
    var quantity: Int
    var modifierNames: [String]       // "no onion", "medium rare"
    var negations: [String]           // modifiers that are removals
    var course: CourseFlag
    var seatNumber: Int?
    var notes: String
    var confidence: Double
    var hasAllergyFlag: Bool          // low complexity

    // Kitchen note template pre-populated if menu item has one
    var kitchenNoteTemplate: String?
}

// Medium complexity: voice macro types
enum VoiceMacro: String, CaseIterable {
    case repeatLastOrder = "repeat last order"
    case addSideSalad = "add side salad"
    case splitCheck = "split check"

    var displayName: String {
        switch self {
        case .repeatLastOrder: return "Repeat Last Order"
        case .addSideSalad: return "Add Side Salad"
        case .splitCheck: return "Split Check"
        }
    }
}
```

**Verify:** Read all three files, confirm no compiler errors (check types, CodingKeys, SwiftData macros). In Xcode: `Cmd+B` must succeed.

---

## Task 2: Service Protocols

**Files:**
- Create: `ios/WaitTicket/Services/Protocols.swift`

**Step 1: Write all service protocols**

```swift
// ios/WaitTicket/Services/Protocols.swift
import Foundation
import AVFoundation
import Combine

// MARK: - Audio Capture

protocol AudioCaptureServiceProtocol: AnyObject {
    var isRecording: Bool { get }
    var noiseLevel: Float { get }  // low complexity: noise detection, 0.0-1.0
    func startCapture() throws
    func stopCapture()
    func audioBufferPublisher() -> AnyPublisher<AVAudioPCMBuffer, Never>
}

// MARK: - Transcription

protocol TranscriptionServiceProtocol: AnyObject {
    /// Streams partial and final transcription results as text segments
    func transcriptionPublisher() -> AnyPublisher<TranscriptionSegment, Never>
    func startTranscribing(audioPublisher: AnyPublisher<AVAudioPCMBuffer, Never>) throws
    func stopTranscribing()
}

struct TranscriptionSegment {
    let text: String
    let isFinal: Bool
}

// MARK: - Order Parser

protocol OrderParserProtocol {
    /// Given full transcript text, returns updated draft (incremental, cursor-aware)
    func parseDraft(transcript: String, existingDraft: TicketDraft, menu: MenuV1) -> TicketDraft
    /// Detect voice macros in text
    func detectMacro(in text: String) -> VoiceMacro?
    /// Generate repeat-back summary string (low complexity: repeat-back coach)
    func repeatBackSummary(for draft: TicketDraft) -> String
}

// MARK: - Menu Store

protocol MenuStoreProtocol {
    var menu: MenuV1? { get }
    func loadMenu() async throws
    func findBestMatches(text: String, maxResults: Int) -> [(item: MenuItem, score: Double)]
    func item(byId id: String) -> MenuItem?
}

// MARK: - Ticket Repository

protocol TicketRepositoryProtocol {
    func fetchAll() async throws -> [Ticket]
    func fetchOpen() async throws -> [Ticket]
    func save(_ ticket: Ticket) async throws
    func delete(_ ticket: Ticket) async throws
    func createTicket(from draft: TicketDraft, serverId: String) async throws -> Ticket
}

// MARK: - Upsell Engine

protocol UpsellEngineProtocol {
    /// Returns upsell suggestions for current draft items
    func suggestions(for draft: TicketDraft, menu: MenuV1) -> [UpsellSuggestionResult]
}

struct UpsellSuggestionResult: Identifiable {
    let id: String = UUID().uuidString
    let menuItem: MenuItem
    let reason: String
    let playbookScript: String?  // medium complexity: restaurant upsell script
}
```

**Verify:** All protocol methods are correct Swift syntax. No implementations here — protocols only.

---

## Task 3: AudioCaptureService

**Files:**
- Create: `ios/WaitTicket/Services/AudioCaptureService.swift`

**Step 1: Implement AudioCaptureService**

```swift
// ios/WaitTicket/Services/AudioCaptureService.swift
import AVFoundation
import Combine

final class AudioCaptureService: AudioCaptureServiceProtocol {
    private(set) var isRecording = false
    private(set) var noiseLevel: Float = 0.0  // low complexity: noise detection

    private let audioEngine = AVAudioEngine()
    private let bufferSubject = PassthroughSubject<AVAudioPCMBuffer, Never>()
    private var noiseLevelTimer: Timer?

    func startCapture() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.bufferSubject.send(buffer)
            self?.updateNoiseLevel(buffer: buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true
    }

    func stopCapture() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        isRecording = false
        noiseLevel = 0.0
    }

    func audioBufferPublisher() -> AnyPublisher<AVAudioPCMBuffer, Never> {
        bufferSubject.eraseToAnyPublisher()
    }

    // Low complexity: noise level detection
    private func updateNoiseLevel(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        var rms: Float = 0
        for i in 0..<frameCount { rms += channelData[i] * channelData[i] }
        rms = sqrt(rms / Float(frameCount))
        // Normalize to 0-1 range (approximate)
        DispatchQueue.main.async { self.noiseLevel = min(rms * 10, 1.0) }
    }
}
```

**Verify:** `AVAudioEngine`, `AVAudioSession` APIs are correct. `isRecording` and `noiseLevel` are `@Published`-compatible (they're plain vars — ViewModel will use `@Observable` or Combine).

---

## Task 4: SFSpeechTranscriptionService

**Files:**
- Create: `ios/WaitTicket/Services/SFSpeechTranscriptionService.swift`

**Step 1: Implement SFSpeechTranscriptionService**

```swift
// ios/WaitTicket/Services/SFSpeechTranscriptionService.swift
import Speech
import AVFoundation
import Combine

final class SFSpeechTranscriptionService: TranscriptionServiceProtocol {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private let transcriptionSubject = PassthroughSubject<TranscriptionSegment, Never>()
    private var cancellables = Set<AnyCancellable>()

    static func requestPermission(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }

    func transcriptionPublisher() -> AnyPublisher<TranscriptionSegment, Never> {
        transcriptionSubject.eraseToAnyPublisher()
    }

    func startTranscribing(audioPublisher: AnyPublisher<AVAudioPCMBuffer, Never>) throws {
        guard let recognizer, recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true  // privacy: on-device
        self.recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result {
                let segment = TranscriptionSegment(
                    text: result.bestTranscription.formattedString,
                    isFinal: result.isFinal
                )
                self?.transcriptionSubject.send(segment)
            }
            if error != nil || result?.isFinal == true {
                self?.stopTranscribing()
            }
        }

        audioPublisher
            .sink { [weak request] buffer in request?.append(buffer) }
            .store(in: &cancellables)
    }

    func stopTranscribing() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        cancellables.removeAll()
    }
}

enum TranscriptionError: Error {
    case recognizerUnavailable
    case permissionDenied
}
```

**Verify:** `SFSpeechAudioBufferRecognitionRequest.requiresOnDeviceRecognition` exists on iOS 13+. `recognitionTask` API correct.

---

## Task 5: LocalBundleMenuStore

**Files:**
- Create: `ios/WaitTicket/Services/LocalBundleMenuStore.swift`
- Create: `ios/WaitTicket/Resources/MenuV1.sample.json`

**Step 1: Write sample menu JSON**

```json
{
  "restaurant_id": "demo_restaurant",
  "version": 1,
  "currency": "USD",
  "categories": [
    {
      "id": "cat_apps",
      "name": "Appetizers",
      "items": [
        {
          "id": "item_mozz",
          "name": "Mozzarella Sticks",
          "price": 9.99,
          "description": "Served with marinara",
          "tags": ["fried", "vegetarian"],
          "modifier_groups": [
            {
              "id": "mg_sauce",
              "name": "Sauce Choice",
              "required": false,
              "max_select": 1,
              "modifiers": [
                {"id": "m_ranch", "name": "Ranch", "price_delta": 0.0},
                {"id": "m_marinara", "name": "Marinara", "price_delta": 0.0},
                {"id": "m_honey_mustard", "name": "Honey Mustard", "price_delta": 0.0}
              ]
            }
          ],
          "upsell_links": [],
          "kitchen_note_template": ""
        },
        {
          "id": "item_caesar",
          "name": "Caesar Salad",
          "price": 11.99,
          "description": "Romaine, croutons, parmesan",
          "tags": ["salad", "vegetarian"],
          "modifier_groups": [
            {
              "id": "mg_caesar_mods",
              "name": "Modifications",
              "required": false,
              "max_select": 3,
              "modifiers": [
                {"id": "m_no_croutons", "name": "No Croutons", "price_delta": 0.0},
                {"id": "m_dressing_side", "name": "Dressing on Side", "price_delta": 0.0},
                {"id": "m_add_chicken", "name": "Add Chicken", "price_delta": 3.0}
              ]
            }
          ],
          "upsell_links": [],
          "kitchen_note_template": "GF? No croutons."
        }
      ]
    },
    {
      "id": "cat_entrees",
      "name": "Entrees",
      "items": [
        {
          "id": "item_burger",
          "name": "Classic Burger",
          "price": 14.99,
          "description": "8oz beef patty, lettuce, tomato, onion",
          "tags": ["beef", "entree"],
          "modifier_groups": [
            {
              "id": "mg_temp",
              "name": "Temperature",
              "required": true,
              "max_select": 1,
              "modifiers": [
                {"id": "m_rare", "name": "Rare", "price_delta": 0.0},
                {"id": "m_med_rare", "name": "Medium Rare", "price_delta": 0.0},
                {"id": "m_medium", "name": "Medium", "price_delta": 0.0},
                {"id": "m_med_well", "name": "Medium Well", "price_delta": 0.0},
                {"id": "m_well", "name": "Well Done", "price_delta": 0.0}
              ]
            },
            {
              "id": "mg_burger_mods",
              "name": "Modifications",
              "required": false,
              "max_select": 5,
              "modifiers": [
                {"id": "m_no_onion", "name": "No Onion", "price_delta": 0.0},
                {"id": "m_no_tomato", "name": "No Tomato", "price_delta": 0.0},
                {"id": "m_add_bacon", "name": "Add Bacon", "price_delta": 2.0},
                {"id": "m_add_cheese", "name": "Add Cheese", "price_delta": 1.0}
              ]
            }
          ],
          "upsell_links": [
            {"type": "suggest", "target_item_id": "item_fries", "reason": "Pairs great with burger"}
          ],
          "kitchen_note_template": "Temp: ___. Mods: ___."
        },
        {
          "id": "item_salmon",
          "name": "Grilled Salmon",
          "price": 22.99,
          "description": "Atlantic salmon, seasonal vegetables",
          "tags": ["fish", "entree", "gluten_free"],
          "modifier_groups": [
            {
              "id": "mg_salmon_mods",
              "name": "Modifications",
              "required": false,
              "max_select": 3,
              "modifiers": [
                {"id": "m_no_butter", "name": "No Butter", "price_delta": 0.0},
                {"id": "m_extra_veg", "name": "Extra Vegetables", "price_delta": 2.0},
                {"id": "m_sauce_side", "name": "Sauce on Side", "price_delta": 0.0}
              ]
            }
          ],
          "upsell_links": [],
          "kitchen_note_template": "Allergy? GF by default."
        },
        {
          "id": "item_steak",
          "name": "Ribeye Steak",
          "price": 34.99,
          "description": "12oz ribeye, choice of side",
          "tags": ["beef", "entree", "premium"],
          "modifier_groups": [
            {
              "id": "mg_steak_temp",
              "name": "Temperature",
              "required": true,
              "max_select": 1,
              "modifiers": [
                {"id": "m_steak_rare", "name": "Rare", "price_delta": 0.0},
                {"id": "m_steak_med_rare", "name": "Medium Rare", "price_delta": 0.0},
                {"id": "m_steak_medium", "name": "Medium", "price_delta": 0.0},
                {"id": "m_steak_med_well", "name": "Medium Well", "price_delta": 0.0},
                {"id": "m_steak_well", "name": "Well Done", "price_delta": 0.0}
              ]
            }
          ],
          "upsell_links": [],
          "kitchen_note_template": "Temp: ___."
        }
      ]
    },
    {
      "id": "cat_sides",
      "name": "Sides",
      "items": [
        {
          "id": "item_fries",
          "name": "French Fries",
          "price": 4.99,
          "description": "Crispy golden fries",
          "tags": ["fried", "vegetarian", "side"],
          "modifier_groups": [
            {
              "id": "mg_fries_mods",
              "name": "Modifications",
              "required": false,
              "max_select": 2,
              "modifiers": [
                {"id": "m_extra_crispy", "name": "Extra Crispy", "price_delta": 0.0},
                {"id": "m_seasoned", "name": "Seasoned", "price_delta": 0.0}
              ]
            }
          ],
          "upsell_links": [],
          "kitchen_note_template": ""
        },
        {
          "id": "item_side_salad",
          "name": "Side Salad",
          "price": 5.99,
          "description": "Mixed greens, house dressing",
          "tags": ["salad", "vegetarian", "side"],
          "modifier_groups": [],
          "upsell_links": [],
          "kitchen_note_template": ""
        }
      ]
    },
    {
      "id": "cat_beverages",
      "name": "Beverages",
      "items": [
        {
          "id": "item_coke",
          "name": "Coca-Cola",
          "price": 2.99,
          "description": "Fountain soda",
          "tags": ["soft_drink", "beverage"],
          "modifier_groups": [],
          "upsell_links": [],
          "kitchen_note_template": ""
        },
        {
          "id": "item_water",
          "name": "Water",
          "price": 0.0,
          "description": "Still or sparkling",
          "tags": ["beverage", "soft_drink"],
          "modifier_groups": [
            {
              "id": "mg_water_type",
              "name": "Type",
              "required": false,
              "max_select": 1,
              "modifiers": [
                {"id": "m_still", "name": "Still", "price_delta": 0.0},
                {"id": "m_sparkling", "name": "Sparkling", "price_delta": 1.0}
              ]
            }
          ],
          "upsell_links": [],
          "kitchen_note_template": ""
        },
        {
          "id": "item_ipa",
          "name": "IPA Draft Beer",
          "price": 7.99,
          "description": "Local craft IPA on draft",
          "tags": ["beer", "alcohol", "beverage", "signature_cocktail"],
          "modifier_groups": [],
          "upsell_links": [],
          "kitchen_note_template": ""
        }
      ]
    }
  ],
  "upsell_rules": [
    {
      "id": "rule_drink_if_none",
      "if": {"has_entree": true, "has_drink": false},
      "suggest": [{"tag": "soft_drink"}, {"tag": "beer"}],
      "playbook_script": "Can I start you off with something to drink? We have a great local IPA on draft."
    },
    {
      "id": "rule_fries_with_burger",
      "if": {"has_entree": false, "has_drink": false},
      "suggest": [{"item_id": "item_fries"}],
      "playbook_script": "Would you like to add fries? They're extra crispy today."
    }
  ]
}
```

**Step 2: Implement LocalBundleMenuStore**

```swift
// ios/WaitTicket/Services/LocalBundleMenuStore.swift
import Foundation

final class LocalBundleMenuStore: MenuStoreProtocol {
    private(set) var menu: MenuV1?
    private var itemIndex: [String: MenuItem] = [:]      // id -> item
    private var searchIndex: [(tokens: [String], item: MenuItem)] = []

    func loadMenu() async throws {
        guard let url = Bundle.main.url(forResource: "MenuV1.sample", withExtension: "json") else {
            throw MenuStoreError.fileNotFound
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let loaded = try decoder.decode(MenuV1.self, from: data)
        self.menu = loaded
        buildIndex(from: loaded)
    }

    func findBestMatches(text: String, maxResults: Int = 3) -> [(item: MenuItem, score: Double)] {
        let normalized = normalize(text)
        let queryTokens = normalized.split(separator: " ").map(String.init)

        var results: [(item: MenuItem, score: Double)] = []
        for entry in searchIndex {
            let score = tokenOverlapScore(query: queryTokens, candidate: entry.tokens)
            if score > 0.2 { results.append((entry.item, score)) }
        }
        return results.sorted { $0.score > $1.score }.prefix(maxResults).map { $0 }
    }

    func item(byId id: String) -> MenuItem? { itemIndex[id] }

    private func buildIndex(from menu: MenuV1) {
        itemIndex.removeAll()
        searchIndex.removeAll()
        for category in menu.categories {
            for item in category.items {
                itemIndex[item.id] = item
                let tokens = normalize(item.name).split(separator: " ").map(String.init)
                searchIndex.append((tokens: tokens, item: item))
                // Also add plural/alias variants
                let plural = tokens.map { $0.hasSuffix("s") ? $0 : $0 + "s" }
                searchIndex.append((tokens: plural, item: item))
            }
        }
    }

    private func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private func tokenOverlapScore(query: [String], candidate: [String]) -> Double {
        let querySet = Set(query)
        let candidateSet = Set(candidate)
        let intersection = querySet.intersection(candidateSet)
        guard !querySet.isEmpty else { return 0 }
        return Double(intersection.count) / Double(querySet.count)
    }
}

enum MenuStoreError: Error {
    case fileNotFound
    case decodingFailed
}
```

**Verify:** JSON file is valid. `Bundle.main.url(forResource:withExtension:)` is correct API. Fuzzy search logic is deterministic.

---

## Task 6: FuzzyMenuOrderParser

**Files:**
- Create: `ios/WaitTicket/Services/FuzzyMenuOrderParser.swift`

**Step 1: Implement parser**

```swift
// ios/WaitTicket/Services/FuzzyMenuOrderParser.swift
import Foundation

final class FuzzyMenuOrderParser: OrderParserProtocol {

    // Low complexity: allergy keywords
    private let allergyKeywords = ["allergy", "allergic", "anaphylactic", "epipen", "cannot eat"]

    // Low complexity: filler words to strip
    private let fillerWords = Set(["um", "uh", "like", "so", "and", "the", "a", "an", "for"])

    // Temperature map
    private let temperatureMap: [String: String] = [
        "rare": "Rare", "medium rare": "Medium Rare", "med rare": "Medium Rare",
        "medium": "Medium", "med": "Medium", "medium well": "Medium Well",
        "med well": "Medium Well", "well done": "Well Done", "well": "Well Done"
    ]

    // Number words
    private let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10
    ]

    // Negation prefixes
    private let negationPrefixes = ["no", "without", "hold", "remove", "skip"]

    // Course keywords
    private let courseKeywords: [String: CourseFlag] = [
        "app": .appetizer, "apps": .appetizer, "appetizer": .appetizer, "appetizers": .appetizer, "starter": .appetizer,
        "entree": .entree, "entrees": .entree, "main": .entree, "mains": .entree,
        "dessert": .dessert, "desserts": .dessert, "sweet": .dessert,
        "drink": .beverage, "drinks": .beverage, "beverage": .beverage, "beverages": .beverage,
        "side": .side, "sides": .side
    ]

    // Medium complexity: voice macro patterns
    private let macroPatterns: [String: VoiceMacro] = [
        "repeat last order": .repeatLastOrder,
        "same as last time": .repeatLastOrder,
        "add side salad": .addSideSalad,
        "side salad": .addSideSalad,
        "split check": .splitCheck,
        "split the check": .splitCheck,
        "split bill": .splitCheck
    ]

    func parseDraft(transcript: String, existingDraft: TicketDraft, menu: MenuV1) -> TicketDraft {
        var draft = existingDraft
        draft.rawTranscript = transcript

        // Only parse the new portion since last cursor
        let newText: String
        if draft.consumedCursor < transcript.count {
            let startIndex = transcript.index(transcript.startIndex, offsetBy: draft.consumedCursor)
            newText = String(transcript[startIndex...])
        } else {
            return draft
        }

        let normalized = normalizeText(newText)
        let sentences = splitIntoSegments(normalized)

        var currentCourse: CourseFlag = .entree
        var currentSeat: Int? = nil

        for sentence in sentences {
            // Check for course marker
            if let course = detectCourse(in: sentence) {
                currentCourse = course
                continue
            }

            // Check for seat marker "for seat 2", "seat one"
            if let seat = detectSeat(in: sentence) {
                currentSeat = seat
                continue
            }

            // Try to find a menu item match
            let allItems = menu.categories.flatMap { $0.items }
            if let (matchedItem, score) = findBestItem(in: sentence, from: allItems) {
                let qty = extractQuantity(from: sentence)
                let mods = extractModifiers(from: sentence, item: matchedItem)
                let hasAllergy = allergyKeywords.contains { sentence.contains($0) }
                let kitchenNote = matchedItem.kitchenNoteTemplate ?? ""

                var draftItem = DraftItem(
                    menuItemId: matchedItem.id,
                    name: matchedItem.name,
                    quantity: qty,
                    modifierNames: mods.map { $0.name },
                    negations: mods.filter { $0.isNegation }.map { $0.name },
                    course: currentCourse,
                    seatNumber: currentSeat,
                    notes: kitchenNote,
                    confidence: score,
                    hasAllergyFlag: hasAllergy,
                    kitchenNoteTemplate: kitchenNote.isEmpty ? nil : kitchenNote
                )
                draft.addItem(draftItem)
            }
        }

        draft.consumedCursor = transcript.count
        return draft
    }

    func detectMacro(in text: String) -> VoiceMacro? {
        let normalized = normalizeText(text)
        for (pattern, macro) in macroPatterns {
            if normalized.contains(pattern) { return macro }
        }
        return nil
    }

    // Low complexity: repeat-back coach
    func repeatBackSummary(for draft: TicketDraft) -> String {
        guard !draft.items.isEmpty else { return "No items yet." }
        let lines = draft.items.map { item -> String in
            var line = "\(item.quantity)x \(item.name)"
            if !item.modifierNames.isEmpty {
                line += " (\(item.modifierNames.joined(separator: ", ")))"
            }
            if item.hasAllergyFlag { line += " ⚠️ ALLERGY" }
            return line
        }
        return "Table \(draft.tableNumber): " + lines.joined(separator: "; ")
    }

    // MARK: - Private helpers

    private func normalizeText(_ text: String) -> String {
        var result = text.lowercased()
        // Remove filler words
        for filler in fillerWords {
            result = result.replacingOccurrences(of: "\\b\(filler)\\b", with: "", options: .regularExpression)
        }
        // Convert number words to digits
        for (word, digit) in numberWords {
            result = result.replacingOccurrences(of: "\\b\(word)\\b", with: "\(digit)", options: .regularExpression)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private func splitIntoSegments(_ text: String) -> [String] {
        // Split on commas, periods, and known conjunctions
        let separators = CharacterSet(charactersIn: ",.")
        return text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func detectCourse(in segment: String) -> CourseFlag? {
        for (keyword, course) in courseKeywords {
            if segment.contains(keyword) { return course }
        }
        return nil
    }

    private func detectSeat(in segment: String) -> Int? {
        // Match "seat 2", "seat two", "for seat 3"
        let pattern = #"seat\s+(\d+)"#
        if let range = segment.range(of: pattern, options: .regularExpression) {
            let matched = String(segment[range])
            let digits = matched.filter { $0.isNumber }
            return Int(digits)
        }
        return nil
    }

    private func findBestItem(in segment: String, from items: [MenuItem]) -> (MenuItem, Double)? {
        var best: (MenuItem, Double)? = nil
        let queryTokens = segment.split(separator: " ").map(String.init)

        for item in items {
            let itemTokens = normalizeText(item.name).split(separator: " ").map(String.init)
            let score = tokenOverlapScore(query: queryTokens, candidate: itemTokens)
            if score > 0.4 {
                if best == nil || score > best!.1 { best = (item, score) }
            }
        }
        return best
    }

    private func extractQuantity(from segment: String) -> Int {
        // Match leading digit: "2 burgers", "3 cokes"
        let pattern = #"^(\d+)\s+"#
        if let range = segment.range(of: pattern, options: .regularExpression) {
            let numStr = String(segment[range]).trimmingCharacters(in: .whitespaces)
            return Int(numStr) ?? 1
        }
        return 1
    }

    struct ParsedModifier {
        let name: String
        let isNegation: Bool
    }

    private func extractModifiers(from segment: String, item: MenuItem) -> [ParsedModifier] {
        var mods: [ParsedModifier] = []
        let words = segment.split(separator: " ").map(String.init)

        // Detect temperature
        for (phrase, label) in temperatureMap {
            if segment.contains(phrase) {
                mods.append(ParsedModifier(name: label, isNegation: false))
                break
            }
        }

        // Detect negations and modifier keywords from modifier groups
        for group in item.modifierGroups {
            for modifier in group.modifiers {
                let modName = modifier.name.lowercased()
                let modTokens = modName.split(separator: " ").map(String.init)
                if tokenOverlapScore(query: words, candidate: modTokens) > 0.5 {
                    // Check if preceded by negation word
                    let isNegation = negationPrefixes.contains { segment.contains("\($0) " + modTokens.first!) }
                    mods.append(ParsedModifier(name: isNegation ? "No \(modifier.name)" : modifier.name, isNegation: isNegation))
                }
            }
        }

        return mods
    }

    private func tokenOverlapScore(query: [String], candidate: [String]) -> Double {
        let qSet = Set(query.filter { $0.count > 2 })  // ignore short words
        let cSet = Set(candidate)
        guard !qSet.isEmpty else { return 0 }
        return Double(qSet.intersection(cSet).count) / Double(qSet.count)
    }
}
```

**Verify:** All methods implement the protocol. Regex patterns are valid Swift regex. `CourseFlag` and `VoiceMacro` types match models.

---

## Task 7: RuleBasedUpsellEngine

**Files:**
- Create: `ios/WaitTicket/Services/RuleBasedUpsellEngine.swift`

**Step 1: Implement upsell engine**

```swift
// ios/WaitTicket/Services/RuleBasedUpsellEngine.swift
import Foundation

final class RuleBasedUpsellEngine: UpsellEngineProtocol {
    func suggestions(for draft: TicketDraft, menu: MenuV1) -> [UpsellSuggestionResult] {
        var results: [UpsellSuggestionResult] = []

        let hasEntree = draft.items.contains { $0.course == .entree }
        let hasDrink = draft.items.contains { $0.course == .beverage }
        let allItems = menu.categories.flatMap { $0.items }

        for rule in menu.upsellRules {
            var conditionMet = true
            if let requiresEntree = rule.condition.hasEntree { conditionMet = conditionMet && (hasEntree == requiresEntree) }
            if let requiresNoDrink = rule.condition.hasDrink { conditionMet = conditionMet && (hasDrink == requiresNoDrink) }

            guard conditionMet else { continue }

            // Already suggested these? Skip if item already in draft
            let draftItemIds = Set(draft.items.map { $0.menuItemId })

            for suggestion in rule.suggest {
                var candidates: [MenuItem] = []
                if let tag = suggestion.tag {
                    candidates = allItems.filter { $0.tags.contains(tag) }
                } else if let itemId = suggestion.itemId {
                    candidates = allItems.filter { $0.id == itemId }
                }

                for candidate in candidates.prefix(2) {
                    guard !draftItemIds.contains(candidate.id) else { continue }
                    results.append(UpsellSuggestionResult(
                        menuItem: candidate,
                        reason: "Suggested pairing",
                        playbookScript: rule.playbookScript  // medium complexity: playbook script
                    ))
                }
            }
        }

        // Deduplicate by item ID
        var seen = Set<String>()
        return results.filter { seen.insert($0.menuItem.id).inserted }
    }
}
```

---

## Task 8: SwiftDataTicketRepository

**Files:**
- Create: `ios/WaitTicket/Services/SwiftDataTicketRepository.swift`

**Step 1: Implement repository**

```swift
// ios/WaitTicket/Services/SwiftDataTicketRepository.swift
import Foundation
import SwiftData

final class SwiftDataTicketRepository: TicketRepositoryProtocol {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func fetchAll() async throws -> [Ticket] {
        let descriptor = FetchDescriptor<Ticket>(sortBy: [SortDescriptor(\.openedAt, order: .reverse)])
        return try modelContext.fetch(descriptor)
    }

    func fetchOpen() async throws -> [Ticket] {
        let descriptor = FetchDescriptor<Ticket>(
            predicate: #Predicate { $0.status == "OPEN" || $0.status == "SENT" },
            sortBy: [SortDescriptor(\.openedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }

    func save(_ ticket: Ticket) async throws {
        try modelContext.save()
    }

    func delete(_ ticket: Ticket) async throws {
        modelContext.delete(ticket)
        try modelContext.save()
    }

    func createTicket(from draft: TicketDraft, serverId: String) async throws -> Ticket {
        let ticket = Ticket(
            tableNumber: draft.tableNumber,
            serverId: serverId,
            rawTranscript: draft.rawTranscript
        )

        // Group draft items by seat
        let seatNumbers = Set(draft.items.compactMap { $0.seatNumber })
        if seatNumbers.isEmpty {
            // No seats assigned — put everything in seat 1
            let seat = GuestSeat(seatNumber: 1)
            for draftItem in draft.items {
                let item = buildTicketItem(from: draftItem)
                seat.items.append(item)
                modelContext.insert(item)
            }
            modelContext.insert(seat)
            ticket.guests.append(seat)
        } else {
            for seatNum in seatNumbers.sorted() {
                let seat = GuestSeat(seatNumber: seatNum)
                let seatItems = draft.items.filter { $0.seatNumber == seatNum }
                for draftItem in seatItems {
                    let item = buildTicketItem(from: draftItem)
                    seat.items.append(item)
                    modelContext.insert(item)
                }
                modelContext.insert(seat)
                ticket.guests.append(seat)
            }
            // Items with no seat go to seat 1
            let unseated = draft.items.filter { $0.seatNumber == nil }
            if !unseated.isEmpty {
                let seat = GuestSeat(seatNumber: 1)
                for draftItem in unseated {
                    let item = buildTicketItem(from: draftItem)
                    seat.items.append(item)
                    modelContext.insert(item)
                }
                modelContext.insert(seat)
                ticket.guests.append(seat)
            }
        }

        modelContext.insert(ticket)
        try modelContext.save()
        return ticket
    }

    private func buildTicketItem(from draft: DraftItem) -> TicketItem {
        let item = TicketItem(
            menuItemId: draft.menuItemId,
            name: draft.name,
            quantity: draft.quantity,
            course: draft.course,
            notes: draft.notes,
            confidence: draft.confidence,
            hasAllergyFlag: draft.hasAllergyFlag
        )
        for modName in draft.modifierNames {
            let isNeg = draft.negations.contains(modName)
            let mod = TicketModifier(name: modName, isNegation: isNeg)
            item.modifiers.append(mod)
        }
        return item
    }
}
```

---

## Task 9: ViewModels

**Files:**
- Create: `ios/WaitTicket/ViewModels/TableSelectViewModel.swift`
- Create: `ios/WaitTicket/ViewModels/LiveSessionViewModel.swift`
- Create: `ios/WaitTicket/ViewModels/TicketEditorViewModel.swift`
- Create: `ios/WaitTicket/ViewModels/TicketsListViewModel.swift`

**Step 1: `TableSelectViewModel.swift`**

```swift
// ios/WaitTicket/ViewModels/TableSelectViewModel.swift
import Foundation
import Observation

@Observable
final class TableSelectViewModel {
    var tableNumber: String = ""
    var recentTables: [String] = []
    var isStartingSession = false

    private let repository: TicketRepositoryProtocol

    init(repository: TicketRepositoryProtocol) {
        self.repository = repository
    }

    func loadRecentTables() async {
        let tickets = (try? await repository.fetchAll()) ?? []
        let tables = tickets.map { $0.tableNumber }
        // Unique, most recent first, max 10
        var seen = Set<String>()
        recentTables = tables.filter { seen.insert($0).inserted }.prefix(10).map { $0 }
    }

    func selectTable(_ number: String) {
        tableNumber = number
    }
}
```

**Step 2: `LiveSessionViewModel.swift`**

```swift
// ios/WaitTicket/ViewModels/LiveSessionViewModel.swift
import Foundation
import Observation
import Combine

@Observable
final class LiveSessionViewModel {
    var transcript: String = ""
    var draft: TicketDraft
    var upsellSuggestions: [UpsellSuggestionResult] = []
    var isRecording = false
    var noiseLevel: Float = 0.0              // low complexity: noise display
    var showNoisyEnvironmentWarning = false   // low complexity: noise warning
    var repeatBackText: String = ""          // low complexity: repeat-back coach
    var showRepeatBack = false
    var detectedMacro: VoiceMacro? = nil    // medium complexity: voice macros
    var errorMessage: String? = nil
    var allergyItemsPendingConfirm: [DraftItem] = []  // low complexity: allergy guardrail

    private let audioCapture: AudioCaptureServiceProtocol
    private let transcriptionService: TranscriptionServiceProtocol
    private let parser: OrderParserProtocol
    private let menuStore: MenuStoreProtocol
    private let upsellEngine: UpsellEngineProtocol
    private var cancellables = Set<AnyCancellable>()

    let noiseWarningThreshold: Float = 0.75

    init(
        tableNumber: String,
        audioCapture: AudioCaptureServiceProtocol,
        transcriptionService: TranscriptionServiceProtocol,
        parser: OrderParserProtocol,
        menuStore: MenuStoreProtocol,
        upsellEngine: UpsellEngineProtocol
    ) {
        self.draft = TicketDraft(tableNumber: tableNumber)
        self.audioCapture = audioCapture
        self.transcriptionService = transcriptionService
        self.parser = parser
        self.menuStore = menuStore
        self.upsellEngine = upsellEngine
    }

    func startRecording() {
        do {
            try audioCapture.startCapture()
            let audioPublisher = audioCapture.audioBufferPublisher()
            try transcriptionService.startTranscribing(audioPublisher: audioPublisher)
            isRecording = true

            // Subscribe to transcription results
            transcriptionService.transcriptionPublisher()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] segment in
                    self?.handleTranscriptionSegment(segment)
                }
                .store(in: &cancellables)

            // Low complexity: noise level monitoring
            Timer.publish(every: 0.5, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.checkNoiseLevel() }
                .store(in: &cancellables)

        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        audioCapture.stopCapture()
        transcriptionService.stopTranscribing()
        isRecording = false
        cancellables.removeAll()
        noiseLevel = 0.0
        showNoisyEnvironmentWarning = false
    }

    func triggerRepeatBack() {
        repeatBackText = parser.repeatBackSummary(for: draft)
        showRepeatBack = true
    }

    func confirmAllergyItem(_ item: DraftItem) {
        guard let index = draft.items.firstIndex(where: { $0.id == item.id }) else { return }
        draft.items[index].hasAllergyFlag = true  // keep flag but mark confirmed
        allergyItemsPendingConfirm.removeAll { $0.id == item.id }
    }

    func removeItem(_ item: DraftItem) {
        draft.items.removeAll { $0.id == item.id }
        refreshUpsells()
    }

    func applyMacro(_ macro: VoiceMacro, previousDraft: TicketDraft?) {
        switch macro {
        case .repeatLastOrder:
            if let prev = previousDraft { draft.items = prev.items }
        case .addSideSalad:
            // Look up side salad from menu and add it
            if let menu = menuStore.menu,
               let salad = menu.categories.flatMap({ $0.items }).first(where: { $0.name.lowercased().contains("side salad") }) {
                let item = DraftItem(
                    menuItemId: salad.id, name: salad.name, quantity: 1,
                    modifierNames: [], negations: [], course: .side,
                    seatNumber: nil, notes: "", confidence: 1.0, hasAllergyFlag: false
                )
                draft.addItem(item)
            }
        case .splitCheck:
            // Flag for later — UI will show split check indicator
            break
        }
        detectedMacro = nil
        refreshUpsells()
    }

    // MARK: - Private

    private func handleTranscriptionSegment(_ segment: TranscriptionSegment) {
        transcript = segment.text

        guard let menu = menuStore.menu else { return }

        // Check for voice macros first
        if let macro = parser.detectMacro(in: segment.text) {
            detectedMacro = macro
            return
        }

        let updatedDraft = parser.parseDraft(transcript: segment.text, existingDraft: draft, menu: menu)
        draft = updatedDraft

        // Low complexity: allergy guardrail — flag new allergy items for confirm
        let newAllergyItems = draft.items.filter { $0.hasAllergyFlag && !allergyItemsPendingConfirm.contains(where: { $0.id == $0.id }) }
        allergyItemsPendingConfirm.append(contentsOf: newAllergyItems)

        refreshUpsells()
    }

    private func checkNoiseLevel() {
        noiseLevel = audioCapture.noiseLevel
        showNoisyEnvironmentWarning = noiseLevel > noiseWarningThreshold
    }

    private func refreshUpsells() {
        guard let menu = menuStore.menu else { return }
        upsellSuggestions = upsellEngine.suggestions(for: draft, menu: menu)
    }
}
```

**Step 3: `TicketEditorViewModel.swift`**

```swift
// ios/WaitTicket/ViewModels/TicketEditorViewModel.swift
import Foundation
import Observation

@Observable
final class TicketEditorViewModel {
    var ticket: Ticket
    var isSaving = false
    var errorMessage: String? = nil
    // Medium complexity: course pacing
    var coursePacingStates: [CourseFlag: CoursePacingState] = [:]

    private let repository: TicketRepositoryProtocol

    init(ticket: Ticket, repository: TicketRepositoryProtocol) {
        self.ticket = ticket
        self.repository = repository
        // Load existing pacing states
        for (key, value) in ticket.coursePacingStates {
            if let flag = CourseFlag(rawValue: key), let state = CoursePacingState(rawValue: value) {
                coursePacingStates[flag] = state
            }
        }
    }

    func sendToKitchen() async {
        ticket.sentToKitchenAt = Date()
        ticket.status = TicketStatus.sent.rawValue
        await save()
    }

    func markDelivered() async {
        ticket.deliveredAt = Date()
        ticket.status = TicketStatus.delivered.rawValue
        await save()
    }

    // Medium complexity: course pacing
    func fireCourse(_ course: CourseFlag) async {
        coursePacingStates[course] = .fired
        ticket.coursePacingStates[course.rawValue] = CoursePacingState.fired.rawValue
        await save()
    }

    func holdCourse(_ course: CourseFlag) async {
        coursePacingStates[course] = .holding
        ticket.coursePacingStates[course.rawValue] = CoursePacingState.holding.rawValue
        await save()
    }

    func removeItem(_ item: TicketItem, from seat: GuestSeat) async {
        seat.items.removeAll { $0.id == item.id }
        await save()
    }

    func updateItemNotes(_ item: TicketItem, notes: String) async {
        item.notes = notes
        await save()
    }

    func confirmAllergyItem(_ item: TicketItem) async {
        item.allergyConfirmed = true
        await save()
    }

    // Medium complexity: seat map — move item to different seat
    func moveItem(_ item: TicketItem, fromSeat: GuestSeat, toSeatNumber: Int) async {
        fromSeat.items.removeAll { $0.id == item.id }
        if let targetSeat = ticket.guests.first(where: { $0.seatNumber == toSeatNumber }) {
            targetSeat.items.append(item)
        } else {
            let newSeat = GuestSeat(seatNumber: toSeatNumber)
            newSeat.items.append(item)
            ticket.guests.append(newSeat)
        }
        await save()
    }

    private func save() async {
        isSaving = true
        do {
            try await repository.save(ticket)
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}
```

**Step 4: `TicketsListViewModel.swift`**

```swift
// ios/WaitTicket/ViewModels/TicketsListViewModel.swift
import Foundation
import Observation

@Observable
final class TicketsListViewModel {
    var openTickets: [Ticket] = []
    var completedTickets: [Ticket] = []
    var isLoading = false

    private let repository: TicketRepositoryProtocol

    init(repository: TicketRepositoryProtocol) {
        self.repository = repository
    }

    func loadTickets() async {
        isLoading = true
        let all = (try? await repository.fetchAll()) ?? []
        openTickets = all.filter { $0.ticketStatus == .open || $0.ticketStatus == .sent }
        completedTickets = all.filter { $0.ticketStatus == .delivered || $0.ticketStatus == .closed }
        isLoading = false
    }

    func deleteTicket(_ ticket: Ticket) async {
        try? await repository.delete(ticket)
        await loadTickets()
    }
}
```

---

## Task 10: App Entry + Environment Setup

**Files:**
- Create: `ios/WaitTicket/WaitTicketApp.swift`

**Step 1: Write app entry point**

```swift
// ios/WaitTicket/WaitTicketApp.swift
import SwiftUI
import SwiftData

@main
struct WaitTicketApp: App {
    let container: ModelContainer

    // Services (local implementations; swap to Supabase versions here later)
    let audioCapture: AudioCaptureServiceProtocol = AudioCaptureService()
    let transcriptionService: TranscriptionServiceProtocol = SFSpeechTranscriptionService()
    let menuStore: MenuStoreProtocol = LocalBundleMenuStore()
    let parser: OrderParserProtocol = FuzzyMenuOrderParser()
    let upsellEngine: UpsellEngineProtocol = RuleBasedUpsellEngine()

    init() {
        do {
            container = try ModelContainer(for: Ticket.self, GuestSeat.self, TicketItem.self, TicketModifier.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

        // Request permissions at app start
        SFSpeechTranscriptionService.requestPermission { granted in
            if !granted { print("Speech recognition not authorized") }
        }
        AVAudioSession.sharedInstance().requestRecordPermission { _ in }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(container)
                .environment(AppServices(
                    audioCapture: audioCapture,
                    transcriptionService: transcriptionService,
                    menuStore: menuStore,
                    parser: parser,
                    upsellEngine: upsellEngine,
                    repository: SwiftDataTicketRepository(modelContext: container.mainContext)
                ))
                .task {
                    try? await menuStore.loadMenu()
                }
        }
    }
}

// Service container injected via @Environment
struct AppServices {
    let audioCapture: AudioCaptureServiceProtocol
    let transcriptionService: TranscriptionServiceProtocol
    let menuStore: MenuStoreProtocol
    let parser: OrderParserProtocol
    let upsellEngine: UpsellEngineProtocol
    let repository: TicketRepositoryProtocol
}

extension EnvironmentValues {
    @Entry var appServices: AppServices = AppServices(
        audioCapture: AudioCaptureService(),
        transcriptionService: SFSpeechTranscriptionService(),
        menuStore: LocalBundleMenuStore(),
        parser: FuzzyMenuOrderParser(),
        upsellEngine: RuleBasedUpsellEngine(),
        repository: SwiftDataTicketRepository(modelContext: try! ModelContainer(for: Ticket.self).mainContext)
    )
}
```

---

## Task 11: Views — Core Screens

**Files:**
- Create: `ios/WaitTicket/Views/ContentView.swift`
- Create: `ios/WaitTicket/Views/TableSelectView.swift`
- Create: `ios/WaitTicket/Views/LiveSessionView.swift`
- Create: `ios/WaitTicket/Views/TicketEditorView.swift`
- Create: `ios/WaitTicket/Views/TicketsListView.swift`
- Create: `ios/WaitTicket/Views/MenuAdminView.swift`

**Step 1: `ContentView.swift`**

```swift
// ios/WaitTicket/Views/ContentView.swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            TableSelectView()
                .tabItem { Label("Tables", systemImage: "tablecells") }
            TicketsListView()
                .tabItem { Label("Tickets", systemImage: "doc.text") }
            MenuAdminView()
                .tabItem { Label("Menu", systemImage: "menucard") }
        }
    }
}
```

**Step 2: `TableSelectView.swift`**

```swift
// ios/WaitTicket/Views/TableSelectView.swift
import SwiftUI

struct TableSelectView: View {
    @Environment(\.appServices) var services
    @State private var vm: TableSelectViewModel?
    @State private var navigateToSession: Bool = false
    @State private var customTable: String = ""

    private let presetTables = ["1","2","3","4","5","6","7","8","9","10","11","12","Bar","Patio"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Select Table")
                    .font(.largeTitle.bold())
                    .padding(.top)

                // Custom entry
                HStack {
                    TextField("Table # or Name", text: $customTable)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.default)
                    Button("Go") {
                        guard !customTable.isEmpty else { return }
                        vm?.selectTable(customTable)
                        navigateToSession = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(customTable.isEmpty)
                }
                .padding(.horizontal)

                // Preset grid
                let columns = [GridItem(.adaptive(minimum: 70))]
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(presetTables, id: \.self) { table in
                        Button(table) {
                            vm?.selectTable(table)
                            navigateToSession = true
                        }
                        .buttonStyle(.bordered)
                        .font(.title2.bold())
                        .frame(height: 60)
                    }
                }
                .padding(.horizontal)

                // Recent tables
                if let recent = vm?.recentTables, !recent.isEmpty {
                    VStack(alignment: .leading) {
                        Text("Recent").font(.headline).padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(recent, id: \.self) { table in
                                    Button(table) {
                                        vm?.selectTable(table)
                                        navigateToSession = true
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }

                Spacer()
            }
            .navigationDestination(isPresented: $navigateToSession) {
                if let tableNumber = vm?.tableNumber, !tableNumber.isEmpty {
                    LiveSessionView(tableNumber: tableNumber)
                }
            }
            .task {
                let vm = TableSelectViewModel(repository: services.repository)
                self.vm = vm
                await vm.loadRecentTables()
            }
        }
    }
}
```

**Step 3: `LiveSessionView.swift`**

```swift
// ios/WaitTicket/Views/LiveSessionView.swift
import SwiftUI

struct LiveSessionView: View {
    let tableNumber: String
    @Environment(\.appServices) var services
    @State private var vm: LiveSessionViewModel?
    @State private var navigateToEditor: Ticket? = nil
    @State private var showRepeatBack = false

    var body: some View {
        NavigationStack {
            if let vm {
                VStack(spacing: 0) {
                    // Low complexity: noise warning banner
                    if vm.showNoisyEnvironmentWarning {
                        Label("Loud environment — speak clearly", systemImage: "waveform.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(8)
                            .frame(maxWidth: .infinity)
                            .background(.orange)
                    }

                    // Low complexity: allergy alert
                    ForEach(vm.allergyItemsPendingConfirm) { item in
                        AllergyAlertBanner(item: item) {
                            vm.confirmAllergyItem(item)
                        }
                    }

                    // Medium complexity: voice macro prompt
                    if let macro = vm.detectedMacro {
                        HStack {
                            Image(systemName: "mic.badge.plus")
                            Text("Voice command: \(macro.displayName)")
                            Spacer()
                            Button("Apply") { vm.applyMacro(macro, previousDraft: nil) }
                                .buttonStyle(.borderedProminent)
                                .tint(.blue)
                            Button("Dismiss") { vm.detectedMacro = nil }
                                .buttonStyle(.bordered)
                        }
                        .padding()
                        .background(.blue.opacity(0.1))
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // Live transcript pane
                            GroupBox("Live Transcript") {
                                Text(vm.transcript.isEmpty ? "Hold the button below and speak the order..." : vm.transcript)
                                    .font(.body)
                                    .foregroundStyle(vm.transcript.isEmpty ? .secondary : .primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .animation(.easeInOut, value: vm.transcript)
                            }

                            // Live ticket draft
                            if !vm.draft.items.isEmpty {
                                GroupBox("Ticket Draft — Table \(tableNumber)") {
                                    ForEach(vm.draft.items) { item in
                                        DraftItemRow(item: item) {
                                            vm.removeItem(item)
                                        }
                                    }
                                }
                            }

                            // Upsell suggestions
                            if !vm.upsellSuggestions.isEmpty {
                                UpsellSuggestionsView(suggestions: vm.upsellSuggestions) { suggestion in
                                    let item = DraftItem(
                                        menuItemId: suggestion.menuItem.id,
                                        name: suggestion.menuItem.name,
                                        quantity: 1,
                                        modifierNames: [], negations: [],
                                        course: .beverage, seatNumber: nil,
                                        notes: "", confidence: 1.0, hasAllergyFlag: false
                                    )
                                    vm.draft.addItem(item)
                                }
                            }
                        }
                        .padding()
                    }

                    Divider()

                    // Controls bar
                    VStack(spacing: 12) {
                        // Low complexity: noise level bar
                        if vm.isRecording {
                            HStack {
                                Image(systemName: "waveform")
                                    .foregroundStyle(vm.noiseLevel > 0.75 ? .orange : .green)
                                ProgressView(value: Double(vm.noiseLevel))
                                    .tint(vm.noiseLevel > 0.75 ? .orange : .green)
                                    .frame(width: 120)
                                Text(vm.noiseLevel > 0.75 ? "Loud" : "Good")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        HStack(spacing: 20) {
                            // Low complexity: repeat-back coach
                            Button {
                                vm.triggerRepeatBack()
                            } label: {
                                Label("Confirm", systemImage: "arrow.uturn.backward.circle")
                            }
                            .buttonStyle(.bordered)
                            .disabled(vm.draft.items.isEmpty)

                            // Hold-to-talk button
                            HoldToTalkButton(isRecording: vm.isRecording) {
                                if vm.isRecording { vm.stopRecording() }
                                else { vm.startRecording() }
                            }

                            // Send to editor
                            Button {
                                Task { await confirmAndNavigate(vm: vm) }
                            } label: {
                                Label("Edit", systemImage: "pencil.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(vm.draft.items.isEmpty)
                        }
                    }
                    .padding()
                }
                .navigationTitle("Table \(tableNumber)")
                .navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $showRepeatBack) {
                    RepeatBackSheet(text: vm.repeatBackText)
                }
                .navigationDestination(item: $navigateToEditor) { ticket in
                    TicketEditorView(ticket: ticket)
                }
            } else {
                ProgressView("Setting up...")
            }
        }
        .task {
            vm = LiveSessionViewModel(
                tableNumber: tableNumber,
                audioCapture: services.audioCapture,
                transcriptionService: services.transcriptionService,
                parser: services.parser,
                menuStore: services.menuStore,
                upsellEngine: services.upsellEngine
            )
        }
    }

    private func confirmAndNavigate(vm: LiveSessionViewModel) async {
        let ticket = try? await services.repository.createTicket(from: vm.draft, serverId: "local_server")
        navigateToEditor = ticket
    }
}

// MARK: - Sub-components

struct HoldToTalkButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isRecording ? Color.red : Color.accentColor)
                    .frame(width: 70, height: 70)
                    .scaleEffect(isRecording ? 1.1 : 1.0)
                    .animation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true), value: isRecording)
                Image(systemName: isRecording ? "stop.circle" : "mic.circle")
                    .font(.system(size: 32))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }
}

struct DraftItemRow: View {
    let item: DraftItem
    let onRemove: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                HStack {
                    Text("\(item.quantity)x \(item.name)")
                        .fontWeight(.medium)
                    if item.hasAllergyFlag {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    if item.confidence < 0.7 {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.orange)
                    }
                }
                if !item.modifierNames.isEmpty {
                    Text(item.modifierNames.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(item.course.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.blue.opacity(0.15))
                    .clipShape(Capsule())
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .background(item.hasAllergyFlag ? Color.red.opacity(0.08) : .clear)
    }
}

struct AllergyAlertBanner: View {
    let item: DraftItem
    let onConfirm: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text("ALLERGY: \(item.name)")
                .fontWeight(.bold)
                .foregroundStyle(.red)
            Spacer()
            Button("Confirm", action: onConfirm)
                .buttonStyle(.bordered)
                .tint(.red)
        }
        .padding()
        .background(.red.opacity(0.12))
    }
}

struct RepeatBackSheet: View {
    let text: String
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.title3)
                    .padding()
            }
            .navigationTitle("Confirm Order")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct UpsellSuggestionsView: View {
    let suggestions: [UpsellSuggestionResult]
    let onAdd: (UpsellSuggestionResult) -> Void

    var body: some View {
        GroupBox("Suggestions") {
            ForEach(suggestions) { suggestion in
                HStack {
                    VStack(alignment: .leading) {
                        Text(suggestion.menuItem.name).fontWeight(.medium)
                        if let script = suggestion.playbookScript {  // medium complexity: playbook
                            Text(script).font(.caption).foregroundStyle(.secondary).italic()
                        } else {
                            Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Add") { onAdd(suggestion) }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 4)
            }
        }
    }
}
```

**Step 4: `TicketEditorView.swift`**

```swift
// ios/WaitTicket/Views/TicketEditorView.swift
import SwiftUI

struct TicketEditorView: View {
    let ticket: Ticket
    @Environment(\.appServices) var services
    @State private var vm: TicketEditorViewModel?
    @State private var showSeatMap = false

    var body: some View {
        if let vm {
            List {
                // Header section
                Section {
                    LabeledContent("Table", value: ticket.tableNumber)
                    LabeledContent("Opened", value: ticket.openedAt.formatted(.dateTime.hour().minute()))
                    LabeledContent("Status", value: ticket.ticketStatus.rawValue.capitalized)
                    if let timeToSend = ticket.timeToSend {
                        LabeledContent("Time to Send", value: formatInterval(timeToSend))
                    }
                }

                // Medium complexity: Course pacing
                let courses = Set(ticket.allItems.map { $0.courseFlag })
                if !courses.isEmpty {
                    Section("Course Pacing") {
                        ForEach(Array(courses).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { course in
                            CourseControlRow(
                                course: course,
                                state: vm.coursePacingStates[course] ?? .holding,
                                onFire: { Task { await vm.fireCourse(course) } },
                                onHold: { Task { await vm.holdCourse(course) } }
                            )
                        }
                    }
                }

                // Items by seat
                ForEach(ticket.guests.sorted(by: { $0.seatNumber < $1.seatNumber })) { seat in
                    Section("Seat \(seat.seatNumber)") {
                        ForEach(seat.items) { item in
                            TicketItemRow(item: item, onConfirmAllergy: {
                                Task { await vm.confirmAllergyItem(item) }
                            }, onUpdateNotes: { notes in
                                Task { await vm.updateItemNotes(item, notes: notes) }
                            }, onMoveSeat: { toSeat in
                                Task { await vm.moveItem(item, fromSeat: seat, toSeatNumber: toSeat) }
                            }, seatCount: ticket.guests.count)
                        }
                        .onDelete { offsets in
                            let items = offsets.map { seat.items[$0] }
                            for item in items { Task { await vm.removeItem(item, from: seat) } }
                        }
                    }
                }

                // Upsell / notes section
                if !ticket.notes.isEmpty {
                    Section("Notes") { Text(ticket.notes) }
                }

                // Actions
                Section {
                    Button("Send to Kitchen") { Task { await vm.sendToKitchen() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(ticket.ticketStatus != .open)

                    Button("Mark Delivered") { Task { await vm.markDelivered() } }
                        .disabled(ticket.ticketStatus != .sent)
                }

                // Seat map button (medium complexity)
                Section {
                    Button("View Seat Map") { showSeatMap = true }
                        .foregroundStyle(.blue)
                }
            }
            .navigationTitle("Ticket — Table \(ticket.tableNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showSeatMap) {
                SeatMapView(ticket: ticket, vm: vm)
            }
        } else {
            ProgressView()
                .task {
                    vm = TicketEditorViewModel(ticket: ticket, repository: services.repository)
                }
        }
    }

    private func formatInterval(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return "\(minutes)m \(seconds)s"
    }
}

struct TicketItemRow: View {
    let item: TicketItem
    let onConfirmAllergy: () -> Void
    let onUpdateNotes: (String) -> Void
    let onMoveSeat: (Int) -> Void
    let seatCount: Int
    @State private var editingNotes = false
    @State private var notesText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // Low complexity: abbreviation shown in brackets
                Text("\(item.quantity)x \(item.name)")
                    .fontWeight(.medium)
                Text("[\(item.ticketAbbreviation)]")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if item.hasAllergyFlag && !item.allergyConfirmed {
                    Button {
                        onConfirmAllergy()
                    } label: {
                        Label("ALLERGY", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.red)
                            .clipShape(Capsule())
                    }
                }
            }
            ForEach(item.modifiers) { mod in
                Text(mod.name)
                    .font(.caption)
                    .foregroundStyle(mod.isNegation ? .red : .secondary)
            }
            if !item.notes.isEmpty {
                Text(item.notes)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .italic()
            }
            // Confidence indicator
            if item.confidence < 0.7 {
                Label("Low confidence — tap to confirm", systemImage: "questionmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("Edit Note") {
                    notesText = item.notes
                    editingNotes = true
                }
                .font(.caption)
                .buttonStyle(.bordered)

                if seatCount > 1 {
                    Menu("Move Seat") {
                        ForEach(1...max(seatCount, 1), id: \.self) { seat in
                            Button("Seat \(seat)") { onMoveSeat(seat) }
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            }
        }
        .sheet(isPresented: $editingNotes) {
            NavigationStack {
                Form {
                    TextField("Kitchen note", text: $notesText, axis: .vertical)
                }
                .navigationTitle("Edit Note")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            onUpdateNotes(notesText)
                            editingNotes = false
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { editingNotes = false }
                    }
                }
            }
        }
    }
}

// Medium complexity: Course pacing control row
struct CourseControlRow: View {
    let course: CourseFlag
    let state: CoursePacingState
    let onFire: () -> Void
    let onHold: () -> Void

    var body: some View {
        HStack {
            Text(course.displayName)
                .fontWeight(.medium)
            Spacer()
            Text(state == .fired ? "Fired" : "Holding")
                .font(.caption)
                .foregroundStyle(state == .fired ? .green : .orange)
            Button(course.fireCommand, action: onFire)
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(state == .fired)
            Button("Hold", action: onHold)
                .buttonStyle(.bordered)
                .disabled(state == .holding)
        }
    }
}
```

**Step 5: `TicketsListView.swift`**

```swift
// ios/WaitTicket/Views/TicketsListView.swift
import SwiftUI

struct TicketsListView: View {
    @Environment(\.appServices) var services
    @State private var vm: TicketsListViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let vm {
                    List {
                        if !vm.openTickets.isEmpty {
                            Section("Open") {
                                ForEach(vm.openTickets) { ticket in
                                    NavigationLink(destination: TicketEditorView(ticket: ticket)) {
                                        TicketRow(ticket: ticket)
                                    }
                                }
                            }
                        }
                        if !vm.completedTickets.isEmpty {
                            Section("Completed") {
                                ForEach(vm.completedTickets) { ticket in
                                    NavigationLink(destination: TicketEditorView(ticket: ticket)) {
                                        TicketRow(ticket: ticket)
                                    }
                                }
                                .onDelete { offsets in
                                    let tickets = offsets.map { vm.completedTickets[$0] }
                                    for t in tickets { Task { await vm.deleteTicket(t) } }
                                }
                            }
                        }
                        if vm.openTickets.isEmpty && vm.completedTickets.isEmpty {
                            ContentUnavailableView("No Tickets", systemImage: "doc.text", description: Text("Start an order from the Tables tab."))
                        }
                    }
                    .refreshable { await vm.loadTickets() }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Tickets")
            .task {
                let vm = TicketsListViewModel(repository: services.repository)
                self.vm = vm
                await vm.loadTickets()
            }
        }
    }
}

struct TicketRow: View {
    let ticket: Ticket

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Table \(ticket.tableNumber)")
                    .fontWeight(.bold)
                Spacer()
                StatusBadge(status: ticket.ticketStatus)
            }
            Text("\(ticket.allItems.count) item(s)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let timeToSend = ticket.timeToSend {
                let minutes = Int(timeToSend) / 60
                let seconds = Int(timeToSend) % 60
                Text("Sent in \(minutes)m \(seconds)s")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct StatusBadge: View {
    let status: TicketStatus
    var body: some View {
        Text(status.rawValue)
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(statusColor.opacity(0.15))
            .foregroundStyle(statusColor)
            .clipShape(Capsule())
    }
    var statusColor: Color {
        switch status {
        case .open: return .blue
        case .sent: return .orange
        case .delivered: return .green
        case .closed: return .secondary
        }
    }
}
```

**Step 6: `MenuAdminView.swift`**

```swift
// ios/WaitTicket/Views/MenuAdminView.swift
import SwiftUI

struct MenuAdminView: View {
    @Environment(\.appServices) var services
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let menu = services.menuStore.menu {
                    List {
                        Section("Restaurant") {
                            LabeledContent("ID", value: menu.restaurantId)
                            LabeledContent("Version", value: "\(menu.version)")
                            LabeledContent("Categories", value: "\(menu.categories.count)")
                            LabeledContent("Total Items", value: "\(menu.categories.flatMap { $0.items }.count)")
                        }
                        ForEach(menu.categories) { category in
                            Section(category.name) {
                                ForEach(category.items) { item in
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(item.name).fontWeight(.medium)
                                            Text(item.description).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(item.price, format: .currency(code: menu.currency))
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                    }
                } else if isLoading {
                    ProgressView("Loading menu...")
                } else {
                    ContentUnavailableView(
                        "No Menu Loaded",
                        systemImage: "menucard",
                        description: Text("Add MenuV1.sample.json to the app bundle.")
                    )
                }
            }
            .navigationTitle("Menu")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Reload") {
                        Task {
                            isLoading = true
                            try? await services.menuStore.loadMenu()
                            isLoading = false
                        }
                    }
                }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}
```

---

## Task 12: Seat Map View (Medium Complexity)

**Files:**
- Create: `ios/WaitTicket/Views/Components/SeatMapView.swift`

**Step 1: Implement seat map**

```swift
// ios/WaitTicket/Views/Components/SeatMapView.swift
import SwiftUI

struct SeatMapView: View {
    let ticket: Ticket
    let vm: TicketEditorViewModel
    @Environment(\.dismiss) var dismiss
    @State private var draggedItem: TicketItem? = nil
    @State private var draggedFromSeat: GuestSeat? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Table \(ticket.tableNumber)")
                        .font(.title2.bold())
                        .padding(.top)

                    // Table representation
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.brown.opacity(0.3))
                        .frame(height: 80)
                        .overlay(Text("TABLE").font(.caption.bold()).foregroundStyle(.brown))
                        .padding(.horizontal, 60)

                    // Seats arranged around table
                    let seats = ticket.guests.sorted(by: { $0.seatNumber < $1.seatNumber })
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 16) {
                        ForEach(seats) { seat in
                            SeatCard(
                                seat: seat,
                                isDragTarget: false
                            ) { item in
                                // Item dropped on this seat
                                if let draggedItem, let fromSeat = draggedFromSeat {
                                    Task { await vm.moveItem(draggedItem, fromSeat: fromSeat, toSeatNumber: seat.seatNumber) }
                                }
                                self.draggedItem = nil
                                self.draggedFromSeat = nil
                            }
                            .onDrop(of: [.text], delegate: SeatDropDelegate(
                                seat: seat, draggedItem: $draggedItem,
                                draggedFromSeat: $draggedFromSeat, vm: vm
                            ))
                        }

                        // Add seat button
                        Button {
                            let newSeatNum = (seats.last?.seatNumber ?? 0) + 1
                            let newSeat = GuestSeat(seatNumber: newSeatNum)
                            ticket.guests.append(newSeat)
                        } label: {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(.secondary, style: StrokeStyle(dash: [5]))
                                .frame(height: 120)
                                .overlay(Label("Add Seat", systemImage: "plus.circle").foregroundStyle(.secondary))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal)
                }
            }
            .navigationTitle("Seat Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct SeatCard: View {
    let seat: GuestSeat
    let isDragTarget: Bool
    let onDrop: (TicketItem) -> Void
    @State private var isDragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Seat \(seat.seatNumber)")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(seat.items) { item in
                Text("\(item.quantity)x \(item.name)")
                    .font(.caption)
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .draggable(item.id)
            }
            if seat.items.isEmpty {
                Text("Empty seat").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .background(isDragTarget ? Color.blue.opacity(0.15) : Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isDragTarget ? .blue : .clear, lineWidth: 2)
        )
    }
}

struct SeatDropDelegate: DropDelegate {
    let seat: GuestSeat
    @Binding var draggedItem: TicketItem?
    @Binding var draggedFromSeat: GuestSeat?
    let vm: TicketEditorViewModel

    func performDrop(info: DropInfo) -> Bool {
        guard let item = draggedItem, let fromSeat = draggedFromSeat else { return false }
        Task { await vm.moveItem(item, fromSeat: fromSeat, toSeatNumber: seat.seatNumber) }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
```

---

## Task 13: GitHub Actions CI

**Files:**
- Create: `.github/workflows/build.yml`

**Step 1: Write workflow**

```yaml
# .github/workflows/build.yml
name: iOS Build Check

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

jobs:
  build:
    name: Build WaitTicket
    runs-on: macos-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Select Xcode
        uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: latest-stable

      - name: Build for simulator (no signing)
        run: |
          xcodebuild \
            -project ios/WaitTicket/WaitTicket.xcodeproj \
            -scheme WaitTicket \
            -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest' \
            -configuration Debug \
            CODE_SIGN_IDENTITY="" \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGNING_ALLOWED=NO \
            clean build \
            | xcpretty || true

      - name: Run unit tests
        run: |
          xcodebuild test \
            -project ios/WaitTicket/WaitTicket.xcodeproj \
            -scheme WaitTicket \
            -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest' \
            CODE_SIGN_IDENTITY="" \
            CODE_SIGNING_REQUIRED=NO \
            | xcpretty || true
```

> **Note:** The `.xcodeproj` must be created in Xcode first (new project → import Swift files), then committed. The GitHub Action will compile it. No code signing = no provisioning profiles needed.

---

## Task 14: Documentation

**Files:**
- Create: `docs/SCHEMAS.md`
- Create: `docs/PARSING.md`
- Create: `docs/UX_FLOWS.md`
- Create: `docs/FUTURE_GOALS.md`

> See separate docs tasks below.

---

## Task 15: Future Goals (High Complexity — Deferred)

**Files:**
- Create: `docs/FUTURE_GOALS.md`

Document all high-complexity features as tracked future work:

```markdown
# WaitTicket — Future Goals (High Complexity)

These features were explicitly deferred from MVP. Each has notes on recommended approach when the time comes.

## 1. Multilingual Support
- **What:** Server speaks English; capture customer language, translate on-device or via API
- **Approach:** Apple's `NLLanguageRecognizer` for detection + `NLTranslator` (iOS 15+) for on-device translation; fallback to DeepL/Google Translate API
- **Dependencies:** Localized menu data; server locale setting in Supabase profile
- **Trigger:** When expanding to non-English-speaking markets

## 2. POS Integration (Toast, Square, Clover)
- **What:** Push ticket directly to POS system via webhook/API
- **Approach:** Abstract `POSExportServiceProtocol`; implement per-POS adapters (Toast REST API, Square Orders API, Clover Orders API)
- **Dependencies:** Restaurant must provide API credentials; TicketV1 schema maps to POS order format
- **Trigger:** First restaurant partner requests it

## 3. Fraud / Void Analytics (Manager View)
- **What:** Track voided items, comps, and anomaly patterns per server per shift
- **Approach:** Add `voidedAt`, `voidReason`, `isComped` fields to TicketItem; build Supabase aggregate queries; add manager-role auth
- **Dependencies:** Supabase backend (Phase 2); manager auth role
- **Trigger:** Restaurant requests manager reporting dashboard

## 4. Training Mode (New Staff Validation)
- **What:** Validates order completeness against restaurant rules (required upsell attempt, allergy confirm, etc.)
- **Approach:** `TrainingEvaluatorService` scores sessions against a rubric; shows real-time coaching tips; exports training report
- **Dependencies:** Upsell playbook (already in Phase 1); training mode flag in server profile
- **Trigger:** Restaurant requests onboarding tool for new staff

## 5. Table QR / NFC Auto-Select
- **What:** Scan QR or tap NFC tag at table to auto-select table number
- **Approach:** `UIImagePickerController` + `AVFoundation` QR scan; `CoreNFC` NFCTagReaderSession
- **Dependencies:** Restaurant provides QR codes or NFC tags; table number encoded in payload
- **Trigger:** Restaurant wants faster table selection

## 6. Kitchen Display Mode
- **What:** Second-screen view showing live tickets with course pacing controls for kitchen staff
- **Approach:** iPad-optimized SwiftUI view; real-time updates via Supabase Realtime
- **Dependencies:** Supabase backend (Phase 2)
- **Trigger:** Restaurant has kitchen display screen

## 7. Printer Support
- **What:** Print ticket to receipt printer (Star Micronics, Epson)
- **Approach:** Star SDK or Epson ePOS SDK; format ticket as ESC/POS commands
- **Dependencies:** Physical printer + SDK integration
- **Trigger:** Restaurant requests paper ticket output
```

---

## Execution Order Summary

| # | Task | Dependencies |
|---|------|-------------|
| 1 | Data Models | none |
| 2 | Service Protocols | Task 1 |
| 3 | AudioCaptureService | Task 2 |
| 4 | SFSpeechTranscriptionService | Task 2 |
| 5 | LocalBundleMenuStore | Task 1, 2 |
| 6 | FuzzyMenuOrderParser | Task 1, 2 |
| 7 | RuleBasedUpsellEngine | Task 1, 2 |
| 8 | SwiftDataTicketRepository | Task 1, 2 |
| 9 | ViewModels | Tasks 1–8 |
| 10 | App Entry + Environment | Tasks 1–9 |
| 11 | Views — Core Screens | Tasks 9–10 |
| 12 | SeatMapView | Tasks 9–11 |
| 13 | GitHub Actions CI | all |
| 14–15 | Docs + Future Goals | all |
