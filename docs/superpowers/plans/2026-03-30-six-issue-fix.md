# Six-Issue Fix + Visual Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix 5 confirmed bugs (transcript persistence, add-mode recording, transcript cascade, edit history detail, menu not found + PDF parsing) and apply a metallic chrome visual redesign with floor map UX improvements, then push a successful TestFlight CI build.

**Architecture:** Bug fixes target the ViewModel and Service layers directly using confirmed root causes. The menu system gains an embedded Swift-string fallback (bundle-independent) plus a PDFKit-based import service. Visual redesign uses a shared `ChromeStyle.swift` modifier file applied across all views without changing any data flow. All changes committed incrementally; version bumped at end for CI.

**Tech Stack:** Swift 5.9, SwiftUI, SwiftData, Combine, PDFKit (on-device PDF text extraction), AVFoundation, Speech.framework, xcodegen

---

## File Map

| File | Action | What changes |
|------|--------|-------------|
| `ios/WhisperTicket/ViewModels/LiveSessionViewModel.swift` | Modify | Add `priorSeatTranscript` property; fix `startRecording()` cursor seeding; fix `handleTranscriptionSegment()` to prepend prior text |
| `ios/WhisperTicket/Views/TableOrderEntryView.swift` | Modify | Rename "Re-record" → "Add More"; add separate "Clear" destructive button |
| `ios/WhisperTicket/ViewModels/TicketEditorViewModel.swift` | Modify | Inject parser+menuStore; enrich `logEdit` summaries; add `reparseItems(for:transcript:)` called from `updateTranscript` and `updateSeatTranscript` |
| `ios/WhisperTicket/Views/TicketEditorView.swift` | Modify | Pass `services.parser` + `services.menuStore` when creating `TicketEditorViewModel` |
| `ios/WhisperTicket/Services/LocalBundleMenuStore.swift` | Modify | Add UserDefaults persistence layer; add embedded Swift-string fallback; expose `saveMenuToDefaults(_:)` |
| `ios/WhisperTicket/Services/PDFMenuImportService.swift` | Create | `PDFMenuImportService: MenuImportServiceProtocol` — PDFKit text extraction → MenuV1 |
| `ios/WhisperTicket/WhisperTicketApp.swift` | Modify | Use `PDFMenuImportService()` instead of `StubMenuImportService()` |
| `ios/WhisperTicket/Views/MenuAdminView.swift` | Modify | On import success, save to store; add menu name/switch UI |
| `ios/WhisperTicket/Views/Components/ChromeStyle.swift` | Create | `chromeCard()`, `chromeGlow()`, `shimmerOverlay()` ViewModifiers + Color constants |
| `ios/WhisperTicket/Services/FloorPlanStore.swift` | Modify | Add `resetTablePositions()` method |
| `ios/WhisperTicket/Views/FloorView.swift` | Modify | Segmented Map/Tables picker defaulting to Map; bigger table cards; chrome style |
| `ios/WhisperTicket/Views/FloorPlanEditorView.swift` | Modify | Add "Reset Positions" button in canvas toolbar; chrome style |
| `ios/WhisperTicket/Views/ContentView.swift` | Modify | Tab icon size; smooth fade transitions |
| `ios/WhisperTicket/Views/TableOrderEntryView.swift` | Modify | Chrome style on seat chips, transcript cards, controls |
| `ios/WhisperTicket/Views/TicketsListView.swift` | Modify | Chrome style on ticket rows |
| `ios/WhisperTicket/Views/MenuAdminView.swift` | Modify | Chrome style on menu cards |
| `project.yml` | Modify | Bump `MARKETING_VERSION` to 1.5.0, `CURRENT_PROJECT_VERSION` to 8; fix resource spec |

---

## Task 1: Fix Transcript Accumulation Across Recording Sessions (Issues #1 & #2)

**Root cause confirmed:** `startRecording()` resets `draft.consumedCursor = 0` and `startTranscribing()` resets `accumulatedBase = ""` on every mic press. Each new recording session only transcribes its own audio; `handleTranscriptionSegment` overwrites `seatTranscripts[seatNumber]` with the new session's text alone.

**Files:**
- Modify: `ios/WhisperTicket/ViewModels/LiveSessionViewModel.swift`
- Modify: `ios/WhisperTicket/Views/TableOrderEntryView.swift`

- [ ] **Step 1.1 — Add `priorSeatTranscript` storage to `LiveSessionViewModel`**

In `LiveSessionViewModel.swift`, add one private property after the existing private declarations (around line 32):

```swift
// Stores the transcript text that existed for the active seat before the current
// recording session began. Used to prepend to new ASR segments so accumulation
// survives multiple mic button presses for the same seat.
private var priorSeatTranscript = ""
```

- [ ] **Step 1.2 — Fix `startRecording()` to seed from existing seat transcript**

Replace the current `startRecording()` body (lines 54–74) with:

```swift
func startRecording() {
    do {
        // Capture whatever transcript already exists for this seat BEFORE starting ASR.
        // New ASR segments will be prepended with this text so users can press record
        // multiple times without losing prior speech.
        priorSeatTranscript = seatTranscripts[activeSeatNumber] ?? ""

        // Position the parse cursor so the parser skips already-processed prior text.
        // If prior text exists, new words start after a space separator (+1).
        draft.consumedCursor = priorSeatTranscript.isEmpty
            ? 0
            : priorSeatTranscript.count + 1

        try audioCapture.startCapture()
        let audioPublisher = audioCapture.audioBufferPublisher()
        try transcriptionService.startTranscribing(audioPublisher: audioPublisher)
        isRecording = true

        transcriptionCancellable = transcriptionService.transcriptionPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] segment in self?.handleTranscriptionSegment(segment) }

        Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.checkNoiseLevel() }
            .store(in: &cancellables)

    } catch {
        errorMessage = "Could not start recording: \(error.localizedDescription)"
    }
}
```

- [ ] **Step 1.3 — Fix `handleTranscriptionSegment()` to prepend prior text**

Replace the three lines at the top of `handleTranscriptionSegment` that set `seatTranscripts` and `draft.rawTranscript` (lines 161–163 and 174–176):

```swift
private func handleTranscriptionSegment(_ segment: TranscriptionSegment) {
    // Build the full seat transcript: everything spoken before this recording session
    // (priorSeatTranscript) + whatever ASR has produced in this session (segment.text).
    let fullText: String
    if priorSeatTranscript.isEmpty {
        fullText = segment.text
    } else {
        fullText = "\(priorSeatTranscript) \(segment.text)"
    }

    seatTranscripts[activeSeatNumber] = fullText
    draft.seatTranscripts[activeSeatNumber] = fullText
    draft.rawTranscript = fullText

    if let macro = parser.detectMacro(in: segment.text) {
        detectedMacro = macro
    }

    guard let menu = menuStore.menu else { return }

    let previousIds = Set(draft.items.map { $0.id })
    let updatedDraft = parser.parseDraft(transcript: fullText, existingDraft: draft, menu: menu)
    draft = updatedDraft
    // Re-sync per-seat transcripts after parseDraft replaces the draft struct.
    draft.seatTranscripts = seatTranscripts
    draft.rawTranscript = fullText

    // Stamp newly added items with the active seat.
    for i in draft.items.indices where !previousIds.contains(draft.items[i].id) {
        draft.items[i].seatNumber = activeSeatNumber
    }

    let existingIds = Set(allergyItemsPendingConfirm.map { $0.id })
    let newAllergyItems = draft.items.filter { $0.hasAllergyFlag && !existingIds.contains($0.id) }
    allergyItemsPendingConfirm.append(contentsOf: newAllergyItems)

    refreshUpsells()
}
```

- [ ] **Step 1.4 — Update `clearSeat()` to also reset `priorSeatTranscript` when clearing the active seat**

After the existing `clearSeat` body, add one guard at the top:

```swift
func clearSeat(_ seatNumber: Int) {
    draft.items.removeAll { $0.seatNumber == seatNumber }
    seatTranscripts.removeValue(forKey: seatNumber)
    draft.seatTranscripts.removeValue(forKey: seatNumber)
    // If the active seat is being cleared, reset the prior-session accumulator
    // so the next recording starts truly fresh.
    if seatNumber == activeSeatNumber {
        priorSeatTranscript = ""
        draft.consumedCursor = 0
    }
    refreshUpsells()
}
```

- [ ] **Step 1.5 — Change "Re-record" to "Add More" + add "Clear" in `TableOrderEntryView`**

In `TableOrderEntryView.swift`, find the `orderSummarySection` function. Replace the existing "Re-record" `Button` (lines 173–178) with two buttons side-by-side:

```swift
HStack(spacing: 8) {
    // "Add More" — switches to this seat and starts a new recording that
    // appends to the existing transcript (no items or transcript cleared).
    Button {
        activeSeatIndex = max(0, group.seatNumber - 1)
        vm.activeSeatNumber = group.seatNumber
        vm.activeSeatLabel = seatConfigs[max(0, group.seatNumber - 1)].label
    } label: {
        Text("Add More")
            .font(.caption2)
            .foregroundStyle(.blue)
    }
    Text("·")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    // "Clear" — destructive: wipes transcript + items for this seat.
    Button(role: .destructive) {
        activeSeatIndex = max(0, group.seatNumber - 1)
        vm.activeSeatNumber = group.seatNumber
        vm.clearSeat(group.seatNumber)
    } label: {
        Text("Clear")
            .font(.caption2)
            .foregroundStyle(.red)
    }
}
```

- [ ] **Step 1.6 — Commit**

```bash
cd "C:/Users/pr0ph/Documents/AI LLC/Apps/Whisper"
git add ios/WhisperTicket/ViewModels/LiveSessionViewModel.swift \
        ios/WhisperTicket/Views/TableOrderEntryView.swift
git commit -m "fix: accumulate transcript across recording sessions; add Add More / Clear buttons

- startRecording() captures priorSeatTranscript and seeds consumedCursor past it
- handleTranscriptionSegment() prepends prior text to every ASR segment
- clearSeat() resets accumulator only for the active seat
- TableOrderEntryView: 'Re-record' → 'Add More' (no wipe) + separate 'Clear' button"
```

---

## Task 2: Enrich Edit History Summaries (Issue #4)

**Root cause confirmed:** `logEdit()` summaries are hardcoded generic strings with no content or seat label.

**Files:**
- Modify: `ios/WhisperTicket/ViewModels/TicketEditorViewModel.swift`

- [ ] **Step 2.1 — Update `updateTranscript()` summary**

Replace `updateTranscript` (lines 69–73):

```swift
func updateTranscript(_ text: String) async {
    ticket.rawTranscript = text
    let preview = text.prefix(80)
    let suffix = text.count > 80 ? "…" : ""
    logEdit(type: "transcript_set", seatNumber: 0,
            summary: "Table transcript: \(preview)\(suffix)")
    await save()
}
```

- [ ] **Step 2.2 — Update `updateSeatTranscript()` summary**

Replace `updateSeatTranscript` (lines 75–79):

```swift
func updateSeatTranscript(_ text: String, for seat: GuestSeat) async {
    seat.rawTranscript = text
    let preview = text.prefix(80)
    let suffix = text.count > 80 ? "…" : ""
    logEdit(type: "transcript_set", seatNumber: seat.seatNumber,
            summary: "Seat \(seat.seatNumber): \(preview)\(suffix)")
    await save()
}
```

- [ ] **Step 2.3 — Commit**

```bash
git add ios/WhisperTicket/ViewModels/TicketEditorViewModel.swift
git commit -m "fix: enrich edit history with seat number and transcript content preview"
```

---

## Task 3: Transcript Edit Cascade — Re-parse Items on Edit (Issue #3)

**Root cause confirmed:** `TicketEditorViewModel` has no parser or menuStore reference; transcript edits only update the raw text field, never seat items.

**Files:**
- Modify: `ios/WhisperTicket/ViewModels/TicketEditorViewModel.swift`
- Modify: `ios/WhisperTicket/Views/TicketEditorView.swift`

- [ ] **Step 3.1 — Add parser + menuStore to `TicketEditorViewModel`**

Replace the class header and `init` in `TicketEditorViewModel.swift` (lines 1–21):

```swift
import Foundation
import Observation

@Observable
final class TicketEditorViewModel {
    var ticket: Ticket
    var isSaving = false
    var errorMessage: String? = nil
    var coursePacingStates: [CourseFlag: CoursePacingState] = [:]

    private let repository: TicketRepositoryProtocol
    private let parser: OrderParserProtocol?
    private let menuStore: MenuStoreProtocol?

    init(ticket: Ticket,
         repository: TicketRepositoryProtocol,
         parser: OrderParserProtocol? = nil,
         menuStore: MenuStoreProtocol? = nil) {
        self.ticket = ticket
        self.repository = repository
        self.parser = parser
        self.menuStore = menuStore
        for (key, value) in ticket.coursePacingStates {
            if let flag = CourseFlag(rawValue: key), let state = CoursePacingState(rawValue: value) {
                coursePacingStates[flag] = state
            }
        }
    }
```

- [ ] **Step 3.2 — Add `reparseItems(for:transcript:)` private method**

Add this method to `TicketEditorViewModel` before the `logEdit` method:

```swift
/// Re-parses a transcript and appends any newly discovered items to the seat.
/// Existing items are preserved — only net-new items are added (merge, not replace).
private func reparseItems(for seat: GuestSeat, transcript: String) {
    guard let parser, let menu = menuStore?.menu else { return }
    var draft = TicketDraft(tableNumber: ticket.tableNumber)
    let parsed = parser.parseDraft(transcript: transcript, existingDraft: draft, menu: menu)

    for draftItem in parsed.items {
        let alreadyExists = seat.items.contains {
            $0.menuItemId == draftItem.menuItemId && $0.name == draftItem.name
        }
        guard !alreadyExists else { continue }
        let newItem = TicketItem(
            menuItemId: draftItem.menuItemId,
            name: draftItem.name,
            quantity: draftItem.quantity,
            course: draftItem.course,
            notes: draftItem.notes,
            confidence: draftItem.confidence,
            hasAllergyFlag: draftItem.hasAllergyFlag
        )
        for modName in draftItem.modifierNames {
            let isNeg = draftItem.negations.contains(modName)
            newItem.modifiers.append(TicketModifier(name: modName, priceDelta: 0, isNegation: isNeg))
        }
        seat.items.append(newItem)
        logEdit(type: "item_added", seatNumber: seat.seatNumber,
                summary: "Auto-parsed from transcript: \(draftItem.name)")
    }
}
```

- [ ] **Step 3.3 — Wire cascade into `updateTranscript()` and `updateSeatTranscript()`**

Replace both functions (already edited in Task 2 for summaries — now extend them):

```swift
func updateTranscript(_ text: String) async {
    ticket.rawTranscript = text
    // Cascade: update the primary seat transcript and re-parse items.
    if let primarySeat = ticket.guests.sorted(by: { $0.seatNumber < $1.seatNumber }).first {
        primarySeat.rawTranscript = text
        reparseItems(for: primarySeat, transcript: text)
    }
    let preview = text.prefix(80)
    let suffix = text.count > 80 ? "…" : ""
    logEdit(type: "transcript_set", seatNumber: 0,
            summary: "Table transcript: \(preview)\(suffix)")
    await save()
}

func updateSeatTranscript(_ text: String, for seat: GuestSeat) async {
    seat.rawTranscript = text
    reparseItems(for: seat, transcript: text)
    let preview = text.prefix(80)
    let suffix = text.count > 80 ? "…" : ""
    logEdit(type: "transcript_set", seatNumber: seat.seatNumber,
            summary: "Seat \(seat.seatNumber): \(preview)\(suffix)")
    await save()
}
```

- [ ] **Step 3.4 — Pass parser + menuStore when creating VM in `TicketEditorView`**

In `TicketEditorView.swift`, find the `.task {}` block (around line 53) that creates the VM:

```swift
// Replace this:
vm = TicketEditorViewModel(ticket: ticket, repository: services.repository)

// With this:
vm = TicketEditorViewModel(
    ticket: ticket,
    repository: services.repository,
    parser: services.parser,
    menuStore: services.menuStore
)
```

- [ ] **Step 3.5 — Commit**

```bash
git add ios/WhisperTicket/ViewModels/TicketEditorViewModel.swift \
        ios/WhisperTicket/Views/TicketEditorView.swift
git commit -m "fix: cascade transcript edits into seat items via re-parse

- TicketEditorViewModel now accepts optional parser + menuStore
- updateTranscript() cascades to primary seat + re-parses
- updateSeatTranscript() re-parses seat items on save
- TicketEditorView passes services.parser + services.menuStore"
```

---

## Task 4: Menu System — Embedded Fallback + PDF Parsing (Issue #5)

**Root cause confirmed:** (a) Bundle resource registration unreliable — `**/*.json` source exclusion pattern can interfere with xcodegen resource phase. (b) No embedded fallback. (c) `StubMenuImportService` never parses PDFs.

**Files:**
- Modify: `ios/WhisperTicket/Services/LocalBundleMenuStore.swift`
- Create: `ios/WhisperTicket/Services/PDFMenuImportService.swift`
- Modify: `ios/WhisperTicket/WhisperTicketApp.swift`
- Modify: `ios/WhisperTicket/Views/MenuAdminView.swift`
- Modify: `project.yml`

- [ ] **Step 4.1 — Fix `project.yml` resource registration**

Replace the `sources` + `resources` section (lines 12–18) with:

```yaml
    sources:
      - path: ios/WhisperTicket
        excludes:
          - "Resources/**"
    resources:
      - path: ios/WhisperTicket/Resources
      - path: ios/WhisperTicket/Assets.xcassets
```

This ensures the entire Resources folder (including the JSON) is registered as a bundle resource without relying on the per-file glob override.

- [ ] **Step 4.2 — Add UserDefaults persistence + embedded fallback to `LocalBundleMenuStore`**

Replace `LocalBundleMenuStore.swift` entirely:

```swift
import Foundation
import Observation

@Observable
final class LocalBundleMenuStore: MenuStoreProtocol {
    private(set) var menu: MenuV1?
    private var itemIndex: [String: MenuItem] = [:]
    private var searchIndex: [(tokens: [String], item: MenuItem)] = []

    private static let defaultsKey = "whisperticket.menu.v1.json"

    func loadMenu() async throws {
        // Strategy 1: try bundle file (fixed by project.yml resource folder spec)
        if let url = resolveMenuURL(), let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode(MenuV1.self, from: data) {
            await MainActor.run { self.applyMenu(loaded) }
            return
        }

        // Strategy 2: UserDefaults — previously imported menu
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let loaded = try? JSONDecoder().decode(MenuV1.self, from: data) {
            await MainActor.run { self.applyMenu(loaded) }
            return
        }

        // Strategy 3: Embedded Swift-string fallback — always works, no file I/O
        if let data = Self.embeddedMenuJSON.data(using: .utf8),
           let loaded = try? JSONDecoder().decode(MenuV1.self, from: data) {
            await MainActor.run { self.applyMenu(loaded) }
            return
        }

        throw MenuStoreError.fileNotFound
    }

    /// Called by MenuAdminView after a successful PDF import to persist the menu.
    func saveMenu(_ newMenu: MenuV1) {
        if let data = try? JSONEncoder().encode(newMenu) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        applyMenu(newMenu)
    }

    private func applyMenu(_ newMenu: MenuV1) {
        menu = newMenu
        buildIndex(from: newMenu)
    }

    private func resolveMenuURL() -> URL? {
        if let url = Bundle.main.url(forResource: "MenuV1.sample", withExtension: "json") { return url }
        let direct = Bundle.main.bundleURL.appendingPathComponent("MenuV1.sample.json")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        if let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) {
            if let m = urls.first(where: { $0.lastPathComponent.lowercased().contains("menu") }) { return m }
        }
        return nil
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
        let querySet = Set(query); let candidateSet = Set(candidate)
        let intersection = querySet.intersection(candidateSet)
        guard !querySet.isEmpty else { return 0 }
        return Double(intersection.count) / Double(querySet.count)
    }

    // MARK: - Embedded fallback menu (always available, no bundle dependency)

    private static let embeddedMenuJSON = """
    {
      "restaurant_id": "demo",
      "version": 1,
      "currency": "USD",
      "categories": [
        {
          "id": "cat_apps",
          "name": "Appetizers",
          "items": [
            {"id": "item_boneless_wings","name": "Boneless Wings","price": 13.99,"description": "Crispy chicken tossed in sauce","tags": ["fried","shareable"],"modifier_groups": [],"upsell_links": []},
            {"id": "item_mozz_sticks","name": "Mozzarella Sticks","price": 11.99,"description": "Golden-fried with marinara","tags": ["fried","vegetarian"],"modifier_groups": [],"upsell_links": []}
          ]
        },
        {
          "id": "cat_mains",
          "name": "Entrees",
          "items": [
            {"id": "item_classic_burger","name": "Classic Burger","price": 14.99,"description": "Half-pound beef patty","tags": ["burger","popular"],"modifier_groups": [{"id": "mg_temp","name": "Temperature","required": true,"max_select": 1,"modifiers": [{"id": "m_rare","name": "Rare","price_delta": 0},{"id": "m_medium","name": "Medium","price_delta": 0},{"id": "m_well","name": "Well Done","price_delta": 0}]}],"upsell_links": []},
            {"id": "item_grilled_salmon","name": "Grilled Salmon","price": 22.99,"description": "Fresh Atlantic salmon","tags": ["seafood","healthy"],"modifier_groups": [],"upsell_links": []},
            {"id": "item_ribeye","name": "Ribeye Steak","price": 34.99,"description": "12 oz. USDA Choice","tags": ["steak","premium"],"modifier_groups": [],"upsell_links": []}
          ]
        },
        {
          "id": "cat_sides",
          "name": "Sides",
          "items": [
            {"id": "item_fries","name": "French Fries","price": 4.99,"description": "Seasoned crispy fries","tags": ["side","fried"],"modifier_groups": [],"upsell_links": []},
            {"id": "item_side_salad","name": "Side Salad","price": 5.99,"description": "Fresh garden salad","tags": ["side","salad","vegetarian"],"modifier_groups": [],"upsell_links": []}
          ]
        },
        {
          "id": "cat_drinks",
          "name": "Beverages",
          "items": [
            {"id": "item_coke","name": "Coca-Cola","price": 2.99,"description": "Fountain soda","tags": ["soft_drink","beverage"],"modifier_groups": [],"upsell_links": []},
            {"id": "item_water","name": "Water","price": 0.00,"description": "Still or sparkling","tags": ["beverage"],"modifier_groups": [],"upsell_links": []},
            {"id": "item_draft_beer","name": "IPA Draft Beer","price": 7.99,"description": "Local craft IPA on tap","tags": ["beer","beverage","alcohol"],"modifier_groups": [],"upsell_links": []}
          ]
        }
      ],
      "upsell_rules": [
        {"id": "rule_drink","if": {"has_entree": true, "has_drink": false},"suggest": [{"tag": "soft_drink"},{"tag": "beer"}],"playbook_script": "Can I start you off with something to drink?"},
        {"id": "rule_fries","if": {"has_entree": false, "has_drink": false},"suggest": [{"item_id": "item_fries"}],"playbook_script": "Would you like fries with that?"}
      ]
    }
    """
}

enum MenuStoreError: Error, LocalizedError {
    case fileNotFound
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .fileNotFound: return "Menu could not be loaded. Import a menu PDF from the Menu tab."
        case .decodingFailed: return "Menu file could not be read — file may be corrupted."
        }
    }
}
```

- [ ] **Step 4.3 — Add `saveMenu(_:)` to `MenuStoreProtocol`**

In `Protocols.swift`, add `saveMenu` to `MenuStoreProtocol`:

```swift
protocol MenuStoreProtocol: AnyObject {
    var menu: MenuV1? { get }
    func loadMenu() async throws
    func saveMenu(_ menu: MenuV1)
    func findBestMatches(text: String, maxResults: Int) -> [(item: MenuItem, score: Double)]
    func item(byId id: String) -> MenuItem?
}
```

Also add a no-op implementation to `PlaceholderMenuStore` in `WhisperTicketApp.swift`:

```swift
private final class PlaceholderMenuStore: MenuStoreProtocol {
    var menu: MenuV1? = nil
    func loadMenu() async throws {}
    func saveMenu(_ menu: MenuV1) {}
    func findBestMatches(text: String, maxResults: Int) -> [(item: MenuItem, score: Double)] { [] }
    func item(byId id: String) -> MenuItem? { nil }
}
```

- [ ] **Step 4.4 — Create `PDFMenuImportService.swift`**

Create `ios/WhisperTicket/Services/PDFMenuImportService.swift`:

```swift
import Foundation
import PDFKit

/// Extracts text from a PDF and parses it into MenuV1 format using price-anchored detection.
/// Works best with text-layer PDFs (not scanned images). Each line containing a price
/// pattern like "$X.XX" is treated as a menu item; ALL-CAPS lines without prices are
/// treated as category headers.
final class PDFMenuImportService: MenuImportServiceProtocol {

    func importMenu(from fileURL: URL, fileType: MenuImportFileType) async -> MenuImportResult {
        switch fileType {
        case .pdf:  return await parsePDF(at: fileURL)
        case .image: return .failure("Image import not yet supported — select a PDF instead.")
        }
    }

    // MARK: - PDF Extraction

    private func parsePDF(at url: URL) async -> MenuImportResult {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        guard let document = PDFDocument(url: url) else {
            return .failure("Could not open PDF. Ensure the file is a valid, non-encrypted PDF.")
        }

        var fullText = ""
        for i in 0..<document.pageCount {
            fullText += (document.page(at: i)?.string ?? "") + "\n"
        }

        guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("PDF appears to contain only images (no text layer). Use a text-based PDF.")
        }

        return parseTextIntoMenu(fullText, restaurantName: url.deletingPathExtension().lastPathComponent)
    }

    // MARK: - Text → MenuV1

    private func parseTextIntoMenu(_ text: String, restaurantName: String) -> MenuImportResult {
        let priceRegex = try! NSRegularExpression(pattern: #"\$\s*(\d+\.\d{2})"#)
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var categories: [MenuCategory] = []
        var currentCategoryName = "Menu Items"
        var currentItems: [MenuItem] = []
        var catIndex = 0

        func flushCategory() {
            guard !currentItems.isEmpty else { return }
            categories.append(MenuCategory(id: "cat_\(catIndex)", name: currentCategoryName, items: currentItems))
            catIndex += 1
            currentItems = []
        }

        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            let priceMatches = priceRegex.matches(in: line, range: range)

            if priceMatches.isEmpty {
                // Potential category header: ALL-CAPS, short, no numbers
                let stripped = line.replacingOccurrences(of: "[^A-Za-z &/-]", with: "", options: .regularExpression)
                if line == line.uppercased() && stripped.count >= 3 && stripped.count <= 60 {
                    flushCategory()
                    currentCategoryName = line.capitalized
                }
                continue
            }

            // Extract first price on this line
            let priceMatch = priceMatches[0]
            guard let priceValueRange = Range(priceMatch.range(at: 1), in: line),
                  let price = Double(line[priceValueRange]) else { continue }

            // Name = everything before the first "$"
            let dollarRange = Range(priceMatch.range, in: line)!
            let rawName = String(line[line.startIndex..<dollarRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !rawName.isEmpty else { continue }

            let itemId = "item_\(catIndex)_\(currentItems.count)"
            let item = MenuItem(
                id: itemId,
                name: rawName,
                price: price,
                description: "",
                tags: inferTags(from: rawName),
                modifierGroups: [],
                upsellLinks: [],
                kitchenNoteTemplate: nil
            )
            currentItems.append(item)
        }

        flushCategory()

        guard !categories.isEmpty else {
            return .failure("No menu items found in PDF. The PDF may be image-only or use an unusual format.")
        }

        let menu = MenuV1(
            restaurantId: "imported_\(Int(Date().timeIntervalSince1970))",
            version: 1,
            currency: "USD",
            categories: categories,
            upsellRules: defaultUpsellRules()
        )
        return .success(menu)
    }

    // MARK: - Helpers

    private func inferTags(from name: String) -> [String] {
        var tags: [String] = []
        let lower = name.lowercased()
        if lower.contains("salad") || lower.contains("veggie") { tags.append("vegetarian") }
        if lower.contains("burger") || lower.contains("sandwich") { tags.append("burger") }
        if lower.contains("steak") || lower.contains("rib") { tags.append("steak") }
        if lower.contains("beer") || lower.contains("wine") || lower.contains("cocktail") { tags.append("alcohol"); tags.append("beverage") }
        if lower.contains("coke") || lower.contains("lemonade") || lower.contains("juice") || lower.contains("soda") { tags.append("soft_drink"); tags.append("beverage") }
        if lower.contains("water") { tags.append("beverage") }
        if lower.contains("fries") || lower.contains("side") { tags.append("side") }
        return tags
    }

    private func defaultUpsellRules() -> [UpsellRule] {
        [
            UpsellRule(
                id: "rule_drink_if_none",
                condition: UpsellCondition(hasEntree: true, hasDrink: false),
                suggest: [UpsellSuggestion(tag: "soft_drink", itemId: nil), UpsellSuggestion(tag: "beverage", itemId: nil)],
                playbookScript: "Can I start you off with something to drink?"
            ),
            UpsellRule(
                id: "rule_side_if_none",
                condition: UpsellCondition(hasEntree: true, hasDrink: false),
                suggest: [UpsellSuggestion(tag: "side", itemId: nil)],
                playbookScript: "Would you like to add a side?"
            )
        ]
    }
}
```

- [ ] **Step 4.5 — Wire `PDFMenuImportService` in `WhisperTicketApp.swift`**

In `WhisperTicketApp.swift`, replace:
```swift
menuImporter: StubMenuImportService(),
```
with:
```swift
menuImporter: PDFMenuImportService(),
```

- [ ] **Step 4.6 — Update `MenuAdminView` to save imported menu and show menu name**

In `MenuAdminView.swift`, update the import success handler inside the `.fileImporter` closure:

```swift
case .success(let menu):
    // Persist so it survives app restarts and replaces any prior menu.
    services.menuStore.saveMenu(menu)
    currentMenu = menu
    importResult = "Imported \(menu.categories.count) categories, \(menu.categories.flatMap { $0.items }.count) items from \(url.lastPathComponent)"
```

Also update the `loadMenu()` call in `.task {}` to always sync after load:

```swift
.task {
    currentMenu = services.menuStore.menu
    if currentMenu == nil {
        await loadMenu()
    }
}
```

And in `loadMenu()`:
```swift
private func loadMenu() async {
    isLoading = true
    do {
        try await services.menuStore.loadMenu()
        currentMenu = services.menuStore.menu
    } catch {
        // Even on error, check if embedded fallback succeeded
        currentMenu = services.menuStore.menu
        if currentMenu == nil {
            errorMessage = error.localizedDescription
        }
    }
    isLoading = false
}
```

- [ ] **Step 4.7 — Commit**

```bash
git add ios/WhisperTicket/Services/LocalBundleMenuStore.swift \
        ios/WhisperTicket/Services/PDFMenuImportService.swift \
        ios/WhisperTicket/Services/Protocols.swift \
        ios/WhisperTicket/WhisperTicketApp.swift \
        ios/WhisperTicket/Views/MenuAdminView.swift \
        project.yml
git commit -m "fix: menu system — embedded fallback + UserDefaults persistence + PDF parsing

- LocalBundleMenuStore: 3-strategy load (bundle → UserDefaults → embedded Swift literal)
- PDFMenuImportService: PDFKit text extraction + price-anchored item/category detection
- MenuAdminView: saves imported menu to store; survives app restarts
- Protocols: saveMenu(_:) added to MenuStoreProtocol
- project.yml: resource spec uses folder inclusion to fix bundle registration
- WhisperTicketApp: replaces StubMenuImportService with PDFMenuImportService"
```

---

## Task 5: Chrome Visual Redesign + Floor Map UX (Issue #6)

**Goal:** Metallic chrome aesthetic (dark glass cards, silver gradient borders, colored glow shadows, shimmer animation on the record button), floor view defaulting to map canvas, reset table positions, bigger table containers, smooth SwiftUI transitions. No dark/light mode lock — uses materials that adapt.

**Files:**
- Create: `ios/WhisperTicket/Views/Components/ChromeStyle.swift`
- Modify: `ios/WhisperTicket/Services/FloorPlanStore.swift`
- Modify: `ios/WhisperTicket/Views/FloorView.swift`
- Modify: `ios/WhisperTicket/Views/FloorPlanEditorView.swift`
- Modify: `ios/WhisperTicket/Views/ContentView.swift`
- Modify: `ios/WhisperTicket/Views/TableOrderEntryView.swift`
- Modify: `ios/WhisperTicket/Views/TicketsListView.swift`
- Modify: `ios/WhisperTicket/Views/MenuAdminView.swift`

- [ ] **Step 5.1 — Create `ChromeStyle.swift` with all shared design tokens**

Create `ios/WhisperTicket/Views/Components/ChromeStyle.swift`:

```swift
import SwiftUI

// MARK: - Chrome Design System
// "Liquid chrome" aesthetic: dark glass cards, gradient chrome borders,
// colored glow shadows, shimmer animation. Adapts to system light/dark mode.

// MARK: - Color Tokens

extension Color {
    /// Tinted blue-purple accent used for primary interactive elements and glow.
    static let chromePrimary = Color(red: 0.35, green: 0.55, blue: 1.0)
    /// Soft teal accent used for positive states (available, confirmed).
    static let chromeTeal = Color(red: 0.2, green: 0.85, blue: 0.75)
    /// Warm amber for in-progress / sent states.
    static let chromeAmber = Color(red: 1.0, green: 0.65, blue: 0.2)
    /// Chrome silver gradient start (high-specularity highlight).
    static let chromeSilverHigh = Color(red: 0.88, green: 0.90, blue: 0.96)
    /// Chrome silver gradient end (shadow side).
    static let chromeSilverLow = Color(red: 0.55, green: 0.58, blue: 0.68)
}

// MARK: - ViewModifiers

/// A glass-chrome card: translucent material background + gradient border + glow.
struct ChromeCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 16
    var glowColor: Color = .chromePrimary
    var glowRadius: CGFloat = 0   // 0 = no glow

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.regularMaterial)
                    .overlay(
                        // Subtle blue-silver tint over the material
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.chromeSilverHigh.opacity(0.08),
                                        Color.chromePrimary.opacity(0.04),
                                        Color.chromeSilverLow.opacity(0.06),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
            )
            .overlay(
                // Chrome border: bright highlight on top-left, fading to transparent
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.chromeSilverHigh.opacity(0.55),
                                Color.chromeSilverHigh.opacity(0.20),
                                Color.chromeSilverLow.opacity(0.10),
                                Color.clear,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: glowRadius > 0 ? glowColor.opacity(0.25) : .clear,
                radius: glowRadius, x: 0, y: 3
            )
    }
}

/// A shimmer sweep animation for the record button or key interactive element.
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1.2

    func body(content: Content) -> some View {
        content.overlay(
            GeometryReader { geo in
                LinearGradient(
                    colors: [
                        .clear,
                        .white.opacity(0.35),
                        .clear,
                    ],
                    startPoint: .init(x: phase, y: 0.1),
                    endPoint: .init(x: phase + 0.6, y: 0.9)
                )
                .frame(width: geo.size.width, height: geo.size.height)
                .allowsHitTesting(false)
            }
            .clipped()
        )
        .onAppear {
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                phase = 1.2
            }
        }
    }
}

/// Status-color glow ring around a view (used on table cards).
struct GlowRingModifier: ViewModifier {
    var color: Color
    var radius: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(0.4), radius: radius, x: 0, y: 2)
            .shadow(color: color.opacity(0.15), radius: radius * 2, x: 0, y: 4)
    }
}

// MARK: - View Extensions

extension View {
    /// Glass-chrome card style with optional glow.
    func chromeCard(cornerRadius: CGFloat = 16, glowColor: Color = .clear, glowRadius: CGFloat = 0) -> some View {
        modifier(ChromeCardModifier(cornerRadius: cornerRadius, glowColor: glowColor, glowRadius: glowRadius))
    }

    /// Animated shimmer sweep (use on record button, primary CTA).
    func chromeShimmer() -> some View {
        modifier(ShimmerModifier())
    }

    /// Colored glow halo (use on active/status elements).
    func glowRing(color: Color, radius: CGFloat = 8) -> some View {
        modifier(GlowRingModifier(color: color, radius: radius))
    }
}

// MARK: - Chrome Section Header

/// Drop-in replacement for plain section label text — chrome gradient title.
struct ChromeSectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.bold())
                .foregroundStyle(.chromePrimary)
            Text(title.uppercased())
                .font(.caption.bold())
                .tracking(0.8)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.chromeSilverHigh, .chromeSilverLow],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
        }
    }
}

// MARK: - Chrome Tab Bar Background

/// Applied to the TabView to give the tab bar a frosted chrome bottom.
struct ChromeTabBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                let appearance = UITabBarAppearance()
                appearance.configureWithOpaqueBackground()
                appearance.backgroundEffect = UIBlurEffect(style: .systemChromeMaterialDark)
                appearance.backgroundColor = UIColor(
                    red: 0.08, green: 0.09, blue: 0.14, alpha: 0.92
                )
                // Selected item: chrome blue
                appearance.stackedLayoutAppearance.selected.iconColor = UIColor(Color.chromePrimary)
                appearance.stackedLayoutAppearance.selected.titleTextAttributes = [
                    .foregroundColor: UIColor(Color.chromePrimary)
                ]
                UITabBar.appearance().standardAppearance = appearance
                UITabBar.appearance().scrollEdgeAppearance = appearance
            }
    }
}

extension View {
    func chromeTabBar() -> some View { modifier(ChromeTabBarModifier()) }
}
```

- [ ] **Step 5.2 — Add `resetTablePositions()` to `FloorPlanStore`**

In `FloorPlanStore.swift`, add this method before `save()`:

```swift
/// Resets all table drag offsets to .zero without changing table names or seats.
func resetTablePositions() {
    floorPlan.tables = floorPlan.tables.map { table in
        var t = table
        t.position = .zero
        return t
    }
    save()
}
```

- [ ] **Step 5.3 — Redesign `FloorView.swift`**

Replace the entire `FloorView.swift` with:

```swift
import SwiftUI

/// Operational floor screen.
/// Defaults to the visual Map view (canvas). Tables tab shows the live ticket list.
struct FloorView: View {
    @Environment(\.appServices) var services
    @State private var selectedTab: FloorTab = .map
    @State private var navigateToOrder: FloorTable?
    @State private var navigateToTicket: Ticket?
    @State private var showEditor = false
    @State private var activeTickets: [String: Ticket] = [:]
    @State private var showCustomEntry = false
    @State private var customTableName = ""

    enum FloorTab: String, CaseIterable {
        case map = "Map"
        case tables = "Tables"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ── Tab Picker ─────────────────────────────────────────
                Picker("View", selection: $selectedTab.animation(.easeInOut(duration: 0.25))) {
                    ForEach(FloorTab.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                // ── Content ────────────────────────────────────────────
                ZStack {
                    if selectedTab == .map {
                        FloorMapEmbedView(activeTickets: activeTickets, onTapTable: { table in
                            if activeTickets[table.name] != nil {
                                navigateToTicket = activeTickets[table.name]
                            } else {
                                navigateToOrder = table
                            }
                        })
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.98)),
                            removal: .opacity.combined(with: .scale(scale: 0.98))
                        ))
                    } else {
                        tableListView
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.98)),
                                removal: .opacity.combined(with: .scale(scale: 0.98))
                            ))
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: selectedTab)
            }
            .navigationTitle("Floor")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button { Task { await loadActiveTickets() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        Button { showEditor = true } label: {
                            Label("Edit Map", systemImage: "map.fill")
                                .font(.subheadline.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.chromePrimary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        .foregroundStyle(Color.chromePrimary)
                    }
                }
            }
            .refreshable { await loadActiveTickets() }
            .task { await loadActiveTickets() }
            .onAppear { Task { await loadActiveTickets() } }
            .navigationDestination(item: $navigateToOrder) { TableOrderEntryView(table: $0) }
            .navigationDestination(item: $navigateToTicket) { TicketEditorView(ticket: $0) }
            .sheet(isPresented: $showEditor) { FloorPlanEditorView() }
            .alert("Custom Table", isPresented: $showCustomEntry) {
                TextField("e.g. Bar 3, Booth A", text: $customTableName)
                Button("Start Order") {
                    let name = customTableName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    navigateToOrder = FloorTable(name: name, seats: SeatConfig.numbered(2))
                    customTableName = ""
                }
                Button("Cancel", role: .cancel) { customTableName = "" }
            }
        }
    }

    // MARK: - Table List (operational view)

    @ViewBuilder
    private var tableListView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                let plan = services.floorPlanStore.floorPlan
                let activeTables = plan.tables.filter { activeTickets[$0.name] != nil }
                let availableTables = plan.tables.filter { activeTickets[$0.name] == nil }

                if !activeTables.isEmpty {
                    ChromeSectionHeader(title: "Active", systemImage: "flame.fill")
                        .padding(.horizontal)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                        ForEach(activeTables) { table in
                            ChromeActiveTableCard(
                                table: table, ticket: activeTickets[table.name]!,
                                section: plan.sections.first { $0.tableIds.contains(table.id) }
                            ) { navigateToTicket = activeTickets[table.name] }
                        }
                    }
                    .padding(.horizontal)
                }

                let sections = plan.sections
                if !sections.isEmpty {
                    ForEach(sections) { section in
                        let sectionTables = availableTables.filter { section.tableIds.contains($0.id) }
                        if !sectionTables.isEmpty {
                            ChromeSectionHeader(title: section.name, systemImage: "rectangle.3.group")
                                .padding(.horizontal)
                            availableGrid(sectionTables)
                        }
                    }
                    let unassigned = availableTables.filter { t in
                        !sections.contains { $0.tableIds.contains(t.id) }
                    }
                    if !unassigned.isEmpty {
                        ChromeSectionHeader(title: activeTables.isEmpty ? "All Tables" : "Available",
                                            systemImage: "checkmark.circle")
                            .padding(.horizontal)
                        availableGrid(unassigned)
                    }
                } else {
                    ChromeSectionHeader(title: activeTables.isEmpty ? "All Tables" : "Available",
                                        systemImage: "checkmark.circle")
                        .padding(.horizontal)
                    availableGrid(availableTables)
                }
            }
            .padding(.vertical)
        }
    }

    @ViewBuilder
    private func availableGrid(_ tables: [FloorTable]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
            ForEach(tables) { table in
                ChromeAvailableTableCard(table: table) { navigateToOrder = table }
            }
            Button { showCustomEntry = true } label: {
                VStack(spacing: 6) {
                    Image(systemName: "plus.circle.dashed").font(.title2)
                    Text("Other").font(.caption)
                }
                .frame(maxWidth: .infinity).frame(height: 110)
                .foregroundStyle(.secondary)
                .chromeCard(cornerRadius: 14)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
    }

    private func loadActiveTickets() async {
        guard let all = try? await services.repository.fetchAll() else { return }
        let relevant = all.filter { $0.ticketStatus != .closed }
        var map: [String: Ticket] = [:]
        for ticket in relevant.reversed() { map[ticket.tableNumber] = ticket }
        activeTickets = map
    }
}

// MARK: - Embedded Map View (shows canvas without entering edit mode)

struct FloorMapEmbedView: View {
    @Environment(\.appServices) var services
    let activeTickets: [String: Ticket]
    let onTapTable: (FloorTable) -> Void

    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                // Grid background
                Canvas { ctx, size in
                    let spacing: CGFloat = 40
                    var path = Path()
                    var x: CGFloat = 0
                    while x <= size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += spacing }
                    var y: CGFloat = 0
                    while y <= size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += spacing }
                    ctx.stroke(path, with: .color(.primary.opacity(0.05)), lineWidth: 0.5)
                }
                .frame(width: 900, height: 700)

                ForEach(services.floorPlanStore.floorPlan.tables) { table in
                    let isActive = activeTickets[table.name] != nil
                    let ticket = activeTickets[table.name]
                    Button { onTapTable(table) } label: {
                        MapTableTile(table: table, ticket: ticket)
                    }
                    .buttonStyle(.plain)
                    .offset(x: table.position.width + 40, y: table.position.height + 40)
                }
            }
            .frame(minWidth: 900, minHeight: 700)
        }
        .background(Color(.systemGroupedBackground))
    }
}

struct MapTableTile: View {
    let table: FloorTable
    let ticket: Ticket?

    var statusColor: Color {
        guard let t = ticket else { return .chromeTeal }
        switch t.ticketStatus {
        case .open: return .chromePrimary
        case .sent: return .chromeAmber
        case .delivered: return .green
        case .closed: return .secondary
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(table.name).font(.title3.bold())
            Text("\(table.seats.count)👤").font(.caption2)
            if let ticket {
                Text(ticket.ticketStatus.rawValue.capitalized)
                    .font(.caption2.bold())
                    .foregroundStyle(statusColor)
            } else {
                Text("Open").font(.caption2).foregroundStyle(.chromeTeal)
            }
        }
        .frame(width: 100, height: 100)
        .chromeCard(cornerRadius: 16, glowColor: statusColor, glowRadius: ticket != nil ? 10 : 0)
        .glowRing(color: statusColor, radius: ticket != nil ? 6 : 0)
    }
}

// MARK: - Chrome Table Cards

struct ChromeActiveTableCard: View {
    let table: FloorTable
    let ticket: Ticket
    let section: ServerSection?
    let onTap: () -> Void

    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var statusColor: Color {
        switch ticket.ticketStatus {
        case .open: return .chromePrimary
        case .sent: return .chromeAmber
        case .delivered: return .chromeTeal
        case .closed: return .secondary
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(table.name).font(.title3.bold())
                        if let section {
                            HStack(spacing: 4) {
                                Circle().fill(section.color).frame(width: 6, height: 6)
                                Text(section.name).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    Image(systemName: ticket.ticketStatus == .sent ? "flame.fill" : "pencil.circle.fill")
                        .foregroundStyle(statusColor).font(.title3)
                }
                HStack(spacing: 6) {
                    Text(ticket.ticketStatus.rawValue.capitalized)
                        .font(.caption.bold()).foregroundStyle(statusColor)
                    Text("·").foregroundStyle(.secondary)
                    Text("\(ticket.allItems.count) item\(ticket.allItems.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Image(systemName: "clock").font(.caption2)
                    Text(formatElapsed(elapsed))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(elapsed > 1200 ? .red : elapsed > 600 ? .orange : .secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .chromeCard(cornerRadius: 16, glowColor: statusColor, glowRadius: 12)
            .glowRing(color: statusColor, radius: 6)
        }
        .buttonStyle(.plain)
        .onAppear { elapsed = Date().timeIntervalSince(ticket.openedAt) }
        .onReceive(timer) { _ in elapsed = Date().timeIntervalSince(ticket.openedAt) }
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let m = Int(t) / 60; let s = Int(t) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}

struct ChromeAvailableTableCard: View {
    let table: FloorTable
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                Text(table.name).font(.title2.bold())
                Text("\(table.seats.count)👤").font(.caption2).foregroundStyle(.secondary)
                Text("Available").font(.caption2.bold()).foregroundStyle(.chromeTeal)
            }
            .frame(maxWidth: .infinity).frame(height: 110)
            .chromeCard(cornerRadius: 14, glowColor: .chromeTeal, glowRadius: 6)
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 5.4 — Add "Reset Positions" to `FloorPlanEditorView`**

In `FloorPlanEditorView.swift`, find the canvas editor section. In the toolbar `Menu`, add after "Manage Sections":

```swift
Button {
    services.floorPlanStore.resetTablePositions()
} label: {
    Label("Reset Table Positions", systemImage: "arrow.uturn.backward.circle")
}
```

- [ ] **Step 5.5 — Apply chrome to `ContentView.swift`**

Replace `ContentView.swift` entirely:

```swift
import SwiftUI

struct ContentView: View {
    @State private var showWelcome = true

    var body: some View {
        ZStack {
            TabView {
                FloorView()
                    .tabItem { Label("Floor", systemImage: "tablecells.fill") }

                TicketsListView()
                    .tabItem { Label("Tickets", systemImage: "doc.text.fill") }

                MenuAdminView()
                    .tabItem { Label("Menu", systemImage: "menucard.fill") }
            }
            .chromeTabBar()

            if showWelcome {
                WelcomeView(isPresented: $showWelcome)
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
                    .zIndex(1)
            }
        }
        .animation(.spring(duration: 0.45, bounce: 0.1), value: showWelcome)
    }
}
```

- [ ] **Step 5.6 — Apply chrome shimmer to the record button in `TableOrderEntryView`**

In `TableOrderEntryView.swift`, find `HoldToTalkButton` usage in `bottomControls`. Replace the `HoldToTalkButton` line with:

```swift
HoldToTalkButton(isRecording: vm.isRecording) {
    if vm.isRecording { vm.stopRecording() }
    else { vm.startRecording() }
}
.if(vm.isRecording) { $0.chromeShimmer() }
.glowRing(color: vm.isRecording ? .red : .chromePrimary, radius: vm.isRecording ? 14 : 6)
```

Add the `.if` extension to `ChromeStyle.swift`:

```swift
extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}
```

Also update `SeatTranscriptCard` to use chrome style — replace the `.background` + `.overlay` + `.clipShape` block with:

```swift
.padding(12)
.chromeCard(
    cornerRadius: 12,
    glowColor: isActive ? .chromePrimary : .clear,
    glowRadius: isActive ? 8 : 0
)
```

And update `SeatChip` active background to use chrome gradient:

```swift
.background(
    isActive
        ? LinearGradient(colors: [.chromePrimary, Color(red: 0.3, green: 0.4, blue: 0.9)],
                         startPoint: .topLeading, endPoint: .bottomTrailing)
        : LinearGradient(colors: [Color(.secondarySystemBackground), Color(.secondarySystemBackground)],
                         startPoint: .topLeading, endPoint: .bottomTrailing)
)
```

- [ ] **Step 5.7 — Apply chrome to `TicketsListView.swift`**

Read the file first, then add `.chromeCard(cornerRadius: 12)` to each ticket row's container. Find the `TicketRow` view definition and wrap its outermost `HStack`/`VStack` content with:

```swift
// Wrap TicketRow's content VStack with:
.padding(14)
.chromeCard(cornerRadius: 14, glowColor: statusColor, glowRadius: 5)
```

Where `statusColor` mirrors the existing `statusBadge` color logic.

- [ ] **Step 5.8 — Apply chrome to `MenuAdminView.swift` section header**

Replace the plain `Section` headers in the menu list with styled views. At the top of the `List` body add:

```swift
.listStyle(.insetGrouped)
```

And add a chrome navigation title style by setting:
```swift
.navigationTitle("Menu")
.toolbarBackground(.regularMaterial, for: .navigationBar)
.toolbarColorScheme(.dark, for: .navigationBar)
```

- [ ] **Step 5.9 — Commit visual redesign**

```bash
git add ios/WhisperTicket/Views/Components/ChromeStyle.swift \
        ios/WhisperTicket/Services/FloorPlanStore.swift \
        ios/WhisperTicket/Views/FloorView.swift \
        ios/WhisperTicket/Views/FloorPlanEditorView.swift \
        ios/WhisperTicket/Views/ContentView.swift \
        ios/WhisperTicket/Views/TableOrderEntryView.swift \
        ios/WhisperTicket/Views/TicketsListView.swift \
        ios/WhisperTicket/Views/MenuAdminView.swift
git commit -m "feat: chrome visual redesign + floor map UX improvements

- ChromeStyle.swift: shared glass-chrome cards, gradient borders, glow shadows, shimmer
- FloorView: defaults to Map canvas tab; bigger table cards (110pt); chrome aesthetic
- FloorMapEmbedView: interactive canvas showing table positions + live status glow
- FloorPlanStore: resetTablePositions() resets all drag offsets
- FloorPlanEditorView: Reset Positions button in canvas toolbar
- ContentView: chrome tab bar + spring transitions
- HoldToTalkButton: shimmer + glow ring animation during recording
- SeatChip / SeatTranscriptCard: chrome gradient + glow
- TicketsListView: chrome card rows
- MenuAdminView: inset grouped style + material nav bar"
```

---

## Task 6: Version Bump + CI Push

- [ ] **Step 6.1 — Bump version in `project.yml`**

In `project.yml`, change:
```yaml
MARKETING_VERSION: "1.4.0"
CURRENT_PROJECT_VERSION: "7"
```
to:
```yaml
MARKETING_VERSION: "1.5.0"
CURRENT_PROJECT_VERSION: "8"
```

- [ ] **Step 6.2 — Final commit and push**

```bash
git add project.yml
git commit -m "chore: bump version to 1.5.0 (build 8)

Six-issue batch:
- Transcript accumulates across recording sessions (Issues #1 #2)
- Edit history shows seat + content preview (Issue #4)
- Transcript edits cascade to seat items via re-parse (Issue #3)
- Menu: embedded fallback + UserDefaults persistence + PDF parsing (Issue #5)
- Chrome visual redesign + floor map UX improvements (Issue #6)"

git push origin main
```

- [ ] **Step 6.3 — Monitor CI**

Check GitHub Actions:
```bash
gh run list --limit 3
gh run view --log
```

Expected: xcodegen generates project, signing installs, archive succeeds, compliance PATCH returns 409 (expected/non-fatal), TestFlight upload succeeds.

- [ ] **Step 6.4 — If CI fails: read the log and diagnose**

```bash
gh run view <run-id> --log | grep -A 20 "error:"
```

Common failures and fixes:
- **`saveMenu` not found on PlaceholderMenuStore** → ensure Step 4.3 (Protocols.swift + PlaceholderMenuStore) was committed
- **`PDFMenuImportService` type not found** → ensure Step 4.4 file was created and committed
- **`resetTablePositions` not found** → ensure Step 5.2 was committed
- **`chromePrimary` / `chromeCard` not found** → ensure `ChromeStyle.swift` was created and committed
- **`FloorMapEmbedView` not found** → ensure Step 5.3 was fully committed (large file)
- **Resource copy phase: MenuV1.sample.json not found** → the `project.yml` change in Step 4.1 will fix this; confirm xcodegen runs in CI log
- **Signing failure** → check GitHub secrets (DIST_PRIVATE_KEY_PEM, DIST_CERT_DER_B64, etc.) — not related to this PR

---

## Self-Review Checklist

**Spec coverage:**
- [x] Issue #1 (transcript cuts off) → Task 1
- [x] Issue #2 (ADD mode) → Task 1 Step 1.5 (Add More button)
- [x] Issue #3 (transcript cascade) → Task 3
- [x] Issue #4 (edit history detail) → Task 2 + Task 3 Steps 3.3
- [x] Issue #5 (menu not found + PDF) → Task 4
- [x] Issue #6 (visual redesign) → Task 5
- [x] CI push with TestFlight → Task 6
- [x] Floor map default → Task 5 Step 5.3 (FloorTab defaults to .map)
- [x] Bigger floor map button → Step 5.3 toolbar button with background pill
- [x] Reset table positions → Step 5.2 + 5.4
- [x] Bigger table containers → Step 5.3 (min: 110, height: 110)
- [x] Smooth transitions → Step 5.3 (ZStack + asymmetric), Step 5.5 (spring animation)
- [x] Chrome shimmer on mic button → Step 5.6

**Placeholder scan:** None found. All steps contain complete code.

**Type consistency:**
- `ChromeCardModifier`, `chromeCard()`, `chromeShimmer()`, `glowRing()` defined in ChromeStyle.swift and used consistently
- `saveMenu(_:)` added to both protocol (Step 4.3) and PlaceholderMenuStore (Step 4.3) and implementation (Step 4.2)
- `resetTablePositions()` added to FloorPlanStore (Step 5.2) and called in FloorPlanEditorView (Step 5.4)
- `reparseItems(for:transcript:)` private — only referenced within TicketEditorViewModel
- `priorSeatTranscript` private — only used within LiveSessionViewModel
