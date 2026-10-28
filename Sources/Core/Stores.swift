import Foundation
import CryptoKit

/// Small saved-to-disk values (fingerprints, Jev verdicts). A missing or damaged file reads as empty.
public enum JSONStore {
    public static func load<T: Decodable & ExpressibleByDictionaryLiteral>(_ type: T.Type, from url: URL) -> T {
        guard let d = try? Data(contentsOf: url), let v = try? JSONDecoder().decode(T.self, from: d) else { return [:] }
        return v
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}

/// Edited versions the iPhone failed to make, by device-scoped key. Every try jams the connection and costs a
/// reconnect, so each gets one try per check and is given up on for good after `max` failed checks.
/// `counts` is what is saved; the file used to hold the date of the single try instead of a count.
public struct RenderTries {
    public static let max = 3
    public private(set) var counts: [String: Int]
    private var triedThisRun: Set<String> = []
    public init(counts: [String: Int] = [:]) { self.counts = counts }

    public static func load(from url: URL) -> RenderTries {
        // A count is a small whole number; anything else is an old-style date, which stood for one try.
        RenderTries(counts: JSONStore.load([String: Double].self, from: url).mapValues { $0 >= 1 && $0 <= Double(max) ? Int($0) : 1 })
    }

    /// A new check: everything not yet given up on gets one more try.
    public mutating func newRun() { triedThisRun = [] }
    public func shouldTry(_ key: String) -> Bool { !triedThisRun.contains(key) && !gaveUp(key) }
    public mutating func failed(_ key: String) { if triedThisRun.insert(key).inserted { counts[key, default: 0] += 1 } }
    public func tried(_ key: String) -> Bool { (counts[key] ?? 0) > 0 }
    public func gaveUp(_ key: String) -> Bool { (counts[key] ?? 0) >= Self.max }
}

/// Grid thumbnails kept on the Mac, so the grid still shows pictures while the iPhone is unplugged.
/// Note: no size limit (~20 KB each, ~80 MB for 4,000 photos); add pruning if the library grows a lot.
public struct ThumbnailStore: Sendable {
    let dir: URL
    public init(dir: URL) { self.dir = dir }

    public func data(for key: String) -> Data? { try? Data(contentsOf: url(for: key)) }

    public func put(_ data: Data, for key: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url(for: key), options: .atomic)
    }

    private func url(for key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(name + ".jpg")
    }
}
