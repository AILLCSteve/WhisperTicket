import SwiftUI

struct LiveSessionView: View {
    let tableNumber: String
    @Environment(\.appServices) var services
    @State private var vm: LiveSessionViewModel?
    @State private var navigateToEditor: Ticket? = nil
    @State private var createTicketError: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color.chromeBackground.ignoresSafeArea()

                if let vm {
                    VStack(spacing: 0) {
                        alertsRow(vm: vm)

                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                transcriptCard(vm: vm)

                                if !vm.draft.items.isEmpty {
                                    draftItemsCard(vm: vm)
                                }

                                if !vm.upsellSuggestions.isEmpty {
                                    UpsellSuggestionsView(suggestions: vm.upsellSuggestions) { suggestion in
                                        let item = DraftItem(
                                            menuItemId: suggestion.menuItem.id,
                                            name: suggestion.menuItem.name,
                                            quantity: 1,
                                            modifierNames: [], negations: [],
                                            course: .beverage, seatNumber: nil,
                                            notes: "", confidence: 1.0, hasAllergyFlag: false
                                        )
                                        vm.draft.addItem(item)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                            .padding(.bottom, 160)
                        }

                        controlsBar(vm: vm)
                    }
                    .navigationTitle("Table \(tableNumber)")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(Color.chromeBackground, for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
                    .toolbarColorScheme(.dark, for: .navigationBar)
                    .sheet(isPresented: Binding(
                        get: { vm.showRepeatBack },
                        set: { vm.showRepeatBack = $0 }
                    )) {
                        RepeatBackSheet(draft: vm.draft, onAddItem: { itemText in
                            vm.showRepeatBack = false
                            vm.addManualItem(name: itemText)
                        }) {
                            vm.showRepeatBack = false
                            Task { await confirmAndSend(vm: vm) }
                        }
                    }
                    .navigationDestination(item: $navigateToEditor) { ticket in
                        TicketEditorView(ticket: ticket)
                    }
                    .alert("Error", isPresented: Binding(
                        get: { createTicketError != nil },
                        set: { if !$0 { createTicketError = nil } }
                    )) {
                        Button("OK") { createTicketError = nil }
                    } message: {
                        Text(createTicketError ?? "")
                    }
                } else {
                    VStack(spacing: 16) {
                        ProgressView().tint(Color.chromePrimary)
                        Text("Setting up…").font(.callout).foregroundStyle(Color.chromeSilverLow)
                    }
                }
            }
        }
        .task {
            vm = LiveSessionViewModel(
                tableNumber: tableNumber,
                audioCapture: services.audioCapture,
                transcriptionService: services.transcriptionService,
                parser: services.parser,
                menuStore: services.menuStore,
                upsellEngine: services.upsellEngine
            )
        }
    }

    // MARK: - Alerts

    @ViewBuilder
    private func alertsRow(vm: LiveSessionViewModel) -> some View {
        if vm.showNoisyEnvironmentWarning || !vm.allergyItemsPendingConfirm.isEmpty {
            VStack(spacing: 0) {
                if vm.showNoisyEnvironmentWarning {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.badge.exclamationmark").font(.caption.bold())
                        Text("Loud environment — speak clearly").font(.caption.bold())
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.chromeAmber.opacity(0.85))
                }
                ForEach(vm.allergyItemsPendingConfirm) { item in
                    AllergyAlertBanner(item: item) { vm.confirmAllergyItem(item) }
                }
            }
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private func transcriptCard(vm: LiveSessionViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if vm.isRecording {
                    Circle().fill(Color.chromeRed).frame(width: 8, height: 8)
                        .glowRing(color: .chromeRed, radius: 4)
                }
                ChromeSectionHeader(
                    title: vm.isRecording ? "Recording…" : "Transcript",
                    systemImage: "waveform"
                )
                Spacer()
                if vm.isFinalizingTranscription {
                    HStack(spacing: 5) {
                        ProgressView().tint(Color.chromePrimary).scaleEffect(0.65)
                        Text("Processing…").font(.caption).foregroundStyle(Color.chromeSilverLow)
                    }
                }
            }

            Text(vm.activeSeatTranscript.isEmpty
                 ? "Tap the mic button and speak the order…"
                 : vm.activeSeatTranscript)
                .font(.callout)
                .foregroundStyle(vm.activeSeatTranscript.isEmpty ? Color.chromeSilverLow.opacity(0.6) : .white)
                .italic(vm.activeSeatTranscript.isEmpty)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeInOut, value: vm.activeSeatTranscript)
        }
        .padding(14)
        .chromeCard(
            cornerRadius: 14,
            glowColor: vm.isRecording ? .chromeRed : .clear,
            glowRadius: vm.isRecording ? 10 : 0
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(vm.isRecording ? Color.chromeRed.opacity(0.4) : Color.clear, lineWidth: 1.5)
        )
        .animation(.easeInOut(duration: 0.2), value: vm.isRecording)
    }

    // MARK: - Draft Items

    @ViewBuilder
    private func draftItemsCard(vm: LiveSessionViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ChromeSectionHeader(title: "Order Draft — Table \(tableNumber)", systemImage: "list.bullet.clipboard.fill")

            ForEach(vm.draft.items) { item in
                HStack(alignment: .top, spacing: 10) {
                    CourseDot(course: item.course).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("\(item.quantity)× \(item.name)")
                                .font(.callout.bold()).foregroundStyle(.white)
                            ConfidenceDot(confidence: item.confidence)
                            if item.hasAllergyFlag { ChromeAllergyCapsule() }
                        }
                        if !item.modifierNames.isEmpty {
                            Text(item.modifierNames.joined(separator: " · "))
                                .font(.caption).foregroundStyle(Color.chromeSilverLow)
                        }
                    }
                    Spacer()
                    Button { vm.removeItem(item) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.chromeSilverLow.opacity(0.5))
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
                if item.id != vm.draft.items.last?.id {
                    Divider().background(Color.chromeSilverLow.opacity(0.1))
                }
            }
        }
        .padding(14)
        .chromeCard(cornerRadius: 14)
    }

    // MARK: - Controls Bar

    @ViewBuilder
    private func controlsBar(vm: LiveSessionViewModel) -> some View {
        VStack(spacing: 0) {
            if vm.isRecording || vm.isFinalizingTranscription {
                HStack {
                    Spacer()
                    AudioWaveformView(isActive: vm.isRecording, noiseLevel: vm.noiseLevel)
                    Spacer()
                }
                .padding(.vertical, 6)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(spacing: 0) {
                Button { vm.triggerRepeatBack() } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(vm.draft.items.isEmpty && vm.seatTranscripts.isEmpty
                                             ? Color.chromeSilverLow.opacity(0.4)
                                             : Color.chromeTeal)
                        Text("Confirm")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(vm.draft.items.isEmpty && vm.seatTranscripts.isEmpty
                                             ? Color.chromeSilverLow.opacity(0.4)
                                             : Color.chromeTeal)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(vm.draft.items.isEmpty && vm.seatTranscripts.isEmpty)

                LiveMicButton(isRecording: vm.isRecording, isDisabled: false) {
                    if vm.isRecording { vm.stopRecording() }
                    else { vm.startRecording() }
                }
                .frame(maxWidth: .infinity)

                Button { Task { await confirmAndNavigate(vm: vm) } } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(vm.draft.items.isEmpty && vm.seatTranscripts.isEmpty
                                             ? Color.chromeSilverLow.opacity(0.4)
                                             : Color.chromePrimary)
                        Text("Edit")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(vm.draft.items.isEmpty && vm.seatTranscripts.isEmpty
                                             ? Color.chromeSilverLow.opacity(0.4)
                                             : Color.chromePrimary)
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
                            .fill(LinearGradient(
                                colors: [Color.chromeSilverHigh.opacity(0.10), Color.clear],
                                startPoint: .top, endPoint: .bottom
                            ))
                            .frame(height: 1),
                        alignment: .top
                    )
            )
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 0) }
        }
        .animation(.easeInOut(duration: 0.25), value: vm.isRecording)
    }

    // MARK: - Actions

    private func confirmAndNavigate(vm: LiveSessionViewModel) async {
        do {
            let ticket = try await services.repository.createTicket(from: vm.draft, serverId: "local_server")
            navigateToEditor = ticket
        } catch {
            createTicketError = "Could not create ticket: \(error.localizedDescription)"
        }
    }

    private func confirmAndSend(vm: LiveSessionViewModel) async {
        do {
            let ticket = try await services.repository.createTicket(from: vm.draft, serverId: "local_server")
            ticket.sentToKitchenAt = Date()
            ticket.status = TicketStatus.sent.rawValue
            try await services.repository.save(ticket)
            navigateToEditor = ticket
        } catch {
            createTicketError = "Could not send ticket: \(error.localizedDescription)"
        }
    }
}

// MARK: - Hold-to-Talk Button (kept for any legacy callers)

struct HoldToTalkButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        LiveMicButton(isRecording: isRecording, isDisabled: false, action: action)
    }
}

// MARK: - Draft Item Row (kept for any legacy callers)

struct DraftItemRow: View {
    let item: DraftItem
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CourseDot(course: item.course).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(item.quantity)× \(item.name)").font(.callout.bold()).foregroundStyle(.white)
                    ConfidenceDot(confidence: item.confidence)
                    if item.hasAllergyFlag { ChromeAllergyCapsule() }
                }
                if !item.modifierNames.isEmpty {
                    Text(item.modifierNames.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Color.chromeSilverLow)
                }
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.chromeSilverLow.opacity(0.5))
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Repeat-Back Sheet

struct RepeatBackSheet: View {
    let draft: TicketDraft
    var seatLabels: [Int: String] = [:]
    var onAddItem: ((String) -> Void)? = nil
    let onSendToKitchen: () -> Void
    @Environment(\.dismiss) var dismiss

    @State private var showAddItem = false
    @State private var addItemText = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color.chromeBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Review the order with your guests before sending to the kitchen.")
                            .font(.callout)
                            .foregroundStyle(Color.chromeSilverLow)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)

                        orderContent
                            .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 20)
                }
            }
            .navigationTitle("Confirm Order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.chromeBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Edit Order") { dismiss() }
                        .foregroundStyle(Color.chromeSilverLow)
                }
                if onAddItem != nil {
                    ToolbarItem(placement: .bottomBar) {
                        Button {
                            addItemText = ""
                            showAddItem = true
                        } label: {
                            Label("Add Item", systemImage: "plus.circle")
                                .foregroundStyle(Color.chromePrimary)
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onSendToKitchen()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "flame.fill")
                            Text("Send")
                        }
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.chromeAmber)
                    }
                }
            }
            .alert("Add Item", isPresented: $showAddItem) {
                TextField("e.g. Caesar salad no croutons", text: $addItemText)
                Button("Add") {
                    let t = addItemText.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { onAddItem?(t) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Item will be added to the current seat's order.")
            }
        }
    }

    @ViewBuilder
    private var orderContent: some View {
        let seatedNums = Set(draft.items.compactMap { $0.seatNumber }).sorted()
        let unseated = draft.items.filter { $0.seatNumber == nil }
        if !seatedNums.isEmpty || !unseated.isEmpty {
            ForEach(seatedNums, id: \.self) { num in
                RepeatBackSeatSection(
                    label: seatLabels[num] ?? "Seat \(num)",
                    items: draft.items.filter { $0.seatNumber == num },
                    transcript: draft.seatTranscripts[num]
                )
            }
            if !unseated.isEmpty {
                RepeatBackSeatSection(label: "Unassigned", items: unseated, transcript: nil)
            }
        } else if !draft.aggregateTranscript.isEmpty {
            Text(draft.aggregateTranscript)
                .font(.callout)
                .foregroundStyle(.white)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .chromeCard(cornerRadius: 12)
        } else {
            Text("No order captured yet.")
                .foregroundStyle(Color.chromeSilverLow)
                .italic()
        }
    }
}

private struct RepeatBackSeatSection: View {
    let label: String
    let items: [DraftItem]
    let transcript: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "person.fill")
                    .font(.caption.bold())
                    .foregroundStyle(Color.chromePrimary)
                Text(label)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
            }

            if items.isEmpty {
                if let t = transcript, !t.isEmpty {
                    Text("\"\(t)\"")
                        .font(.callout).foregroundStyle(Color.chromeSilverLow).italic()
                } else {
                    Text("No items").font(.callout).foregroundStyle(Color.chromeSilverLow).italic()
                }
            } else {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        CourseDot(course: item.course).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("\(item.quantity)× \(item.name)").font(.callout.bold()).foregroundStyle(.white)
                                if item.hasAllergyFlag { ChromeAllergyCapsule() }
                            }
                            if !item.modifierNames.isEmpty {
                                Text(item.modifierNames.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(Color.chromeSilverLow)
                            }
                            if !item.notes.isEmpty {
                                Text(item.notes).font(.caption).foregroundStyle(Color.chromeAmber.opacity(0.8)).italic()
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .chromeCard(cornerRadius: 14)
    }
}
