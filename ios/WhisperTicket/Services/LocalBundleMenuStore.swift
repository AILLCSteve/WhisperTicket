import Foundation
import Observation

private let kMenuDefaultsKey = "whisperticket.menu.v1.json"

@Observable
final class LocalBundleMenuStore: MenuStoreProtocol {
    private(set) var menu: MenuV1?
    private var itemIndex: [String: MenuItem] = [:]
    private var searchIndex: [(tokens: [String], item: MenuItem)] = []

    // MARK: - Load (3-strategy with embedded fallback)

    func loadMenu() async throws {
        // Strategy 1: Bundle file
        if let url = resolveMenuURL(), let loaded = try? decode(from: url) {
            await apply(loaded)
            return
        }

        // Strategy 2: Previously saved menu in UserDefaults
        if let data = UserDefaults.standard.data(forKey: kMenuDefaultsKey),
           let loaded = try? JSONDecoder().decode(MenuV1.self, from: data) {
            await apply(loaded)
            return
        }

        // Strategy 3: Embedded Swift-string fallback — always available
        if let loaded = try? JSONDecoder().decode(MenuV1.self, from: Data(embeddedMenuJSON.utf8)) {
            await apply(loaded)
            return
        }

        throw MenuStoreError.fileNotFound
    }

    // MARK: - Save (persists to UserDefaults for subsequent launches)

    func saveMenu(_ newMenu: MenuV1) {
        if let data = try? JSONEncoder().encode(newMenu) {
            UserDefaults.standard.set(data, forKey: kMenuDefaultsKey)
        }
        menu = newMenu
        buildIndex(from: newMenu)
    }

    // MARK: - Search

    func findBestMatches(text: String, maxResults: Int = 3) -> [(item: MenuItem, score: Double)] {
        let normalized = normalize(text)
        let queryTokens = normalized.split(separator: " ").map(String.init)
        var results: [(item: MenuItem, score: Double)] = []
        for entry in searchIndex {
            let score = tokenOverlapScore(query: queryTokens, candidate: entry.tokens)
            if score > 0.2 { results.append((entry.item, score)) }
        }
        return results.sorted { $0.score > $1.score }.prefix(maxResults).map { $0 }
    }

    func item(byId id: String) -> MenuItem? { itemIndex[id] }

    // MARK: - Private helpers

    @MainActor
    private func apply(_ loaded: MenuV1) {
        self.menu = loaded
        self.buildIndex(from: loaded)
    }

    private func decode(from url: URL) throws -> MenuV1 {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MenuV1.self, from: data)
    }

    private func resolveMenuURL() -> URL? {
        // 1. Standard lookup
        if let url = Bundle.main.url(forResource: "MenuV1.sample", withExtension: "json") {
            return url
        }
        // 2. Direct path from bundle root
        let direct = Bundle.main.bundleURL.appendingPathComponent("MenuV1.sample.json")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        // 3. Any JSON in bundle with "menu" in the name
        if let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) {
            if let match = urls.first(where: { $0.lastPathComponent.lowercased().contains("menu") }) {
                return match
            }
        }
        // 4. Subdirectory scan
        for subdir in ["Resources", "WhisperTicket", "ios"] {
            if let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: subdir),
               let match = urls.first(where: { $0.lastPathComponent.lowercased().contains("menu") }) {
                return match
            }
        }
        return nil
    }

    private func buildIndex(from menu: MenuV1) {
        itemIndex.removeAll()
        searchIndex.removeAll()
        for category in menu.categories {
            for item in category.items {
                itemIndex[item.id] = item
                let tokens = normalize(item.name).split(separator: " ").map(String.init)
                searchIndex.append((tokens: tokens, item: item))
                let plural = tokens.map { $0.hasSuffix("s") ? $0 : $0 + "s" }
                searchIndex.append((tokens: plural, item: item))
            }
        }
    }

    private func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private func tokenOverlapScore(query: [String], candidate: [String]) -> Double {
        let querySet = Set(query)
        let candidateSet = Set(candidate)
        let intersection = querySet.intersection(candidateSet)
        guard !querySet.isEmpty else { return 0 }
        return Double(intersection.count) / Double(querySet.count)
    }
}

// MARK: - Errors

enum MenuStoreError: Error, LocalizedError {
    case fileNotFound
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .fileNotFound: return "Menu could not be loaded. The app will use a built-in sample menu."
        case .decodingFailed: return "Menu file could not be read. The file may be corrupted."
        }
    }
}

// MARK: - Embedded fallback menu (always available, no bundle dependency)

private let embeddedMenuJSON = """
{
  "restaurant_id": "demo_restaurant",
  "version": 1,
  "currency": "USD",
  "categories": [
    {
      "id": "cat_apps",
      "name": "Appetizers",
      "items": [
        {"id": "app_wings", "name": "Buffalo Wings", "price": 13.99, "description": "Crispy wings with your choice of sauce", "tags": ["appetizer"], "modifier_groups": [], "upsell_links": []},
        {"id": "app_nachos", "name": "Loaded Nachos", "price": 11.99, "description": "Tortilla chips with cheese, jalapenos, salsa, sour cream", "tags": ["appetizer", "shareable"], "modifier_groups": [], "upsell_links": []},
        {"id": "app_soup", "name": "Soup of the Day", "price": 6.99, "description": "Ask your server", "tags": ["soup"], "modifier_groups": [], "upsell_links": []}
      ]
    },
    {
      "id": "cat_salads",
      "name": "Salads",
      "items": [
        {"id": "sal_caesar", "name": "Caesar Salad", "price": 10.99, "description": "Romaine, croutons, parmesan, caesar dressing", "tags": ["salad", "vegetarian"], "modifier_groups": [], "upsell_links": []},
        {"id": "sal_garden", "name": "Garden Salad", "price": 8.99, "description": "Mixed greens, tomato, cucumber, choice of dressing", "tags": ["salad", "vegetarian"], "modifier_groups": [], "upsell_links": []},
        {"id": "sal_side", "name": "Side Salad", "price": 4.99, "description": "Small garden salad", "tags": ["side salad", "salad"], "modifier_groups": [], "upsell_links": []}
      ]
    },
    {
      "id": "cat_entrees",
      "name": "Entrees",
      "items": [
        {"id": "ent_burger", "name": "Classic Burger", "price": 14.99, "description": "8oz beef patty, lettuce, tomato, onion, pickles", "tags": ["burger", "entree"], "modifier_groups": [{"id": "mg_temp", "name": "Temperature", "required": false, "max_select": 1, "modifiers": [{"id": "mod_mw", "name": "Medium Well", "price_delta": 0}, {"id": "mod_med", "name": "Medium", "price_delta": 0}, {"id": "mod_wd", "name": "Well Done", "price_delta": 0}]}], "upsell_links": []},
        {"id": "ent_chicken", "name": "Grilled Chicken", "price": 16.99, "description": "Herb-marinated chicken breast with seasonal vegetables", "tags": ["chicken", "entree", "gluten-free"], "modifier_groups": [], "upsell_links": []},
        {"id": "ent_salmon", "name": "Atlantic Salmon", "price": 22.99, "description": "Pan-seared salmon with lemon butter sauce", "tags": ["fish", "entree", "gluten-free"], "modifier_groups": [], "upsell_links": []},
        {"id": "ent_pasta", "name": "Fettuccine Alfredo", "price": 15.99, "description": "Pasta in creamy parmesan sauce", "tags": ["pasta", "vegetarian", "entree"], "modifier_groups": [], "upsell_links": []},
        {"id": "ent_steak", "name": "NY Strip Steak", "price": 32.99, "description": "12oz NY strip with garlic mashed potatoes", "tags": ["steak", "entree"], "modifier_groups": [], "upsell_links": []}
      ]
    },
    {
      "id": "cat_sides",
      "name": "Sides",
      "items": [
        {"id": "sid_fries", "name": "French Fries", "price": 4.99, "description": "Crispy golden fries", "tags": ["side", "vegetarian"], "modifier_groups": [], "upsell_links": []},
        {"id": "sid_mash", "name": "Mashed Potatoes", "price": 4.99, "description": "Creamy garlic mashed potatoes", "tags": ["side", "vegetarian"], "modifier_groups": [], "upsell_links": []},
        {"id": "sid_veg", "name": "Seasonal Vegetables", "price": 4.99, "description": "Chef's selection of fresh vegetables", "tags": ["side", "vegetarian", "gluten-free"], "modifier_groups": [], "upsell_links": []}
      ]
    },
    {
      "id": "cat_drinks",
      "name": "Drinks",
      "items": [
        {"id": "drk_soda", "name": "Soda", "price": 3.49, "description": "Coke, Diet Coke, Sprite, Dr Pepper, Root Beer", "tags": ["drink", "non-alcoholic"], "modifier_groups": [], "upsell_links": []},
        {"id": "drk_water", "name": "Sparkling Water", "price": 2.99, "description": "Still or sparkling", "tags": ["drink", "non-alcoholic"], "modifier_groups": [], "upsell_links": []},
        {"id": "drk_beer", "name": "Draft Beer", "price": 6.99, "description": "Ask your server for today's taps", "tags": ["drink", "alcohol", "beer"], "modifier_groups": [], "upsell_links": []},
        {"id": "drk_wine", "name": "House Wine", "price": 8.99, "description": "Red or white, ask your server", "tags": ["drink", "alcohol", "wine"], "modifier_groups": [], "upsell_links": []},
        {"id": "drk_coffee", "name": "Coffee", "price": 3.49, "description": "Regular or decaf, unlimited refills", "tags": ["drink", "non-alcoholic", "hot"], "modifier_groups": [], "upsell_links": []}
      ]
    },
    {
      "id": "cat_desserts",
      "name": "Desserts",
      "items": [
        {"id": "des_cake", "name": "Chocolate Lava Cake", "price": 8.99, "description": "Warm chocolate cake with vanilla ice cream", "tags": ["dessert"], "modifier_groups": [], "upsell_links": []},
        {"id": "des_ice", "name": "Ice Cream", "price": 5.99, "description": "Two scoops, ask for flavors", "tags": ["dessert"], "modifier_groups": [], "upsell_links": []},
        {"id": "des_pie", "name": "Key Lime Pie", "price": 7.99, "description": "Classic key lime pie with whipped cream", "tags": ["dessert"], "modifier_groups": [], "upsell_links": []}
      ]
    }
  ],
  "upsell_rules": [
    {"id": "rule_dessert", "if": {"has_entree": true}, "suggest": [{"tag": "dessert"}], "playbook_script": "Save room for dessert? Our chocolate lava cake is amazing tonight."},
    {"id": "rule_drink", "if": {"has_entree": true, "has_drink": false}, "suggest": [{"tag": "drink"}], "playbook_script": "Can I get you something to drink with that?"}
  ]
}
"""
