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
