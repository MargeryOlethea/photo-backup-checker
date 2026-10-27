import Foundation
import Core

func edgeTests() async {
    // Naming
    for bad in ["\n", " \n ", String(repeating: "a", count: 101)] {
        check(Naming.validateFolderName(bad) != nil, "rejects folder name \(bad.debugDescription.prefix(20))")
    }
    check(Naming.validateFolderName("Bali (2) 🌴") == nil, "accepts brackets and emoji")
    check(Naming.label(forFolder: "2026-10 Bali (2)") == "Bali (2)", "label keeps brackets")
    check(Naming.existingNumbers(label: "Bali (2)", in: ["Bali (2) 04.JPG", "Bali 05.JPG"]) == [4], "label with regex characters matches literally")
    check(Naming.fileName(label: "Bali", number: 1, ext: "") == "Bali 01", "no extension: no trailing dot")
    check(Naming.existingNumbers(label: "Bali", in: ["Bali 07"]) == [7], "numbered file without extension counts")
    check(Naming.nextNumbers(count: 2, label: "Bali", existing: ["Bali 99.JPG"]) == [100, 101], "99 rolls to 100")

    // Bundler / plan: edited Live photo keeps four distinct names
    func p(_ n: String, group: String? = "G", uti: String = "public.heic") -> PhoneItem {
        PhoneItem(id: "DCIM/100APPLE/\(n)", name: n, size: 5, captureDate: Date(timeIntervalSince1970: 10), uti: uti, groupUUID: group)
    }
    let mov = "com.apple.quicktime-movie"
    let editedLive = Bundler.bundles([p("IMG_0001.HEIC"), p("IMG_0001.MOV", uti: mov), p("IMG_E0001.HEIC"), p("IMG_E0001.MOV", uti: mov)])
    check(editedLive.count == 1 && editedLive[0].primary.name == "IMG_0001.HEIC", "edited Live photo is one tile, original first")
    let names = (try? BackupWriter.plan(bundles: editedLive, folderName: "Bali", existingNames: []))?.map(\.destName) ?? []
    check(Set(names).count == 4, "edited Live photo gets 4 distinct names (got \(names))")

    let lone = Bundler.bundles([PhoneItem(id: "DCIM/1/IMG_9.AAE", name: "IMG_9.AAE", size: 1, uti: "com.apple.photos.aae", isSidecar: true)])
    check(lone.count == 1 && !Matcher.isDeletable(Matcher.bundleStatus(lone[0].members.map { ($0, .none) })), "lone edit file is never deletable")

    let noExt = Bundler.bundles([PhoneItem(id: "DCIM/1/FILE", name: "FILE", size: 1, uti: "public.data")])
    let noExtNames = (try? BackupWriter.plan(bundles: noExt, folderName: "Bali", existingNames: []))?.map(\.destName) ?? []
    check(noExtNames == ["Bali 01"], "phone file without extension named without trailing dot (got \(noExtNames))")

    // Matcher: no capture date or no duration never becomes "possible"
    let noDate = PhoneItem(id: "x", name: "x.HEIC", size: 1, uti: "public.heic", pixelWidth: 3, pixelHeight: 4)
    let cand = DriveFile(path: "/d/y", size: 2, modified: Date(), captureDate: Date(), pixelWidth: 3, pixelHeight: 4, metadataRead: true)
    check(Matcher.status(item: noDate, phoneHash: nil, sameSize: [], candidates: [cand]) == .none, "no capture date: not a possible copy")

    // Drive index: missing drive must not wipe what was learned
    let dir = tempDir()
    try! Data("abc".utf8).write(to: dir.appendingPathComponent("a.jpg"))
    let cache = tempDir().appendingPathComponent("c.json")
    let idx = DriveIndex(root: dir, cacheURL: cache)
    _ = try? await idx.scan(progress: { _, _ in })
    _ = try? await idx.ensureHashes(forSizes: [3])
    try? await idx.save()
    let gone = DriveIndex(root: dir.appendingPathComponent("unplugged"), cacheURL: cache)
    await checkThrowsAsync("scan of a missing drive throws") { _ = try await gone.scan(progress: { _, _ in }) }
    try? await gone.save()
    let reread = DriveIndex(root: dir, cacheURL: cache)
    _ = try? await reread.scan(progress: { _, _ in })
    let kept = await reread.allFiles()
    check(kept.first?.sha256 != nil, "unplugged scan + save keeps earlier fingerprints")

    // Receipt: a damaged receipt is kept, not replaced
    let folder = tempDir()
    let damaged = Data("not json".utf8)
    try! damaged.write(to: folder.appendingPathComponent(BackupWriter.receiptName))
    let e = ReceiptEntry(phoneName: "a", captureDate: nil, size: 1, sha256: "h", destName: "B 01.JPG", bundleID: "a", bundleMembers: ["a"], verified: true, at: Date())
    try? BackupWriter.appendReceipt([e], folder: folder)
    check((try? Data(contentsOf: folder.appendingPathComponent(BackupWriter.receiptName))) == damaged, "damaged receipt left untouched")
    let others = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(".photo-backup-receipt") }
    check(others.count == 2, "new entries go to a second receipt file (got \(others))")
}
