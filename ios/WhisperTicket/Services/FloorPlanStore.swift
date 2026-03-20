import Foundation
import Observation

/// Persists the restaurant's floor configuration (tables, seats, sections) in UserDefaults.
/// Separates static layout config from transactional ticket data (SwiftData).
@Observable
final class FloorPlanStore {
    private(set) var floorPlan: FloorPlan = .default
    private let key = "whisperticket.floorplan.v2"

    init() { load() }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let plan = try? JSONDecoder().decode(FloorPlan.self, from: data) else { return }
        floorPlan = plan
    }

    func save() {
        guard let data = try? JSONEncoder().encode(floorPlan) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    // MARK: - Table management

    func upsertTable(_ table: FloorTable) {
        if let idx = floorPlan.tables.firstIndex(where: { $0.id == table.id }) {
            floorPlan.tables[idx] = table
        } else {
            floorPlan.tables.append(table)
        }
        save()
    }

    func deleteTable(id: String) {
        floorPlan.tables.removeAll { $0.id == id }
        // Remove from sections too
        for i in floorPlan.sections.indices {
            floorPlan.sections[i].tableIds.removeAll { $0 == id }
        }
        save()
    }

    func moveTable(fromOffsets: IndexSet, toOffset: Int) {
        floorPlan.tables.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    /// Returns the FloorTable whose name matches the given ticket table number.
    func table(named name: String) -> FloorTable? {
        floorPlan.tables.first { $0.name.lowercased() == name.lowercased() }
    }

    // MARK: - Section management

    func upsertSection(_ section: ServerSection) {
        if let idx = floorPlan.sections.firstIndex(where: { $0.id == section.id }) {
            floorPlan.sections[idx] = section
        } else {
            floorPlan.sections.append(section)
        }
        save()
    }

    func deleteSection(id: String) {
        floorPlan.sections.removeAll { $0.id == id }
        for i in floorPlan.tables.indices where floorPlan.tables[i].sectionId == id {
            floorPlan.tables[i].sectionId = nil
        }
        save()
    }

    func assignTable(id tableId: String, toSection sectionId: String?) {
        guard let idx = floorPlan.tables.firstIndex(where: { $0.id == tableId }) else { return }
        floorPlan.tables[idx].sectionId = sectionId
        // Keep section.tableIds in sync
        for i in floorPlan.sections.indices {
            floorPlan.sections[i].tableIds.removeAll { $0 == tableId }
            if floorPlan.sections[i].id == sectionId {
                floorPlan.sections[i].tableIds.append(tableId)
            }
        }
        save()
    }

    // MARK: - Helpers

    func resetToDefault() {
        floorPlan = .default
        save()
    }
}
