import Foundation
import Observation

@Observable
final class TicketEditorViewModel {
    var ticket: Ticket
    var isSaving = false
    var errorMessage: String? = nil
    var coursePacingStates: [CourseFlag: CoursePacingState] = [:]

    private let repository: TicketRepositoryProtocol

    init(ticket: Ticket, repository: TicketRepositoryProtocol) {
        self.ticket = ticket
        self.repository = repository
        for (key, value) in ticket.coursePacingStates {
            if let flag = CourseFlag(rawValue: key), let state = CoursePacingState(rawValue: value) {
                coursePacingStates[flag] = state
            }
        }
    }

    func sendToKitchen() async {
        ticket.sentToKitchenAt = Date()
        ticket.status = TicketStatus.sent.rawValue
        logEdit(type: "status_changed", summary: "Sent to kitchen")
        await save()
    }

    func markDelivered() async {
        ticket.deliveredAt = Date()
        ticket.status = TicketStatus.delivered.rawValue
        logEdit(type: "status_changed", summary: "Marked delivered")
        await save()
    }

    func closeTicket() async {
        ticket.closedAt = Date()
        ticket.status = TicketStatus.closed.rawValue
        logEdit(type: "status_changed", summary: "Ticket closed")
        await save()
    }

    func fireCourse(_ course: CourseFlag) async {
        coursePacingStates[course] = .fired
        ticket.coursePacingStates[course.rawValue] = CoursePacingState.fired.rawValue
        logEdit(type: "status_changed", summary: "Fired \(course.displayName)")
        await save()
    }

    func holdCourse(_ course: CourseFlag) async {
        coursePacingStates[course] = .holding
        ticket.coursePacingStates[course.rawValue] = CoursePacingState.holding.rawValue
        logEdit(type: "status_changed", summary: "Held \(course.displayName)")
        await save()
    }

    func removeItem(_ item: TicketItem, from seat: GuestSeat) async {
        seat.items.removeAll { $0.id == item.id }
        logEdit(type: "item_removed", seatNumber: seat.seatNumber,
                summary: "Removed "\(item.name)" from Seat \(seat.seatNumber)")
        do {
            try await repository.deleteItem(item)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateTranscript(_ text: String) async {
        ticket.rawTranscript = text
        logEdit(type: "transcript_set", summary: "Edited ticket transcript")
        await save()
    }

    func updateSeatTranscript(_ text: String, for seat: GuestSeat) async {
        seat.rawTranscript = text
        logEdit(type: "transcript_set", seatNumber: seat.seatNumber,
                summary: "Edited Seat \(seat.seatNumber) transcript")
        await save()
    }

    func updateItemNotes(_ item: TicketItem, notes: String) async {
        item.notes = notes
        logEdit(type: "notes_updated", summary: "Updated note on "\(item.name)"")
        await save()
    }

    func confirmAllergyItem(_ item: TicketItem) async {
        item.allergyConfirmed = true
        await save()
    }

    func moveItem(_ item: TicketItem, fromSeat: GuestSeat, toSeatNumber: Int) async {
        fromSeat.items.removeAll { $0.id == item.id }
        if let targetSeat = ticket.guests.first(where: { $0.seatNumber == toSeatNumber }) {
            targetSeat.items.append(item)
        } else {
            let newSeat = GuestSeat(seatNumber: toSeatNumber)
            newSeat.items.append(item)
            ticket.guests.append(newSeat)
        }
        logEdit(type: "item_moved", seatNumber: fromSeat.seatNumber,
                summary: "Moved "\(item.name)" from Seat \(fromSeat.seatNumber) → Seat \(toSeatNumber)")
        await save()
    }

    // MARK: - Edit History

    private func logEdit(type: String, seatNumber: Int = 0, summary: String) {
        let event = TicketEditEvent(eventType: type, seatNumber: seatNumber, summary: summary)
        ticket.editHistory.append(event)
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
