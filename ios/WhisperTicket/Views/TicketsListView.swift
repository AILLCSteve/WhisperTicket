import SwiftUI

struct TicketsListView: View {
    @Environment(\.appServices) var services
    @State private var vm: TicketsListViewModel?
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.chromeBackground.ignoresSafeArea()

                if let vm {
                    listContent(vm: vm)
                } else {
                    ProgressView()
                        .tint(Color.chromePrimary)
                }
            }
            .navigationTitle("Tickets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .task {
                let newVm = TicketsListViewModel(repository: services.repository)
                vm = newVm
                await newVm.loadTickets()
            }
        }
    }

    @ViewBuilder
    private func listContent(vm: TicketsListViewModel) -> some View {
        List {
            if vm.openTickets.isEmpty && vm.completedTickets.isEmpty {
                emptyStateRow
            }

            if !vm.openTickets.isEmpty {
                Section {
                    ForEach(vm.openTickets) { ticket in
                        NavigationLink(destination: TicketEditorView(ticket: ticket)) {
                            ChromeTicketCard(ticket: ticket)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await vm.deleteTicket(ticket) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        ChromeSectionHeader(title: "Open", systemImage: "circle.fill")
                        Spacer()
                        Text("\(vm.openTickets.count)")
                            .font(.caption.bold())
                            .foregroundStyle(Color.chromePrimary)
                    }
                }
            }

            if !vm.completedTickets.isEmpty {
                Section {
                    ForEach(vm.completedTickets) { ticket in
                        NavigationLink(destination: TicketEditorView(ticket: ticket)) {
                            ChromeTicketCard(ticket: ticket)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await vm.deleteTicket(ticket) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        ChromeSectionHeader(title: "Completed", systemImage: "checkmark.circle.fill")
                        Spacer()
                        Text("\(vm.completedTickets.count)")
                            .font(.caption.bold())
                            .foregroundStyle(Color.chromeSilverLow)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await vm.loadTickets() }
        .onAppear { Task { await vm.loadTickets() } }
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                if !vm.openTickets.isEmpty || !vm.completedTickets.isEmpty {
                    Button("Clear All", role: .destructive) {
                        showClearConfirm = true
                    }
                    .foregroundStyle(Color.chromeRed)
                }
            }
        }
        .confirmationDialog(
            "Clear all tickets?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete All Tickets", role: .destructive) {
                Task { await vm.clearAll() }
            }
        } message: {
            Text("This permanently deletes all open and completed tickets.")
        }
    }

    private var emptyStateRow: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(Color.chromeSilverLow)
            Text("No Tickets")
                .font(.title2.bold())
                .foregroundStyle(Color.chromeSilverHigh)
            Text("Start an order from the Floor tab.")
                .font(.callout)
                .foregroundStyle(Color.chromeSilverLow)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

// MARK: - Chrome Ticket Card

struct ChromeTicketCard: View {
    let ticket: Ticket
    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var statusColor: Color {
        switch ticket.ticketStatus {
        case .open: return Color.chromePrimary
        case .sent: return Color.chromeAmber
        case .delivered: return Color.chromeTeal
        case .closed: return Color.chromeSilverLow
        }
    }

    private var isActive: Bool {
        ticket.ticketStatus == .open || ticket.ticketStatus == .sent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(statusColor)
                        .frame(width: 3, height: 32)
                        .if(ticket.ticketStatus == .open) { $0.glowRing(color: statusColor, radius: 4) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Table \(ticket.tableNumber)")
                            .font(.headline)
                            .foregroundStyle(Color.chromeSilverHigh)
                        Text(ticket.openedAt.formatted(.dateTime.hour().minute().month().day()))
                            .font(.caption)
                            .foregroundStyle(Color.chromeSilverLow)
                    }
                }
                Spacer()
                StatusBadge(status: ticket.ticketStatus)
            }

            Rectangle()
                .fill(Color.chromeSilverLow.opacity(0.2))
                .frame(height: 1)

            HStack(spacing: 14) {
                Label("\(ticket.allItems.count) item\(ticket.allItems.count == 1 ? "" : "s")",
                      systemImage: "list.bullet")
                    .font(.caption)
                    .foregroundStyle(Color.chromeSilverLow)

                if !ticket.rawTranscript.isEmpty {
                    Label("Transcript", systemImage: "mic.fill")
                        .font(.caption)
                        .foregroundStyle(Color.chromeSilverLow)
                }

                Spacer()

                if isActive {
                    Label(formatElapsed(elapsed), systemImage: "clock")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(
                            elapsed > 1200 ? Color.chromeRed :
                            elapsed > 600  ? Color.chromeAmber :
                                             Color.chromeSilverLow
                        )
                } else if let totalTime = ticket.totalTime {
                    Label(formatElapsed(totalTime), systemImage: "clock.badge.checkmark")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.chromeSilverLow)
                }
            }
        }
        .padding(14)
        .chromeCard(
            cornerRadius: 14,
            glowColor: statusColor,
            glowRadius: ticket.ticketStatus == .open ? 8 : 0
        )
        .onAppear { elapsed = Date().timeIntervalSince(ticket.openedAt) }
        .onReceive(timer) { _ in elapsed = Date().timeIntervalSince(ticket.openedAt) }
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let status: TicketStatus

    var body: some View {
        Text(status.rawValue.capitalized)
            .font(.caption.bold())
            .tracking(0.5)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(statusColor.opacity(0.18))
            .foregroundStyle(statusColor)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(statusColor.opacity(0.35), lineWidth: 1))
    }

    private var statusColor: Color {
        switch status {
        case .open: return Color.chromePrimary
        case .sent: return Color.chromeAmber
        case .delivered: return Color.chromeTeal
        case .closed: return Color.chromeSilverLow
        }
    }
}
