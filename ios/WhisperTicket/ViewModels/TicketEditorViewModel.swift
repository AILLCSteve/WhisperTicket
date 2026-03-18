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
        await save()
    }

    func markDelivered() async {
        ticket.deliveredAt = Date()
        ticket.status = TicketStatus.delivered.rawValue
        await save()
    }

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
