import SwiftUI

/// The seat-first ordering hub.
///
/// Workflow:
/// 1. Server arrives at table → taps table on Floor view → this screen appears.
/// 2. Seat chips across the top represent each guest. Active seat is highlighted.
/// 3. Server taps a seat chip to select who they're ordering for.
/// 4. Tap-to-talk records voice — items are attributed to the selected seat.
/// 5. Server taps next seat chip, records again. Items accumulate per seat.
/// 6. Any seat can have items added manually (type a few words) as a fallback.
/// 7. "Review & Send" confirms the full order and fires to kitchen.
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
                ZStack {
                    Color.chromeBackground.ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .tint(Color.chromePrimary)
                            .scaleEffect(1.3)
                        Text("Setting up table…")
                            .font(.callout)
                            .foregroundStyle(Color.chromeSilverLow)
                    }
                }
                .task { setupVM() }
            }
        }
        .navigationTitle("Table \(table.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.chromeBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .background(Color.chromeBackground)
    }

    // MARK: - Main Layout

    @ViewBuilder
    private func mainContent(vm: LiveSessionViewModel) -> some View {
        ZStack(alignment: .bottom) {
            Color.chromeBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                seatSelectorStrip(vm: vm)

                // Alerts row
                alertsRow(vm: vm)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !vm.itemsBySeat().isEmpty {
                            orderSummarySection(vm: vm)
                        }
                        transcriptSection(vm: vm)
                        if !vm.upsellSuggestions.isEmpty {
                            upsellSection(vm: vm)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 180)
                }
            }

            bottomBar(vm: vm)
        }
        .sheet(isPresented: Binding(get: { vm.showRepeatBack }, set: { vm.showRepeatBack = $0 })) {
            let seatLabelMap = Dictionary(
                uniqueKeysWithValues: seatConfigs.enumerated().map { ($0.offset + 1, $0.element.label) }
            )
            RepeatBackSheet(draft: vm.draft, seatLabels: seatLabelMap, onAddItem: { itemText in
                vm.showRepeatBack = false
                vm.addManualItem(name: itemText)
            }) {
                vm.showRepeatBack = false
                Task { await createAndSend(vm: vm) }
            }
        }
        .navigationDestination(item: $navigateToEditor) { ticket in
            TicketEditorView(ticket: ticket)
        }
        .alert("Error", isPresented: Binding(
            get: { createError != nil },
            set: { if !$0 { createError = nil } }
        )) {
            Button("OK") { createError = nil }
        } message: { Text(createError ?? "") }
    }

    // MARK: - Seat Selector Strip

    @ViewBuilder
    private func seatSelectorStrip(vm: LiveSessionViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
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

                Button {
                    newSeatLabel = "\(seatConfigs.count + 1)"
                    showAddSeat = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Add")
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .foregroundStyle(Color.chromeSilverLow)
                    .background(Color.chromeSurface)
                    .overlay(Capsule().strokeBorder(Color.chromeSilverLow.opacity(0.2), lineWidth: 1))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
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
        .background(
            Color.chromeBackground
                .overlay(
                    Rectangle()
                        .fill(Color.chromeSilverHigh.opacity(0.06))
                        .frame(height: 1),
                    alignment: .bottom
                )
        )
    }

    // MARK: - Alerts Row

    @ViewBuilder
    private func alertsRow(vm: LiveSessionViewModel) -> some View {
        if vm.showNoisyEnvironmentWarning || !vm.allergyItemsPendingConfirm.isEmpty || vm.detectedMacro != nil {
            VStack(spacing: 0) {
                if vm.showNoisyEnvironmentWarning {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.badge.exclamationmark")
                            .font(.caption.bold())
                        Text("Loud environment — speak clearly")
                            .font(.caption.bold())
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.chromeAmber.opacity(0.85))
                }

                ForEach(vm.allergyItemsPendingConfirm) { item in
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.chromeRed)
                            .font(.subheadline.bold())
                        Text("ALLERGY: \(item.name)")
                            .font(.subheadline.bold())
                            .foregroundStyle(Color.chromeRed)
                        Spacer()
                        Button("Confirm") { vm.confirmAllergyItem(item) }
                            .font(.caption.bold())
                            .foregroundStyle(Color.chromeRed)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Color.chromeRed.opacity(0.15))
                            .overlay(Capsule().strokeBorder(Color.chromeRed.opacity(0.4), lineWidth: 1))
                            .clipShape(Capsule())
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.chromeRed.opacity(0.08))
                    .overlay(
                        Rectangle()
                            .fill(Color.chromeRed)
                            .frame(width: 3),
                        alignment: .leading
                    )
                }

                if let macro = vm.detectedMacro {
                    HStack(spacing: 10) {
                        Image(systemName: "mic.badge.plus")
                            .foregroundStyle(Color.chromePrimary)
                        Text("Voice command: \(macro.displayName)")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                        Spacer()
                        Button("Apply") { vm.applyMacro(macro, previousDraft: nil) }
                            .font(.caption.bold())
                            .foregroundStyle(Color.chromePrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Color.chromePrimary.opacity(0.15))
                            .overlay(Capsule().strokeBorder(Color.chromePrimary.opacity(0.4), lineWidth: 1))
                            .clipShape(Capsule())
                        Button("Dismiss") { vm.detectedMacro = nil }
                            .font(.caption)
                            .foregroundStyle(Color.chromeSilverLow)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.chromePrimary.opacity(0.07))
                    .overlay(
                        Rectangle()
                            .fill(Color.chromePrimary)
                            .frame(width: 3),
                        alignment: .leading
                    )
                }
            }
        }
    }

    // MARK: - Order Summary

    @ViewBuilder
    private func orderSummarySection(vm: LiveSessionViewModel) -> some View {
        let groups = vm.itemsBySeat()
        VStack(alignment: .leading, spacing: 10) {
            ChromeSectionHeader(title: "Order", systemImage: "list.bullet.clipboard.fill")
                .padding(.bottom, 2)

            ForEach(groups, id: \.seatNumber) { group in
                let seatIdx = group.seatNumber - 1
                let label = seatIdx >= 0 && seatIdx < seatConfigs.count
                    ? seatConfigs[seatIdx].label : "Seat \(group.seatNumber)"
                let isActive = group.seatNumber == activeSeatIndex + 1

                SeatOrderCard(
                    label: label,
                    seatNumber: group.seatNumber,
                    items: group.items,
                    isActive: isActive
                ) {
                    // Switch to this seat
                    activeSeatIndex = max(0, group.seatNumber - 1)
                    vm.activeSeatNumber = group.seatNumber
                    vm.activeSeatLabel = seatConfigs[max(0, group.seatNumber - 1)].label
                } onClear: {
                    activeSeatIndex = max(0, group.seatNumber - 1)
                    vm.activeSeatNumber = group.seatNumber
                    vm.clearSeat(group.seatNumber)
                } onRemoveItem: { item in
                    vm.removeItem(item)
                }
            }
        }
    }

    // MARK: - Transcript Section

    @ViewBuilder
    private func transcriptSection(vm: LiveSessionViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ChromeSectionHeader(title: "Transcript", systemImage: "waveform")
                Spacer()
                if vm.isFinalizingTranscription {
                    HStack(spacing: 6) {
                        ProgressView()
                            .tint(Color.chromePrimary)
                            .scaleEffect(0.65)
                        Text("Processing…")
                            .font(.caption)
                            .foregroundStyle(Color.chromeSilverLow)
                    }
                }
            }

            ForEach(seatConfigs.indices, id: \.self) { idx in
                let seatNum = idx + 1
                let isActive = seatNum == activeSeatIndex + 1
                let stored = vm.seatTranscripts[seatNum] ?? ""
                let display = (isActive && vm.isRecording) ? vm.activeSeatTranscript : stored

                if isActive || !stored.isEmpty {
                    SeatTranscriptCard(
                        seatLabel: seatConfigs[idx].label,
                        transcript: display,
                        isActive: isActive,
                        isRecording: isActive && vm.isRecording,
                        noiseLevel: vm.noiseLevel
                    ) {
                        activeSeatIndex = idx
                        vm.activeSeatNumber = seatNum
                        vm.activeSeatLabel = seatConfigs[idx].label
                    }
                }
            }
        }
    }

    // MARK: - Upsell Section

    @ViewBuilder
    private func upsellSection(vm: LiveSessionViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ChromeSectionHeader(title: "Suggestions", systemImage: "sparkles")
                .padding(.bottom, 2)

            ForEach(vm.upsellSuggestions) { suggestion in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(suggestion.menuItem.name)
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                        Text(suggestion.playbookScript ?? suggestion.reason)
                            .font(.caption)
                            .foregroundStyle(Color.chromeSilverLow)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button {
                        let item = DraftItem(
                            menuItemId: suggestion.menuItem.id,
                            name: suggestion.menuItem.name,
                            quantity: 1, modifierNames: [], negations: [],
                            course: .beverage, seatNumber: activeSeatIndex + 1,
                            notes: "", confidence: 1.0, hasAllergyFlag: false
                        )
                        vm.draft.addItem(item)
                    } label: {
                        Text("Add")
                            .font(.caption.bold())
                            .foregroundStyle(Color.chromePrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.chromePrimary.opacity(0.15))
                            .overlay(Capsule().strokeBorder(Color.chromePrimary.opacity(0.4), lineWidth: 1))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .chromeCard(cornerRadius: 12, glowColor: .chromePrimary, glowRadius: 4)
            }
        }
    }

    // MARK: - Bottom Bar

    @ViewBuilder
    private func bottomBar(vm: LiveSessionViewModel) -> some View {
        VStack(spacing: 0) {
            // Waveform strip — visible when recording
            if vm.isRecording || vm.isFinalizingTranscription {
                HStack(spacing: 0) {
                    Spacer()
                    AudioWaveformView(isActive: vm.isRecording, noiseLevel: vm.noiseLevel)
                    Spacer()
                }
                .padding(.vertical, 6)
                .background(Color.chromeBackground)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Main controls
            HStack(spacing: 0) {
                // Manual entry
                Button {
                    manualItemText = ""
                    showManualEntry = true
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 20, weight: .medium))
                        Text("Type")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Color.chromeSilverLow)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .alert("Add Item Manually", isPresented: $showManualEntry) {
                    TextField("e.g. Caesar salad no croutons", text: $manualItemText)
                    Button("Add") { vm.addManualItem(name: manualItemText) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Adding to \(activeSeat.label)")
                }

                // Mic button — center
                LiveMicButton(
                    isRecording: vm.isRecording,
                    isDisabled: false
                ) {
                    if vm.isRecording { vm.stopRecording() }
                    else { vm.startRecording() }
                }
                .frame(maxWidth: .infinity)

                // Review & Send
                Button {
                    vm.triggerRepeatBack()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(vm.draft.items.isEmpty && vm.seatTranscripts.isEmpty
                                             ? Color.chromeSilverLow.opacity(0.4)
                                             : Color.chromeTeal)
                        Text("Send")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(vm.draft.items.isEmpty && vm.seatTranscripts.isEmpty
                                             ? Color.chromeSilverLow.opacity(0.4)
                                             : Color.chromeTeal)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(vm.draft.items.isEmpty && vm.seatTranscripts.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(
                Color.chromeSurface
                    .overlay(
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.chromeSilverHigh.opacity(0.10), Color.clear],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .frame(height: 1),
                        alignment: .top
                    )
            )
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 0) }
        }
        .animation(.easeInOut(duration: 0.25), value: vm.isRecording)
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

// MARK: - Seat Order Card

private struct SeatOrderCard: View {
    let label: String
    let seatNumber: Int
    let items: [DraftItem]
    let isActive: Bool
    let onSwitchTo: () -> Void
    let onClear: () -> Void
    let onRemoveItem: (DraftItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "person.fill" : "person")
                    .font(.caption.bold())
                    .foregroundStyle(isActive ? Color.chromePrimary : Color.chromeSilverLow)
                Text(label)
                    .font(.subheadline.bold())
                    .foregroundStyle(isActive ? .white : Color.chromeSilverHigh)
                Spacer()
                Button(action: onSwitchTo) {
                    Text("Add More")
                        .font(.caption2.bold())
                        .foregroundStyle(Color.chromePrimary)
                }
                .buttonStyle(.plain)
                Text("·").font(.caption2).foregroundStyle(Color.chromeSilverLow.opacity(0.5))
                Button(role: .destructive, action: onClear) {
                    Text("Clear")
                        .font(.caption2.bold())
                        .foregroundStyle(Color.chromeRed.opacity(0.7))
                }
                .buttonStyle(.plain)
            }

            Divider()
                .background(Color.chromeSilverLow.opacity(0.15))

            ForEach(items) { item in
                HStack(alignment: .top, spacing: 10) {
                    CourseDot(course: item.course)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("\(item.quantity)× \(item.name)")
                                .font(.callout.bold())
                                .foregroundStyle(.white)
                            ConfidenceDot(confidence: item.confidence)
                            if item.hasAllergyFlag { ChromeAllergyCapsule() }
                        }
                        if !item.modifierNames.isEmpty {
                            Text(item.modifierNames.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(Color.chromeSilverLow)
                        }
                        if !item.negations.isEmpty {
                            Text(item.negations.map { "no \($0)" }.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(Color.chromeAmber.opacity(0.8))
                        }
                    }
                    Spacer()
                    Button { onRemoveItem(item) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.chromeSilverLow.opacity(0.5))
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .chromeCard(
            cornerRadius: 14,
            glowColor: isActive ? .chromePrimary : .clear,
            glowRadius: isActive ? 8 : 0
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    isActive ? Color.chromePrimary.opacity(0.35) : Color.clear,
                    lineWidth: 1
                )
        )
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
    @State private var renameText = ""

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if hasItems {
                    Circle()
                        .fill(isActive ? .white : Color.chromeTeal)
                        .frame(width: 6, height: 6)
                        .shadow(color: Color.chromeTeal.opacity(0.8), radius: 3)
                }
                Text(label)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 110)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                isActive
                    ? AnyView(LinearGradient(
                        colors: [Color(red: 0.25, green: 0.45, blue: 0.95), Color.chromePrimary],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                      ).clipShape(Capsule()))
                    : AnyView(Color.chromeSurface.clipShape(Capsule()))
            )
            .foregroundStyle(isActive ? .white : Color.chromeSilverHigh)
            .overlay(
                Capsule().strokeBorder(
                    isActive
                        ? Color.chromePrimary.opacity(0.5)
                        : hasItems
                            ? Color.chromeTeal.opacity(0.35)
                            : Color.chromeSilverLow.opacity(0.18),
                    lineWidth: 1
                )
            )
            .shadow(
                color: isActive ? Color.chromePrimary.opacity(0.4) : .clear,
                radius: 8
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renameText = label
                showRename = true
            } label: { Label("Rename", systemImage: "pencil") }

            if hasItems {
                Button(role: .destructive, action: onClear) {
                    Label("Clear Items", systemImage: "trash")
                }
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
            Text("Use a helpful cue: \"Mom\", \"Blue shirt\", \"Window seat\"")
        }
    }
}

// MARK: - Seat Transcript Card

struct SeatTranscriptCard: View {
    let seatLabel: String
    let transcript: String
    let isActive: Bool
    let isRecording: Bool
    let noiseLevel: Float
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // Recording pulse dot
                if isRecording {
                    Circle()
                        .fill(Color.chromeRed)
                        .frame(width: 8, height: 8)
                        .glowRing(color: .chromeRed, radius: 4)
                }

                Text(isRecording ? "Recording: \(seatLabel)" : seatLabel)
                    .font(.caption.bold())
                    .tracking(0.5)
                    .foregroundStyle(isActive ? Color.chromePrimary : Color.chromeSilverLow)

                Spacer()

                if !isActive {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.chromeSilverLow.opacity(0.5))
                }
            }

            if !transcript.isEmpty {
                Text(transcript)
                    .font(.callout)
                    .foregroundStyle(isActive ? .white : Color.chromeSilverHigh)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(isActive ? nil : 2)
                    .animation(.easeInOut(duration: 0.2), value: transcript)
            } else if isActive {
                Text("Tap the mic and speak \(seatLabel)'s order.")
                    .font(.callout)
                    .foregroundStyle(Color.chromeSilverLow.opacity(0.7))
                    .italic()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.chromeSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            isRecording
                                ? Color.chromeRed.opacity(0.5)
                                : isActive
                                    ? Color.chromePrimary.opacity(0.3)
                                    : Color.chromeSilverLow.opacity(0.12),
                            lineWidth: isRecording ? 1.5 : 1
                        )
                )
        )
        .shadow(
            color: isRecording ? Color.chromeRed.opacity(0.15) : isActive ? Color.chromePrimary.opacity(0.10) : .clear,
            radius: 8
        )
        .onTapGesture(perform: isActive ? {} : onTap)
        .animation(.easeInOut(duration: 0.2), value: isRecording)
    }
}

// MARK: - Allergy Alert Banner (used in LiveSessionView too)

struct AllergyAlertBanner: View {
    let item: DraftItem
    let onConfirm: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.chromeRed)
                .font(.subheadline.bold())
            Text("ALLERGY: \(item.name)")
                .font(.subheadline.bold())
                .foregroundStyle(Color.chromeRed)
            Spacer()
            Button("Confirm", action: onConfirm)
                .font(.caption.bold())
                .foregroundStyle(Color.chromeRed)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.chromeRed.opacity(0.15))
                .overlay(Capsule().strokeBorder(Color.chromeRed.opacity(0.4), lineWidth: 1))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.chromeRed.opacity(0.08))
        .overlay(Rectangle().fill(Color.chromeRed).frame(width: 3), alignment: .leading)
    }
}

// MARK: - Upsell Suggestions View (used in LiveSessionView too)

struct UpsellSuggestionsView: View {
    let suggestions: [UpsellSuggestionResult]
    let onAdd: (UpsellSuggestionResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChromeSectionHeader(title: "Suggestions", systemImage: "sparkles")
            ForEach(suggestions) { suggestion in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(suggestion.menuItem.name)
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                        Text(suggestion.playbookScript ?? suggestion.reason)
                            .font(.caption)
                            .foregroundStyle(Color.chromeSilverLow)
                    }
                    Spacer()
                    Button("Add") { onAdd(suggestion) }
                        .font(.caption.bold())
                        .foregroundStyle(Color.chromePrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.chromePrimary.opacity(0.15))
                        .overlay(Capsule().strokeBorder(Color.chromePrimary.opacity(0.4), lineWidth: 1))
                        .clipShape(Capsule())
                        .buttonStyle(.plain)
                }
                .padding(12)
                .chromeCard(cornerRadius: 12)
            }
        }
    }
}
