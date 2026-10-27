import Foundation
import CryptoKit

public struct CopyJob: Sendable {
    public var item: PhoneItem
    public var destName: String
    public var bundleID: String
    public var bundleMembers: [String]
    public var read: @Sendable (Int64, Int) async throws -> Data

    public init(item: PhoneItem, destName: String, bundleID: String, bundleMembers: [String], read: @escaping @Sendable (Int64, Int) async throws -> Data) {
        self.item = item; self.destName = destName; self.bundleID = bundleID; self.bundleMembers = bundleMembers; self.read = read
    }
}

public struct PlannedCopy: Sendable, Hashable {
    public var item: PhoneItem
    public var destName: String
    public var bundleID: String
    public var bundleMembers: [String]
}

public struct ReceiptEntry: Codable, Sendable, Equatable {
    public var phoneName: String
    public var captureDate: Date?
    public var size: Int64
    public var sha256: String
    public var destName: String
    public var bundleID: String
    public var bundleMembers: [String]
    public var verified: Bool
    public var at: Date

    public init(phoneName: String, captureDate: Date?, size: Int64, sha256: String, destName: String,
                bundleID: String, bundleMembers: [String], verified: Bool, at: Date) {
        self.phoneName = phoneName; self.captureDate = captureDate; self.size = size; self.sha256 = sha256
        self.destName = destName; self.bundleID = bundleID; self.bundleMembers = bundleMembers
        self.verified = verified; self.at = at
    }
}

public enum BackupError: Error, Equatable {
    case invalidFolder(String)
    case notEnoughSpace
    case fileTooLargeForFAT(String)
    case nameTaken(String)
    case verifyFailed(String)
    case driveGone
    case io(Int32)
}

/// Copies phone files to the drive without ever replacing an existing file, and only reports
/// success after re-reading the copy from the drive and matching its fingerprint.
public enum BackupWriter {
    public static let receiptName = ".photo-backup-receipt.json"

    // Test seams. nil in the app.
    nonisolated(unsafe) public static var _afterWriteHook: ((URL) -> Void)?
    nonisolated(unsafe) public static var _renameExclHook: ((String, String) -> Int32)?
    nonisolated(unsafe) public static var _linkHook: ((String, String) -> Int32)?

    public static func plan(bundles: [ItemBundle], folderName: String, existingNames: [String]) throws -> [PlannedCopy] {
        if let msg = Naming.validateFolderName(folderName) { throw BackupError.invalidFolder(msg) }
        let label = Naming.label(forFolder: folderName)
        let slots = bundles.reduce(0) { $0 + ($1.kind == .burst ? $1.mediaMembers.count : 1) }
        var numbers = Naming.nextNumbers(count: slots, label: label, existing: existingNames).makeIterator()
        var out: [PlannedCopy] = []
        for b in bundles {
            let names = b.members.map(\.name)
            var numberForStem: [String: Int] = [:]
            let shared = b.kind == .burst ? nil : numbers.next()
            for m in b.mediaMembers where b.kind == .burst { numberForStem[m.stem] = numbers.next() }
            for m in b.members {
                let n = shared ?? numberForStem[m.stem] ?? numberForStem.values.min() ?? 1
                var dest = Naming.fileName(label: label, number: n, ext: m.ext)
                if m.isEditedRender {
                    dest = Naming.fileName(label: label, number: n, ext: "").appending(" edited") + (m.ext.isEmpty ? "" : "." + m.ext)
                }
                out.append(PlannedCopy(item: m, destName: dest, bundleID: b.id, bundleMembers: names))
            }
        }
        return out
    }

    public static func preflight(folder: URL, totalBytes: Int64, largestFile: Int64) throws {
        var probe = folder
        while !FileManager.default.fileExists(atPath: probe.path) && probe.path != "/" { probe.deleteLastPathComponent() }
        let v = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let free = v?.volumeAvailableCapacityForImportantUsage ?? v?.volumeAvailableCapacity.map(Int64.init) ?? 0
        if free < 100_000_000 || free - 100_000_000 < totalBytes { throw BackupError.notEnoughSpace }
        var fs = statfs()
        if statfs(probe.path, &fs) == 0 {
            let type = withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if type == "msdos" && largestFile >= 4 * 1024 * 1024 * 1024 { throw BackupError.fileTooLargeForFAT(type) }
        }
    }

    public static func copy(_ job: CopyJob, into folder: URL) async throws -> ReceiptEntry {
        let n = job.destName
        guard !n.isEmpty, !n.contains("/"), !n.contains(":"), !n.hasPrefix(".") else { throw BackupError.invalidFolder("Bad file name: \(n)") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(".pbc-staging-\(UUID().uuidString)").path
        let final = folder.appendingPathComponent(job.destName).path

        let fd = open(staging, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard fd >= 0 else { throw BackupError.io(errno) }
        var stagingExists = true
        defer { if stagingExists { unlink(staging) } }   // only ever the app's own staging file

        let phoneHash: String
        do {
            phoneHash = try await streamToFile(fd: fd, size: job.item.size, read: job.read)
            guard fsync(fd) == 0 else { throw BackupError.io(errno) }
            close(fd)
        } catch { close(fd); throw error }

        _afterWriteHook?(URL(fileURLWithPath: staging))
        guard (try? Fingerprint.sha256(fileAt: URL(fileURLWithPath: staging))) == phoneHash else {
            throw BackupError.verifyFailed(job.destName)
        }
        if try place(staging: staging, final: final, hash: phoneHash, name: job.destName) { stagingExists = false }

        return ReceiptEntry(phoneName: job.item.name, captureDate: job.item.captureDate, size: job.item.size, sha256: phoneHash,
                            destName: job.destName, bundleID: job.bundleID, bundleMembers: job.bundleMembers, verified: true, at: Date())
    }

    public static func appendReceipt(_ entries: [ReceiptEntry], folder: URL) throws {
        let url = folder.appendingPathComponent(receiptName)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        var old: [ReceiptEntry] = []
        var target = url
        if let data = try? Data(contentsOf: url) {
            if let list = try? dec.decode([ReceiptEntry].self, from: data) { old = list }
            else {   // damaged receipt: keep it as it is, write a new one next to it
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                target = folder.appendingPathComponent(".photo-backup-receipt-\(stamp).json")
            }
        }
        try enc.encode(old + entries).write(to: target, options: .atomic)   // atomic replace of the app's own receipt only
    }

    // MARK: - internals

    private static func streamToFile(fd: Int32, size: Int64, read: (Int64, Int) async throws -> Data) async throws -> String {
        guard size > 0 else { throw EmptyFile() }
        var hasher = SHA256()
        var offset: Int64 = 0
        while offset < size {
            let len = Int(min(Int64(Fingerprint.chunkSize), size - offset))
            let d = try await read(offset, len)
            guard d.count == len else { throw ShortRead() }
            hasher.update(data: d)
            try writeAll(fd: fd, d)
            offset += Int64(len)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func writeAll(fd: Int32, _ d: Data) throws {
        try d.withUnsafeBytes { buf in
            var done = 0
            while done < buf.count {
                let n = write(fd, buf.baseAddress! + done, buf.count - done)
                if n < 0 { throw BackupError.io(errno) }
                done += n
            }
        }
    }

    /// Moves staging to final without ever replacing an existing file.
    /// Returns true when staging was consumed (renamed), false when it still needs deleting.
    private static func place(staging: String, final: String, hash: String, name: String) throws -> Bool {
        var r = (_renameExclHook ?? { renamex_np($0, $1, UInt32(RENAME_EXCL)) == 0 ? 0 : errno })(staging, final)
        if r == 0 { return true }
        if r == EEXIST { throw BackupError.nameTaken(name) }
        guard r == ENOTSUP || r == EINVAL else { throw r == ENOENT ? BackupError.driveGone : BackupError.io(r) }

        r = (_linkHook ?? { link($0, $1) == 0 ? 0 : errno })(staging, final)
        if r == 0 { return false }
        if r == EEXIST { throw BackupError.nameTaken(name) }
        guard r == ENOTSUP || r == EPERM else { throw BackupError.io(r) }

        // Last resort: claim the final name exclusively, copy into it, verify.
        let out = open(final, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        if out < 0 { throw errno == EEXIST ? BackupError.nameTaken(name) : BackupError.io(errno) }
        do {
            let src = try FileHandle(forReadingFrom: URL(fileURLWithPath: staging))
            defer { try? src.close() }
            while let d = try src.read(upToCount: Fingerprint.chunkSize), !d.isEmpty { try writeAll(fd: out, d) }
            guard fsync(out) == 0 else { throw BackupError.io(errno) }
            close(out)
        } catch { close(out); unlink(final); throw error }   // final was created by us just now
        guard (try? Fingerprint.sha256(fileAt: URL(fileURLWithPath: final))) == hash else {
            unlink(final); throw BackupError.verifyFailed(name)
        }
        return false
    }
}
