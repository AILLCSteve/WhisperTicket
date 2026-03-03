import Foundation
import Observation

@Observable
final class TableSelectViewModel {
    var tableNumber: String = ""
    var recentTables: [String] = []
    var isStartingSession = false

    private let repository: TicketRepositoryProtocol

    init(repository: TicketRepositoryProtocol) {
        self.repository = repository
    }

    func loadRecentTables() async {
        let tickets = (try? await repository.fetchAll()) ?? []
        let tables = tickets.map { $0.tableNumber }
        var seen = Set<String>()
        recentTables = tables.filter { seen.insert($0).inserted }.prefix(10).map { $0 }
    }

    func selectTable(_ number: String) {
        tableNumber = number
    }
}
