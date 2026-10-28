import Foundation
import CoreGraphics
import ImageIO
@preconcurrency import ImageCaptureCore
import UniformTypeIdentifiers
import Core

struct PhoneGone: Error {}
/// The phone is connected but doesn't list this file: its list is still coming in, or the file was removed on the phone.
struct NotOnPhone: Error {}

/// The phone, through Apple's camera connection (the same one Image Capture uses).
/// ImageCaptureCore calls its delegates on the main thread; all state here lives on the main actor.
@MainActor
final class PhoneSource: NSObject, @preconcurrency ICDeviceBrowserDelegate, @preconcurrency ICCameraDeviceDelegate {
    var onChange: (() -> Void)?
    private(set) var deviceName: String?
    private(set) var deviceID: String?
    private(set) var isLocked = false
    private(set) var canDelete = false
    private(set) var catalogReady = false
    private(set) var items: [PhoneItem] = [] { didSet { itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) } }
    private var itemsByID: [String: PhoneItem] = [:]
    /// A request hung in a way that blocks every later one (see `HangTracker`). Nothing is asked of the phone
    /// until `reconnect()` reopens the session or the phone is replugged.
    private(set) var jammed = false

    private let browser = ICDeviceBrowser()
    private var device: ICCameraDevice?
    private var files: [String: ICCameraFile] = [:]
    private var demoFiles: [String: URL] = [:]   // demo mode: a folder on the Mac stands in for the iPhone
    private var hangs = HangTracker()
    private var reopenPending = false            // reconnect() asked to close; open again once it has
    /// Healthy edited versions answer in well under a second (0.7 s worst case over 699 reads); one the iPhone can't
    /// make never answers, however long we wait (2 min tried). Give up fast so the connection can be reopened.
    static let editedReadTimeout: Double = 10

    func start() {
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
    }

    /// Demo mode (PBC_DEMO_PHONE): the photos in `folder` act as the iPhone's, so the app can be tried without one.
    func startDemo(folder: URL) {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"; fmt.locale = Locale(identifier: "en_US_POSIX")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        items = names.reversed().map { name in
            let url = folder.appendingPathComponent(name)
            let props = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]
            let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let id = "DCIM/DEMO/\(name)"
            demoFiles[id] = url
            return PhoneItem(id: id, name: name, size: size,
                             captureDate: (exif?[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(fmt.date(from:)),
                             uti: UTType(filenameExtension: url.pathExtension)?.identifier ?? "public.data",
                             pixelWidth: props?[kCGImagePropertyPixelWidth] as? Int, pixelHeight: props?[kCGImagePropertyPixelHeight] as? Int)
        }
        deviceName = "Demo iPhone"; deviceID = "demo"; canDelete = true; catalogReady = true
        changed()
    }

    // MARK: reading

    /// The phone's own small preview image (JPEG data), or nil if it doesn't answer within 15 s.
    func thumbnailData(id: String) async -> Data? {
        if let url = demoFiles[id] {
            guard let img = AppModel.downscaled(url, to: 320) else { return nil }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, img, nil)
            return CGImageDestinationFinalize(dest) ? out as Data : nil
        }
        guard let f = files[id] else { return nil }
        nonisolated(unsafe) let file = f
        return try? await Timeout.callback(seconds: 15) { done in
            file.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: 320]) { d, _ in done(.success(d)) }
        } ?? nil
    }

    /// Exact-length chunk reader for one phone file. Short reads and a vanished phone are errors.
    func reader(id: String, timeout: Double = 30) -> @Sendable (Int64, Int) async throws -> Data {
        if let url = demoFiles[id] {
            return { offset, length in
                let h = try FileHandle(forReadingFrom: url)
                defer { try? h.close() }
                try h.seek(toOffset: UInt64(offset))
                let d = try h.read(upToCount: length) ?? Data()
                guard d.count == length else { throw ShortRead() }
                return d
            }
        }
        nonisolated(unsafe) let file = files[id]
        let item = itemsByID[id]
        let limit = item?.isEditedRender == true ? min(timeout, Self.editedReadTimeout) : timeout
        return { offset, length in
            guard let file else { throw NotOnPhone() }
            guard file.device != nil else { throw PhoneGone() }
            // A locked or stalled iPhone may never answer: give up after `limit` so the app can pause and retry.
            let d: Data
            do {
                d = try await Timeout.callback(seconds: limit) { done in
                    file.requestReadData(atOffset: off_t(offset), length: off_t(length)) { data, error in
                        if let data { done(.success(data)) }
                        else { done(.failure(file.device == nil ? PhoneGone() : (error ?? PhoneGone()))) }
                    }
                }
            } catch is TimedOut {
                if let item { await self.hung(item) }
                throw TimedOut()
            }
            await self.answered()
            guard d.count == length else { throw ShortRead() }
            return d
        }
    }

    /// A locked phone doesn't answer either; that is waited out, not treated as a jam.
    private func hung(_ item: PhoneItem) {
        guard !isLocked, hangs.timedOut(item), !jammed else { return }
        jammed = true
        Diag.log("iPhone connection jammed after \(item.id)")
    }
    private func answered() { hangs.answered() }

    /// Software replug: closes the session and opens it again, which clears a jammed connection without unplugging.
    /// `catalogReady` is false until the phone has listed its photos again; the caller decides how long to wait.
    /// A jammed session sometimes never confirms the close; after 20 s the open is sent anyway.
    func reconnect() {
        jammed = false
        hangs = HangTracker()
        guard let device, demoFiles.isEmpty else { return }
        Diag.log("reconnecting: closing the session")
        reopenPending = true
        catalogReady = false
        device.requestCloseSession()
        changed()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, self.reopenPending, self.device == device else { return }
            self.reopen(why: "the close didn't answer; opening the session anyway")
        }
    }

    /// Second half of `reconnect()`. (Synchronous on purpose: in an async context Swift picks the framework's
    /// async `requestOpenSession(options:)` instead of the delegate-based one this class is built on.)
    private func reopen(why: String) {
        reopenPending = false
        Diag.log("reconnecting: \(why)")
        device?.requestOpenSession()
    }

    func fullData(id: String) async throws -> Data {
        guard let item = itemsByID[id], item.size > 0 else { throw EmptyFile() }
        let read = reader(id: id)
        var out = Data(capacity: Int(item.size))
        var off: Int64 = 0
        while off < item.size {
            try Task.checkCancellation()
            let len = Int(min(Int64(Fingerprint.chunkSize), item.size - off))
            out.append(try await read(off, len))
            off += Int64(len)
        }
        return out
    }

    /// Deletes from the phone. Returns item id → nil on success, or the failure message.
    /// Throws `TimedOut` when the phone doesn't answer in time (30 s, plus 10 s per extra file), so the caller can pause and ask again.
    func delete(ids: [String]) async throws -> [String: String?] {
        if !demoFiles.isEmpty {   // demo: drop from the list only; the sample files stay
            items.removeAll { ids.contains($0.id) }
            changed()
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, nil) })
        }
        guard let device else { return Dictionary(uniqueKeysWithValues: ids.map { ($0, "iPhone disconnected") }) }
        // Only a fully loaded list can say a file is already gone.
        guard catalogReady else { return Dictionary(uniqueKeysWithValues: ids.map { ($0, "iPhone still loading its photo list") }) }
        // Files already gone (an earlier request that timed out went through after all) aren't asked for again.
        // Captured now: the phone may report the removal (and drop them from `files`) before the answer arrives.
        let present = ids.compactMap { id in files[id].map { (id, $0) } }
        guard !present.isEmpty else { return PhoneDelete.outcome(ids: ids, present: [], confirmed: []) }
        nonisolated(unsafe) let dev = device
        nonisolated(unsafe) let list = present.map(\.1)
        // Success is only what the phone lists as deleted, matched by object identity, not by name.
        let deleted: [ObjectIdentifier]
        do {
            deleted = try await Timeout.callback(seconds: 30 + 10 * Double(list.count - 1), { done in
                _ = dev.requestDeleteFiles(list, deleteFailed: { _ in }, completion: { result, _ in
                    done(.success((result[.successful] ?? []).map(ObjectIdentifier.init)))
                })
            })
        } catch let e as TimedOut {
            Diag.log("delete got no answer from the iPhone")
            throw e
        }
        let ok = Set(deleted)
        let confirmed = present.filter { ok.contains(ObjectIdentifier($0.1)) }.map(\.0)
        return PhoneDelete.outcome(ids: ids, present: Set(present.map(\.0)), confirmed: Set(confirmed))
    }

    // MARK: building the item list

    private func rebuild() {
        guard let device else { items = []; files = [:]; return }
        let media = (device.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        let sidecarNames = Set(media.flatMap { ($0.sidecarFiles ?? []).compactMap { $0.name } })
        var map: [String: ICCameraFile] = [:]
        var list: [PhoneItem] = []
        for f in media {
            let id = Self.path(of: f)
            map[id] = f
            let name = f.name ?? id
            list.append(PhoneItem(
                id: id, name: name, size: Int64(f.fileSize),
                captureDate: f.exifCreationDate ?? f.creationDate, uti: f.uti ?? "",
                pixelWidth: f.width > 0 ? f.width : nil, pixelHeight: f.height > 0 ? f.height : nil,
                duration: f.duration > 0 ? f.duration : nil,
                groupUUID: f.groupUUID, relatedUUID: f.relatedUUID, burstUUID: f.burstUUID,
                isSidecar: sidecarNames.contains(name) || (name as NSString).pathExtension.uppercased() == "AAE"))
        }
        files = map
        items = list
    }

    private static func path(of item: ICCameraItem) -> String {
        var parts = [item.name ?? "?"]
        var p = item.parentFolder
        while let folder = p, let n = folder.name, !n.isEmpty { parts.insert(n, at: 0); p = folder.parentFolder }
        return parts.joined(separator: "/")
    }

    private func changed() { onChange?() }

    // MARK: ICDeviceBrowserDelegate

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard self.device == nil, let cam = device as? ICCameraDevice else { return }
        self.device = cam
        deviceName = cam.name
        deviceID = cam.persistentIDString ?? cam.uuidString
        cam.delegate = self
        cam.requestOpenSession()
        changed()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard device == self.device else { return }
        reset()
    }

    private func reset() {
        device = nil; deviceName = nil; deviceID = nil; isLocked = false; canDelete = false; catalogReady = false
        items = []; files = [:]
        jammed = false; hangs = HangTracker(); reopenPending = false
        changed()
    }

    // MARK: ICDeviceDelegate / ICCameraDeviceDelegate

    func didRemove(_ device: ICDevice) { if device == self.device { reset() } }
    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        isLocked = (device as? ICCameraDevice)?.isAccessRestrictedAppleDevice ?? false
        changed()
    }
    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        Diag.log("session closed (error: \(error?.localizedDescription ?? "none"))")
        guard reopenPending, device == self.device else { return }
        reopen(why: "opening the session again")
    }
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Diag.log("catalog ready: \(device.mediaFiles?.count ?? 0) files")
        catalogReady = true
        isLocked = device.isAccessRestrictedAppleDevice
        canDelete = device.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue)
        Diag.log("iPhone allows deleting from the Mac: \(canDelete)")
        rebuild()
        changed()
    }
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) { if catalogReady { rebuild(); changed() } }
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) { if catalogReady { rebuild(); changed() } }
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) { rebuild(); changed() }
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        canDelete = camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue)
        changed()
    }
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) { isLocked = false; changed() }
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) { isLocked = true; changed() }
}
