import Foundation
import UniformTypeIdentifiers

/// One file on the phone, as listed by the phone's camera connection.
public struct PhoneItem: Hashable, Sendable, Codable {
    public var id: String            // folder path + name on the phone, e.g. DCIM/109APPLE/IMG_9469.JPG
    public var name: String
    public var size: Int64
    public var captureDate: Date?
    public var uti: String
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var duration: Double?
    public var groupUUID: String?
    public var relatedUUID: String?
    public var burstUUID: String?
    public var isSidecar: Bool

    public init(id: String, name: String, size: Int64, captureDate: Date? = nil, uti: String,
                pixelWidth: Int? = nil, pixelHeight: Int? = nil, duration: Double? = nil,
                groupUUID: String? = nil, relatedUUID: String? = nil, burstUUID: String? = nil,
                isSidecar: Bool = false) {
        self.id = id; self.name = name; self.size = size; self.captureDate = captureDate; self.uti = uti
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.duration = duration
        self.groupUUID = groupUUID; self.relatedUUID = relatedUUID; self.burstUUID = burstUUID
        self.isSidecar = isSidecar
    }

    public var isVideo: Bool { UTType(uti)?.conforms(to: .movie) ?? false }

    /// An edited version: the original's 4-character prefix plus E (IMG_E0001 for IMG_0001, ECEIE5383 for ECEI5383).
    /// The iPhone creates these on request, and some never finish.
    public var isEditedRender: Bool { Self.editedOriginal((name as NSString).deletingPathExtension.uppercased()) != nil }

    /// File name without extension, with an edited version's E dropped so it shares its original's stem.
    public var stem: String {
        let base = (name as NSString).deletingPathExtension.uppercased()
        return Self.editedOriginal(base) ?? base
    }

    /// The original's name for an edited version's upper-cased base name, nil when it isn't one.
    private static func editedOriginal(_ base: String) -> String? {
        // (IMG_|[A-Z]{4})E\d+, by hand: a regex here made grouping 8,000 files too slow.
        let c = Array(base.utf8)
        guard c.count > 5, c[4] == UInt8(ascii: "E"), c[5...].allSatisfy({ (48...57).contains($0) }) else { return nil }
        let prefix = c[0..<4]
        guard prefix.elementsEqual("IMG_".utf8) || prefix.allSatisfy({ (65...90).contains($0) }) else { return nil }
        return String(decoding: prefix + c[5...], as: UTF8.self)
    }

    /// Stored files first, edited versions last, each keeping its order, so a hanging edit can't hold up the rest.
    public static func storedFirst(_ items: [PhoneItem]) -> [PhoneItem] {
        items.filter { !$0.isEditedRender } + items.filter(\.isEditedRender)
    }

    /// Short file type for the grid: HEIC, JPG, PNG, MOV…
    public var formatLabel: String {
        let e = ext.uppercased()
        return e == "JPEG" ? "JPG" : e.isEmpty ? "?" : e
    }

    public var folder: String { (id as NSString).deletingLastPathComponent }
    public var ext: String { (name as NSString).pathExtension }
}

/// One file on the backup drive.
public struct DriveFile: Hashable, Sendable, Codable {
    public var path: String
    public var size: Int64
    public var modified: Date
    public var sha256: String?
    public var captureDate: Date?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var duration: Double?
    public var metadataRead: Bool

    public init(path: String, size: Int64, modified: Date, sha256: String? = nil, captureDate: Date? = nil,
                pixelWidth: Int? = nil, pixelHeight: Int? = nil, duration: Double? = nil, metadataRead: Bool = false) {
        self.path = path; self.size = size; self.modified = modified; self.sha256 = sha256
        self.captureDate = captureDate; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.duration = duration; self.metadataRead = metadataRead
    }
}

public enum Status: Hashable, Sendable {
    case verified(drivePath: String)
    case possible(drivePath: String, reason: String)
    case none
}

/// What the grid shows as one tile: a single file, or files the phone treats as one photo.
public struct ItemBundle: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case single, live, edited, burst }
    public var id: String
    public var primary: PhoneItem
    public var members: [PhoneItem]   // includes primary and sidecars
    public var kind: Kind

    public init(id: String, primary: PhoneItem, members: [PhoneItem], kind: Kind) {
        self.id = id; self.primary = primary; self.members = members; self.kind = kind
    }

    public var totalSize: Int64 { members.reduce(0) { $0 + $1.size } }
    public var mediaMembers: [PhoneItem] { members.filter { !$0.isSidecar } }
    /// What can be read from the iPhone: everything but a burst shot's edited version (see `Bundler`).
    public var readableMembers: [PhoneItem] { members.filter { !($0.isSidecar && $0.isEditedRender) } }
    /// The iPhone refuses to delete photos with an edited version from a Mac (answers "deleted", keeps them).
    public var onlyPhoneCanDelete: Bool { members.contains(where: \.isEditedRender) }
}
