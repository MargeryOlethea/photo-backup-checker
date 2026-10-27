import Foundation
import Core
import CoreGraphics

private func reader(_ d: Data) -> @Sendable (Int64, Int) async throws -> Data {
    { off, len in d.subdata(in: Int(off)..<min(d.count, Int(off) + len)) }
}
private func phoneJob(_ name: String, _ d: Data) -> CopyJob {
    CopyJob(item: PhoneItem(id: "DCIM/1/\(name)", name: name, size: Int64(d.count), uti: "public.heic"),
            destName: name, bundleID: "DCIM/1/\(name)", bundleMembers: [name], read: reader(d))
}
private func names(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
}
private func receiptNames(_ dir: URL) -> [String] {
    struct E: Decodable { let destName: String }
    guard let d = try? Data(contentsOf: dir.appendingPathComponent(".photo-backup-receipt.json")),
          let l = try? JSONDecoder().decode([E].self, from: d) else { return [] }
    return l.map(\.destName)
}

func settleTests() async {
    // Which version is better
    check(Settle.better(phonePixels: 12_000_000, phoneSize: 2, drivePixels: 3_000_000, driveSize: 9) == .phone, "more pixels wins")
    check(Settle.better(phonePixels: 3_000_000, phoneSize: 9, drivePixels: 12_000_000, driveSize: 2) == .drive, "drive with more pixels wins")
    check(Settle.better(phonePixels: 100, phoneSize: 9, drivePixels: 100, driveSize: 2) == .phone, "same pixels: bigger file wins")
    check(Settle.better(phonePixels: 100, phoneSize: 2, drivePixels: 100, driveSize: 9) == .drive, "same pixels: bigger drive file wins")
    check(Settle.better(phonePixels: 100, phoneSize: 5, drivePixels: 100, driveSize: 5) == .phone, "full tie keeps the iPhone original")
    check(Settle.better(phonePixels: nil, phoneSize: 5, drivePixels: 100, driveSize: 1) == .drive, "unknown iPhone size: don't claim it's better")

    // Verdict
    // Measured on real pairs: a JPG re-save of the same picture differs 0.001–0.002, a 1% shifted
    // burst neighbour 0.006, a different photo 0.12+.
    check(Settle.verdict(difference: 0.0016, better: .phone) == .settle, "same picture, iPhone better: settle")
    check(Settle.verdict(difference: 0.0009, better: .drive) == .driveBetter, "same picture, drive better: leave")
    check(Settle.verdict(difference: 0.0064, better: .phone) == .differentPhoto, "burst neighbour is not the same picture")
    check(Settle.verdict(difference: 0.3, better: .phone) == .differentPhoto, "looks different: leave alone")
    check(Settle.verdict(difference: nil, better: .phone) == .differentPhoto, "couldn't compare: leave alone")

    func solid(_ v: CGFloat) -> CGImage {
        let c = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
        c.setFillColor(gray: v, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: 40, height: 30)); return c.makeImage()!
    }
    check(Settle.pixelDifference(solid(0.5), solid(0.5)) == 0, "identical images differ by 0")
    check((Settle.pixelDifference(solid(0), solid(1)) ?? 0) > 0.99, "black vs white differ by ~1")

    // Replace: different format
    do {
        let dir = tempDir()
        let old = dir.appendingPathComponent("Bali 03.JPG")
        try Data("small jpg".utf8).write(to: old)
        var trashed: [String] = []
        let out = try await Settle.replace(phoneJob("IMG_0003.HEIC", Data("original heic".utf8)), old: old, trash: { trashed.append($0.lastPathComponent); try FileManager.default.removeItem(at: $0) })
        check(names(dir) == ["Bali 03.HEIC"], "HEIC original takes the JPG's place (got \(names(dir)))")
        check(trashed == ["Bali 03.JPG"] && out.oldTrashed, "old JPG went to the Trash")
        check(out.finalPath == dir.appendingPathComponent("Bali 03.HEIC").path, "result points at the new file")
        check((try? Data(contentsOf: dir.appendingPathComponent("Bali 03.HEIC"))) == Data("original heic".utf8), "new file has the iPhone's bytes")
        check(receiptNames(dir) == ["Bali 03.HEIC"], "receipt names the new file")
    } catch { check(false, "replace different format threw \(error)") }

    // Replace: same format, same name
    do {
        let dir = tempDir()
        let old = dir.appendingPathComponent("Bali 04.jpg")
        try Data("recompressed".utf8).write(to: old)
        let out = try await Settle.replace(phoneJob("IMG_0004.JPG", Data("original jpg".utf8)), old: old, trash: { try FileManager.default.removeItem(at: $0) })
        check(names(dir) == ["Bali 04.JPG"] || names(dir) == ["Bali 04.jpg"], "same format ends under the old name (got \(names(dir)))")
        check((try? Data(contentsOf: URL(fileURLWithPath: out.finalPath))) == Data("original jpg".utf8), "same name now holds the iPhone's bytes")
        check(receiptNames(dir).count == 1 && receiptNames(dir)[0].hasPrefix("Bali 04"), "receipt names the final file (got \(receiptNames(dir)))")
    } catch { check(false, "replace same format threw \(error)") }

    // Trash fails: both copies kept, nothing deleted
    do {
        let dir = tempDir()
        let old = dir.appendingPathComponent("Bali 05.JPG")
        try Data("old".utf8).write(to: old)
        struct NoTrash: Error {}
        let out = try await Settle.replace(phoneJob("IMG_0005.JPG", Data("new".utf8)), old: old, trash: { _ in throw NoTrash() })
        check(!out.oldTrashed, "trash failure is reported")
        check(names(dir).count == 2 && (try? Data(contentsOf: old)) == Data("old".utf8), "both copies kept when the Trash fails (got \(names(dir)))")
        check((try? Data(contentsOf: URL(fileURLWithPath: out.finalPath))) == Data("new".utf8), "new copy is where the result says")
    } catch { check(false, "replace with trash failure threw \(error)") }

    // The drive file changed after it was shown: never trash it
    do {
        let dir = tempDir()
        let old = dir.appendingPathComponent("Bali 07.JPG")
        try Data("shown to the person".utf8).write(to: old)
        let seen = try Settle.identity(of: old)
        var job = phoneJob("IMG_0007.HEIC", Data("new".utf8))
        let real = job.read
        job.read = { o, l in try? Data("someone replaced it with something else".utf8).write(to: old); return try await real(o, l) }
        let out = try await Settle.replace(job, old: old, expect: seen, trash: { _ in check(false, "a changed drive file must not be trashed") })
        check(!out.oldTrashed, "changed drive file is kept")
        check((try? String(contentsOf: old, encoding: .utf8)) == "someone replaced it with something else", "changed file untouched")
    } catch { check(false, "identity test threw \(error)") }

    // Changed before starting: refuse without copying
    do {
        let dir = tempDir()
        let old = dir.appendingPathComponent("Bali 08.JPG")
        try Data("v1".utf8).write(to: old)
        let seen = try Settle.identity(of: old)
        try Data("v2 longer".utf8).write(to: old)
        let r = try? await Settle.replace(phoneJob("IMG_0008.HEIC", Data("new".utf8)), old: old, expect: seen, trash: { _ in })
        check(r == nil && names(dir) == ["Bali 08.JPG"], "drive file changed since it was shown: nothing copied (got \(names(dir)))")
    } catch { check(false, "identity setup threw \(error)") }

    // A broken read never touches the old copy
    do {
        let dir = tempDir()
        let old = dir.appendingPathComponent("Bali 06.JPG")
        try Data("old".utf8).write(to: old)
        struct Gone: Error {}
        var job = phoneJob("IMG_0006.HEIC", Data("new".utf8))
        job.read = { _, _ in throw Gone() }
        _ = try? await Settle.replace(job, old: old, trash: { _ in check(false, "trash must not be called after a failed copy") })
        check(names(dir) == ["Bali 06.JPG"], "failed copy leaves the old file alone (got \(names(dir)))")
    } catch { check(false, "setup threw \(error)") }
}
