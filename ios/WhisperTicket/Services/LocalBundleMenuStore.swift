import Foundation
import Observation

@Observable
final class LocalBundleMenuStore: MenuStoreProtocol {
    private(set) var menu: MenuV1?
    private var itemIndex: [String: MenuItem] = [:]
    private var searchIndex: [(tokens: [String], item: MenuItem)] = []

    func loadMenu() async throws {
        guard let url = resolveMenuURL() else {
            let available = (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
                .map { $0.lastPathComponent }
            print("⚠️ MenuV1.sample.json not found. Bundle JSON files: \(available)")
            throw MenuStoreError.fileNotFound
        }
        do {
            let data = try Data(contentsOf: url)
            let loaded = try JSONDecoder().decode(MenuV1.self, from: data)
            await MainActor.run {
                self.menu = loaded
                self.buildIndex(from: loaded)
            }
        } catch let error as DecodingError {
            print("⚠️ Menu decode error: \(error)")
            throw MenuStoreError.decodingFailed
        }
    }

    /// Tries several lookup strategies to locate the menu JSON regardless of
    /// how XcodeGen packaged the resource in the bundle.
    private func resolveMenuURL() -> URL? {
        // 1. Standard lookup — works when XcodeGen copies file flat to bundle root
        if let url = Bundle.main.url(forResource: "MenuV1.sample", withExtension: "json") {
            return url
        }
        // 2. Direct path from bundle root (some XcodeGen configs)
        let direct = Bundle.main.bundleURL.appendingPathComponent("MenuV1.sample.json")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }

        // 3. Scan all bundle JSON files — handles renamed / path-preserved copies
        if let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) {
            if let match = urls.first(where: {
                $0.lastPathComponent.lowercased().contains("menu") &&
                $0.lastPathComponent.lowercased().contains("v1")
            }) { return match }
            // Broader fallback: any JSON file in bundle with "menu" in the name
            if let match = urls.first(where: {
                $0.lastPathComponent.lowercased().contains("menu")
            }) { return match }
        }

        // 4. Subdirectory scan (XcodeGen may preserve folder structure)
        for subdir in ["Resources", "WhisperTicket", "ios"] {
            if let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: subdir) {
                if let match = urls.first(where: {
                    $0.lastPathComponent.lowercased().contains("menu")
                }) { return match }
            }
        }

        return nil
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

enum MenuStoreError: Error, LocalizedError {
    case fileNotFound
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "Menu file not found in app bundle. Try reloading — if the problem persists, reinstall the app."
        case .decodingFailed:
            return "Menu file could not be read. The file may be corrupted."
        }
    }
}
