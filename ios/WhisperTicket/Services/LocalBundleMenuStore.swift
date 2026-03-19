import Foundation
import Observation

@Observable
final class LocalBundleMenuStore: MenuStoreProtocol {
    private(set) var menu: MenuV1?
    private var itemIndex: [String: MenuItem] = [:]
    private var searchIndex: [(tokens: [String], item: MenuItem)] = []

    func loadMenu() async throws {
        guard let url = Bundle.main.url(forResource: "MenuV1.sample", withExtension: "json") else {
            throw MenuStoreError.fileNotFound
        }
        let data = try Data(contentsOf: url)
        let loaded = try JSONDecoder().decode(MenuV1.self, from: data)
        await MainActor.run {
            self.menu = loaded
            self.buildIndex(from: loaded)
        }
    }

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

    private func buildIndex(from menu: MenuV1) {
        itemIndex.removeAll()
        searchIndex.removeAll()
        for category in menu.categories {
            for item in category.items {
                itemIndex[item.id] = item
                let tokens = normalize(item.name).split(separator: " ").map(String.init)
                searchIndex.append((tokens: tokens, item: item))
                // Also add plural/alias variants
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

enum MenuStoreError: Error {
    case fileNotFound
    case decodingFailed
}
