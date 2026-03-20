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

    func deleteItem(_ item: TicketItem) async throws {
        modelContext.delete(item)
        try modelContext.save()
    }

    func deleteAll() async throws {
        let tickets = try modelContext.fetch(FetchDescriptor<Ticket>())
        for ticket in tickets { modelContext.delete(ticket) }
        try modelContext.save()
    }

    func createTicket(from draft: TicketDraft, serverId: String) async throws -> Ticket {
        let ticket = Ticket(
            tableNumber: draft.tableNumber,
            serverId: serverId,
            rawTranscript: draft.rawTranscript
        )

        let seatNumbers = Set(draft.items.compactMap { $0.seatNumber })
        if seatNumbers.isEmpty {
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
            // Unseated items go to seat 1
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
