import SwiftUI

/// The main floor view — shows all tables with live status from active tickets.
/// Replaces the old TableSelectView with a situationally-aware layout.
struct FloorView: View {
    @Environment(\.appServices) var services

    // Navigation state
    @State private var selectedTable = ""
    @State private var navigateToLiveSession = false
    @State private var navigateToTicket: Ticket? = nil

    // Floor data
    @State private var activeTickets: [String: Ticket] = [:]   // tableNumber → Ticket
    @State private var isLoading = false
    @State private var customTable = ""
    @State private var showCustomEntry = false

    private let presetTables = [
        "1","2","3","4","5","6","7","8","9","10","11","12","Bar","Patio"
    ]

    // Tables that currently have active (non-closed) tickets
    private var activeTables: [String] {
        presetTables.filter { activeTickets[$0] != nil }
    }
    private var availableTables: [String] {
        presetTables.filter { activeTickets[$0] == nil }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // Active tables section
                    if !activeTables.isEmpty {
                        SectionHeader(title: "Active Tables", count: activeTables.count, color: .orange)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                            ForEach(activeTables, id: \.self) { table in
                                ActiveTableCard(
                                    tableNumber: table,
                                    ticket: activeTickets[table]!
                                ) {
                                    navigateToTicket = activeTickets[table]
                                }
                            }
                        }
                    }

                    // Available tables section
                    SectionHeader(
                        title: activeTables.isEmpty ? "All Tables" : "Available",
                        count: availableTables.count,
                        color: .green
                    )
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 10)], spacing: 10) {
                        ForEach(availableTables, id: \.self) { table in
                            AvailableTableCard(tableNumber: table) {
                                selectedTable = table
                                navigateToLiveSession = true
                            }
                        }

                        // Custom table button
                        Button {
                            showCustomEntry = true
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "plus.circle.dashed")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                                Text("Other")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 80)
                            .background(.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Floor")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await loadActiveTickets() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .refreshable { await loadActiveTickets() }
            .navigationDestination(isPresented: $navigateToLiveSession) {
                if !selectedTable.isEmpty {
                    LiveSessionView(tableNumber: selectedTable)
                }
            }
            .navigationDestination(item: $navigateToTicket) { ticket in
                TicketEditorView(ticket: ticket)
            }
            .alert("Table Number", isPresented: $showCustomEntry) {
                TextField("e.g. 13, Booth 4, Bar 2", text: $customTable)
                Button("Start Order") {
                    let t = customTable.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty {
                        selectedTable = t
                        navigateToLiveSession = true
                    }
                    customTable = ""
                }
                Button("Cancel", role: .cancel) { customTable = "" }
            }
            .task { await loadActiveTickets() }
            .onAppear { Task { await loadActiveTickets() } }
        }
    }

    private func loadActiveTickets() async {
        isLoading = true
        defer { isLoading = false }
        guard let all = try? await services.repository.fetchAll() else { return }
        // Show tickets that are open, sent, or delivered (not closed)
        let relevant = all.filter { $0.ticketStatus != .closed }
        // Last active ticket per table wins
        var map: [String: Ticket] = [:]
        for ticket in relevant.reversed() {
            map[ticket.tableNumber] = ticket
        }
        activeTickets = map
    }
}

// MARK: - Active Table Card

struct ActiveTableCard: View {
    let tableNumber: String
    let ticket: Ticket
    let onTap: () -> Void

    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var statusColor: Color {
        switch ticket.ticketStatus {
        case .open: return .blue
        case .sent: return .orange
        case .delivered: return .green
        case .closed: return .secondary
        }
    }

    var statusIcon: String {
        switch ticket.ticketStatus {
        case .open: return "pencil.circle.fill"
        case .sent: return "flame.fill"
        case .delivered: return "checkmark.circle.fill"
        case .closed: return "archivebox.fill"
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Table \(tableNumber)")
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                        .font(.title3)
                }

                HStack(spacing: 6) {
                    Text(ticket.ticketStatus.rawValue.capitalized)
                        .font(.caption.bold())
                        .foregroundStyle(statusColor)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text("\(ticket.allItems.count) item\(ticket.allItems.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(formatElapsed(elapsed))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(elapsed > 1200 ? .red : elapsed > 600 ? .orange : .secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(statusColor.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(statusColor.opacity(0.25), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onAppear { elapsed = Date().timeIntervalSince(ticket.openedAt) }
        .onReceive(timer) { _ in elapsed = Date().timeIntervalSince(ticket.openedAt) }
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}

// MARK: - Available Table Card

struct AvailableTableCard: View {
    let tableNumber: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                Text(tableNumber)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                Text("Available")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 80)
            .background(Color.green.opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.green.opacity(0.2), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let title: String
    let count: Int
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.headline)
            Text("\(count)")
                .font(.caption.bold())
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(color.opacity(0.15))
                .foregroundStyle(color)
                .clipShape(Capsule())
            Spacer()
        }
    }
}
