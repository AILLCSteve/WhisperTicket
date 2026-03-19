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
                            Section {
                                ForEach(vm.openTickets) { ticket in
                                    NavigationLink(destination: TicketEditorView(ticket: ticket)) {
                                        TicketRow(ticket: ticket)
                                    }
                                }
                            } header: {
                                Label("Open", systemImage: "circle.fill")
                                    .foregroundStyle(.blue)
                            }
                        }

                        if !vm.completedTickets.isEmpty {
                            Section {
                                ForEach(vm.completedTickets) { ticket in
                                    NavigationLink(destination: TicketEditorView(ticket: ticket)) {
                                        TicketRow(ticket: ticket)
                                    }
                                }
                                .onDelete { offsets in
                                    let tickets = offsets.map { vm.completedTickets[$0] }
                                    for t in tickets { Task { await vm.deleteTicket(t) } }
                                }
                            } header: {
                                Label("Completed", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if vm.openTickets.isEmpty && vm.completedTickets.isEmpty {
                            ContentUnavailableView(
                                "No Tickets",
                                systemImage: "doc.text",
                                description: Text("Start an order from the Floor tab.")
                            )
                        }
                    }
                    .refreshable { await vm.loadTickets() }
                    // Refresh every time the tab appears so newly-created tickets show immediately
                    .onAppear { Task { await vm.loadTickets() } }
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
    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Table \(ticket.tableNumber)").fontWeight(.bold)
                Spacer()
                StatusBadge(status: ticket.ticketStatus)
            }

            HStack(spacing: 12) {
                Label("\(ticket.allItems.count) item\(ticket.allItems.count == 1 ? "" : "s")",
                      systemImage: "list.bullet")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if ticket.ticketStatus == .open || ticket.ticketStatus == .sent {
                    Label(formatElapsed(elapsed), systemImage: "clock")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(elapsed > 1200 ? .red : elapsed > 600 ? .orange : .secondary)
                } else if let totalTime = ticket.totalTime {
                    Label(formatElapsed(totalTime), systemImage: "clock.badge.checkmark")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .onAppear { elapsed = Date().timeIntervalSince(ticket.openedAt) }
        .onReceive(timer) { _ in elapsed = Date().timeIntervalSince(ticket.openedAt) }
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}

struct StatusBadge: View {
    let status: TicketStatus
    var body: some View {
        Text(status.rawValue.capitalized)
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
