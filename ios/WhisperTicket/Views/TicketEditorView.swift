import SwiftUI

struct TicketEditorView: View {
    let ticket: Ticket
    @Environment(\.appServices) var services
    @State private var vm: TicketEditorViewModel?
    @State private var showSeatMap = false
    @State private var editingTranscript = false
    @State private var transcriptText = ""
    // Per-seat transcript editing: (seat, initial text)
    @State private var editingSeatTranscript: (GuestSeat, String)? = nil

    var body: some View {
        if let vm {
            List {
                transcriptSection(vm: vm)
                ticketInfoSection()
                timelineSection()
                coursePacingSection(vm: vm)
                orderItemsSection(vm: vm)
                notesSection()
                editHistorySection()
                actionsSection(vm: vm)
                seatMapSection()
            }
            .navigationTitle("Table \(ticket.tableNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showSeatMap) {
                SeatMapView(ticket: ticket, vm: vm)
            }
            .sheet(isPresented: $editingTranscript) {
                TranscriptEditorSheet(text: $transcriptText) {
                    Task { await vm.updateTranscript(transcriptText) }
                    editingTranscript = false
                }
            }
            .sheet(item: Binding(
                get: { editingSeatTranscript.map { SeatTranscriptEditWrapper(id: $0.0.seatNumber, seat: $0.0, text: $0.1) } },
                set: { if $0 == nil { editingSeatTranscript = nil } }
            )) { (wrapper: SeatTranscriptEditWrapper) in
                TranscriptEditorSheet(text: Binding(
                    get: { editingSeatTranscript?.1 ?? "" },
                    set: { editingSeatTranscript = (wrapper.seat, $0) }
                )) {
                    if let (seat, text) = editingSeatTranscript {
                        Task { await vm.updateSeatTranscript(text, for: seat) }
                    }
                    editingSeatTranscript = nil
                }
            }
        } else {
            ProgressView()
                .task {
                    vm = TicketEditorViewModel(ticket: ticket, repository: services.repository)
                }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func transcriptSection(vm: TicketEditorViewModel) -> some View {
        Section {
            if ticket.rawTranscript.isEmpty {
                Text("No transcript recorded")
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                Text(ticket.rawTranscript)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if ticket.ticketStatus != .closed {
                Button {
                    transcriptText = ticket.rawTranscript
                    editingTranscript = true
                } label: {
                    Label("Edit Transcript", systemImage: "pencil")
                        .font(.caption)
                }
            }
        } header: {
            Label("Voice Transcript", systemImage: "mic.fill")
        }
    }

    @ViewBuilder
    private func ticketInfoSection() -> some View {
        Section("Ticket Info") {
            LabeledContent("Table", value: ticket.tableNumber)
            LabeledContent("Status", value: ticket.ticketStatus.rawValue.capitalized)
            LabeledContent("Opened", value: ticket.openedAt.formatted(.dateTime.hour().minute().month().day()))
            if ticket.ticketStatus == .open || ticket.ticketStatus == .sent {
                ElapsedTimeLabel(since: ticket.openedAt)
            }
        }
    }

    @ViewBuilder
    private func timelineSection() -> some View {
        Section("Timeline") {
            TimelineRow(label: "Opened", date: ticket.openedAt, color: .blue)
            if let sent = ticket.sentToKitchenAt {
                TimelineRow(label: "Sent to Kitchen", date: sent, color: .orange,
                            delta: ticket.timeToSend.map { formatInterval($0) })
            }
            if let delivered = ticket.deliveredAt {
                TimelineRow(label: "Delivered", date: delivered, color: .green,
                            delta: ticket.timeToDeliver.map { formatInterval($0) })
            }
            if let closed = ticket.closedAt {
                TimelineRow(label: "Closed", date: closed, color: .secondary,
                            delta: ticket.totalTime.map { "Total: " + formatInterval($0) })
            }
        }
    }

    @ViewBuilder
    private func coursePacingSection(vm: TicketEditorViewModel) -> some View {
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
    }

    @ViewBuilder
    private func orderItemsSection(vm: TicketEditorViewModel) -> some View {
        if ticket.guests.isEmpty || ticket.allItems.isEmpty {
            Section("Order Items") {
                Text("No items — order was entered as transcript only")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        } else {
            ForEach(ticket.guests.sorted(by: { $0.seatNumber < $1.seatNumber })) { seat in
                Section(header: Label("Seat \(seat.seatNumber)", systemImage: "person")) {
                    if !seat.rawTranscript.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Transcript", systemImage: "mic")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Text(seat.rawTranscript)
                                .font(.callout)
                                .foregroundStyle(.primary)
                        }
                        .padding(.vertical, 4)

                        if ticket.ticketStatus != .closed {
                            Button {
                                editingSeatTranscript = (seat, seat.rawTranscript)
                            } label: {
                                Label("Edit Transcript", systemImage: "pencil")
                                    .font(.caption)
                            }
                        }
                    }

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
        }
    }

    @ViewBuilder
    private func notesSection() -> some View {
        if !ticket.notes.isEmpty {
            Section("Notes") { Text(ticket.notes) }
        }
    }

    @ViewBuilder
    private func editHistorySection() -> some View {
        if !ticket.editHistory.isEmpty {
            Section("Edit History") {
                ForEach(ticket.editHistory.sorted(by: { $0.timestamp < $1.timestamp })) { event in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: editHistoryIcon(event.eventType))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.summary)
                                .font(.callout)
                            Text(event.timestamp.formatted(.dateTime.hour().minute().second()))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actionsSection(vm: TicketEditorViewModel) -> some View {
        if ticket.ticketStatus != .closed {
            Section("Actions") {
                Button("Send to Kitchen") { Task { await vm.sendToKitchen() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(ticket.ticketStatus != .open)

                Button("Mark Delivered") { Task { await vm.markDelivered() } }
                    .disabled(ticket.ticketStatus != .sent)

                Button("Close Ticket") { Task { await vm.closeTicket() } }
                    .foregroundStyle(.red)
                    .disabled(ticket.ticketStatus != .delivered)
            }
        }
    }

    @ViewBuilder
    private func seatMapSection() -> some View {
        if !ticket.guests.isEmpty {
            Section {
                Button("View Seat Map") { showSeatMap = true }
                    .foregroundStyle(.blue)
            }
        }
    }

    // MARK: - Helpers

    private func formatInterval(_ interval: TimeInterval) -> String {
        "\(Int(interval / 60))m \(Int(interval) % 60)s"
    }

    private func editHistoryIcon(_ eventType: String) -> String {
        switch eventType {
        case "item_added":     return "plus.circle"
        case "item_removed":   return "minus.circle"
        case "item_moved":     return "arrow.left.arrow.right"
        case "notes_updated":  return "note.text"
        case "transcript_set": return "mic"
        case "status_changed": return "arrow.triangle.2.circlepath"
        default:               return "clock"
        }
    }
}

/// Minimal Identifiable wrapper so `.sheet(item:)` can drive the per-seat transcript editor.
private struct SeatTranscriptEditWrapper: Identifiable {
    let id: Int   // seat number
    let seat: GuestSeat
    let text: String
}

// MARK: - Transcript Editor Sheet

struct TranscriptEditorSheet: View {
    @Binding var text: String
    let onSave: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding()
                .navigationTitle("Edit Transcript")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { onSave() }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }
}

// MARK: - Timeline Row

struct TimelineRow: View {
    let label: String
    let date: Date
    let color: Color
    var delta: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).fontWeight(.medium)
                Text(date.formatted(.dateTime.hour().minute().month().day()))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let delta {
                Text(delta)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
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

// MARK: - Course Control Row

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
