import Foundation
import CryptoKit
import Core

private func hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

func deleteGateTests() async {
    let dir = tempDir()
    func file(_ name: String, _ s: String) -> (PhoneItem, String, String) {
        let d = Data(s.utf8), url = dir.appendingPathComponent(name)
        try! d.write(to: url)
        return (PhoneItem(id: "DCIM/100APPLE/\(name)", name: name, size: Int64(d.count), uti: "public.heic"), url.path, hex(d))
    }
    func candidate(_ files: [(PhoneItem, String, String)], dropHash: String? = nil) -> DeleteCandidate {
        let items = files.map(\.0)
        let b = ItemBundle(id: items[0].id, primary: items[0], members: items, kind: items.count > 1 ? .live : .single)
        var hashes: [String: String] = [:], paths: [String: String] = [:]
        for (i, p, h) in files where i.id != dropHash { hashes[i.id] = h }
        for (i, p, _) in files { paths[i.id] = p }
        return DeleteCandidate(bundle: b, phoneHashes: hashes, drivePaths: paths)
    }

    let good = candidate([file("IMG_1.HEIC", "one"), file("IMG_1.MOV", "one-video")])
    let missing = file("IMG_2.HEIC", "two"); let missC = candidate([missing]); try! FileManager.default.removeItem(atPath: missing.1)
    let changed = file("IMG_3.HEIC", "three"); let chC = candidate([changed]); try! Data("THREE".utf8).write(to: URL(fileURLWithPath: changed.1))
    let unhashed = file("IMG_4.HEIC", "four"); let unC = candidate([unhashed], dropHash: unhashed.0.id)

    let r = await DeleteGate.verify([good, missC, chC, unC])
    check(r.ok.map(\.id) == [good.bundle.id], "only the fully verified bundle passes")
    let reasons = Dictionary(uniqueKeysWithValues: r.rejected.map { ($0.0.id, $0.1) })
    check(reasons[missC.bundle.id]?.contains("missing") == true, "missing drive copy rejected")
    check(reasons[chC.bundle.id]?.contains("changed") == true, "changed drive copy rejected")
    check(reasons[unC.bundle.id]?.contains("Not checked") == true, "no session hash rejected")
}
