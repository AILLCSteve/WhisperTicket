import SwiftUI

/// Operational floor screen.
/// Defaults to the visual Map view (canvas). Tables tab shows the live ticket list.
struct FloorView: View {
    @Environment(\.appServices) var services
    @State private var selectedTab: FloorTab = .map
    @State private var navigateToOrder: FloorTable?
    @State private var navigateToTicket: Ticket?
    @State private var showEditor = false
    @State private var activeTickets: [String: Ticket] = [:]
    @State private var showCustomEntry = false
    @State private var customTableName = ""

    enum FloorTab: String, CaseIterable {
        case map = "Map"
        case tables = "Tables"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $selectedTab.animation(.easeInOut(duration: 0.25))) {
                    ForEach(FloorTab.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                ZStack {
                    if selectedTab == .map {
                        FloorMapEmbedView(activeTickets: activeTickets, onTapTable: { table in
                            if activeTickets[table.name] != nil {
                                navigateToTicket = activeTickets[table.name]
                            } else {
                                navigateToOrder = table
                            }
                        })
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.98)),
                            removal: .opacity.combined(with: .scale(scale: 0.98))
                        ))
                    } else {
                        tableListView
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.98)),
                                removal: .opacity.combined(with: .scale(scale: 0.98))
                            ))
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: selectedTab)
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
                            Label("Edit Map", systemImage: "map.fill")
                                .font(.subheadline.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.chromePrimary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        .foregroundStyle(Color.chromePrimary)
                    }
                }
            }
            .refreshable { await loadActiveTickets() }
            .task { await loadActiveTickets() }
            .onAppear { Task { await loadActiveTickets() } }
            .navigationDestination(item: $navigateToOrder) { TableOrderEntryView(table: $0) }
            .navigationDestination(item: $navigateToTicket) { TicketEditorView(ticket: $0) }
            .sheet(isPresented: $showEditor) { FloorPlanEditorView() }
            .alert("Custom Table", isPresented: $showCustomEntry) {
                TextField("e.g. Bar 3, Booth A", text: $customTableName)
                Button("Start Order") {
                    let name = customTableName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    navigateToOrder = FloorTable(name: name, seats: SeatConfig.numbered(2))
                    customTableName = ""
                }
                Button("Cancel", role: .cancel) { customTableName = "" }
            }
        }
    }

    // MARK: - Table List (operational view)

    @ViewBuilder
    private var tableListView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                let plan = services.floorPlanStore.floorPlan
                let activeTables = plan.tables.filter { activeTickets[$0.name] != nil }
                let availableTables = plan.tables.filter { activeTickets[$0.name] == nil }

                if !activeTables.isEmpty {
                    ChromeSectionHeader(title: "Active", systemImage: "flame.fill")
                        .padding(.horizontal)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                        ForEach(activeTables) { table in
                            ChromeActiveTableCard(
                                table: table, ticket: activeTickets[table.name]!,
                                section: plan.sections.first { $0.tableIds.contains(table.id) }
                            ) { navigateToTicket = activeTickets[table.name] }
                        }
                    }
                    .padding(.horizontal)
                }

                let sections = plan.sections
                if !sections.isEmpty {
                    ForEach(sections) { section in
                        let sectionTables = availableTables.filter { section.tableIds.contains($0.id) }
                        if !sectionTables.isEmpty {
                            ChromeSectionHeader(title: section.name, systemImage: "rectangle.3.group")
                                .padding(.horizontal)
                            availableGrid(sectionTables)
                        }
                    }
                    let unassigned = availableTables.filter { t in
                        !sections.contains { $0.tableIds.contains(t.id) }
                    }
                    if !unassigned.isEmpty {
                        ChromeSectionHeader(title: activeTables.isEmpty ? "All Tables" : "Available",
                                            systemImage: "checkmark.circle")
                            .padding(.horizontal)
                        availableGrid(unassigned)
                    }
                } else {
                    ChromeSectionHeader(title: activeTables.isEmpty ? "All Tables" : "Available",
                                        systemImage: "checkmark.circle")
                        .padding(.horizontal)
                    availableGrid(availableTables)
                }
            }
            .padding(.vertical)
        }
    }

    @ViewBuilder
    private func availableGrid(_ tables: [FloorTable]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
            ForEach(tables) { table in
                ChromeAvailableTableCard(table: table) { navigateToOrder = table }
            }
            Button { showCustomEntry = true } label: {
                VStack(spacing: 6) {
                    Image(systemName: "plus.circle.dashed").font(.title2)
                    Text("Other").font(.caption)
                }
                .frame(maxWidth: .infinity).frame(height: 110)
                .foregroundStyle(.secondary)
                .chromeCard(cornerRadius: 14)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
    }

    private func loadActiveTickets() async {
        guard let all = try? await services.repository.fetchAll() else { return }
        let relevant = all.filter { $0.ticketStatus != .closed }
        var map: [String: Ticket] = [:]
        for ticket in relevant.reversed() { map[ticket.tableNumber] = ticket }
        activeTickets = map
    }
}

// MARK: - Embedded Map View (read-only canvas, no edit mode required)

struct FloorMapEmbedView: View {
    @Environment(\.appServices) var services
    let activeTickets: [String: Ticket]
    let onTapTable: (FloorTable) -> Void

    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                // Dot-grid background
                Canvas { ctx, size in
                    let spacing: CGFloat = 40
                    var path = Path()
                    var x: CGFloat = 0
                    while x <= size.width {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                        x += spacing
                    }
                    var y: CGFloat = 0
                    while y <= size.height {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                        y += spacing
                    }
                    ctx.stroke(path, with: .color(.primary.opacity(0.05)), lineWidth: 0.5)
                }
                .frame(width: 900, height: 700)

                ForEach(services.floorPlanStore.floorPlan.tables) { table in
                    let ticket = activeTickets[table.name]
                    Button { onTapTable(table) } label: {
                        MapTableTile(table: table, ticket: ticket)
                    }
                    .buttonStyle(.plain)
                    .offset(x: table.position.width + 40, y: table.position.height + 40)
                }
            }
            .frame(minWidth: 900, minHeight: 700)
        }
        .background(Color(.systemGroupedBackground))
    }
}

struct MapTableTile: View {
    let table: FloorTable
    let ticket: Ticket?

    var statusColor: Color {
        guard let t = ticket else { return .chromeTeal }
        switch t.ticketStatus {
        case .open: return .chromePrimary
        case .sent: return .chromeAmber
        case .delivered: return .green
        case .closed: return .secondary
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(table.name).font(.title3.bold())
            Text("\(table.seats.count)\u{1F465}").font(.caption2)
            if let ticket {
                Text(ticket.ticketStatus.rawValue.capitalized)
                    .font(.caption2.bold())
                    .foregroundStyle(statusColor)
            } else {
                Text("Open").font(.caption2).foregroundStyle(Color.chromeTeal)
            }
        }
        .frame(width: 100, height: 100)
        .chromeCard(cornerRadius: 16, glowColor: statusColor, glowRadius: ticket != nil ? 10 : 0)
        .glowRing(color: statusColor, radius: ticket != nil ? 6 : 0)
    }
}

// MARK: - Chrome Table Cards

struct ChromeActiveTableCard: View {
    let table: FloorTable
    let ticket: Ticket
    let section: ServerSection?
    let onTap: () -> Void

    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var statusColor: Color {
        switch ticket.ticketStatus {
        case .open: return .chromePrimary
        case .sent: return .chromeAmber
        case .delivered: return .chromeTeal
        case .closed: return .secondary
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(table.name).font(.title3.bold())
                        if let section {
                            HStack(spacing: 4) {
                                Circle().fill(section.color).frame(width: 6, height: 6)
                                Text(section.name).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    Image(systemName: ticket.ticketStatus == .sent ? "flame.fill" : "pencil.circle.fill")
                        .foregroundStyle(statusColor).font(.title3)
                }
                HStack(spacing: 6) {
                    Text(ticket.ticketStatus.rawValue.capitalized)
                        .font(.caption.bold()).foregroundStyle(statusColor)
                    Text("\u{00B7}").foregroundStyle(.secondary)
                    Text("\(ticket.allItems.count) item\(ticket.allItems.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Image(systemName: "clock").font(.caption2)
                    Text(formatElapsed(elapsed))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(elapsed > 1200 ? .red : elapsed > 600 ? .orange : .secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .chromeCard(cornerRadius: 16, glowColor: statusColor, glowRadius: 12)
            .glowRing(color: statusColor, radius: 6)
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

struct ChromeAvailableTableCard: View {
    let table: FloorTable
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                Text(table.name).font(.title2.bold())
                Text("\(table.seats.count)\u{1F465}").font(.caption2).foregroundStyle(.secondary)
                Text("Available").font(.caption2.bold()).foregroundStyle(Color.chromeTeal)
            }
            .frame(maxWidth: .infinity).frame(height: 110)
            .chromeCard(cornerRadius: 14, glowColor: .chromeTeal, glowRadius: 6)
        }
        .buttonStyle(.plain)
    }
}
