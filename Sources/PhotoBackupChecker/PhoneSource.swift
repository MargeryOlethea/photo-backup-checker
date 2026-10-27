import Foundation
import CoreGraphics
import ImageIO
@preconcurrency import ImageCaptureCore
import Core

struct PhoneGone: Error {}

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
    private(set) var items: [PhoneItem] = []

    private let browser = ICDeviceBrowser()
    private var device: ICCameraDevice?
    private var files: [String: ICCameraFile] = [:]

    func start() {
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
    }

    // MARK: reading

    /// The phone's own small preview image (JPEG data), or nil if it doesn't answer within 15 s.
    func thumbnailData(id: String) async -> Data? {
        guard let f = files[id] else { return nil }
        nonisolated(unsafe) let file = f
        return try? await Timeout.callback(seconds: 15) { done in
            file.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: 320]) { d, _ in done(.success(d)) }
        } ?? nil
    }

    /// Exact-length chunk reader for one phone file. Short reads and a vanished phone are errors.
    func reader(id: String, timeout: Double = 30) -> @Sendable (Int64, Int) async throws -> Data {
        nonisolated(unsafe) let file = files[id]
        return { offset, length in
            guard let file, file.device != nil else { throw PhoneGone() }
            // A locked or stalled iPhone may never answer: give up after 30 s so the app can pause and retry.
            let d: Data = try await Timeout.callback(seconds: timeout) { done in
                file.requestReadData(atOffset: off_t(offset), length: off_t(length)) { data, error in
                    if let data { done(.success(data)) }
                    else { done(.failure(file.device == nil ? PhoneGone() : (error ?? PhoneGone()))) }
                }
            }
            guard d.count == length else { throw ShortRead() }
            return d
        }
    }

    func fullData(id: String) async throws -> Data {
        guard let item = items.first(where: { $0.id == id }), item.size > 0 else { throw EmptyFile() }
        let read = reader(id: id)
        var out = Data(capacity: Int(item.size))
        var off: Int64 = 0
        while off < item.size {
            let len = Int(min(Int64(Fingerprint.chunkSize), item.size - off))
            out.append(try await read(off, len))
            off += Int64(len)
        }
        return out
    }

    /// Deletes from the phone. Returns item id → nil on success, or the failure message.
    func delete(ids: [String]) async -> [String: String?] {
        guard let device else { return Dictionary(uniqueKeysWithValues: ids.map { ($0, "iPhone disconnected") }) }
        let targets = ids.compactMap { files[$0] }
        nonisolated(unsafe) let dev = device
        nonisolated(unsafe) let list = targets
        // Success is only what the phone lists as deleted, matched by object identity, not by name.
        // No answer in 2 minutes: report nothing as deleted. A fresh check shows what actually went.
        guard let deleted: [ObjectIdentifier] = try? await Timeout.callback(seconds: 120, { done in
            _ = dev.requestDeleteFiles(list, deleteFailed: { _ in }, completion: { result, _ in
                done(.success((result[.successful] ?? []).map(ObjectIdentifier.init)))
            })
        }) else {
            Diag.log("delete got no answer from the iPhone")
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, "iPhone didn't confirm. Check again to see what was deleted.") })
        }
        let ok = Set(deleted)
        var out: [String: String?] = [:]
        for id in ids {
            guard let f = files[id] else { out[id] = "Not found on iPhone"; continue }
            out[id] = ok.contains(ObjectIdentifier(f)) ? nil : "iPhone didn't delete it"
        }
        return out
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
    }
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Diag.log("catalog ready: \(device.mediaFiles?.count ?? 0) files")
        catalogReady = true
        isLocked = device.isAccessRestrictedAppleDevice
        canDelete = device.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue)
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
