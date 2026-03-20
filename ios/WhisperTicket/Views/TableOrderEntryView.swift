import SwiftUI

/// The seat-first ordering hub.
///
/// Workflow:
/// 1. Server arrives at table → taps table on Floor view → this screen appears.
/// 2. Seat chips across the top represent each guest. Active seat is highlighted.
/// 3. Server taps a seat chip to select who they're ordering for.
/// 4. Hold-to-talk records voice — items are attributed to the selected seat.
/// 5. Server taps next seat chip, records again. Items accumulate per seat.
/// 6. Any seat can have items added manually (type a few words) as a fallback.
/// 7. "Review & Send" confirms the full order and fires to kitchen.
///
/// This solves the "auction problem": servers know exactly who ordered what
/// because every item is tagged to a specific seat from the moment it's captured.
struct TableOrderEntryView: View {
    let table: FloorTable
    @Environment(\.appServices) var services
    @State private var vm: LiveSessionViewModel?
    @State private var seatConfigs: [SeatConfig]
    @State private var activeSeatIndex: Int = 0
    @State private var navigateToEditor: Ticket?
    @State private var createError: String?
    @State private var showManualEntry = false
    @State private var manualItemText = ""
    @State private var showAddSeat = false
    @State private var newSeatLabel = ""

    init(table: FloorTable) {
        self.table = table
        _seatConfigs = State(initialValue: table.seats.isEmpty ? SeatConfig.numbered(2) : table.seats)
    }

    private var activeSeat: SeatConfig { seatConfigs[min(activeSeatIndex, seatConfigs.count - 1)] }

    var body: some View {
        Group {
            if let vm {
                mainContent(vm: vm)
            } else {
                ProgressView("Setting up table...")
                    .task { setupVM() }
            }
        }
        .navigationTitle("Table \(table.name)")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Main Layout

    @ViewBuilder
    private func mainContent(vm: LiveSessionViewModel) -> some View {
        VStack(spacing: 0) {
            // ── Seat Selector ──────────────────────────────────────────
            seatSelectorStrip(vm: vm)

            Divider()

            // ── Order Summary + Transcript ─────────────────────────────
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    orderSummarySection(vm: vm)
                    transcriptSection(vm: vm)
                    if !vm.upsellSuggestions.isEmpty { upsellSection(vm: vm) }
                }
                .padding()
            }

            Divider()

            // ── Controls ───────────────────────────────────────────────
            bottomControls(vm: vm)
        }
        .sheet(isPresented: Binding(get: { vm.showRepeatBack }, set: { vm.showRepeatBack = $0 })) {
            RepeatBackSheet(text: vm.repeatBackText) {
                vm.showRepeatBack = false
                Task { await createAndSend(vm: vm) }
            }
        }
        .navigationDestination(item: $navigateToEditor) { ticket in
            TicketEditorView(ticket: ticket)
        }
        .alert("Error", isPresented: Binding(get: { createError != nil }, set: { if !$0 { createError = nil } })) {
            Button("OK") { createError = nil }
        } message: { Text(createError ?? "") }
    }

    // MARK: - Seat Strip

    @ViewBuilder
    private func seatSelectorStrip(vm: LiveSessionViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(seatConfigs.indices, id: \.self) { idx in
                    let seatNum = idx + 1
                    let hasItems = vm.draft.items.contains { $0.seatNumber == seatNum }
                    SeatChip(
                        label: seatConfigs[idx].label,
                        isActive: idx == activeSeatIndex,
                        hasItems: hasItems
                    ) {
                        activeSeatIndex = idx
                        vm.activeSeatNumber = seatNum
                        vm.activeSeatLabel = seatConfigs[idx].label
                    } onRename: { newLabel in
                        seatConfigs[idx].label = newLabel
                        if idx == activeSeatIndex { vm.activeSeatLabel = newLabel }
                        persistSeats()
                    } onClear: {
                        vm.clearSeat(seatNum)
                    }
                }

                // Add seat
                Button {
                    newSeatLabel = "\(seatConfigs.count + 1)"
                    showAddSeat = true
                } label: {
                    Label("Add", systemImage: "person.badge.plus")
                        .font(.caption.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .alert("Add Seat", isPresented: $showAddSeat) {
                    TextField("Name or number", text: $newSeatLabel)
                    Button("Add") {
                        let l = newSeatLabel.trimmingCharacters(in: .whitespaces)
                        guard !l.isEmpty else { return }
                        seatConfigs.append(SeatConfig(label: l))
                        persistSeats()
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.secondarySystemBackground))
    }

    // MARK: - Order Summary

    @ViewBuilder
    private func orderSummarySection(vm: LiveSessionViewModel) -> some View {
        let groups = vm.itemsBySeat()
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Order", systemImage: "list.bullet.clipboard")
                    .font(.headline)

                ForEach(groups, id: \.seatNumber) { group in
                    let seatIdx = group.seatNumber - 1
                    let label = seatIdx >= 0 && seatIdx < seatConfigs.count
                        ? seatConfigs[seatIdx].label : "Seat \(group.seatNumber)"
                    let isActive = group.seatNumber == activeSeatIndex + 1

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(label, systemImage: isActive ? "person.fill" : "person")
                                .font(.subheadline.bold())
                                .foregroundStyle(isActive ? .accentColor : .primary)
                            Spacer()
                            Button {
                                activeSeatIndex = max(0, group.seatNumber - 1)
                                vm.activeSeatNumber = group.seatNumber
                                vm.clearSeat(group.seatNumber)
                            } label: {
                                Text("Re-record")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        ForEach(group.items) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Text("•")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(item.quantity)× \(item.name)")
                                        .font(.callout)
                                    if !item.modifierNames.isEmpty {
                                        Text(item.modifierNames.joined(separator: ", "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button { vm.removeItem(item) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(Color(.tertiaryLabel))
                                }
                            }
                            .padding(.leading, 8)
                        }
                    }
                    .padding(12)
                    .background(isActive ? Color.accentColor.opacity(0.06) : Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    // MARK: - Live Transcript for Active Seat

    @ViewBuilder
    private func transcriptSection(vm: LiveSessionViewModel) -> some View {
        let seatLabel = activeSeat.label
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Recording for: \(seatLabel)", systemImage: "mic.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.accentColor)
                Spacer()
                if vm.isFinalizingTranscription {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }

            if vm.isRecording {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .foregroundStyle(vm.noiseLevel > 0.75 ? .orange : .green)
                    ProgressView(value: Double(vm.noiseLevel))
                        .tint(vm.noiseLevel > 0.75 ? .orange : .green)
                        .frame(maxWidth: 120)
                    Text(vm.noiseLevel > 0.75 ? "Loud" : "Good")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if !vm.transcript.isEmpty {
                Text(vm.transcript)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .animation(.easeInOut, value: vm.transcript)
            } else if !vm.isRecording {
                Text("Hold the mic button to record \(seatLabel)'s order.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .italic()
            }

            // Allergy banners
            ForEach(vm.allergyItemsPendingConfirm) { item in
                AllergyAlertBanner(item: item) { vm.confirmAllergyItem(item) }
            }
        }
    }

    // MARK: - Upsell

    @ViewBuilder
    private func upsellSection(vm: LiveSessionViewModel) -> some View {
        UpsellSuggestionsView(suggestions: vm.upsellSuggestions) { suggestion in
            let item = DraftItem(
                menuItemId: suggestion.menuItem.id,
                name: suggestion.menuItem.name,
                quantity: 1, modifierNames: [], negations: [],
                course: .beverage, seatNumber: activeSeatIndex + 1,
                notes: "", confidence: 1.0, hasAllergyFlag: false
            )
            vm.draft.addItem(item)
        }
    }

    // MARK: - Bottom Controls

    @ViewBuilder
    private func bottomControls(vm: LiveSessionViewModel) -> some View {
        VStack(spacing: 10) {
            // Manual entry row
            HStack(spacing: 12) {
                // Manual item button
                Button {
                    manualItemText = ""
                    showManualEntry = true
                } label: {
                    Label("Add Item", systemImage: "keyboard")
                        .font(.caption.bold())
                }
                .buttonStyle(.bordered)
                .alert("Add Item Manually", isPresented: $showManualEntry) {
                    TextField("e.g. Caesar salad no croutons", text: $manualItemText)
                    Button("Add") { vm.addManualItem(name: manualItemText) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Type a short description for \(activeSeat.label)'s item.")
                }

                // AI Auto-fill placeholder
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                    Text("AI Fill")
                    Text("(Soon)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .foregroundStyle(.secondary)
                .clipShape(Capsule())
            }

            // Main action row
            HStack(spacing: 24) {
                // Review & Send
                Button {
                    vm.triggerRepeatBack()
                } label: {
                    Label("Review & Send", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(vm.draft.items.isEmpty && vm.transcript.isEmpty)

                // Hold-to-Talk
                HoldToTalkButton(isRecording: vm.isRecording) {
                    if vm.isRecording { vm.stopRecording() }
                    else { vm.startRecording() }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
    }

    // MARK: - Actions

    private func setupVM() {
        let newVM = LiveSessionViewModel(
            tableNumber: table.name,
            audioCapture: services.audioCapture,
            transcriptionService: services.transcriptionService,
            parser: services.parser,
            menuStore: services.menuStore,
            upsellEngine: services.upsellEngine
        )
        newVM.activeSeatNumber = 1
        newVM.activeSeatLabel = seatConfigs.first?.label ?? "1"
        vm = newVM
    }

    private func createAndSend(vm: LiveSessionViewModel) async {
        do {
            let ticket = try await services.repository.createTicket(
                from: vm.draft, serverId: "local_server"
            )
            ticket.sentToKitchenAt = Date()
            ticket.status = TicketStatus.sent.rawValue
            try await services.repository.save(ticket)
            navigateToEditor = ticket
        } catch {
            createError = "Could not send order: \(error.localizedDescription)"
        }
    }

    private func persistSeats() {
        var updated = table
        updated.seats = seatConfigs
        services.floorPlanStore.upsertTable(updated)
    }
}

// MARK: - Seat Chip

struct SeatChip: View {
    let label: String
    let isActive: Bool
    let hasItems: Bool
    let onTap: () -> Void
    let onRename: (String) -> Void
    let onClear: () -> Void

    @State private var showRename = false
    @State private var showMenu = false
    @State private var renameText = ""

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                if hasItems {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(isActive ? .white : .green)
                }
                Text(label)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 100)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isActive ? Color.accentColor : Color(.secondarySystemBackground))
            .foregroundStyle(isActive ? .white : .primary)
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(
                    hasItems && !isActive ? Color.green.opacity(0.5) : Color.clear,
                    lineWidth: 1.5
                )
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renameText = label
                showRename = true
            } label: { Label("Rename", systemImage: "pencil") }

            if hasItems {
                Button(role: .destructive) {
                    onClear()
                } label: { Label("Clear Items", systemImage: "trash") }
            }
        }
        .alert("Rename Seat", isPresented: $showRename) {
            TextField("Name or mnemonic", text: $renameText)
            Button("Save") {
                let t = renameText.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { onRename(t) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Use a helpful cue: "Mom", "Blue shirt", "Window seat"")
        }
    }
}
