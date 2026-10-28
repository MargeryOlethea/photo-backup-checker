import Foundation
import ImageIO
import AVFoundation

/// Everything known about the backup drive, cached so the next check only reads what changed.
public actor DriveIndex {
    public let root: URL
    let cacheURL: URL
    private var byPath: [String: DriveFile] = [:]
    private var cached: [String: DriveFile] = [:]
    private var scanned = false

    public init(root: URL, cacheURL: URL) {
        self.root = root
        self.cacheURL = cacheURL
        if let d = try? Data(contentsOf: cacheURL), let list = try? JSONDecoder().decode([DriveFile].self, from: d) {
            cached = Dictionary(list.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    public func scan(progress: @Sendable (Int, Int) -> Void) throws -> [DriveFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard FileManager.default.fileExists(atPath: root.path) else { throw CocoaError(.fileReadNoSuchFile) }
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var found: [String: DriveFile] = [:]
        var folders: Set<URL> = [root]
        for case let url as URL in e {
            guard !url.lastPathComponent.hasPrefix("."),
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let size = v.fileSize, let mod = v.contentModificationDate else { continue }
            let path = url.path
            if let c = cached[path], c.size == Int64(size), abs(c.modified.timeIntervalSince(mod)) < 0.001 {
                found[path] = c
            } else {
                found[path] = DriveFile(path: path, size: Int64(size), modified: mod)
            }
            folders.insert(url.deletingLastPathComponent())
            if found.count % 200 == 0 { progress(found.count, 0) }
        }
        // Unplugged part-way: the list is incomplete, so keep what we had.
        guard FileManager.default.fileExists(atPath: root.path) else { throw CocoaError(.fileReadNoSuchFile) }
        for f in folders { Self.removeStaleStaging(in: f) }
        byPath = found
        scanned = true
        progress(found.count, found.count)
        return Array(found.values)
    }

    /// Fingerprints every file whose size is in `sizes` and has no fingerprint yet. 4 at a time.
    public func ensureHashes(forSizes sizes: Set<Int64>, progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> [DriveFile] {
        let todo = byPath.values.filter { $0.sha256 == nil && sizes.contains($0.size) }.map(\.path)
        var done = 0
        progress(0, todo.count)
        try await withThrowingTaskGroup(of: (String, String?).self) { group in
            var it = todo.makeIterator()
            func add() -> Bool {
                guard let p = it.next() else { return false }
                group.addTask { (p, try? Fingerprint.sha256(fileAt: URL(fileURLWithPath: p))) }
                return true
            }
            for _ in 0..<4 { if !add() { break } }
            while let (p, h) = try await group.next() {
                try Task.checkCancellation()
                byPath[p]?.sha256 = h
                done += 1
                progress(done, todo.count)
                _ = add()
            }
        }
        return Array(byPath.values)
    }

    /// Staging files are hidden and normally removed by the copy that made them. One can be left behind if the
    /// drive is unplugged mid-copy, so any that is over an hour old is removed here. Only the app's own
    /// ".pbc-staging-" files are ever touched.
    public static let stagingPrefix = ".pbc-staging-"
    static func removeStaleStaging(in folder: URL, olderThan age: TimeInterval = 3600) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for n in names where n.hasPrefix(stagingPrefix) {
            let url = folder.appendingPathComponent(n)
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), v.isRegularFile == true,
                  let m = v.contentModificationDate, Date().timeIntervalSince(m) > age else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func files(withSize size: Int64) -> [DriveFile] { byPath.values.filter { $0.size == size } }
    public func allFiles() -> [DriveFile] { Array(byPath.values) }

    /// Reads capture date, pixel size and duration once; used for the "possible copy" check.
    public func metadata(for path: String) async -> DriveFile? {
        guard var f = byPath[path] else { return nil }
        if f.metadataRead { return f }
        let url = URL(fileURLWithPath: path)
        // Drive unplugged (or file gone): don't remember empty dates as if they were read.
        guard FileManager.default.fileExists(atPath: path) else { return f }
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            f.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
            f.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int
            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
               let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                f.captureDate = Self.exifDate(s)
            }
        } else {
            let asset = AVURLAsset(url: url)
            if let d = try? await asset.load(.duration), d.isNumeric { f.duration = d.seconds }
            if let c = try? await asset.load(.creationDate), let date = try? await c.load(.dateValue) { f.captureDate = date }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize) {
                f.pixelWidth = Int(abs(size.width)); f.pixelHeight = Int(abs(size.height))
            }
        }
        f.metadataRead = true
        byPath[path] = f
        return f
    }

    public func save() throws {
        guard scanned else { return }   // nothing complete to save; never overwrite the cache with less
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(byPath.values)).write(to: cacheURL, options: .atomic)
    }

    static func exifDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: s)
    }
}
