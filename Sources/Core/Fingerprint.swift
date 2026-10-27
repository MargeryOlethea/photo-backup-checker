import Foundation
import CryptoKit

public struct ShortRead: Error { public init() {} }
public struct EmptyFile: Error { public init() {} }

public enum Fingerprint {
    public static let chunkSize = 8 * 1024 * 1024

    public static func sha256(fileAt url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let d = try h.read(upToCount: chunkSize), !d.isEmpty { hasher.update(data: d) }
        return hex(hasher.finalize())
    }

    /// Hashes a file read in exact chunks; any chunk shorter than asked for is an error.
    public static func sha256(readChunk: (Int64, Int) async throws -> Data, size: Int64) async throws -> String {
        guard size > 0 else { throw EmptyFile() }
        var hasher = SHA256()
        var offset: Int64 = 0
        while offset < size {
            let len = Int(min(Int64(chunkSize), size - offset))
            let d = try await readChunk(offset, len)
            guard d.count == len else { throw ShortRead() }
            hasher.update(data: d)
            offset += Int64(len)
        }
        return hex(hasher.finalize())
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}
