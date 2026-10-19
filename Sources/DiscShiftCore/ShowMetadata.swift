import Foundation

public struct CatalogShow: Decodable, Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let premiered: String?
    public let language: String?
    public let network: Network?
    public let webChannel: Network?
    public struct Network: Decodable, Equatable, Sendable {
        public let name: String
        public let country: Country?
    }
    public struct Country: Decodable, Equatable, Sendable { public let name: String }
    public var year: String { premiered.map { String($0.prefix(4)) } ?? "" }
    public var detail: String {
        [year.isEmpty ? nil : year, (network ?? webChannel)?.name,
         (network ?? webChannel)?.country?.name, language].compactMap { $0 }.joined(separator: " · ")
    }
    public var pageURL: URL { URL(string: "https://www.tvmaze.com/shows/\(id)")! }
}

public struct CatalogEpisode: Decodable, Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let season: Int
    public let number: Int?
    public let airdate: String?
    public let runtime: Int?
    public var label: String {
        guard let number else { return name }
        return String(format: "E%02d · %@", number, name)
    }
}

public protocol ShowMetadataProviding: Sendable {
    func search(query: String) async throws -> [CatalogShow]
    func episodes(showID: Int) async throws -> [CatalogEpisode]
}

public struct MetadataFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct TVMazeClient: ShowMetadataProviding {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func search(query: String) async throws -> [CatalogShow] {
        var url = URLComponents(string: "https://api.tvmaze.com/search/shows")!
        url.queryItems = [URLQueryItem(name: "q", value: query)]
        struct Hit: Decodable { let show: CatalogShow }
        let hits: [Hit] = try await fetch(url.url!)
        var seen: Set<Int> = []
        return hits.map(\.show).filter { seen.insert($0.id).inserted }
    }
    public func episodes(showID: Int) async throws -> [CatalogEpisode] {
        guard showID > 0 else { throw MetadataFailure("Choose a show first.") }
        return try await fetch(URL(string: "https://api.tvmaze.com/shows/\(showID)/episodes")!)
    }
    private func fetch<T: Decodable>(_ url: URL) async throws -> T {
        for attempt in 0...1 {
            try Task.checkCancellation()
            var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15)
            request.setValue("DiscShift/0.8.1 (macOS)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw MetadataFailure("The lookup service returned an unreadable response.") }
            if response.statusCode == 429 && attempt == 0 {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                continue
            }
            guard (200...299).contains(response.statusCode) else {
                throw MetadataFailure(response.statusCode == 429 ? "The lookup service is busy. Try again shortly, or enter details manually." : "Show lookup is unavailable (HTTP \(response.statusCode)). You can enter details manually.")
            }
            guard data.count < 8_000_000 else { throw MetadataFailure("The lookup response was too large. Enter details manually.") }
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { throw MetadataFailure("The lookup response could not be read. You can enter details manually.") }
        }
        throw MetadataFailure("Show lookup is unavailable. You can enter details manually.")
    }
}

/// A search hint only. Disc numbers never become season or episode numbers.
public enum DiscLabelHint {
    public static func clean(_ label: String) -> String {
        var text = label
        if text.uppercased() == "VIDEO_TS" || text.uppercased() == "AUDIO_TS" { return "" }
        text = text.replacingOccurrences(of: #"(?i)[\s._-]*(?:s\d{1,3}[\s._-]*d\d{1,3}|(?:season|series|disc|disk|dvd|vol(?:ume)?)[\s._-]*\d{1,3})\b"#, with: " ", options: .regularExpression)
        // Labels often have no separator before DISC, e.g. SHOWDISC1.
        text = text.replacingOccurrences(of: #"(?i)(?:disc|disk|dvd)[\s._-]*\d{1,3}$"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<=[a-z])(?=[A-Z])"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[_.-]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[\[(](?:19|20)\d{2}[\])]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[()\[\]]"#, with: " ", options: .regularExpression)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func query(_ label: String, words: Set<String>) -> String {
        let cleaned = clean(label)
        guard !cleaned.contains(" "), cleaned.count > 8, cleaned.count <= 100,
              cleaned.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) else { return cleaned }
        let text = Array(cleaned.lowercased())
        var best: [(cost: Int, words: [String])?] = Array(repeating: nil, count: text.count + 1)
        best[0] = (0, [])
        for end in 1...text.count {
            for start in max(0, end - 30)..<end {
                guard let previous = best[start] else { continue }
                let word = String(text[start..<end])
                let valid = words.contains(word) || (word.count > 3 && word.hasSuffix("s") && words.contains(String(word.dropLast())))
                guard valid, word.count > 1 || word == "a" || word == "i" else { continue }
                let cost = previous.cost + (word.count == 1 ? 20 : 10)
                if best[end] == nil || cost < best[end]!.cost { best[end] = (cost, previous.words + [word]) }
            }
        }
        guard let result = best[text.count], result.words.count > 1 else { return cleaned }
        return result.words.joined(separator: " ")
    }
    public static let systemWords: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map { $0.lowercased() })
    }()
}
