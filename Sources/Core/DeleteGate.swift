import Foundation

public struct DeleteCandidate: Sendable {
    public var bundle: ItemBundle
    public var phoneHashes: [String: String]   // item id → fingerprint read from the phone this session (kept copy: its fingerprint when kept)
    public var drivePaths: [String: String]    // item id → verified drive copy
    /// item id → size of a kept drive copy that isn't identical to the iPhone file (the drive's better version).
    public var keptSizes: [String: Int64]

    public init(bundle: ItemBundle, phoneHashes: [String: String], drivePaths: [String: String], keptSizes: [String: Int64] = [:]) {
        self.bundle = bundle; self.phoneHashes = phoneHashes; self.drivePaths = drivePaths; self.keptSizes = keptSizes
    }
}

/// Last check before anything leaves the phone: every photo/video in the bundle must have a drive copy
/// that exists right now and whose bytes, re-read now, match what was read from the phone
/// (or, for a kept drive copy, match that copy as it was when the person kept it).
public enum DeleteGate {
    public static func verify(_ candidates: [DeleteCandidate]) async -> (ok: [ItemBundle], rejected: [(ItemBundle, String)]) {
        var ok: [ItemBundle] = [], rejected: [(ItemBundle, String)] = []
        for c in candidates {
            if let why = await reason(c) { rejected.append((c.bundle, why)) } else { ok.append(c.bundle) }
        }
        return (ok, rejected)
    }

    private static func reason(_ c: DeleteCandidate) async -> String? {
        if c.bundle.mediaMembers.isEmpty { return "Nothing to verify: \(c.bundle.primary.name)" }
        for m in c.bundle.mediaMembers {
            guard let h = c.phoneHashes[m.id] else { return "Not checked this session: \(m.name)" }
            guard let p = c.drivePaths[m.id] else { return "No drive copy: \(m.name)" }
            let attrs = try? FileManager.default.attributesOfItem(atPath: p)
            guard let size = attrs?[.size] as? NSNumber else { return "Drive copy missing: \(m.name)" }
            guard size.int64Value == c.keptSizes[m.id] ?? m.size else { return "Drive copy changed: \(m.name)" }
            let fresh = await Task.detached { try? Fingerprint.sha256(fileAt: URL(fileURLWithPath: p)) }.value
            guard fresh == h else { return "Drive copy changed: \(m.name)" }
        }
        return nil
    }
}

public enum PhoneDelete {
    /// Names the iPhone Shortcut reads from the clipboard, one per line, for bundles the iPhone only deletes itself.
    /// Photos on the iPhone knows a photo by its stem without extension (IMG_2663), and the Shortcut matches "Name is".
    /// A bundle whose stem exists in more than one folder on the phone is left out: a look-alike that isn't backed up
    /// must never be deleted.
    public static func handoverList(_ bundles: [ItemBundle], allPhoneItems: [PhoneItem]) -> (names: [String], notUnique: [ItemBundle]) {
        let foldersByStem = Dictionary(grouping: allPhoneItems, by: \.stem).mapValues { Set($0.map(\.folder)) }
        var names: [String] = []
        var notUnique: [ItemBundle] = []
        for bundle in bundles {
            if foldersByStem[bundle.primary.stem]?.count == 1 {
                names.append(bundle.primary.stem)
            } else {
                notUnique.append(bundle)
            }
        }
        return (names, notUnique)
    }

    /// Per file: nil when it's gone from the iPhone, otherwise why it's still there. Gone means the phone confirmed
    /// deleting it, or it was already off the phone when asked (a late answer to an earlier request that timed out).
    public static func outcome(ids: [String], present: Set<String>, confirmed: Set<String>) -> [String: String?] {
        Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, !present.contains(id) || confirmed.contains(id) ? nil : "iPhone didn't delete it")
        })
    }
}
