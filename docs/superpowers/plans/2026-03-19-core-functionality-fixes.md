# Core Functionality Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the broken transcript→ticket pipeline, menu display, ticket closeout, order timing, and scaffold the menu upload feature so the app is fully usable end-to-end.

**Architecture:** Protocol-abstracted MVVM with @Observable ViewModels, SwiftData persistence, on-device ASR via SFSpeechRecognizer. All changes stay within existing layer boundaries. No new dependencies. POS-integration points are noted but not built yet.

**Tech Stack:** Swift 5.9, SwiftUI, SwiftData, AVAudioEngine, Speech.framework, Combine, iOS 17+

---

## Root Cause Summary (read before touching any code)

| Bug | Root Cause | Files Affected |
|-----|-----------|----------------|
| Transcript never converts to ticket | `stopRecording()` calls `cancellables.removeAll()` before `isFinal=true` segment arrives; also calls `recognitionTask.cancel()` so final result is never delivered | LiveSessionViewModel.swift, SFSpeechTranscriptionService.swift |
| Menu never shows after load | `LocalBundleMenuStore` is not `@Observable` — `menu` property changes don't trigger SwiftUI re-render | LocalBundleMenuStore.swift |
| Edit button always disabled | Button is gated on `draft.items.isEmpty`; if menu isn't loaded or parser found nothing, user is stuck | LiveSessionView.swift |
| rawTranscript always empty on tickets | `handleTranscriptionSegment` updates `transcript` but never `draft.rawTranscript` | LiveSessionViewModel.swift |
| Duplicate seat 1 (R6) | `createTicket` creates a seat-1 GuestSeat in both the seatNumbers loop AND the unseated-items block | SwiftDataTicketRepository.swift |
| Orphaned TicketItem (R8) | `removeItem` removes from relationship array but never calls `modelContext.delete(item)` | TicketEditorViewModel.swift |
| Error alert never dismisses (R10) | `.constant(errorMessage != nil)` is a read-only binding; tapping OK sets `errorMessage = nil` but binding never changes | MenuAdminView.swift |
| No ticket close | `TicketStatus.closed` exists in model but no VM method or UI button | TicketEditorViewModel.swift, TicketEditorView.swift |
| No total ticket time | `closedAt` exists but never set; no computed `totalTime` on Ticket | Ticket.swift, TicketEditorView.swift |

---

## File Map

| File | Change Type | What Changes |
|------|------------|--------------|
| `ios/WhisperTicket/Services/LocalBundleMenuStore.swift` | Modify | Add `@Observable` |
| `ios/WhisperTicket/ViewModels/LiveSessionViewModel.swift` | Modify | Fix stopRecording/finalization flow; set draft.rawTranscript |
| `ios/WhisperTicket/Views/LiveSessionView.swift` | Modify | Enable Edit button on any transcript; add error alert for createTicket failure |
| `ios/WhisperTicket/Services/SwiftDataTicketRepository.swift` | Modify | Fix duplicate seat-1 in createTicket |
| `ios/WhisperTicket/ViewModels/TicketEditorViewModel.swift` | Modify | Add closeTicket(); fix removeItem to delete from context; add markItemDelivered |
| `ios/WhisperTicket/Views/TicketEditorView.swift` | Modify | Add Close Ticket button; add total time display; add elapsed live timer |
| `ios/WhisperTicket/Models/Ticket.swift` | Modify | Add `totalTime` computed property |
| `ios/WhisperTicket/Views/MenuAdminView.swift` | Modify | Fix error alert binding; add import scaffold UI; improve empty state |
| `ios/WhisperTicket/Services/Protocols.swift` | Modify | Add `MenuImportServiceProtocol` |
| `ios/WhisperTicket/Services/MenuImportService.swift` | Create | OpenAI Vision stub + local PDF extraction scaffold |
| `ios/WhisperTicket/WhisperTicketApp.swift` | Modify | Wire MenuImportService into AppServices |

---

## Task 1: Fix LocalBundleMenuStore @Observable — Menu Displays After Load

**Files:**
- Modify: `ios/WhisperTicket/Services/LocalBundleMenuStore.swift`

### Why this must go first
Every other feature depends on the menu. If `LocalBundleMenuStore` is not `@Observable`, SwiftUI views never re-render when `menu` changes from nil to loaded. The fuzzy parser also silently returns an empty draft because `menuStore.menu` is nil at parse time.

- [ ] **Step 1: Add @Observable and @MainActor**

Open `ios/WhisperTicket/Services/LocalBundleMenuStore.swift`. Replace the class declaration and `loadMenu` to be observation-aware:

```swift
import Foundation
import Observation

@Observable
final class LocalBundleMenuStore: MenuStoreProtocol {
    private(set) var menu: MenuV1?
    private var itemIndex: [String: MenuItem] = [:]
    private var searchIndex: [(tokens: [String], item: MenuItem)] = []

    func loadMenu() async throws {
        guard let url = Bundle.main.url(forResource: "MenuV1.sample", withExtension: "json") else {
            throw MenuStoreError.fileNotFound
        }
        let data = try Data(contentsOf: url)
        let loaded = try JSONDecoder().decode(MenuV1.self, from: data)
        await MainActor.run {
            self.menu = loaded
            self.buildIndex(from: loaded)
        }
    }
    // ... rest of the file unchanged
}
```

**Important**: The `@Observable` macro synthesises `_$observationRegistrar` and wraps property accesses. `private(set) var menu` becomes observable automatically. No manual `willSet`/`didSet` needed.

- [ ] **Step 2: Fix WhisperTicketApp to propagate loadMenu errors to UI**

In `ios/WhisperTicket/WhisperTicketApp.swift`, change the `.task` block from `try?` to a proper handler:

```swift
.task {
    do {
        try await menuStore.loadMenu()
    } catch {
        print("⚠️ Menu load failed: \(error)")
        // Phase 2: propagate to UI via an @Observable app-level error state
    }
}
```

- [ ] **Step 3: Verify build compiles — no protocol conformance errors**

`MenuStoreProtocol` requires `var menu: MenuV1? { get }`. The `@Observable` macro exposes `menu` as a get-only property from outside. Confirm protocol conformance still satisfied. If `MenuStoreProtocol` is `AnyObject`, `@Observable final class` satisfies that.

- [ ] **Step 4: Commit**

```bash
git add ios/WhisperTicket/Services/LocalBundleMenuStore.swift ios/WhisperTicket/WhisperTicketApp.swift
git commit -m "fix: make LocalBundleMenuStore @Observable so menu displays after async load"
```

---

## Task 2: Fix ASR Finalization — Transcript Converts to Draft on Button Release

**Files:**
- Modify: `ios/WhisperTicket/ViewModels/LiveSessionViewModel.swift`

### Root cause detail
`stopRecording()` calls `cancellables.removeAll()` synchronously, which tears down the subscription to `transcriptionPublisher()` BEFORE the `isFinal=true` segment arrives. `SFSpeechTranscriptionService.stopTranscribing()` also calls `recognitionTask.cancel()` (not `finish()`), which kills the task without delivering a final result.

### Fix strategy
Split "stop audio" from "finalize transcription":
1. `stopRecording()` → stops audio capture only, sets `isRecording=false`, starts a 3-second safety timeout
2. Keep the transcription subscription alive
3. SFSpeechRecognizer detects silence after audio stops → sends `isFinal=true` naturally
4. `handleTranscriptionSegment` detects `isFinal=true` → parses draft → calls `finalizeTranscription()`
5. If `isFinal` never arrives within 3s, the timeout fires `finalizeTranscription()` with whatever transcript was accumulated

- [ ] **Step 1: Add `isFinalizingTranscription` state and `finalizationTimer` to LiveSessionViewModel**

```swift
// Add these properties to LiveSessionViewModel:
var isFinalizingTranscription = false   // shows "Processing…" indicator in UI
private var finalizationTimer: AnyCancellable?
private var transcriptionCancellable: AnyCancellable?  // separate from main cancellables
```

- [ ] **Step 2: Rewrite startRecording() to keep transcription subscription separate**

```swift
func startRecording() {
    do {
        try audioCapture.startCapture()
        let audioPublisher = audioCapture.audioBufferPublisher()
        try transcriptionService.startTranscribing(audioPublisher: audioPublisher)
        draft.consumedCursor = 0
        isRecording = true

        // Store transcription sub separately so stopRecording() doesn't kill it
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

- [ ] **Step 3: Rewrite stopRecording() — stop audio only, keep transcription alive**

```swift
func stopRecording() {
    audioCapture.stopCapture()
    isRecording = false
    isFinalizingTranscription = true
    noiseLevel = 0.0
    showNoisyEnvironmentWarning = false
    cancellables.removeAll()   // kills noise timer etc., NOT transcription sub

    // Safety timeout: if isFinal never arrives within 3s, finalize anyway
    finalizationTimer = Timer.publish(every: 3.0, on: .main, in: .common)
        .autoconnect()
        .first()
        .sink { [weak self] _ in self?.finalizeTranscription() }
}
```

- [ ] **Step 4: Add finalizeTranscription() and update handleTranscriptionSegment**

```swift
private func handleTranscriptionSegment(_ segment: TranscriptionSegment) {
    transcript = segment.text
    draft.rawTranscript = segment.text   // FIX: was never set before

    if let macro = parser.detectMacro(in: segment.text) {
        detectedMacro = macro
    }

    guard let menu = menuStore.menu else {
        // Menu not loaded: still update transcript so user can see it
        if segment.isFinal { finalizeTranscription() }
        return
    }

    let updatedDraft = parser.parseDraft(transcript: segment.text, existingDraft: draft, menu: menu)
    draft = updatedDraft
    draft.rawTranscript = segment.text   // keep in sync after parse

    let existingIds = Set(allergyItemsPendingConfirm.map { $0.id })
    let newAllergyItems = draft.items.filter { $0.hasAllergyFlag && !existingIds.contains($0.id) }
    allergyItemsPendingConfirm.append(contentsOf: newAllergyItems)

    refreshUpsells()

    if segment.isFinal { finalizeTranscription() }
}

private func finalizeTranscription() {
    finalizationTimer?.cancel()
    finalizationTimer = nil
    transcriptionCancellable?.cancel()
    transcriptionCancellable = nil
    transcriptionService.stopTranscribing()
    isFinalizingTranscription = false
}
```

- [ ] **Step 5: Commit**

```bash
git add ios/WhisperTicket/ViewModels/LiveSessionViewModel.swift
git commit -m "fix: preserve ASR subscription after mic release to receive isFinal segment"
```

---

## Task 3: Fix Edit Button + Create Ticket Error Handling in LiveSessionView

**Files:**
- Modify: `ios/WhisperTicket/Views/LiveSessionView.swift`

### Problems
1. Edit button is `.disabled(vm.draft.items.isEmpty)` — if menu wasn't loaded, items are always empty even with a long transcript. User is stuck.
2. `confirmAndNavigate` uses `try?` — silently fails, user sees nothing.
3. No "processing" indicator while finalizing transcription.

- [ ] **Step 1: Change Edit button disabled condition**

Enable Edit whenever there's any transcript text (even with 0 parsed items — user can still see the ticket and manually note things):

```swift
// Before:
.disabled(vm.draft.items.isEmpty)

// After:
.disabled(vm.transcript.isEmpty && vm.draft.items.isEmpty)
```

- [ ] **Step 2: Add @State for createTicket error and show alert**

```swift
// Add to LiveSessionView:
@State private var createTicketError: String? = nil
```

Update `confirmAndNavigate`:

```swift
private func confirmAndNavigate(vm: LiveSessionViewModel) async {
    do {
        let ticket = try await services.repository.createTicket(
            from: vm.draft, serverId: "local_server"
        )
        navigateToEditor = ticket
    } catch {
        createTicketError = "Could not create ticket: \(error.localizedDescription)"
    }
}
```

Add alert to the view body (inside the `if let vm` block, alongside the existing `.sheet`):

```swift
.alert("Error", isPresented: Binding(
    get: { createTicketError != nil },
    set: { if !$0 { createTicketError = nil } }
)) {
    Button("OK") { createTicketError = nil }
} message: {
    Text(createTicketError ?? "")
}
```

- [ ] **Step 3: Add "Finalizing…" indicator while isFinalizingTranscription is true**

In the controls bar section, just above the HStack with the buttons:

```swift
if vm.isFinalizingTranscription {
    HStack(spacing: 8) {
        ProgressView()
        Text("Processing speech…")
            .font(.caption).foregroundStyle(.secondary)
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add ios/WhisperTicket/Views/LiveSessionView.swift
git commit -m "fix: enable Edit on any transcript, show createTicket error, add finalization indicator"
```

---

## Task 4: Fix Duplicate Seat 1 in createTicket (R6)

**Files:**
- Modify: `ios/WhisperTicket/Services/SwiftDataTicketRepository.swift`

### Root cause
When `seatNumbers` is non-empty AND there are unseated items, the code creates a second `GuestSeat(seatNumber: 1)` even though seat 1 might already have been created in the loop above.

- [ ] **Step 1: Replace the unseated-items block to reuse existing seat 1**

```swift
// Replace the final unseated block:
let unseated = draft.items.filter { $0.seatNumber == nil }
if !unseated.isEmpty {
    // Reuse seat 1 if it was already created; otherwise create it
    if let existingSeat1 = ticket.guests.first(where: { $0.seatNumber == 1 }) {
        for draftItem in unseated {
            let item = buildTicketItem(from: draftItem)
            existingSeat1.items.append(item)
            modelContext.insert(item)
        }
    } else {
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
```

- [ ] **Step 2: Commit**

```bash
git add ios/WhisperTicket/Services/SwiftDataTicketRepository.swift
git commit -m "fix: reuse existing seat 1 for unseated items instead of creating duplicate GuestSeat"
```

---

## Task 5: Fix Orphaned TicketItem on removeItem (R8)

**Files:**
- Modify: `ios/WhisperTicket/ViewModels/TicketEditorViewModel.swift`

### Root cause
`removeItem` removes the item from the relationship array (`seat.items.removeAll`) but never calls `modelContext.delete(item)`. The item remains in the SwiftData context, consuming memory and potentially reappearing.

The ViewModel doesn't have a direct `ModelContext` reference — it goes through the repository. We need to either:
a) Add `delete(item)` to `TicketRepositoryProtocol` and `SwiftDataTicketRepository`
b) Or pass the context into the VM

Option (a) is cleaner and keeps the repository as the single DB gateway (better for POS integration later).

- [ ] **Step 1: Add deleteItem to TicketRepositoryProtocol**

In `ios/WhisperTicket/Services/Protocols.swift`, add to `TicketRepositoryProtocol`:

```swift
protocol TicketRepositoryProtocol {
    func fetchAll() async throws -> [Ticket]
    func fetchOpen() async throws -> [Ticket]
    func save(_ ticket: Ticket) async throws
    func delete(_ ticket: Ticket) async throws
    func deleteItem(_ item: TicketItem) async throws      // NEW
    func createTicket(from draft: TicketDraft, serverId: String) async throws -> Ticket
}
```

- [ ] **Step 2: Implement deleteItem in SwiftDataTicketRepository**

```swift
func deleteItem(_ item: TicketItem) async throws {
    modelContext.delete(item)
    try modelContext.save()
}
```

- [ ] **Step 3: Update removeItem in TicketEditorViewModel**

```swift
func removeItem(_ item: TicketItem, from seat: GuestSeat) async {
    seat.items.removeAll { $0.id == item.id }
    do {
        try await repository.deleteItem(item)
    } catch {
        errorMessage = error.localizedDescription
    }
}
```

- [ ] **Step 4: Update PlaceholderTicketRepository in WhisperTicketApp.swift**

```swift
private final class PlaceholderTicketRepository: TicketRepositoryProtocol {
    // ... existing methods ...
    func deleteItem(_ item: TicketItem) async throws {}
}
```

- [ ] **Step 5: Commit**

```bash
git add ios/WhisperTicket/Services/Protocols.swift \
        ios/WhisperTicket/Services/SwiftDataTicketRepository.swift \
        ios/WhisperTicket/ViewModels/TicketEditorViewModel.swift \
        ios/WhisperTicket/WhisperTicketApp.swift
git commit -m "fix: delete TicketItem from SwiftData context when removing from ticket (R8)"
```

---

## Task 6: Add Close Ticket + Full Timing Display

**Files:**
- Modify: `ios/WhisperTicket/Models/Ticket.swift`
- Modify: `ios/WhisperTicket/ViewModels/TicketEditorViewModel.swift`
- Modify: `ios/WhisperTicket/Views/TicketEditorView.swift`

### What to build
- `closeTicket()` method on VM: sets `closedAt = Date()`, status = `.closed`
- `totalTime` computed property on `Ticket`: `closedAt - openedAt`
- Display in TicketEditorView: Time to Send, Time to Deliver, Total Time
- Elapsed time label for open tickets (live-updating, so users can see how long the table has been waiting)
- "Close Ticket" button in Actions section (enabled when status is `.delivered`)
- POS integration note: `closedAt` will map to the "check closed" event in Toast/Square

- [ ] **Step 1: Add totalTime to Ticket.swift**

```swift
// In Ticket, after timeToDeliver:
var totalTime: TimeInterval? {
    guard let closed = closedAt else { return nil }
    return closed.timeIntervalSince(openedAt)
}
```

- [ ] **Step 2: Add closeTicket() to TicketEditorViewModel**

```swift
func closeTicket() async {
    ticket.closedAt = Date()
    ticket.status = TicketStatus.closed.rawValue
    await save()
}
```

- [ ] **Step 3: Update TicketEditorView header section + actions**

In the header `Section`, after `timeToDeliver` display:

```swift
if let totalTime = ticket.totalTime {
    LabeledContent("Total Time", value: formatInterval(totalTime))
}
// Elapsed time for open/sent tickets (live updating):
if ticket.ticketStatus == .open || ticket.ticketStatus == .sent {
    ElapsedTimeLabel(since: ticket.openedAt)
}
```

In the Actions `Section`, after "Mark Delivered":

```swift
Button("Close Ticket") { Task { await vm.closeTicket() } }
    .foregroundStyle(.red)
    .disabled(ticket.ticketStatus != .delivered)
```

- [ ] **Step 4: Add ElapsedTimeLabel component to TicketEditorView.swift**

```swift
struct ElapsedTimeLabel: View {
    let since: Date
    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        LabeledContent("Elapsed") {
            Text(formatInterval(elapsed))
                .foregroundStyle(elapsed > 1200 ? .red : elapsed > 600 ? .orange : .primary)
        }
        .onAppear { elapsed = Date().timeIntervalSince(since) }
        .onReceive(timer) { _ in elapsed = Date().timeIntervalSince(since) }
    }

    private func formatInterval(_ interval: TimeInterval) -> String {
        "\(Int(interval / 60))m \(Int(interval) % 60)s"
    }
}
```

- [ ] **Step 5: Commit**

```bash
git add ios/WhisperTicket/Models/Ticket.swift \
        ios/WhisperTicket/ViewModels/TicketEditorViewModel.swift \
        ios/WhisperTicket/Views/TicketEditorView.swift
git commit -m "feat: add closeTicket, total time, and live elapsed time display"
```

---

## Task 7: Fix MenuAdminView Error Alert (R10)

**Files:**
- Modify: `ios/WhisperTicket/Views/MenuAdminView.swift`

### Root cause
`.alert("Error", isPresented: .constant(errorMessage != nil))` creates a read-only Binding — tapping OK can't set it to false. Also the `try?` in Reload swallows errors into nowhere.

- [ ] **Step 1: Replace the error alert with a proper Binding**

```swift
.alert("Error", isPresented: Binding(
    get: { errorMessage != nil },
    set: { if !$0 { errorMessage = nil } }
)) {
    Button("OK") { errorMessage = nil }
} message: {
    Text(errorMessage ?? "")
}
```

- [ ] **Step 2: Fix the Reload button to capture errors**

```swift
Button("Reload") {
    Task {
        isLoading = true
        do {
            try await services.menuStore.loadMenu()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
```

- [ ] **Step 3: Improve the empty state message**

```swift
ContentUnavailableView(
    "No Menu Loaded",
    systemImage: "menucard",
    description: Text("Tap Reload to load the demo menu, or use Import to add a menu from a PDF or image.")
)
```

- [ ] **Step 4: Commit**

```bash
git add ios/WhisperTicket/Views/MenuAdminView.swift
git commit -m "fix: MenuAdminView error alert uses real Binding, Reload captures errors (R10)"
```

---

## Task 8: Menu Import Scaffold (Protocol + Stub + File Picker UI)

**Files:**
- Modify: `ios/WhisperTicket/Services/Protocols.swift`
- Create: `ios/WhisperTicket/Services/MenuImportService.swift`
- Modify: `ios/WhisperTicket/WhisperTicketApp.swift`
- Modify: `ios/WhisperTicket/Views/MenuAdminView.swift`

### What to build now vs later
- **Now**: Protocol, stub that simulates async work, file picker UI in MenuAdminView, wiring in AppServices. The user can pick a PDF or image; the stub returns a descriptive "not yet connected" result. This scaffolds the full flow.
- **Later (Phase 2)**: Replace stub with real `OpenAIMenuImportService` that calls Vision API and returns `MenuV1` JSON. The PDF at `Menus/applebees-menu-and-prices.pdf` is the test fixture.

### POS integration note
`MenuImportServiceProtocol` is intentionally broad. Phase 2 will add `importFromPOSSystem(restaurantId:)` to this protocol for Toast/Square menu sync.

- [ ] **Step 1: Add MenuImportServiceProtocol to Protocols.swift**

```swift
// Menu import result — either a parsed menu or an error with raw response for debugging
enum MenuImportResult {
    case success(MenuV1)
    case failure(String)      // human-readable error; preserve raw AI response for debugging
}

protocol MenuImportServiceProtocol {
    /// Import a menu from a PDF or image file at the given URL.
    /// Implementations should send the file to an AI service (e.g., OpenAI Vision)
    /// and parse the response into MenuV1 format.
    func importMenu(from fileURL: URL, fileType: MenuImportFileType) async -> MenuImportResult
}

enum MenuImportFileType: String {
    case pdf
    case image    // JPEG, PNG, HEIC
}
```

- [ ] **Step 2: Create MenuImportService.swift with stub**

Create `ios/WhisperTicket/Services/MenuImportService.swift`:

```swift
import Foundation

/// Stub implementation — returns a placeholder result.
/// Replace with OpenAIMenuImportService in Phase 2:
///   1. Read file data
///   2. For PDF: extract pages as images (PDFKit)
///   3. POST to https://api.openai.com/v1/chat/completions with vision model
///   4. System prompt instructs model to return strict MenuV1 JSON
///   5. Parse response into MenuV1
///   6. Return .success(menu) or .failure(rawResponse)
final class StubMenuImportService: MenuImportServiceProtocol {
    func importMenu(from fileURL: URL, fileType: MenuImportFileType) async -> MenuImportResult {
        // Simulate async work
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        return .failure(
            "Menu import not yet connected. File received: \(fileURL.lastPathComponent). " +
            "Phase 2: wire OpenAIMenuImportService here with your API key."
        )
    }
}
```

- [ ] **Step 3: Add menuImportService to AppServices and wire in WhisperTicketApp**

In `AppServices` struct:

```swift
struct AppServices {
    let audioCapture: AudioCaptureServiceProtocol
    let transcriptionService: TranscriptionServiceProtocol
    let menuStore: MenuStoreProtocol
    let parser: OrderParserProtocol
    let upsellEngine: UpsellEngineProtocol
    let repository: TicketRepositoryProtocol
    let menuImporter: MenuImportServiceProtocol    // NEW
}
```

In `WhisperTicketApp.body`:

```swift
.environment(\.appServices, AppServices(
    audioCapture: audioCapture,
    transcriptionService: transcriptionService,
    menuStore: menuStore,
    parser: parser,
    upsellEngine: upsellEngine,
    repository: SwiftDataTicketRepository(modelContext: container.mainContext),
    menuImporter: StubMenuImportService()    // NEW
))
```

Update the `@Entry` default in the `EnvironmentValues` extension too:

```swift
@Entry var appServices: AppServices = AppServices(
    audioCapture: AudioCaptureService(),
    transcriptionService: SFSpeechTranscriptionService(),
    menuStore: PlaceholderMenuStore(),
    parser: FuzzyMenuOrderParser(),
    upsellEngine: RuleBasedUpsellEngine(),
    repository: PlaceholderTicketRepository(),
    menuImporter: StubMenuImportService()    // NEW
)
```

- [ ] **Step 4: Add Import button + file picker to MenuAdminView**

Add these state variables to `MenuAdminView`:

```swift
@State private var showImportPicker = false
@State private var isImporting = false
@State private var importResult: String? = nil
```

Add to the toolbar alongside "Reload":

```swift
ToolbarItem(placement: .secondaryAction) {
    Button {
        showImportPicker = true
    } label: {
        Label("Import Menu", systemImage: "square.and.arrow.down")
    }
    .disabled(isImporting)
}
```

Add `.fileImporter` modifier:

```swift
.fileImporter(
    isPresented: $showImportPicker,
    allowedContentTypes: [.pdf, .image, .jpeg, .png],
    allowsMultipleSelection: false
) { result in
    switch result {
    case .success(let urls):
        guard let url = urls.first else { return }
        let fileType: MenuImportFileType = url.pathExtension.lowercased() == "pdf" ? .pdf : .image
        Task {
            isImporting = true
            let outcome = await services.menuImporter.importMenu(from: url, fileType: fileType)
            switch outcome {
            case .success(let menu):
                // Phase 2: save to menuStore and reload
                importResult = "Imported: \(menu.categories.count) categories, \(menu.categories.flatMap { $0.items }.count) items"
            case .failure(let message):
                importResult = message
            }
            isImporting = false
        }
    case .failure(let error):
        errorMessage = error.localizedDescription
    }
}
.alert("Import Result", isPresented: Binding(
    get: { importResult != nil },
    set: { if !$0 { importResult = nil } }
)) {
    Button("OK") { importResult = nil }
} message: {
    Text(importResult ?? "")
}
```

Also add an import progress overlay when `isImporting`:

```swift
// In the Group body, add after the else branch:
if isImporting {
    ProgressView("Importing menu…")
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
}
```

- [ ] **Step 5: Commit**

```bash
git add ios/WhisperTicket/Services/Protocols.swift \
        ios/WhisperTicket/Services/MenuImportService.swift \
        ios/WhisperTicket/WhisperTicketApp.swift \
        ios/WhisperTicket/Views/MenuAdminView.swift
git commit -m "feat: scaffold menu import (PDF/image → AI → MenuV1) with stub + file picker UI"
```

---

## Task 9: Add Demo Menu to Menus/ and Verify Bundle Resource

**Files:**
- No code changes — verify existing wiring

The user has placed `Menus/applebees-menu-and-prices.pdf` in the project root. The existing bundle menu `ios/WhisperTicket/Resources/MenuV1.sample.json` is already referenced in `project.yml` as a resource. With Task 1 done, the demo menu should load and display automatically.

- [ ] **Step 1: Confirm MenuV1.sample.json is in project.yml resources**

Check `project.yml`:
```yaml
resources:
  - path: ios/WhisperTicket/Resources/MenuV1.sample.json
  - path: ios/WhisperTicket/Assets.xcassets
```
This is already correct. No change needed.

- [ ] **Step 2: Verify the Applebee's PDF path is correct for future import scaffold**

The file is at `Menus/applebees-menu-and-prices.pdf` relative to the project root. This is NOT bundled (and shouldn't be — it's just a test fixture for the upload flow). When the user picks a file via the import picker, they'll navigate to the Files app and select it there.

- [ ] **Step 3: Commit**

```bash
git add Menus/
git commit -m "chore: track Applebees PDF as test fixture for menu import scaffold"
```

---

## Task 10: Push to TestFlight

- [ ] **Step 1: Verify all files compile (check for missing protocol conformances)**

The key conformance chain to verify:
- `PlaceholderTicketRepository` now needs `deleteItem(_:)` (added in Task 5)
- `AppServices` struct now has 7 fields (added `menuImporter`) — all callsites updated
- `LocalBundleMenuStore` is `@Observable` — Xcode may warn about `@Observable` + protocol synthesis; confirm no redeclaration errors

- [ ] **Step 2: Push**

```bash
git push origin main
```

- [ ] **Step 3: Watch CI**

```bash
gh run watch --repo AILLCSteve/WhisperTicket
```

Expected: green in ~2.5 minutes. TestFlight build appears after 10–15 min Apple processing.

---

## Known Limitations / Deferred

| Item | Status | When |
|------|--------|------|
| `repeatLastOrder` macro needs `previousDraft` passed from somewhere | Deferred | Phase 2: store last completed draft in app state |
| `splitCheck` macro is a no-op | Deferred | Phase 2: POS integration |
| `draggedFromSeatNumber` never set in SeatMapView (R9) | Deferred | Low priority |
| No XCTest targets | Deferred | Phase 2: add unit tests for parser and repository |
| OpenAI Vision integration for real menu import | Phase 2 | Needs API key wiring |
| `fetchOpen()` on TicketsListViewModel not called | Minor | TicketsListViewModel.loadTickets() uses fetchAll() — works fine but wastes a query |

---

## POS Integration Notes (for future Toast/Square/Clover work)

Every touch point that will matter for POS integration is marked here:

- **`createTicket`** → maps to "create check" in Toast POS API. `ticket.id` will become the POS check ID.
- **`sendToKitchen`** → maps to "send order to kitchen display" / KDS fire event.
- **`markDelivered`** → maps to "course delivered" event.
- **`closeTicket`** → maps to "close check" / payment event. `closedAt` = check close time.
- **`MenuImportServiceProtocol`** → Phase 2 adds `importFromPOSMenu(restaurantId:)` to sync menu directly from Toast's menu management.
- **`restaurantId` and `serverId`** on `Ticket` — already placeholder-ready for multi-tenant Supabase + POS auth context.
- **`tableNumber`** — string format already accommodates Toast's table naming conventions (e.g., "101", "Bar-3").
