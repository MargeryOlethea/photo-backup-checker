import Foundation
import CoreGraphics

/// Settling a possible copy: the drive holds the same picture in a lesser version (e.g. AirDrop turned HEIC into JPG).
/// The iPhone's exact original goes in its place, and the old copy goes to the drive's Trash, never deleted outright.
public enum Settle {
    public enum Better: Equatable { case phone, drive }
    /// `sameClip`: a video matched on date and length; frames aren't compared, so the drive copy is never trashed by default.
    public enum Verdict: Equatable { case settle, driveBetter, differentPhoto, sameClip }
    /// What to do with one possible copy. Every row gets one, so the whole list can be fixed in one go.
    public enum Action: String, CaseIterable, Identifiable, Sendable {
        case replace = "Replace", keepBoth = "Keep both", skip = "Skip"
        public var id: String { rawValue }
    }
    /// What makes a drive file "the one that was shown": its inode, size and change time.
    public struct Identity: Equatable, Sendable { let inode: UInt64; let size: Int64; let modified: Date }
    public enum SettleError: Error { case driveFileChanged }

    public static func identity(of url: URL) throws -> Identity {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        return Identity(inode: (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                        size: (a[.size] as? NSNumber)?.int64Value ?? -1,
                        modified: a[.modificationDate] as? Date ?? .distantPast)
    }

    public struct Outcome: Sendable { public var finalPath: String; public var oldTrashed: Bool; public var receipt: ReceiptEntry }

    /// Average difference (0…1) of the two pictures shrunk to 32×32 grey, under which they count as the same
    /// picture. Measured: a JPG re-save differs 0.001–0.002, a burst neighbour shifted 1% already 0.006.
    public static let samePicture = 0.004

    /// More pixels wins, then the bigger file. A full tie keeps the iPhone original; unknown iPhone pixels never win.
    public static func better(phonePixels: Int?, phoneSize: Int64, drivePixels: Int?, driveSize: Int64) -> Better {
        guard let p = phonePixels else { return .drive }
        let d = drivePixels ?? 0
        if p != d { return p > d ? .phone : .drive }
        return phoneSize >= driveSize ? .phone : .drive
    }

    public static func verdict(difference: Double?, better: Better) -> Verdict {
        guard let difference, difference <= samePicture else { return .differentPhoto }
        return better == .phone ? .settle : .driveBetter
    }

    /// How different two pictures look: both shrunk to 32×32 grey (colour-managed), mean absolute difference 0…1.
    /// The default action for a verdict. Nothing is ever lost: "Replace" sends the old copy to the Trash,
    /// "Keep both" adds the iPhone original next to it. Either way the photo turns green.
    public static func suggested(for verdict: Verdict) -> Action {
        switch verdict {
        case .settle: .replace            // same picture, iPhone's is better: swap it in
        case .driveBetter: .keepBoth      // same picture but the drive's is bigger: keep that, add the original
        case .differentPhoto: .keepBoth   // not the same picture (or couldn't compare): never trash it
        case .sameClip: .keepBoth         // probably the same video, but not checked frame by frame
        }
    }

    /// Adds the iPhone file next to `old` without touching it: as "<old stem>.<iPhone ext>", or
    /// "<old stem> (from iPhone).<ext>" when that name is taken or is `old` itself. Never overwrites anything.
    public static func alongside(_ job: CopyJob, old: URL) async throws -> ReceiptEntry {
        let folder = old.deletingLastPathComponent()
        let stem = old.deletingPathExtension().lastPathComponent
        let ext = job.item.ext
        let plain = ext.isEmpty ? stem : "\(stem).\(ext)"
        let names = [plain, alongsideName(old: old, ext: ext)].filter { $0.lowercased() != old.lastPathComponent.lowercased() }
        var j = job
        for (n, name) in names.enumerated() {
            j.destName = name
            do {
                let entry = try await BackupWriter.copy(j, into: folder)
                try? BackupWriter.appendReceipt([entry], folder: folder)
                return entry
            } catch BackupError.nameTaken where n < names.count - 1 { continue }
        }
        throw BackupError.nameTaken(names.last ?? plain)
    }

    /// Name for the iPhone original when it is added next to `old` rather than replacing it.
    public static func alongsideName(old: URL, ext: String) -> String {
        let stem = old.deletingPathExtension().lastPathComponent
        return ext.isEmpty ? "\(stem) (from iPhone)" : "\(stem) (from iPhone).\(ext)"
    }

    public static func pixelDifference(_ a: CGImage, _ b: CGImage) -> Double? {
        func grey(_ img: CGImage) -> [UInt8]? {
            var px = [UInt8](repeating: 0, count: 32 * 32)
            let ok = px.withUnsafeMutableBytes { buf -> Bool in
                guard let c = CGContext(data: buf.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 32,
                                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
                c.interpolationQuality = .high
                c.draw(img, in: CGRect(x: 0, y: 0, width: 32, height: 32))
                return true
            }
            return ok ? px : nil
        }
        guard let x = grey(a), let y = grey(b) else { return nil }
        var total = 0
        for i in 0..<x.count { total += abs(Int(x[i]) - Int(y[i])) }
        return Double(total) / Double(x.count) / 255
    }

    /// Copies the iPhone file next to `old` under old's name with the iPhone's format, verified byte for byte,
    /// then moves `old` to the Trash. If trashing fails, both copies stay. A failed copy never touches `old`.
    /// With `expect`, `old` must still be the file that was shown: changed before the copy, nothing happens;
    /// changed during it, the copy stays and `old` is left alone.
    public static func replace(_ job: CopyJob, old: URL, expect: Identity? = nil,
                               trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) async throws -> Outcome {
        if let expect, (try? identity(of: old)) != expect { throw SettleError.driveFileChanged }
        let folder = old.deletingLastPathComponent()
        let stem = old.deletingPathExtension().lastPathComponent
        let ext = job.item.ext
        let target = ext.isEmpty ? stem : "\(stem).\(ext)"
        let holding = alongsideName(old: old, ext: ext)
        var j = job
        j.destName = target.lowercased() == old.lastPathComponent.lowercased() ? holding : target
        var entry: ReceiptEntry
        do { entry = try await BackupWriter.copy(j, into: folder) }
        catch BackupError.nameTaken(_) where j.destName == target {   // some other file already has that name
            j.destName = holding
            entry = try await BackupWriter.copy(j, into: folder)
        }
        var final = folder.appendingPathComponent(j.destName)

        var trashed = false
        if expect == nil || (try? identity(of: old)) == expect {
            do { try trash(old); trashed = true } catch {}
        }
        if trashed && j.destName != target {
            let dest = folder.appendingPathComponent(target)
            if !FileManager.default.fileExists(atPath: dest.path), (try? FileManager.default.moveItem(at: final, to: dest)) != nil { final = dest }
        }
        entry.destName = final.lastPathComponent
        try? BackupWriter.appendReceipt([entry], folder: folder)
        return Outcome(finalPath: final.path, oldTrashed: trashed, receipt: entry)
    }
}
