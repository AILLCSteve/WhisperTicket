import SwiftUI

/// The operational floor view — shows live ticket status per table.
/// Tapping an available table → TableOrderEntryView (seat-first ordering).
/// Tapping an active table → TicketEditorView.
/// Toolbar: Edit Floor Plan → FloorPlanEditorView.
struct FloorView: View {
    @Environment(\.appServices) var services

    // Navigation
    @State private var navigateToOrder: FloorTable?
    @State private var navigateToTicket: Ticket?
    @State private var showEditor = false

    // Live ticket data
    @State private var activeTickets: [String: Ticket] = [:]  // tableName → Ticket

    // Custom table entry for off-plan tables
    @State private var showCustomEntry = false
    @State private var customTableName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    let plan = services.floorPlanStore.floorPlan
                    let activeTables = plan.tables.filter { activeTickets[$0.name] != nil }
                    let availableTables = plan.tables.filter { activeTickets[$0.name] == nil }

                    // ── Active Tables ──────────────────────────────────
                    if !activeTables.isEmpty {
                        SectionHeader(title: "Active", count: activeTables.count, color: .orange)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                            ForEach(activeTables) { table in
                                ActiveTableCard(
                                    table: table,
                                    ticket: activeTickets[table.name]!,
                                    section: plan.sections.first { $0.tableIds.contains(table.id) }
                                ) {
                                    navigateToTicket = activeTickets[table.name]
                                }
                            }
                        }
                    }

                    // ── Available Tables (by section) ──────────────────
                    let sections = plan.sections
                    if !sections.isEmpty {
                        ForEach(sections) { section in
                            let sectionTables = availableTables.filter { section.tableIds.contains($0.id) }
                            if !sectionTables.isEmpty {
                                SectionHeader(title: section.name, count: sectionTables.count, color: section.color)
                                availableGrid(sectionTables)
                            }
                        }
                        // Unassigned tables
                        let unassigned = availableTables.filter { t in
                            !sections.contains(where: { $0.tableIds.contains(t.id) })
                        }
                        if !unassigned.isEmpty {
                            SectionHeader(title: activeTables.isEmpty ? "All Tables" : "Available", count: unassigned.count, color: .green)
                            availableGrid(unassigned)
                        }
                    } else {
                        SectionHeader(title: activeTables.isEmpty ? "All Tables" : "Available", count: availableTables.count, color: .green)
                        availableGrid(availableTables)
                    }
                }
                .padding()
            }
            .navigationTitle("Floor")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button { Task { await loadActiveTickets() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        Button { showEditor = true } label: {
                            Image(systemName: "pencil.circle")
                        }
                    }
                }
            }
            .refreshable { await loadActiveTickets() }
            .task { await loadActiveTickets() }
            .onAppear { Task { await loadActiveTickets() } }
            .navigationDestination(item: $navigateToOrder) { table in
                TableOrderEntryView(table: table)
            }
            .navigationDestination(item: $navigateToTicket) { ticket in
                TicketEditorView(ticket: ticket)
            }
            .sheet(isPresented: $showEditor) {
                FloorPlanEditorView()
            }
            .alert("Custom Table", isPresented: $showCustomEntry) {
                TextField("e.g. Bar 3, Booth A", text: $customTableName)
                Button("Start Order") {
                    let name = customTableName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    // Create an ad-hoc FloorTable (not persisted)
                    navigateToOrder = FloorTable(name: name, seats: SeatConfig.numbered(2))
                    customTableName = ""
                }
                Button("Cancel", role: .cancel) { customTableName = "" }
            }
        }
    }

    // MARK: - Available Grid

    @ViewBuilder
    private func availableGrid(_ tables: [FloorTable]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 10)], spacing: 10) {
            ForEach(tables) { table in
                AvailableTableCard(table: table) {
                    navigateToOrder = table
                }
            }
            Button { showCustomEntry = true } label: {
                VStack(spacing: 6) {
                    Image(systemName: "plus.circle.dashed").font(.title2).foregroundStyle(.secondary)
                    Text("Other").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).frame(height: 80)
                .background(.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Data

    private func loadActiveTickets() async {
        guard let all = try? await services.repository.fetchAll() else { return }
        let relevant = all.filter { $0.ticketStatus != .closed }
        var map: [String: Ticket] = [:]
        for ticket in relevant.reversed() { map[ticket.tableNumber] = ticket }
        activeTickets = map
    }
}

// MARK: - Active Table Card

struct ActiveTableCard: View {
    let table: FloorTable
    let ticket: Ticket
    let section: ServerSection?
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
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(table.name).font(.title3.bold()).foregroundStyle(.primary)
                        if let section {
                            HStack(spacing: 4) {
                                Circle().fill(section.color).frame(width: 6, height: 6)
                                Text(section.name).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    Image(systemName: statusIcon).foregroundStyle(statusColor).font(.title3)
                }

                HStack(spacing: 6) {
                    Text(ticket.ticketStatus.rawValue.capitalized)
                        .font(.caption.bold()).foregroundStyle(statusColor)
                    Text("·").foregroundStyle(.secondary)
                    Text("\(ticket.allItems.count) item\(ticket.allItems.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.secondary)
                    Text("\(table.seats.count)👤").font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
                    Text(formatElapsed(elapsed))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(elapsed > 1200 ? .red : elapsed > 600 ? .orange : .secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(statusColor.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(statusColor.opacity(0.25), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onAppear { elapsed = Date().timeIntervalSince(ticket.openedAt) }
        .onReceive(timer) { _ in elapsed = Date().timeIntervalSince(ticket.openedAt) }
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let m = Int(t) / 60; let s = Int(t) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}

// MARK: - Available Table Card

struct AvailableTableCard: View {
    let table: FloorTable
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Text(table.name).font(.title2.bold()).foregroundStyle(.primary)
                Text("\(table.seats.count)👤").font(.caption2).foregroundStyle(.secondary)
                Text("Available").font(.caption2).foregroundStyle(.green)
            }
            .frame(maxWidth: .infinity).frame(height: 84)
            .background(Color.green.opacity(0.07))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.green.opacity(0.2), lineWidth: 1))
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
            Text(title).font(.headline)
            Text("\(count)")
                .font(.caption.bold())
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(color.opacity(0.15))
                .foregroundStyle(color)
                .clipShape(Capsule())
            Spacer()
        }
    }
}
