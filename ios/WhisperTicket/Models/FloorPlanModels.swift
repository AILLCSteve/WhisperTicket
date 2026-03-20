import Foundation
import SwiftUI

// MARK: - Floor Plan (persisted configuration, separate from tickets)

struct FloorPlan: Codable {
    var tables: [FloorTable] = []
    var sections: [ServerSection] = []

    /// Sensible default restaurant layout on first launch.
    static var `default`: FloorPlan {
        let tables: [FloorTable] = [
            FloorTable(name: "1",       position: CGSize(width: 40,  height: 60),  seats: SeatConfig.numbered(4)),
            FloorTable(name: "2",       position: CGSize(width: 180, height: 60),  seats: SeatConfig.numbered(4)),
            FloorTable(name: "3",       position: CGSize(width: 320, height: 60),  seats: SeatConfig.numbered(4)),
            FloorTable(name: "4",       position: CGSize(width: 40,  height: 240), seats: SeatConfig.numbered(4)),
            FloorTable(name: "5",       position: CGSize(width: 180, height: 240), seats: SeatConfig.numbered(4)),
            FloorTable(name: "6",       position: CGSize(width: 320, height: 240), seats: SeatConfig.numbered(4)),
            FloorTable(name: "7",       position: CGSize(width: 40,  height: 420), seats: SeatConfig.numbered(2)),
            FloorTable(name: "8",       position: CGSize(width: 180, height: 420), seats: SeatConfig.numbered(2)),
            FloorTable(name: "Bar",     position: CGSize(width: 320, height: 420), seats: SeatConfig.numbered(6)),
            FloorTable(name: "Patio 1", position: CGSize(width: 40,  height: 580), seats: SeatConfig.numbered(4)),
            FloorTable(name: "Patio 2", position: CGSize(width: 200, height: 580), seats: SeatConfig.numbered(4)),
        ]
        return FloorPlan(tables: tables, sections: [])
    }
}

struct FloorTable: Codable, Identifiable, Hashable {
    static func == (lhs: FloorTable, rhs: FloorTable) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    var id: String = UUID().uuidString
    var name: String                    // "1", "Bar", "Patio 2"
    var position: CGSize                // drag offset from canvas origin
    var seats: [SeatConfig]
    var sectionId: String?              // nil = no section assignment

    init(name: String, position: CGSize = .zero, seats: [SeatConfig] = SeatConfig.numbered(4)) {
        self.name = name
        self.position = position
        self.seats = seats
    }
}

/// Per-seat configuration — the critical mnemonic layer.
/// "1","2","3" by default; server changes to "Red shirt","Mom","Dad" etc.
struct SeatConfig: Codable, Identifiable {
    var id: String = UUID().uuidString
    var label: String

    static func numbered(_ count: Int) -> [SeatConfig] {
        (1...max(count, 1)).map { SeatConfig(label: "\($0)") }
    }
}

struct ServerSection: Codable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var colorHex: String                // stored as 6-char hex, no #
    var tableIds: [String]

    var color: Color { Color(hex6: colorHex) ?? .blue }

    static let palette: [String] = [
        "4A90D9", "E67E22", "27AE60", "8E44AD",
        "E74C3C", "16A085", "F39C12", "2C3E50"
    ]
}

// MARK: - Color hex helper

extension Color {
    init?(hex6: String) {
        let s = hex6.trimmingCharacters(in: .init(charactersIn: "#"))
        guard s.count == 6 else { return nil }
        var v: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&v) else { return nil }
        self.init(
            red:   Double((v >> 16) & 0xFF) / 255,
            green: Double((v >>  8) & 0xFF) / 255,
            blue:  Double( v        & 0xFF) / 255
        )
    }
}
