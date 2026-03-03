import Foundation

struct MenuV1: Codable {
    let restaurantId: String
    let version: Int
    let currency: String
    let categories: [MenuCategory]
    let upsellRules: [UpsellRule]

    enum CodingKeys: String, CodingKey {
        case restaurantId = "restaurant_id"
        case version, currency, categories
        case upsellRules = "upsell_rules"
    }
}

struct MenuCategory: Codable, Identifiable {
    let id: String
    let name: String
    let items: [MenuItem]
}

struct MenuItem: Codable, Identifiable {
    let id: String
    let name: String
    let price: Double
    let description: String
    let tags: [String]
    let modifierGroups: [ModifierGroup]
    let upsellLinks: [UpsellLink]
    var kitchenNoteTemplate: String?

    enum CodingKeys: String, CodingKey {
        case id, name, price, description, tags
        case modifierGroups = "modifier_groups"
        case upsellLinks = "upsell_links"
        case kitchenNoteTemplate = "kitchen_note_template"
    }
}

struct ModifierGroup: Codable, Identifiable {
    let id: String
    let name: String
    let required: Bool
    let maxSelect: Int
    let modifiers: [ModifierOption]

    enum CodingKeys: String, CodingKey {
        case id, name, required
        case maxSelect = "max_select"
        case modifiers
    }
}

struct ModifierOption: Codable, Identifiable {
    let id: String
    let name: String
    let priceDelta: Double

    enum CodingKeys: String, CodingKey {
        case id, name
        case priceDelta = "price_delta"
    }
}

struct UpsellLink: Codable {
    let type: String
    let targetItemId: String
    let reason: String

    enum CodingKeys: String, CodingKey {
        case type
        case targetItemId = "target_item_id"
        case reason
    }
}

struct UpsellRule: Codable, Identifiable {
    let id: String
    let condition: UpsellCondition
    let suggest: [UpsellSuggestion]
    var playbookScript: String?

    enum CodingKeys: String, CodingKey {
        case id
        case condition = "if"
        case suggest
        case playbookScript = "playbook_script"
    }
}

struct UpsellCondition: Codable {
    let hasEntree: Bool?
    let hasDrink: Bool?

    enum CodingKeys: String, CodingKey {
        case hasEntree = "has_entree"
        case hasDrink = "has_drink"
    }
}

struct UpsellSuggestion: Codable {
    let tag: String?
    let itemId: String?

    enum CodingKeys: String, CodingKey {
        case tag
        case itemId = "item_id"
    }
}

extension MenuItem {
    static let abbreviationOverrides: [String: String] = [:]

    var abbreviation: String {
        if let override = Self.abbreviationOverrides[id] { return override }
        let words = name.split(separator: " ")
        if words.count == 1 { return String(name.prefix(4)).uppercased() }
        return words.map { String($0.prefix(1)) }.joined().uppercased()
    }
}
