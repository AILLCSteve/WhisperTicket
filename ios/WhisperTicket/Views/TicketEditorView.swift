import SwiftUI

struct TicketEditorView: View {
    let ticket: Ticket
    @Environment(\.appServices) var services
    @State private var vm: TicketEditorViewModel?
    @State private var showSeatMap = false
    @State private var editingTranscript = false
    @State private var transcriptText = ""
    @State private var editingSeatTranscript: (GuestSeat, String)? = nil
    @State private var showEditHistory = false

    var body: some View {
        ZStack {
            Color.chromeBackground.ignoresSafeArea()

            if let vm {
                editorContent(vm: vm)
            } else {
                ProgressView()
                    .tint(Color.chromePrimary)
                    .task {
                        vm = TicketEditorViewModel(
                            ticket: ticket,
                            repository: services.repository,
                            parser: services.parser,
                            menuStore: services.menuStore
                        )
                    }
            }
        }
        .navigationTitle("Table \(ticket.tableNumber)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Text("Table \(ticket.tableNumber)")
                        .font(.headline)
                        .foregroundStyle(Color.chromeSilverHigh)
                    StatusBadge(status: ticket.ticketStatus)
                }
            }
        }
        .sheet(isPresented: $showSeatMap) {
            if let vm { SeatMapView(ticket: ticket, vm: vm) }
        }
        .sheet(isPresented: $editingTranscript) {
            TranscriptEditorSheet(text: $transcriptText) {
                if let vm { Task { await vm.updateTranscript(transcriptText) } }
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
                if let (seat, text) = editingSeatTranscript, let vm {
                    Task { await vm.updateSeatTranscript(text, for: seat) }
                }
                editingSeatTranscript = nil
            }
        }
    }

    // MARK: - Main editor layout

    @ViewBuilder
    private func editorContent(vm: TicketEditorViewModel) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    statusHeaderCard()
                    orderItemsCard(vm: vm)
                    transcriptCard(vm: vm)
                    timelineCard()
                    coursePacingCard(vm: vm)
                    if !ticket.notes.isEmpty { notesCard() }
                    editHistoryCard()
                    if !ticket.guests.isEmpty {
                        Button { showSeatMap = true } label: {
                            Label("View Seat Map", systemImage: "map")
                                .font(.subheadline.bold())
                                .foregroundStyle(Color.chromePrimary)
                                .frame(maxWidth: .infinity)
                                .padding(14)
                                .chromeCard(cornerRadius: 14, glowColor: Color.chromePrimary, glowRadius: 4)
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 100)
            }

            actionsBar(vm: vm)
        }
    }

    // MARK: - Status Header Card

    @ViewBuilder
    private func statusHeaderCard() -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label(ticket.openedAt.formatted(.dateTime.hour().minute().month().day()),
                      systemImage: "calendar.badge.clock")
                    .font(.caption)
                    .foregroundStyle(Color.chromeSilverLow)
                if ticket.ticketStatus == .open || ticket.ticketStatus == .sent {
                    ElapsedTimeLabel(since: ticket.openedAt)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(ticket.allItems.count)")
                    .font(.title2.bold())
                    .foregroundStyle(Color.chromeSilverHigh)
                Text("item\(ticket.allItems.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(Color.chromeSilverLow)
            }
        }
        .padding(16)
        .chromeCard(cornerRadius: 14)
        .padding(.horizontal, 16)
    }

    // MARK: - Order Items Card

    @ViewBuilder
    private func orderItemsCard(vm: TicketEditorViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ChromeSectionHeader(title: "Order", systemImage: "fork.knife")
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            if ticket.guests.isEmpty || ticket.allItems.isEmpty {
                Text("No items — order entered as transcript only")
                    .font(.callout)
                    .foregroundStyle(Color.chromeSilverLow)
                    .italic()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            } else {
                ForEach(ticket.guests.sorted(by: { $0.seatNumber < $1.seatNumber })) { seat in
                    seatCard(seat: seat, vm: vm)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }
            }
        }
        .chromeCard(cornerRadius: 16)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func seatCard(seat: GuestSeat, vm: TicketEditorViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Seat \(seat.seatNumber)", systemImage: "person")
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.chromeSilverHigh)
                Spacer()
                if ticket.ticketStatus != .closed && !seat.rawTranscript.isEmpty {
                    Button {
                        editingSeatTranscript = (seat, seat.rawTranscript)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                            .font(.caption)
                            .foregroundStyle(Color.chromePrimary)
                    }
                }
            }

            if !seat.rawTranscript.isEmpty {
                Text(seat.rawTranscript)
                    .font(.caption)
                    .foregroundStyle(Color.chromeSilverLow)
                    .italic()
                    .lineLimit(2)
            }

            ForEach(seat.items) { item in
                ChromeItemRow(
                    item: item,
                    onConfirmAllergy: { Task { await vm.confirmAllergyItem(item) } },
                    onUpdateNotes: { notes in Task { await vm.updateItemNotes(item, notes: notes) } },
                    onMoveSeat: { toSeat in Task { await vm.moveItem(item, fromSeat: seat, toSeatNumber: toSeat) } },
                    onDelete: { Task { await vm.removeItem(item, from: seat) } },
                    seatCount: ticket.guests.count
                )
            }
        }
        .padding(12)
        .background(Color.chromeBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.chromeSilverLow.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Transcript Card

    @ViewBuilder
    private func transcriptCard(vm: TicketEditorViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ChromeSectionHeader(title: "Voice Transcript", systemImage: "mic.fill")
                Spacer()
                if ticket.ticketStatus != .closed {
                    Button {
                        transcriptText = ticket.rawTranscript
                        editingTranscript = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                            .font(.caption)
                            .foregroundStyle(Color.chromePrimary)
                    }
                }
            }

            if ticket.rawTranscript.isEmpty {
                Text("No transcript recorded")
                    .font(.callout)
                    .foregroundStyle(Color.chromeSilverLow)
                    .italic()
            } else {
                Text(ticket.rawTranscript)
                    .font(.callout)
                    .foregroundStyle(Color.chromeSilverHigh)
                    .lineLimit(4)
            }
        }
        .padding(16)
        .chromeCard(cornerRadius: 14)
        .padding(.horizontal, 16)
    }

    // MARK: - Timeline Card

    @ViewBuilder
    private func timelineCard() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ChromeSectionHeader(title: "Timeline", systemImage: "timeline.selection.left")
                .padding(.bottom, 2)

            ChromeTimelineRow(label: "Opened", date: ticket.openedAt, color: Color.chromePrimary)
            if let sent = ticket.sentToKitchenAt {
                ChromeTimelineRow(label: "Sent to Kitchen", date: sent, color: Color.chromeAmber,
                                  delta: ticket.timeToSend.map { formatInterval($0) })
            }
            if let delivered = ticket.deliveredAt {
                ChromeTimelineRow(label: "Delivered", date: delivered, color: Color.chromeTeal,
                                  delta: ticket.timeToDeliver.map { formatInterval($0) })
            }
            if let closed = ticket.closedAt {
                ChromeTimelineRow(label: "Closed", date: closed, color: Color.chromeSilverLow,
                                  delta: ticket.totalTime.map { "Total: " + formatInterval($0) })
            }
        }
        .padding(16)
        .chromeCard(cornerRadius: 14)
        .padding(.horizontal, 16)
    }

    // MARK: - Course Pacing Card

    @ViewBuilder
    private func coursePacingCard(vm: TicketEditorViewModel) -> some View {
        let courses = Array(Set(ticket.allItems.map { $0.courseFlag })).sorted(by: { $0.rawValue < $1.rawValue })
        if !courses.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ChromeSectionHeader(title: "Course Pacing", systemImage: "flame")

                ForEach(courses, id: \.self) { course in
                    ChromeCourseRow(
                        course: course,
                        state: vm.coursePacingStates[course] ?? .holding,
                        onFire: { Task { await vm.fireCourse(course) } },
                        onHold: { Task { await vm.holdCourse(course) } }
                    )
                }
            }
            .padding(16)
            .chromeCard(cornerRadius: 14)
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Notes Card

    @ViewBuilder
    private func notesCard() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ChromeSectionHeader(title: "Notes", systemImage: "note.text")
            Text(ticket.notes)
                .font(.callout)
                .foregroundStyle(Color.chromeAmber)
        }
        .padding(16)
        .chromeCard(cornerRadius: 14)
        .padding(.horizontal, 16)
    }

    // MARK: - Edit History Card

    @ViewBuilder
    private func editHistoryCard() -> some View {
        if !ticket.editHistory.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showEditHistory.toggle() }
                } label: {
                    HStack {
                        ChromeSectionHeader(title: "Edit History", systemImage: "clock.arrow.circlepath")
                        Spacer()
                        Image(systemName: showEditHistory ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(Color.chromeSilverLow)
                    }
                }

                if showEditHistory {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider().background(Color.chromeSilverLow.opacity(0.3)).padding(.top, 8)
                        ForEach(ticket.editHistory.sorted(by: { $0.timestamp < $1.timestamp })) { event in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: editHistoryIcon(event.eventType))
                                    .font(.caption)
                                    .foregroundStyle(Color.chromeSilverLow)
                                    .frame(width: 14)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.summary)
                                        .font(.callout)
                                        .foregroundStyle(Color.chromeSilverHigh)
                                    Text(event.timestamp.formatted(.dateTime.hour().minute().second()))
                                        .font(.caption2)
                                        .foregroundStyle(Color.chromeSilverLow)
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
            .chromeCard(cornerRadius: 14)
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Actions Bar (floating bottom)

    @ViewBuilder
    private func actionsBar(vm: TicketEditorViewModel) -> some View {
        if ticket.ticketStatus != .closed {
            VStack(spacing: 0) {
                Divider().background(Color.chromeSilverLow.opacity(0.3))
                HStack(spacing: 12) {
                    if ticket.ticketStatus == .open {
                        Button {
                            Task { await vm.sendToKitchen() }
                        } label: {
                            Label("Send to Kitchen", systemImage: "flame.fill")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity)
                                .padding(14)
                                .background(Color.chromeAmber)
                                .foregroundStyle(.black)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    } else if ticket.ticketStatus == .sent {
                        Button {
                            Task { await vm.markDelivered() }
                        } label: {
                            Label("Mark Delivered", systemImage: "checkmark.circle.fill")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity)
                                .padding(14)
                                .background(Color.chromeTeal)
                                .foregroundStyle(.black)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    } else if ticket.ticketStatus == .delivered {
                        Button {
                            Task { await vm.closeTicket() }
                        } label: {
                            Label("Close Ticket", systemImage: "xmark.circle.fill")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity)
                                .padding(14)
                                .background(Color.chromeRed.opacity(0.8))
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.chromeSurface)
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

// MARK: - Seat Transcript Edit Wrapper

private struct SeatTranscriptEditWrapper: Identifiable {
    let id: Int
    let seat: GuestSeat
    let text: String
}

// MARK: - Chrome Item Row

struct ChromeItemRow: View {
    let item: TicketItem
    let onConfirmAllergy: () -> Void
    let onUpdateNotes: (String) -> Void
    let onMoveSeat: (Int) -> Void
    let onDelete: () -> Void
    let seatCount: Int
    @State private var editingNotes = false
    @State private var notesText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("\(item.quantity)×")
                            .font(.callout.bold())
                            .foregroundStyle(Color.chromePrimary)
                        Text(item.name)
                            .font(.callout.bold())
                            .foregroundStyle(Color.chromeSilverHigh)
                        Text("[\(item.ticketAbbreviation)]")
                            .font(.caption2)
                            .foregroundStyle(Color.chromeSilverLow)
                    }
                    ForEach(item.modifiers) { mod in
                        HStack(spacing: 4) {
                            Image(systemName: mod.isNegation ? "minus.circle.fill" : "plus.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(mod.isNegation ? Color.chromeRed : Color.chromeTeal)
                            Text(mod.isNegation ? "No \(mod.name)" : mod.name)
                                .font(.caption)
                                .foregroundStyle(mod.isNegation ? Color.chromeRed : Color.chromeSilverLow)
                        }
                    }
                    if !item.notes.isEmpty {
                        Label(item.notes, systemImage: "note.text")
                            .font(.caption)
                            .foregroundStyle(Color.chromeAmber)
                            .italic()
                    }
                    if item.confidence < 0.7 {
                        Label("Low confidence — verify", systemImage: "questionmark.circle")
                            .font(.caption2)
                            .foregroundStyle(Color.chromeAmber)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if item.hasAllergyFlag && !item.allergyConfirmed {
                        Button(action: onConfirmAllergy) {
                            Label("ALLERGY", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Color.chromeRed)
                                .clipShape(Capsule())
                        }
                        .glowRing(color: Color.chromeRed, radius: 4)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    notesText = item.notes
                    editingNotes = true
                } label: {
                    Label("Note", systemImage: "square.and.pencil")
                        .font(.caption)
                        .foregroundStyle(Color.chromePrimary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.chromePrimary.opacity(0.12))
                        .clipShape(Capsule())
                }

                if seatCount > 1 {
                    Menu {
                        ForEach(1...max(seatCount, 1), id: \.self) { seat in
                            Button("Seat \(seat)") { onMoveSeat(seat) }
                        }
                    } label: {
                        Label("Move", systemImage: "arrow.left.arrow.right")
                            .font(.caption)
                            .foregroundStyle(Color.chromeAmber)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.chromeAmber.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                Spacer()

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(Color.chromeRed)
                        .padding(6)
                        .background(Color.chromeRed.opacity(0.1))
                        .clipShape(Circle())
                }
            }
        }
        .padding(10)
        .background(Color.chromeSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $editingNotes) {
            NavigationStack {
                ZStack {
                    Color.chromeBackground.ignoresSafeArea()
                    TextEditor(text: $notesText)
                        .scrollContentBackground(.hidden)
                        .background(Color.chromeSurface)
                        .foregroundStyle(Color.chromeSilverHigh)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding()
                }
                .navigationTitle("Kitchen Note")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { onUpdateNotes(notesText); editingNotes = false }
                            .foregroundStyle(Color.chromePrimary)
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { editingNotes = false }
                            .foregroundStyle(Color.chromeRed)
                    }
                }
            }
        }
    }
}

// MARK: - Chrome Timeline Row

struct ChromeTimelineRow: View {
    let label: String
    let date: Date
    let color: Color
    var delta: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(color.opacity(0.2)).frame(width: 24, height: 24)
                Circle().fill(color).frame(width: 8, height: 8)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.chromeSilverHigh)
                Text(date.formatted(.dateTime.hour().minute().month().day()))
                    .font(.caption)
                    .foregroundStyle(Color.chromeSilverLow)
            }
            Spacer()
            if let delta {
                Text(delta)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.chromeSilverLow)
            }
        }
    }
}

// MARK: - Chrome Course Row

struct ChromeCourseRow: View {
    let course: CourseFlag
    let state: CoursePacingState
    let onFire: () -> Void
    let onHold: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(course.displayName)
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.chromeSilverHigh)
                Text(state == .fired ? "Fired" : "Holding")
                    .font(.caption)
                    .foregroundStyle(state == .fired ? Color.chromeTeal : Color.chromeAmber)
            }
            Spacer()
            HStack(spacing: 8) {
                Button(course.fireCommand, action: onFire)
                    .font(.caption.bold())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(state == .fired ? Color.chromeTeal.opacity(0.3) : Color.chromeTeal)
                    .foregroundStyle(state == .fired ? Color.chromeSilverLow : .black)
                    .clipShape(Capsule())
                    .disabled(state == .fired)

                Button("Hold", action: onHold)
                    .font(.caption.bold())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(state == .holding ? Color.chromeAmber.opacity(0.3) : Color.chromeAmber)
                    .foregroundStyle(state == .holding ? Color.chromeSilverLow : .black)
                    .clipShape(Capsule())
                    .disabled(state == .holding)
            }
        }
        .padding(10)
        .background(Color.chromeBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Elapsed Time Label

struct ElapsedTimeLabel: View {
    let since: Date
    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Label(formatInterval(elapsed), systemImage: "clock")
            .font(.caption.monospacedDigit())
            .foregroundStyle(elapsed > 1200 ? Color.chromeRed : elapsed > 600 ? Color.chromeAmber : Color.chromeSilverLow)
            .onAppear { elapsed = Date().timeIntervalSince(since) }
            .onReceive(timer) { _ in elapsed = Date().timeIntervalSince(since) }
    }

    private func formatInterval(_ interval: TimeInterval) -> String {
        "\(Int(interval / 60))m \(Int(interval) % 60)s"
    }
}

// MARK: - Transcript Editor Sheet

struct TranscriptEditorSheet: View {
    @Binding var text: String
    let onSave: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.chromeBackground.ignoresSafeArea()
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .background(Color.chromeSurface)
                    .foregroundStyle(Color.chromeSilverHigh)
                    .font(.body)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding()
            }
            .navigationTitle("Edit Transcript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave() }
                        .foregroundStyle(Color.chromePrimary)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.chromeRed)
                }
            }
        }
    }
}

