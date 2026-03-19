import Foundation
import SwiftData

enum TicketStatus: String, Codable {
    case open = "OPEN"
    case sent = "SENT"
    case delivered = "DELIVERED"
    case closed = "CLOSED"
}

enum CourseFlag: String, Codable, CaseIterable, Hashable {
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
    var status: String
    var rawTranscript: String
    var notes: String
    @Relationship(deleteRule: .cascade) var guests: [GuestSeat]
    var coursePacingStates: [String: String]

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

    var totalTime: TimeInterval? {
        guard let closed = closedAt else { return nil }
        return closed.timeIntervalSince(openedAt)
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
    var course: String
    var notes: String
    var confidence: Double
    var hasAllergyFlag: Bool
    var allergyConfirmed: Bool
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
    var isNegation: Bool

    init(name: String, priceDelta: Double = 0, isNegation: Bool = false) {
        self.name = name
        self.priceDelta = priceDelta
        self.isNegation = isNegation
    }
}
