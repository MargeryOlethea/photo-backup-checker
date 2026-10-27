import Foundation
import CryptoKit
import Core

private func hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

func indexTests() async {
    let dir = tempDir()
    let a = Data("hello photo".utf8), b = Data(repeating: 7, count: 9 * 1024 * 1024 + 3) // spans two 8 MiB chunks
    try! a.write(to: dir.appendingPathComponent("a.jpg"))
    try! b.write(to: dir.appendingPathComponent("b.mov"))
    try! FileManager.default.createDirectory(at: dir.appendingPathComponent("2022-09 trip"), withIntermediateDirectories: true)
    try! Data("x".utf8).write(to: dir.appendingPathComponent("2022-09 trip/c.heic"))
    try! Data("junk".utf8).write(to: dir.appendingPathComponent(".DS_Store"))
    try! Data("staging".utf8).write(to: dir.appendingPathComponent("2022-09 trip/.pbc-staging-123"))

    check(try Fingerprint.sha256(fileAt: dir.appendingPathComponent("b.mov")) == hex(b), "file hash matches CryptoKit")
    let chunked = try? await Fingerprint.sha256(readChunk: { off, len in b.subdata(in: Int(off)..<min(b.count, Int(off) + len)) }, size: Int64(b.count))
    check(chunked == hex(b), "chunked hash matches")

    // RF 4
    await checkThrowsAsync("short read throws") {
        _ = try await Fingerprint.sha256(readChunk: { _, len in Data(count: max(0, len - 1)) }, size: Int64(b.count))
    }
    await checkThrowsAsync("empty file throws") {
        _ = try await Fingerprint.sha256(readChunk: { _, _ in Data() }, size: 0)
    }

    let cache = tempDir().appendingPathComponent("drive-index.json")
    let idx = DriveIndex(root: dir, cacheURL: cache)
    let files = (try? await idx.scan(progress: { _, _ in })) ?? []
    check(files.count == 3, "scan finds 3 files, skips dotfiles and staging (got \(files.count))")
    let hashed = (try? await idx.ensureHashes(forSizes: [Int64(a.count)])) ?? []
    check(hashed.first { $0.path.hasSuffix("a.jpg") }?.sha256 == hex(a), "hashes matching size")
    check(hashed.first { $0.path.hasSuffix("b.mov") }?.sha256 == nil, "skips non-matching size")
    let sameSize = await idx.files(withSize: Int64(a.count))
    check(sameSize.count == 1, "files(withSize:)")
    try? await idx.save()

    // Cache reuse: change bytes, keep size + mtime -> cached hash survives (proves no re-read).
    let aURL = dir.appendingPathComponent("a.jpg")
    let mtime = try! FileManager.default.attributesOfItem(atPath: aURL.path)[.modificationDate] as! Date
    try! Data("HELLO PHOTO".utf8).write(to: aURL)
    try! FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: aURL.path)
    let idx2 = DriveIndex(root: dir, cacheURL: cache)
    _ = try? await idx2.scan(progress: { _, _ in })
    let again = (try? await idx2.ensureHashes(forSizes: [Int64(a.count)])) ?? []
    check(again.first { $0.path.hasSuffix("a.jpg") }?.sha256 == hex(a), "unchanged size+mtime reuses cached hash")

    // Touch mtime -> re-hashed.
    try! FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: aURL.path)
    let idx3 = DriveIndex(root: dir, cacheURL: cache)
    _ = try? await idx3.scan(progress: { _, _ in })
    let fresh = (try? await idx3.ensureHashes(forSizes: [Int64(a.count)])) ?? []
    check(fresh.first { $0.path.hasSuffix("a.jpg") }?.sha256 == hex(Data("HELLO PHOTO".utf8)), "changed mtime re-hashes")

    // RF 2: corrupted cache
    try! Data([0xff, 0x00, 0x12]).write(to: cache)
    let idx4 = DriveIndex(root: dir, cacheURL: cache)
    let files4 = (try? await idx4.scan(progress: { _, _ in })) ?? []
    check(files4.count == 3, "corrupt cache: scan still works")
    try? await idx4.save()
    check((try? JSONSerialization.jsonObject(with: Data(contentsOf: cache))) != nil, "corrupt cache rewritten as valid JSON")
}

func indexSafetyTests() async {
    let dir = tempDir()
    try! Data("abc".utf8).write(to: dir.appendingPathComponent("a.jpg"))
    try! Data("defg".utf8).write(to: dir.appendingPathComponent("b.jpg"))
    let idx = DriveIndex(root: dir, cacheURL: tempDir().appendingPathComponent("c.json"))
    _ = try? await idx.scan(progress: { _, _ in })

    // Drive unplugged before reading dates: nothing is remembered as "read".
    try! FileManager.default.removeItem(at: dir.appendingPathComponent("a.jpg"))
    let m = await idx.metadata(for: dir.appendingPathComponent("a.jpg").path)
    check(m?.metadataRead != true, "missing file is not marked as read")

    // Fingerprinting reports progress with a total.
    final class Box: @unchecked Sendable { var calls: [(Int, Int)] = [] }
    let box = Box()
    _ = try? await idx.ensureHashes(forSizes: [3, 4], progress: { d, t in box.calls.append((d, t)) })
    check(box.calls.last.map { $0.0 == $0.1 && $0.1 == 2 } == true, "fingerprint progress ends at total (got \(box.calls))")
    let files = await idx.allFiles()
    check(files.first { $0.path.hasSuffix("a.jpg") }?.sha256 == nil, "unreadable file stays without fingerprint")
}
