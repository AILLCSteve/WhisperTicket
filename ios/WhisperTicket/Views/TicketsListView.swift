import SwiftUI

struct TicketsListView: View {
    @Environment(\.appServices) var services
    @State private var vm: TicketsListViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let vm {
                    List {
                        if !vm.openTickets.isEmpty {
                            Section("Open") {
                                ForEach(vm.openTickets) { ticket in
                                    NavigationLink(destination: TicketEditorView(ticket: ticket)) {
                                        TicketRow(ticket: ticket)
                                    }
                                }
                            }
                        }
                        if !vm.completedTickets.isEmpty {
                            Section("Completed") {
                                ForEach(vm.completedTickets) { ticket in
                                    NavigationLink(destination: TicketEditorView(ticket: ticket)) {
                                        TicketRow(ticket: ticket)
                                    }
                                }
                                .onDelete { offsets in
                                    let tickets = offsets.map { vm.completedTickets[$0] }
                                    for t in tickets { Task { await vm.deleteTicket(t) } }
                                }
                            }
                        }
                        if vm.openTickets.isEmpty && vm.completedTickets.isEmpty {
                            ContentUnavailableView(
                                "No Tickets",
                                systemImage: "doc.text",
                                description: Text("Start an order from the Tables tab.")
                            )
                        }
                    }
                    .refreshable { await vm.loadTickets() }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Tickets")
            .task {
                let newVm = TicketsListViewModel(repository: services.repository)
                vm = newVm
                await newVm.loadTickets()
            }
        }
    }
}

struct TicketRow: View {
    let ticket: Ticket

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Table \(ticket.tableNumber)").fontWeight(.bold)
                Spacer()
                StatusBadge(status: ticket.ticketStatus)
            }
            Text("\(ticket.allItems.count) item(s)")
                .font(.caption).foregroundStyle(.secondary)
            if let timeToSend = ticket.timeToSend {
                Text("Sent in \(Int(timeToSend / 60))m \(Int(timeToSend) % 60)s")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct StatusBadge: View {
    let status: TicketStatus
    var body: some View {
        Text(status.rawValue)
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(statusColor.opacity(0.15))
            .foregroundStyle(statusColor)
            .clipShape(Capsule())
    }
    var statusColor: Color {
        switch status {
        case .open: return .blue
        case .sent: return .orange
        case .delivered: return .green
        case .closed: return .secondary
        }
    }
}
