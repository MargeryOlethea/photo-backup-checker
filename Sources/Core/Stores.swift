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
