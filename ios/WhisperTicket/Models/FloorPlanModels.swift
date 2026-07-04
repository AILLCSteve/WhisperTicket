import Foundation
import SwiftUI

// MARK: - Floor Plan (persisted configuration, separate from tickets)

struct FloorPlan: Codable {
    var tables: [FloorTable] = []
    var sections: [ServerSection] = []
    var walls: [FloorWall] = []

    init(tables: [FloorTable] = [], sections: [ServerSection] = [], walls: [FloorWall] = []) {
        self.tables = tables
        self.sections = sections
        self.walls = walls
    }

    // Custom decoding: `walls` was added after v2 plans shipped. decodeIfPresent
    // keeps old persisted plans loading instead of silently resetting to default.
    enum CodingKeys: String, CodingKey { case tables, sections, walls }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tables = try c.decodeIfPresent([FloorTable].self, forKey: .tables) ?? []
        sections = try c.decodeIfPresent([ServerSection].self, forKey: .sections) ?? []
        walls = try c.decodeIfPresent([FloorWall].self, forKey: .walls) ?? []
    }

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

/// A wall drawn on the floor plan canvas — an open polyline of points in the
/// shared 900x700 canvas coordinate space. Lets the plan mirror the real room
/// shape (dining room outline, bar counter, patio divider).
struct FloorWall: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var points: [CGPoint]
    var thickness: CGFloat = 10

    enum CodingKeys: String, CodingKey { case id, points, thickness }

    init(points: [CGPoint], thickness: CGFloat = 10) {
        self.points = points
        self.thickness = thickness
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        points = try c.decodeIfPresent([CGPoint].self, forKey: .points) ?? []
        thickness = try c.decodeIfPresent(CGFloat.self, forKey: .thickness) ?? 10
    }

    /// Shortest distance from a point to any segment of this wall (hit testing).
    func distance(to p: CGPoint) -> CGFloat {
        guard points.count >= 2 else { return .infinity }
        var best = CGFloat.infinity
        for i in 0 ..< points.count - 1 {
            best = min(best, Self.segmentDistance(p, points[i], points[i + 1]))
        }
        return best
    }

    private static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let lengthSq = abx * abx + aby * aby
        guard lengthSq > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / lengthSq))
        return hypot(p.x - (a.x + t * abx), p.y - (a.y + t * aby))
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
