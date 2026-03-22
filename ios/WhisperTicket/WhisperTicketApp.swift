import SwiftUI
import SwiftData
import AVFoundation

@main
struct WhisperTicketApp: App {
    let container: ModelContainer

    // Services — swap concrete types here to switch local → Supabase
    let audioCapture: AudioCaptureServiceProtocol = AudioCaptureService()
    let transcriptionService: TranscriptionServiceProtocol = SFSpeechTranscriptionService()
    let menuStore: MenuStoreProtocol = LocalBundleMenuStore()
    let parser: OrderParserProtocol = FuzzyMenuOrderParser()
    let upsellEngine: UpsellEngineProtocol = RuleBasedUpsellEngine()
    let floorPlanStore = FloorPlanStore()

    init() {
        do {
            container = try ModelContainer(
                for: Ticket.self, GuestSeat.self, TicketItem.self,
                    TicketModifier.self, TicketEditEvent.self
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        // Permission requests are deferred to .task{} below.
        // Calling them here (before the SwiftUI scene/window exists) causes a
        // crash on first launch because the OS permission dialog requires an
        // active UIWindowScene to present — which doesn't exist during App.init().
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(container)
                .environment(\.appServices, AppServices(
                    audioCapture: audioCapture,
                    transcriptionService: transcriptionService,
                    menuStore: menuStore,
                    parser: parser,
                    upsellEngine: upsellEngine,
                    repository: SwiftDataTicketRepository(modelContext: container.mainContext),
                    menuImporter: StubMenuImportService(),
                    floorPlanStore: floorPlanStore
                ))
                .task {
                    // Request permissions after the window/scene is ready.
                    // On first launch the OS shows permission dialogs here safely.
                    // On subsequent launches the callbacks fire immediately (cached state).
                    SFSpeechTranscriptionService.requestPermission { granted in
                        if !granted { print("⚠️ Speech recognition not authorized") }
                    }
                    AVAudioSession.sharedInstance().requestRecordPermission { granted in
                        if !granted { print("⚠️ Microphone not authorized") }
                    }
                    do {
                        try await menuStore.loadMenu()
                    } catch {
                        print("⚠️ Menu load failed: \(error)")
                        // Phase 2: propagate to UI via an @Observable app-level error state
                    }
                }
        }
    }
}

// MARK: - Service Container

struct AppServices {
    let audioCapture: AudioCaptureServiceProtocol
    let transcriptionService: TranscriptionServiceProtocol
    let menuStore: MenuStoreProtocol
    let parser: OrderParserProtocol
    let upsellEngine: UpsellEngineProtocol
    let repository: TicketRepositoryProtocol
    let menuImporter: MenuImportServiceProtocol
    let floorPlanStore: FloorPlanStore
}

// Placeholder used only as @Entry default — the real services are always injected
// by WhisperTicketApp before any view renders. If this fires, something is wrong.
private final class PlaceholderTicketRepository: TicketRepositoryProtocol {
    func fetchAll() async throws -> [Ticket] { [] }
    func fetchOpen() async throws -> [Ticket] { [] }
    func save(_ ticket: Ticket) async throws {}
    func delete(_ ticket: Ticket) async throws {}
    func deleteItem(_ item: TicketItem) async throws {}
    func deleteAll() async throws {}
    func createTicket(from draft: TicketDraft, serverId: String) async throws -> Ticket {
        fatalError("AppServices not injected into environment")
    }
}

private final class PlaceholderMenuStore: MenuStoreProtocol {
    var menu: MenuV1? = nil
    func loadMenu() async throws {}
    func findBestMatches(text: String, maxResults: Int) -> [(item: MenuItem, score: Double)] { [] }
    func item(byId id: String) -> MenuItem? { nil }
}

extension EnvironmentValues {
    @Entry var appServices: AppServices = AppServices(
        audioCapture: AudioCaptureService(),
        transcriptionService: SFSpeechTranscriptionService(),
        menuStore: PlaceholderMenuStore(),
        parser: FuzzyMenuOrderParser(),
        upsellEngine: RuleBasedUpsellEngine(),
        repository: PlaceholderTicketRepository(),
        menuImporter: StubMenuImportService(),
        floorPlanStore: FloorPlanStore()
    )
}
