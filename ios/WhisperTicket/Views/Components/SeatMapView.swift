import SwiftUI
import UniformTypeIdentifiers

// Medium complexity: drag-and-drop seat map
struct SeatMapView: View {
    let ticket: Ticket
    let vm: TicketEditorViewModel
    @Environment(\.dismiss) var dismiss
    @Environment(\.modelContext) var modelContext
    @State private var draggedItemId: String? = nil
    @State private var draggedFromSeatNumber: Int? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Table \(ticket.tableNumber)")
                        .font(.title2.bold())
                        .padding(.top)

                    // Table representation
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.brown.opacity(0.3))
                        .frame(height: 80)
                        .overlay(Text("TABLE").font(.caption.bold()).foregroundStyle(.brown))
                        .padding(.horizontal, 60)

                    let seats = ticket.guests.sorted(by: { $0.seatNumber < $1.seatNumber })
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 16) {
                        ForEach(seats) { seat in
                            SeatCard(
                                seat: seat,
                                draggedItemId: draggedItemId,
                                onDrop: { itemId, fromSeatNum in
                                    guard let fromSeat = ticket.guests.first(where: { $0.seatNumber == fromSeatNum }),
                                          let item = fromSeat.items.first(where: { $0.id == itemId }) else { return }
                                    Task { await vm.moveItem(item, fromSeat: fromSeat, toSeatNumber: seat.seatNumber) }
                                    draggedItemId = nil
                                    draggedFromSeatNumber = nil
                                }
                            )
                        }

                        // Add seat button
                        Button {
                            let newSeatNum = (seats.last?.seatNumber ?? 0) + 1
                            let newSeat = GuestSeat(seatNumber: newSeatNum)
                            modelContext.insert(newSeat)
                            ticket.guests.append(newSeat)
                        } label: {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(.secondary, style: StrokeStyle(dash: [5]))
                                .frame(height: 120)
                                .overlay(
                                    Label("Add Seat", systemImage: "plus.circle")
                                        .foregroundStyle(.secondary)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal)
                }
            }
            .navigationTitle("Seat Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct SeatCard: View {
    let seat: GuestSeat
    let draggedItemId: String?
    let onDrop: (String, Int) -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Seat \(seat.seatNumber)")
                .font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(seat.items) { item in
                Text("\(item.quantity)x \(item.name)")
                    .font(.caption)
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    // Encode "itemId|sourceSeatNumber" so the drop target knows the origin
                    .draggable("\(item.id)|\(seat.seatNumber)")
            }
            if seat.items.isEmpty {
                Text("Empty seat").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .background(isTargeted ? Color.blue.opacity(0.15) : Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isTargeted ? .blue : .clear, lineWidth: 2)
        )
        .dropDestination(for: String.self) { items, _ in
            guard let payload = items.first else { return false }
            // Payload is "itemId|sourceSeatNumber"
            let parts = payload.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let sourceSeatNum = Int(parts[1]) else { return false }
            let itemId = String(parts[0])
            onDrop(itemId, sourceSeatNum)
            isTargeted = false
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
}
