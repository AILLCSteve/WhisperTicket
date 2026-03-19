import SwiftUI

struct LiveSessionView: View {
    let tableNumber: String
    @Environment(\.appServices) var services
    @State private var vm: LiveSessionViewModel?
    @State private var navigateToEditor: Ticket? = nil
    @State private var createTicketError: String? = nil

    var body: some View {
        NavigationStack {
            if let vm {
                VStack(spacing: 0) {
                    // Noise warning
                    if vm.showNoisyEnvironmentWarning {
                        Label("Loud environment — speak clearly", systemImage: "waveform.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(8)
                            .frame(maxWidth: .infinity)
                            .background(.orange)
                    }

                    // Allergy alerts
                    ForEach(vm.allergyItemsPendingConfirm) { item in
                        AllergyAlertBanner(item: item) {
                            vm.confirmAllergyItem(item)
                        }
                    }

                    // Voice macro prompt
                    if let macro = vm.detectedMacro {
                        HStack {
                            Image(systemName: "mic.badge.plus")
                            Text("Voice command: \(macro.displayName)")
                            Spacer()
                            Button("Apply") { vm.applyMacro(macro, previousDraft: nil) }
                                .buttonStyle(.borderedProminent).tint(.blue)
                            Button("Dismiss") { vm.detectedMacro = nil }
                                .buttonStyle(.bordered)
                        }
                        .padding()
                        .background(.blue.opacity(0.1))
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // Live transcript
                            GroupBox("Live Transcript") {
                                Text(vm.transcript.isEmpty
                                     ? "Hold the button below and speak the order..."
                                     : vm.transcript)
                                    .font(.body)
                                    .foregroundStyle(vm.transcript.isEmpty ? .secondary : .primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .animation(.easeInOut, value: vm.transcript)
                            }

                            // Live ticket draft
                            if !vm.draft.items.isEmpty {
                                GroupBox("Order Draft — Table \(tableNumber)") {
                                    ForEach(vm.draft.items) { item in
                                        DraftItemRow(item: item) {
                                            vm.removeItem(item)
                                        }
                                    }
                                }
                            }

                            // Upsell suggestions
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
                        .padding()
                    }

                    Divider()

                    // Controls bar
                    VStack(spacing: 12) {
                        if vm.isFinalizingTranscription {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Processing speech…")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }

                        if vm.isRecording {
                            HStack {
                                Image(systemName: "waveform")
                                    .foregroundStyle(vm.noiseLevel > 0.75 ? .orange : .green)
                                ProgressView(value: Double(vm.noiseLevel))
                                    .tint(vm.noiseLevel > 0.75 ? .orange : .green)
                                    .frame(width: 120)
                                Text(vm.noiseLevel > 0.75 ? "Loud" : "Good")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }

                        HStack(spacing: 20) {
                            // Confirm = repeat-back + quick send to kitchen
                            Button {
                                vm.triggerRepeatBack()
                            } label: {
                                Label("Confirm", systemImage: "checkmark.circle")
                            }
                            .buttonStyle(.bordered)
                            .tint(.green)
                            .disabled(vm.draft.items.isEmpty)

                            // Hold-to-talk
                            HoldToTalkButton(isRecording: vm.isRecording) {
                                if vm.isRecording { vm.stopRecording() }
                                else { vm.startRecording() }
                            }

                            // Edit = create ticket, go to full editor
                            Button {
                                Task { await confirmAndNavigate(vm: vm) }
                            } label: {
                                Label("Edit", systemImage: "pencil.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(vm.transcript.isEmpty && vm.draft.items.isEmpty)
                        }
                    }
                    .padding()
                }
                .navigationTitle("Table \(tableNumber)")
                .navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: Binding(
                    get: { vm.showRepeatBack },
                    set: { vm.showRepeatBack = $0 }
                )) {
                    RepeatBackSheet(text: vm.repeatBackText) {
                        // "Confirm & Send" tapped — create ticket and fire to kitchen
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
                ProgressView("Setting up...")
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

    /// Edit path: create ticket, navigate to editor for review before sending.
    private func confirmAndNavigate(vm: LiveSessionViewModel) async {
        do {
            let ticket = try await services.repository.createTicket(
                from: vm.draft, serverId: "local_server"
            )
            navigateToEditor = ticket
        } catch {
            createTicketError = "Could not create ticket: \(error.localizedDescription)"
        }
    }

    /// Confirm path: create ticket AND send to kitchen immediately.
    private func confirmAndSend(vm: LiveSessionViewModel) async {
        do {
            let ticket = try await services.repository.createTicket(
                from: vm.draft, serverId: "local_server"
            )
            ticket.sentToKitchenAt = Date()
            ticket.status = TicketStatus.sent.rawValue
            try await services.repository.save(ticket)
            navigateToEditor = ticket
        } catch {
            createTicketError = "Could not send ticket: \(error.localizedDescription)"
        }
    }
}

// MARK: - Hold-to-Talk Button

struct HoldToTalkButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isRecording ? Color.red : Color.accentColor)
                    .frame(width: 70, height: 70)
                    .scaleEffect(isRecording ? 1.1 : 1.0)
                    .animation(
                        isRecording
                            ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                            : .default,
                        value: isRecording
                    )
                Image(systemName: isRecording ? "stop.circle" : "mic.circle")
                    .font(.system(size: 32))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Draft Item Row

struct DraftItemRow: View {
    let item: DraftItem
    let onRemove: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("\(item.quantity)x \(item.name)").fontWeight(.medium)
                    if item.hasAllergyFlag {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    if item.confidence < 0.7 {
                        Image(systemName: "questionmark.circle").foregroundStyle(.orange)
                    }
                }
                if !item.modifierNames.isEmpty {
                    Text(item.modifierNames.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(item.course.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.blue.opacity(0.15))
                    .clipShape(Capsule())
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .background(item.hasAllergyFlag ? Color.red.opacity(0.08) : .clear)
    }
}

// MARK: - Allergy Alert Banner

struct AllergyAlertBanner: View {
    let item: DraftItem
    let onConfirm: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text("ALLERGY: \(item.name)").fontWeight(.bold).foregroundStyle(.red)
            Spacer()
            Button("Confirm", action: onConfirm).buttonStyle(.bordered).tint(.red)
        }
        .padding()
        .background(.red.opacity(0.12))
    }
}

// MARK: - Repeat-Back Sheet

struct RepeatBackSheet: View {
    let text: String
    let onSendToKitchen: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Review the order with your guests before sending to the kitchen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(text)
                        .font(.body)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding()
            }
            .navigationTitle("Confirm Order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Edit Order") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onSendToKitchen()
                    } label: {
                        Label("Send to Kitchen", systemImage: "flame.fill")
                            .fontWeight(.bold)
                    }
                    .tint(.orange)
                }
            }
        }
    }
}

// MARK: - Upsell Suggestions View

struct UpsellSuggestionsView: View {
    let suggestions: [UpsellSuggestionResult]
    let onAdd: (UpsellSuggestionResult) -> Void

    var body: some View {
        GroupBox("Suggestions") {
            ForEach(suggestions) { suggestion in
                HStack {
                    VStack(alignment: .leading) {
                        Text(suggestion.menuItem.name).fontWeight(.medium)
                        if let script = suggestion.playbookScript {
                            Text(script).font(.caption).foregroundStyle(.secondary).italic()
                        } else {
                            Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Add") { onAdd(suggestion) }.buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 4)
            }
        }
    }
}
