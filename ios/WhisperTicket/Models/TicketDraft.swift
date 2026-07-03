import Foundation

struct TicketDraft {
    var tableNumber: String
    var items: [DraftItem]
    var rawTranscript: String      // aggregate (last recorded); kept for compat
    var seatTranscripts: [Int: String]   // per-seat transcripts: seatNumber → text
    var consumedCursor: Int

    init(tableNumber: String) {
        self.tableNumber = tableNumber
        self.items = []
        self.rawTranscript = ""
        self.seatTranscripts = [:]
        self.consumedCursor = 0
    }

    /// Combined transcript of all seats, used as the ticket-level rawTranscript.
    var aggregateTranscript: String {
        seatTranscripts
            .sorted { $0.key < $1.key }
            .map { "Seat \($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    mutating func addItem(_ item: DraftItem) {
        // Dedup within the same seat only — different seats may legitimately order identical items.
        // Parser-produced items have seatNumber = nil until the VM stamps them, so
        // nil == nil prevents re-adding within one session, while nil != 1 allows cross-seat adds.
        let exists = items.contains { existing in
            existing.menuItemId == item.menuItemId &&
            existing.modifierNames == item.modifierNames &&
            existing.seatNumber == item.seatNumber
        }
        if !exists { items.append(item) }
    }
}

struct DraftItem: Identifiable {
    var id: String = UUID().uuidString
    var menuItemId: String
    var name: String
    var quantity: Int
    var modifierNames: [String]
    var negations: [String]
    var course: CourseFlag
    var seatNumber: Int?
    var notes: String
    var confidence: Double
    var hasAllergyFlag: Bool
    var kitchenNoteTemplate: String?

    /// When the parser matched this spoken phrase to more than one plausible menu
    /// item (e.g. "ham" → "Ham & Cheese Sandwich" vs "Turkey & Ham Sandwich"), the
    /// tentative best guess is used as `menuItemId`/`name` and the competing
    /// candidates (including the guess) are listed here so the UI can ask the user
    /// to confirm. Empty = unambiguous, no confirmation needed.
    var alternativeMenuItemIds: [String] = []

    var needsDisambiguation: Bool { !alternativeMenuItemIds.isEmpty }

    /// True for items that did not match any known menu entry —
    /// off-menu spoken requests, transcript fallbacks, and manually typed items.
    var isOffMenu: Bool {
        menuItemId.hasPrefix("offmenu_") ||
        menuItemId.hasPrefix("transcript_") ||
        menuItemId.hasPrefix("manual_")
    }
}

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
