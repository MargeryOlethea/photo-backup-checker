import Foundation
import CryptoKit
import Core

private func hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
private func reader(_ d: Data) -> @Sendable (Int64, Int) async throws -> Data {
    { off, len in d.subdata(in: Int(off)..<min(d.count, Int(off) + len)) }
}
private func job(_ name: String, _ d: Data, dest: String, read: (@Sendable (Int64, Int) async throws -> Data)? = nil) -> CopyJob {
    CopyJob(item: PhoneItem(id: "DCIM/100APPLE/\(name)", name: name, size: Int64(d.count), uti: "public.heic"),
            destName: dest, bundleID: "DCIM/100APPLE/\(name)", bundleMembers: [name], read: read ?? reader(d))
}
private func leftovers(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(".pbc-staging") }
}
private func phone(_ name: String, group: String? = nil, uti: String = "public.heic", sidecar: Bool = false) -> PhoneItem {
    PhoneItem(id: "DCIM/100APPLE/\(name)", name: name, size: 10, captureDate: Date(timeIntervalSince1970: 1), uti: uti, groupUUID: group, isSidecar: sidecar)
}

func writerTests() async {
    // plan
    let live = Bundler.bundles([phone("IMG_0001.HEIC", group: "G"), phone("IMG_0001.MOV", group: "G", uti: "com.apple.quicktime-movie"),
                                phone("IMG_0001.AAE", uti: "com.apple.photos.aae", sidecar: true)])
    let single = Bundler.bundles([phone("IMG_0002.JPG", uti: "public.jpeg")])
    let planned = (try? BackupWriter.plan(bundles: live + single, folderName: "2026-10 Bali", existingNames: [])) ?? []
    check(planned.map(\.destName) == ["Bali 01.HEIC", "Bali 01.MOV", "Bali 01.AAE", "Bali 02.JPG"], "plan names: bundle shares number (got \(planned.map(\.destName)))")
    check(planned.first?.bundleMembers.count == 3, "plan carries bundle members")
    // RF 5
    let cont = (try? BackupWriter.plan(bundles: single, folderName: "2026-10 Bali", existingNames: ["bali 01.heic"])) ?? []
    check(cont.map(\.destName) == ["Bali 02.JPG"], "plan continues numbering after existing")
    // RF 3
    checkThrows("plan rejects bad folder name") { _ = try BackupWriter.plan(bundles: single, folderName: "a/b", existingNames: []) }

    // copy writes exact bytes
    let drive = tempDir(), folder = drive.appendingPathComponent("2026-10 Bali")
    let bytes = Data((0..<(9 * 1024 * 1024)).map { UInt8($0 % 251) })
    let entry = try? await BackupWriter.copy(job("IMG_0001.HEIC", bytes, dest: "Bali 01.HEIC"), into: folder)
    check(entry?.sha256 == hex(bytes) && entry?.verified == true, "copy returns verified entry with right hash")
    check((try? Data(contentsOf: folder.appendingPathComponent("Bali 01.HEIC"))) == bytes, "copy writes exact bytes")
    check(leftovers(folder).isEmpty, "no staging left after copy")

    // never overwrite
    let existing = Data("old memory".utf8)
    try! existing.write(to: folder.appendingPathComponent("Bali 02.HEIC"))
    await checkThrowsAsync("existing name throws") { _ = try await BackupWriter.copy(job("IMG_0002.HEIC", bytes, dest: "Bali 02.HEIC"), into: folder) }
    check((try? Data(contentsOf: folder.appendingPathComponent("Bali 02.HEIC"))) == existing, "existing file untouched")
    check(leftovers(folder).isEmpty, "no staging left after name clash")
    // case-insensitive clash on a case-insensitive volume is also refused
    await checkThrowsAsync("case-different existing name throws") { _ = try await BackupWriter.copy(job("IMG_0002.HEIC", bytes, dest: "bali 02.heic"), into: folder) }
    check((try? Data(contentsOf: folder.appendingPathComponent("Bali 02.HEIC"))) == existing, "existing file untouched (case)")

    // corrupt copy
    BackupWriter._afterWriteHook = { url in
        let h = try! FileHandle(forUpdating: url); try! h.seek(toOffset: 5); h.write(Data([0xAA])); try! h.close()
    }
    await checkThrowsAsync("corrupt copy throws") { _ = try await BackupWriter.copy(job("IMG_0003.HEIC", bytes, dest: "Bali 03.HEIC"), into: folder) }
    BackupWriter._afterWriteHook = nil
    check(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Bali 03.HEIC").path), "corrupt copy leaves no final file")
    check(leftovers(folder).isEmpty, "corrupt copy leaves no staging")

    // RF 4 short read
    let short: @Sendable (Int64, Int) async throws -> Data = { _, len in Data(count: len - 1) }
    await checkThrowsAsync("short read throws") { _ = try await BackupWriter.copy(job("IMG_0004.HEIC", bytes, dest: "Bali 04.HEIC", read: short), into: folder) }
    check(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Bali 04.HEIC").path), "short read leaves no final")
    check(leftovers(folder).isEmpty, "short read leaves no staging")

    // RF 1 drive gone mid-copy
    let gone = tempDir().appendingPathComponent("Trip")
    let pulls: @Sendable (Int64, Int) async throws -> Data = { off, len in
        if off > 0 { try? FileManager.default.removeItem(at: gone) }
        return bytes.subdata(in: Int(off)..<min(bytes.count, Int(off) + len))
    }
    await checkThrowsAsync("drive gone mid-copy throws") { _ = try await BackupWriter.copy(job("IMG_0005.HEIC", bytes, dest: "Trip 01.HEIC", read: pulls), into: gone) }
    check(!FileManager.default.fileExists(atPath: gone.appendingPathComponent("Trip 01.HEIC").path), "drive gone leaves no final")

    // rename fallbacks
    BackupWriter._renameExclHook = { _, _ in ENOTSUP }
    BackupWriter._linkHook = { _, _ in EPERM }
    let fb = try? await BackupWriter.copy(job("IMG_0006.HEIC", bytes, dest: "Bali 06.HEIC"), into: folder)
    check(fb?.verified == true && (try? Data(contentsOf: folder.appendingPathComponent("Bali 06.HEIC"))) == bytes, "fallback copy works without exclusive rename")
    await checkThrowsAsync("fallback still refuses existing name") { _ = try await BackupWriter.copy(job("IMG_0007.HEIC", bytes, dest: "Bali 02.HEIC"), into: folder) }
    check((try? Data(contentsOf: folder.appendingPathComponent("Bali 02.HEIC"))) == existing, "fallback leaves existing untouched")
    check(leftovers(folder).isEmpty, "fallback leaves no staging")
    BackupWriter._renameExclHook = nil
    BackupWriter._linkHook = nil

    // receipt
    if let e = entry {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let read = { (try? Data(contentsOf: folder.appendingPathComponent(".photo-backup-receipt.json"))).flatMap { try? dec.decode([ReceiptEntry].self, from: $0) } ?? [] }
        try? BackupWriter.appendReceipt([e], folder: folder)
        let first = read()
        var e2 = e; e2.destName = "Bali 09.HEIC"
        try? BackupWriter.appendReceipt([e2], folder: folder)
        let list = read()
        check(first.count == 1 && list.count == 2 && list[0] == first[0] && list[1].destName == "Bali 09.HEIC", "receipt is append-only")
    } else { check(false, "receipt test needs entry") }

    // preflight
    checkThrows("preflight refuses when not enough space") { try BackupWriter.preflight(folder: drive, totalBytes: Int64.max / 2, largestFile: 1) }
    check((try? BackupWriter.preflight(folder: drive, totalBytes: 1, largestFile: 1)) != nil, "preflight passes small copy")
}
