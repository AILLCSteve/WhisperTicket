import SwiftUI

struct TicketEditorView: View {
    let ticket: Ticket
    @Environment(\.appServices) var services
    @State private var vm: TicketEditorViewModel?
    @State private var showSeatMap = false

    var body: some View {
        if let vm {
            List {
                // Header
                Section {
                    LabeledContent("Table", value: ticket.tableNumber)
                    LabeledContent("Opened", value: ticket.openedAt.formatted(.dateTime.hour().minute()))
                    LabeledContent("Status", value: ticket.ticketStatus.rawValue.capitalized)
                    if let timeToSend = ticket.timeToSend {
                        LabeledContent("Time to Send", value: formatInterval(timeToSend))
                    }
                    if let timeToDeliver = ticket.timeToDeliver {
                        LabeledContent("Time to Deliver", value: formatInterval(timeToDeliver))
                    }
                    if let totalTime = ticket.totalTime {
                        LabeledContent("Total Time", value: formatInterval(totalTime))
                    }
                    if ticket.ticketStatus == .open || ticket.ticketStatus == .sent {
                        ElapsedTimeLabel(since: ticket.openedAt)
                    }
                }

                // Medium complexity: Course pacing
                let courses = Set(ticket.allItems.map { $0.courseFlag })
                if !courses.isEmpty {
                    Section("Course Pacing") {
                        ForEach(Array(courses).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { course in
                            CourseControlRow(
                                course: course,
                                state: vm.coursePacingStates[course] ?? .holding,
                                onFire: { Task { await vm.fireCourse(course) } },
                                onHold: { Task { await vm.holdCourse(course) } }
                            )
                        }
                    }
                }

                // Items by seat
                ForEach(ticket.guests.sorted(by: { $0.seatNumber < $1.seatNumber })) { seat in
                    Section("Seat \(seat.seatNumber)") {
                        ForEach(seat.items) { item in
                            TicketItemRow(
                                item: item,
                                onConfirmAllergy: { Task { await vm.confirmAllergyItem(item) } },
                                onUpdateNotes: { notes in Task { await vm.updateItemNotes(item, notes: notes) } },
                                onMoveSeat: { toSeat in Task { await vm.moveItem(item, fromSeat: seat, toSeatNumber: toSeat) } },
                                seatCount: ticket.guests.count
                            )
                        }
                        .onDelete { offsets in
                            let items = offsets.map { seat.items[$0] }
                            for item in items { Task { await vm.removeItem(item, from: seat) } }
                        }
                    }
                }

                // Notes
                if !ticket.notes.isEmpty {
                    Section("Notes") { Text(ticket.notes) }
                }

                // Actions
                Section {
                    Button("Send to Kitchen") { Task { await vm.sendToKitchen() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(ticket.ticketStatus != .open)

                    Button("Mark Delivered") { Task { await vm.markDelivered() } }
                        .disabled(ticket.ticketStatus != .sent)

                    Button("Close Ticket") { Task { await vm.closeTicket() } }
                        .foregroundStyle(.red)
                        .disabled(ticket.ticketStatus != .delivered)
                }

                // Medium complexity: seat map
                Section {
                    Button("View Seat Map") { showSeatMap = true }
                        .foregroundStyle(.blue)
                }
            }
            .navigationTitle("Ticket — Table \(ticket.tableNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showSeatMap) {
                SeatMapView(ticket: ticket, vm: vm)
            }
        } else {
            ProgressView()
                .task {
                    vm = TicketEditorViewModel(ticket: ticket, repository: services.repository)
                }
        }
    }

    private func formatInterval(_ interval: TimeInterval) -> String {
        "\(Int(interval / 60))m \(Int(interval) % 60)s"
    }
}

// MARK: - Ticket Item Row

struct TicketItemRow: View {
    let item: TicketItem
    let onConfirmAllergy: () -> Void
    let onUpdateNotes: (String) -> Void
    let onMoveSeat: (Int) -> Void
    let seatCount: Int
    @State private var editingNotes = false
    @State private var notesText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(item.quantity)x \(item.name)").fontWeight(.medium)
                // Low complexity: abbreviation
                Text("[\(item.ticketAbbreviation)]")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if item.hasAllergyFlag && !item.allergyConfirmed {
                    Button {
                        onConfirmAllergy()
                    } label: {
                        Label("ALLERGY", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.red)
                            .clipShape(Capsule())
                    }
                }
            }
            ForEach(item.modifiers) { mod in
                Text(mod.name)
                    .font(.caption)
                    .foregroundStyle(mod.isNegation ? .red : .secondary)
            }
            if !item.notes.isEmpty {
                Text(item.notes).font(.caption).foregroundStyle(.orange).italic()
            }
            if item.confidence < 0.7 {
                Label("Low confidence — verify", systemImage: "questionmark.circle")
                    .font(.caption2).foregroundStyle(.orange)
            }
            HStack {
                Button("Edit Note") {
                    notesText = item.notes
                    editingNotes = true
                }
                .font(.caption).buttonStyle(.bordered)

                if seatCount > 1 {
                    Menu("Move Seat") {
                        ForEach(1...max(seatCount, 1), id: \.self) { seat in
                            Button("Seat \(seat)") { onMoveSeat(seat) }
                        }
                    }
                    .font(.caption).buttonStyle(.bordered)
                }
            }
        }
        .sheet(isPresented: $editingNotes) {
            NavigationStack {
                Form {
                    TextField("Kitchen note", text: $notesText, axis: .vertical)
                }
                .navigationTitle("Edit Note")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            onUpdateNotes(notesText)
                            editingNotes = false
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { editingNotes = false }
                    }
                }
            }
        }
    }
}

// MARK: - Elapsed Time Label

struct ElapsedTimeLabel: View {
    let since: Date
    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        LabeledContent("Elapsed") {
            Text(formatInterval(elapsed))
                .foregroundStyle(elapsed > 1200 ? .red : elapsed > 600 ? .orange : .primary)
        }
        .onAppear { elapsed = Date().timeIntervalSince(since) }
        .onReceive(timer) { _ in elapsed = Date().timeIntervalSince(since) }
    }

    private func formatInterval(_ interval: TimeInterval) -> String {
        "\(Int(interval / 60))m \(Int(interval) % 60)s"
    }
}

// MARK: - Course Control Row (Medium Complexity)

struct CourseControlRow: View {
    let course: CourseFlag
    let state: CoursePacingState
    let onFire: () -> Void
    let onHold: () -> Void

    var body: some View {
        HStack {
            Text(course.displayName).fontWeight(.medium)
            Spacer()
            Text(state == .fired ? "Fired" : "Holding")
                .font(.caption)
                .foregroundStyle(state == .fired ? .green : .orange)
            Button(course.fireCommand, action: onFire)
                .buttonStyle(.borderedProminent).tint(.green)
                .disabled(state == .fired)
            Button("Hold", action: onHold)
                .buttonStyle(.bordered)
                .disabled(state == .holding)
        }
    }
}
