import Foundation

/// Downloads raw filter lists and caches them in the App Group container
/// (`<group>/lists/<id>.txt`). The raw text is the unit of freshness:
/// conversion happens in-memory on every compile (Compiler).
public final class ListStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func cacheFile(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).txt")
    }

    public func cachedRaw(_ id: String) -> Data? {
        try? Data(contentsOf: cacheFile(id))
    }

    /// Fetches the list over HTTPS. Fails if the server is unreachable;
    /// a previously cached copy (if any) is returned by the caller as
    /// fallback so blocking never fully regresses offline.
    @discardableResult
    public func fetch(_ spec: ListSpec) async throws -> Data {
        var request = URLRequest(url: URL(string: spec.url)!)
        request.timeoutInterval = 60
        request.setValue("bl0cksh1t (filter list update)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ListStoreError.http(code, spec.url)
        }
        guard !data.isEmpty else { throw ListStoreError.empty(spec.id) }
        try data.write(to: cacheFile(spec.id), options: .atomic)
        return data
    }

    public enum ListStoreError: Error, CustomStringConvertible {
        case http(Int, String)
        case empty(String)

        public var description: String {
            switch self {
            case let .http(code, url): return "HTTP \(code) for \(url)"
            case let .empty(id): return "empty list \(id)"
            }
        }
    }
}

/// Splits raw list text into rule lines (drops blanks and comments).
/// `!` lines are comments; `#` is a comment only when it is not the start
/// of a `##` cosmetic rule. Matches the converter's input expectations.
public func parseRuleLines(_ raw: Data) -> [String] {
    guard var text = String(data: raw, encoding: .utf8) else { return [] }
    text.makeContiguousUTF8()
    return text
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { line in
            guard !line.isEmpty else { return false }
            if line.hasPrefix("!") { return false }
            if line.hasPrefix("#") && !line.hasPrefix("##") { return false }
            return true
        }
}
