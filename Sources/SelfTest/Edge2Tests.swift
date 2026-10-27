import Foundation
import Core

func edge2Tests() async {
    // An existing "edited" file still counts for numbering.
    check(Naming.existingNumbers(label: "Bali", in: ["Bali 01 edited.HEIC"]) == [1], "edited file name counts for numbering")
    func p(_ n: String) -> PhoneItem { PhoneItem(id: "DCIM/1/\(n)", name: n, size: 1, captureDate: Date(timeIntervalSince1970: 1), uti: "public.heic") }
    let plan = (try? BackupWriter.plan(bundles: Bundler.bundles([p("IMG_E0002.HEIC")]), folderName: "Bali", existingNames: ["Bali 01 edited.HEIC"]))?.map(\.destName) ?? []
    check(plan == ["Bali 02 edited.HEIC"], "edit after existing edit takes next number (got \(plan))")

    // Delete gate refuses a tile with no photo/video in it.
    let aae = PhoneItem(id: "DCIM/1/IMG_9.AAE", name: "IMG_9.AAE", size: 1, uti: "com.apple.photos.aae", isSidecar: true)
    let lone = ItemBundle(id: aae.id, primary: aae, members: [aae], kind: .single)
    let r = await DeleteGate.verify([DeleteCandidate(bundle: lone, phoneHashes: [:], drivePaths: [:])])
    check(r.ok.isEmpty, "tile with only an edit file is never approved for delete")

    // Similar shots with repeated ids don't crash.
    let a = PhoneItem(id: "same", name: "a", size: 1, captureDate: Date(), uti: "public.jpeg")
    _ = Cleanup.similarGroups(items: [a, a], distance: { _, _ in 0.1 })
    check(true, "repeated ids survive")

    // Out-of-range confidence is not trusted.
    let bad = Data(#"{"answers":{"verdict":{"type":"choice","choice":"junk","confidence":1.5}}}"#.utf8)
    check((try? Jev.verdict(fromResponse: bad))?.0 == .unsure, "confidence above 1 becomes unsure")

    // Free-space check can't be fooled by overflow.
    checkThrows("huge size refused") { try BackupWriter.preflight(folder: tempDir(), totalBytes: Int64.max, largestFile: 1) }

    // Destination names can't leave the folder.
    let item = PhoneItem(id: "DCIM/1/x.HEIC", name: "x.HEIC", size: 3, uti: "public.heic")
    let folder = tempDir().appendingPathComponent("Trip")
    await checkThrowsAsync("name with / refused") {
        _ = try await BackupWriter.copy(CopyJob(item: item, destName: "../outside.HEIC", bundleID: "x", bundleMembers: ["x"], read: { _, l in Data(count: l) }), into: folder)
    }
    check(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().appendingPathComponent("outside.HEIC").path), "nothing written outside")

    // Grouping is fast enough for a whole phone (runs on every phone change).
    var many: [PhoneItem] = []
    for i in 0..<6000 {
        let n = String(format: "IMG_%04d", i % 4000)
        many.append(PhoneItem(id: "DCIM/\(i / 4000)/\(n).HEIC", name: "\(n).HEIC", size: 1, captureDate: Date(timeIntervalSince1970: Double(i)), uti: "public.heic"))
        if i % 3 == 0 { many.append(PhoneItem(id: "DCIM/\(i / 4000)/\(n).AAE", name: "\(n).AAE", size: 1, uti: "com.apple.photos.aae", isSidecar: true)) }
    }
    let t = Date()
    _ = Bundler.bundles(many)
    let secs = Date().timeIntervalSince(t)
    check(secs < 1.0, "grouping 8,000 files under 1 s (took \(String(format: "%.2f", secs)) s)")
}
