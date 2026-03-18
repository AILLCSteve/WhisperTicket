import Foundation

struct TicketDraft {
    var tableNumber: String
    var items: [DraftItem]
    var rawTranscript: String
    var consumedCursor: Int

    init(tableNumber: String) {
        self.tableNumber = tableNumber
        self.items = []
        self.rawTranscript = ""
        self.consumedCursor = 0
    }

    mutating func addItem(_ item: DraftItem) {
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
    var modifierNames: [String]
    var negations: [String]
    var course: CourseFlag
    var seatNumber: Int?
    var notes: String
    var confidence: Double
    var hasAllergyFlag: Bool
    var kitchenNoteTemplate: String?
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
