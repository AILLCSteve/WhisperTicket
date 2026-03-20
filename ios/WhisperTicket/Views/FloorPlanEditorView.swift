import SwiftUI

/// Floor plan editor — manage tables, seats, and server sections.
/// Two modes: List (fast editing) and Canvas (drag-to-position).
struct FloorPlanEditorView: View {
    @Environment(\.appServices) var services
    @Environment(\.dismiss) var dismiss
    @State private var viewMode: EditorMode = .list
    @State private var editingTable: FloorTable?
    @State private var showAddTable = false
    @State private var newTableName = ""
    @State private var newTableSeats = "4"
    @State private var showResetConfirm = false
    @State private var showSectionEditor = false

    enum EditorMode: String, CaseIterable {
        case list = "List"
        case canvas = "Map"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $viewMode) {
                    ForEach(EditorMode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding()

                if viewMode == .list {
                    listEditor
                } else {
                    canvasEditor
                }
            }
            .navigationTitle("Edit Floor Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showAddTable = true } label: {
                            Label("Add Table", systemImage: "plus.rectangle")
                        }
                        Button { showSectionEditor = true } label: {
                            Label("Manage Sections", systemImage: "rectangle.3.group")
                        }
                        Divider()
                        Button(role: .destructive) {
                            showResetConfirm = true
                        } label: {
                            Label("Reset to Default", systemImage: "arrow.counterclockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .alert("Add Table", isPresented: $showAddTable) {
                TextField("Table name (e.g. 9, Bar 2, Booth A)", text: $newTableName)
                TextField("Number of seats", text: $newTableSeats)
                    .keyboardType(.numberPad)
                Button("Add") {
                    let name = newTableName.trimmingCharacters(in: .whitespaces)
                    let count = Int(newTableSeats) ?? 4
                    guard !name.isEmpty else { return }
                    let t = FloorTable(name: name, seats: SeatConfig.numbered(count))
                    services.floorPlanStore.upsertTable(t)
                    newTableName = ""; newTableSeats = "4"
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Reset floor plan to defaults?", isPresented: $showResetConfirm, titleVisibility: .visible) {
                Button("Reset", role: .destructive) {
                    services.floorPlanStore.resetToDefault()
                }
            }
            .sheet(item: $editingTable) { table in
                TableConfigSheet(table: table) { updated in
                    services.floorPlanStore.upsertTable(updated)
                }
            }
            .sheet(isPresented: $showSectionEditor) {
                SectionEditorSheet()
            }
        }
    }

    // MARK: - List Editor

    private var listEditor: some View {
        List {
            let plan = services.floorPlanStore.floorPlan
            ForEach(plan.tables, id: \.id) { table in
                let section = plan.sections.first { $0.tableIds.contains(table.id) }
                HStack(spacing: 12) {
                    if let section {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(section.color)
                            .frame(width: 5, height: 44)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(table.name).fontWeight(.semibold)
                        Text("\(table.seats.count) seat\(table.seats.count == 1 ? "" : "s") · \(seatSummary(table))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { editingTable = table } label: {
                        Image(systemName: "pencil.circle")
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
                .contentShape(Rectangle())
            }
            .onDelete { offsets in
                let ids = offsets.map { plan.tables[$0].id }
                ids.forEach { services.floorPlanStore.deleteTable(id: $0) }
            }
            .onMove { from, to in
                services.floorPlanStore.moveTable(fromOffsets: from, toOffset: to)
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(.active))
    }

    // MARK: - Canvas Editor

    private var canvasEditor: some View {
        ScrollView([.horizontal, .vertical]) {
            CanvasView()
                .frame(width: 600, height: 800)
        }
    }

    private func seatSummary(_ table: FloorTable) -> String {
        let labels = table.seats.prefix(3).map { $0.label }.joined(separator: ", ")
        return table.seats.count > 3 ? "\(labels)..." : labels
    }
}

// MARK: - Canvas with Draggable Tables

struct CanvasView: View {
    @Environment(\.appServices) var services

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Grid background
            Canvas { ctx, size in
                let spacing: CGFloat = 40
                var x: CGFloat = 0
                while x < size.width {
                    let path = Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) }
                    ctx.stroke(path, with: .color(.secondary.opacity(0.1)), lineWidth: 0.5)
                    x += spacing
                }
                var y: CGFloat = 0
                while y < size.height {
                    let path = Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) }
                    ctx.stroke(path, with: .color(.secondary.opacity(0.1)), lineWidth: 0.5)
                    y += spacing
                }
            }

            ForEach(services.floorPlanStore.floorPlan.tables) { table in
                DraggableTableTile(table: table)
            }
        }
    }
}

struct DraggableTableTile: View {
    let table: FloorTable
    @Environment(\.appServices) var services
    @GestureState private var dragDelta = CGSize.zero

    var body: some View {
        VStack(spacing: 4) {
            Text(table.name)
                .font(.caption.bold())
                .foregroundStyle(.white)
            Text("\(table.seats.count)👤")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(width: 80, height: 60)
        .background(Color.accentColor.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 3)
        .offset(
            x: table.position.width + dragDelta.width,
            y: table.position.height + dragDelta.height
        )
        .gesture(
            DragGesture()
                .updating($dragDelta) { value, state, _ in state = value.translation }
                .onEnded { value in
                    var updated = table
                    updated.position = CGSize(
                        width:  max(0, table.position.width  + value.translation.width),
                        height: max(0, table.position.height + value.translation.height)
                    )
                    services.floorPlanStore.upsertTable(updated)
                }
        )
    }
}

// MARK: - Table Config Sheet

struct TableConfigSheet: View {
    @State private var table: FloorTable
    let onSave: (FloorTable) -> Void
    @Environment(\.appServices) var services
    @Environment(\.dismiss) var dismiss

    @State private var newSeatLabel = ""
    @State private var showAddSeat = false

    init(table: FloorTable, onSave: @escaping (FloorTable) -> Void) {
        _table = State(initialValue: table)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Table") {
                    HStack {
                        Text("Name")
                        Spacer()
                        TextField("e.g. 1, Bar, Patio 2", text: $table.name)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("Seats") {
                    ForEach(table.seats.indices, id: \.self) { idx in
                        HStack {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.secondary)
                            TextField("Label", text: $table.seats[idx].label)
                        }
                    }
                    .onDelete { offsets in
                        table.seats.remove(atOffsets: offsets)
                    }
                    .onMove { from, to in
                        table.seats.move(fromOffsets: from, toOffset: to)
                    }

                    Button {
                        newSeatLabel = "\(table.seats.count + 1)"
                        showAddSeat = true
                    } label: {
                        Label("Add Seat", systemImage: "plus")
                    }
                    .alert("Add Seat", isPresented: $showAddSeat) {
                        TextField("Name or number", text: $newSeatLabel)
                        Button("Add") {
                            let l = newSeatLabel.trimmingCharacters(in: .whitespaces)
                            if !l.isEmpty { table.seats.append(SeatConfig(label: l)) }
                        }
                        Button("Cancel", role: .cancel) {}
                    }
                }

                Section("Section") {
                    let sections = services.floorPlanStore.floorPlan.sections
                    if sections.isEmpty {
                        Text("No sections defined yet").foregroundStyle(.secondary)
                    } else {
                        Picker("Assign to Section", selection: $table.sectionId) {
                            Text("None").tag(String?.none)
                            ForEach(sections) { sec in
                                HStack {
                                    Circle().fill(sec.color).frame(width: 10, height: 10)
                                    Text(sec.name)
                                }.tag(Optional(sec.id))
                            }
                        }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit Table")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(table); dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Section Editor Sheet

struct SectionEditorSheet: View {
    @Environment(\.appServices) var services
    @Environment(\.dismiss) var dismiss
    @State private var showAdd = false
    @State private var newName = ""
    @State private var selectedColorIdx = 0

    var body: some View {
        NavigationStack {
            List {
                ForEach(services.floorPlanStore.floorPlan.sections) { section in
                    HStack(spacing: 12) {
                        Circle().fill(section.color).frame(width: 16, height: 16)
                        Text(section.name)
                        Spacer()
                        Text("\(section.tableIds.count) tables")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { services.floorPlanStore.floorPlan.sections[$0].id }
                    ids.forEach { services.floorPlanStore.deleteSection(id: $0) }
                }

                Button { showAdd = true } label: {
                    Label("Add Section", systemImage: "plus")
                }
            }
            .navigationTitle("Server Sections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("New Section", isPresented: $showAdd) {
                TextField("Section name (e.g. Steve's Station)", text: $newName)
                Button("Add") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    let hex = ServerSection.palette[selectedColorIdx % ServerSection.palette.count]
                    selectedColorIdx += 1
                    let sec = ServerSection(name: name, colorHex: hex, tableIds: [])
                    services.floorPlanStore.upsertSection(sec)
                    newName = ""
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}
