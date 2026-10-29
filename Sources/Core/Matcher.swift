import Foundation

/// Decides Verified / Possible copy / Not backed up. Verified means byte-identical, nothing less.
public enum Matcher {
    public static func status(item: PhoneItem, phoneHash: String?, sameSize: [DriveFile], candidates: [DriveFile]) -> Status {
        if let h = phoneHash, let hit = sameSize.first(where: { $0.size == item.size && $0.sha256 == h }) {
            return .verified(drivePath: hit.path)
        }
        guard let date = item.captureDate else { return .none }
        for c in candidates {
            guard let cd = c.captureDate, abs(cd.timeIntervalSince(date)) <= 1 else { continue }
            let name = (c.path as NSString).lastPathComponent
            if item.isVideo {
                if let a = item.duration, let b = c.duration, abs(a - b) <= 1 {
                    return .possible(drivePath: c.path, reason: "Same date and length: \(name)")
                }
            } else if c.duration == nil,   // a photo is never a copy of a video (a Live Photo's MOV has the same date and shape)
                      let r1 = ratio(item.pixelWidth, item.pixelHeight), let r2 = ratio(c.pixelWidth, c.pixelHeight),
                      abs(r1 - r2) / r1 <= 0.01 {
                return .possible(drivePath: c.path, reason: "Same date and shape: \(name)")
            }
        }
        return .none
    }

    /// A bundle is verified only when every photo/video in it is. Edit sidecars (.AAE) don't count.
    public static func bundleStatus(_ members: [(PhoneItem, Status)]) -> Status {
        let media = members.filter { !$0.0.isSidecar }
        var firstVerified: String?
        var missing: [String] = []
        var possible: (String, String)?
        for (item, s) in media {
            switch s {
            case .verified(let p): if firstVerified == nil { firstVerified = p }
            case .possible(let p, let r): if possible == nil { possible = (p, r) }; missing.append(item.name)
            case .none: missing.append(item.name)
            }
        }
        if missing.isEmpty, let p = firstVerified { return .verified(drivePath: p) }
        if let exception = unbackedEditedOriginals(media) {
            return .verified(drivePath: exception.firstEditedDrivePath)
        }
        if let p = firstVerified { return .possible(drivePath: p, reason: "Not everything is backed up: \(missing.joined(separator: ", "))") }
        if let (p, r) = possible { return .possible(drivePath: p, reason: r) }
        return .none
    }

    /// Originals that need copying before a bundle made green by its edited versions can be deleted.
    /// Empty when every media member already has its own verified drive copy.
    public static func unbackedOriginals(_ members: [(PhoneItem, Status)]) -> [(original: PhoneItem, editedDrivePath: String)] {
        unbackedEditedOriginals(members.filter { !$0.0.isSidecar })?.originals ?? []
    }

    public static func isDeletable(_ s: Status) -> Bool {
        if case .verified = s { return true }
        return false
    }

    private static func ratio(_ w: Int?, _ h: Int?) -> Double? {
        guard let w, let h, w > 0, h > 0 else { return nil }
        return Double(max(w, h)) / Double(min(w, h))
    }

    /// The sole owner of the edited-version exception used by both bundle status and delete preparation.
    private struct EditedOriginalException {
        var originals: [(original: PhoneItem, editedDrivePath: String)]
        var firstEditedDrivePath: String
    }

    private static func unbackedEditedOriginals(_ media: [(PhoneItem, Status)]) -> EditedOriginalException? {
        var verifiedEdits: [(item: PhoneItem, drivePath: String)] = []
        for (item, status) in media {
            if item.isEditedRender, case .verified(let drivePath) = status {
                verifiedEdits.append((item, drivePath))
            }
        }

        var originals: [(original: PhoneItem, editedDrivePath: String)] = []
        for (item, status) in media {
            if case .verified = status {
                guard item.isEditedRender else { return nil }
                continue
            }
            guard !item.isVideo, !item.isEditedRender,
                  let edited = verifiedEdits.first(where: { $0.item.stem == item.stem }) else { return nil }
            originals.append((item, edited.drivePath))
        }
        guard let firstEdited = verifiedEdits.first, !originals.isEmpty else { return nil }
        return EditedOriginalException(originals: originals, firstEditedDrivePath: firstEdited.drivePath)
    }
}
