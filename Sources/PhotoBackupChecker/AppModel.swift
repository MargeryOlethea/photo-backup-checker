import Foundation
import AppKit
import Observation
import Vision
import ImageIO
import AVFoundation
import Core

struct CleanupInfo: Equatable {
    var duplicate = false
    var similarGroup: Int?
    var jev: Jev.Verdict?
    var jevConfidence: Double?
    var best = false                 // ★ the one to keep in its similar group
    var bestReason: String?
    var isCandidate: Bool { duplicate || similarGroup != nil || jev == .junk }
}

enum Filter: String, CaseIterable, Identifiable {
    case all = "All", backedUp = "Backed up", possible = "Possible copy", notBackedUp = "Not backed up", cleanup = "Clean-up", videos = "Videos"
    var id: String { rawValue }
    var short: String { self == .possible ? "Possible" : rawValue }
}
enum SortOrder: String, CaseIterable, Identifiable { case newest = "Newest", oldest = "Oldest", largest = "Largest"; var id: String { rawValue } }

struct JevResult: Codable { var verdict: Jev.Verdict; var confidence: Double }

/// One possible copy offered for settling: the iPhone original against the drive copy.
struct SettleRow: Identifiable {
    let id: String               // bundle id
    let bundle: ItemBundle
    let drive: DriveFile
    var item: PhoneItem { bundle.primary }
    var phoneThumb: CGImage?
    var driveThumb: CGImage?
    var better: Settle.Better
    var verdict: Settle.Verdict?   // nil while still comparing
    var action: Settle.Action?     // what Fix will do: the suggestion, or what the person chose in Reconcile; nil = not sure yet
    var identity: Settle.Identity? // the drive file as it was when compared; settling refuses if it changed
}

/// The one sheet shown over the main window, if any.
enum ActiveSheet: Identifiable {
    /// `settle(only:)`: the bundle ids to fix, or nil for every possible copy.
    case preview(ItemBundle), backup, delete, settle(only: Set<String>?), readyList
    var id: String {
        switch self {
        case .preview(let b): "preview \(b.id)"
        case .backup: "backup"
        case .delete: "delete"
        case .settle: "settle"
        case .readyList: "readyList"
        }
    }
}

struct Progress: Equatable { var label: String; var done: Int; var total: Int }

/// Why running work is waiting. It continues by itself once the cause is gone.
enum Pause: Equatable {
    case driveUnplugged, phoneUnplugged, phoneLocked, phoneNotResponding, phoneLoading, phoneStuck
    var text: String {
        switch self {
        case .driveUnplugged: "Hard disk unplugged. Plug it back in to continue. Nothing was lost."
        case .phoneUnplugged: "iPhone unplugged. Plug it back in to continue. Nothing was lost."
        case .phoneLocked: "iPhone is locked. Unlock it to continue."
        case .phoneNotResponding: "iPhone stopped responding. Unlock it and keep the screen on; the app keeps retrying."
        case .phoneLoading: "Reading the list of photos on the iPhone…"
        case .phoneStuck: "iPhone stopped answering. Unplug it and plug it back in; work continues by itself. Nothing was lost."
        }
    }
}

@MainActor @Observable
final class AppModel {
    let phone = PhoneSource()
    private(set) var bundles: [ItemBundle] = []
    private(set) var memberStatus: [String: Status] = [:]
    private(set) var bundleStatus: [String: Status] = [:]
    private(set) var cleanup: [String: CleanupInfo] = [:]
    private(set) var phoneState = 0          // bumped on every phone change so views refresh
    private(set) var checked = false
    var selection: Set<String> = []
    var selectionAnchor: String?          // last item clicked, for shift-click ranges
    private(set) var lastChecked: Date?
    var sheet: ActiveSheet?
    var filter: Filter = .all
    var sort: SortOrder = .newest
    var grouping = Grouping(rawValue: UserDefaults.standard.string(forKey: "grouping") ?? "") ?? .none {
        didSet { UserDefaults.standard.set(grouping.rawValue, forKey: "grouping") }
    }
    var progress: Progress?
    var message: String?
    private(set) var pause: Pause?
    private(set) var driveMounted = false
    var driveRoot: URL {
        didSet {
            UserDefaults.standard.set(driveRoot.path, forKey: "driveRoot")
            driveIndex = DriveIndex(root: driveRoot, cacheURL: appData.appendingPathComponent("drive-index.json"))
            driveMounted = driveAvailable
        }
    }

    let appData: URL
    private var driveIndex: DriveIndex
    private var sessionHashes: [String: String] = [:]   // "id|size|date" → hash read from the phone in this run of the app
    private var hashCache: [String: String] = [:]       // "id|size|date" → hash, from earlier runs
    // Saved on the Mac between runs, keyed "id|size|date" so a different photo never reuses them.
    private var jevCache: [String: JevResult] = [:]
    private var printCache: [String: Data] = [:]        // similar-shot fingerprints (archived)
    private var scoreCache: [String: ShotScore] = [:]   // ★ scores per photo
    private var jevPicks: [String: String] = [:]        // close call "a‖b" → winner's key ("" = Jev unsure)
    private var decisions: [String: Settle.Decision] = [:]   // device key → "keep the drive's copy" / "not the same"
    private(set) var settleRows: [SettleRow] = []
    @ObservationIgnored private var settleLoad = 0       // only the latest load may write settleRows
    @ObservationIgnored var tapBlockedUntil = Date.distantPast   // a drag just ended: don't treat it as a click
    @ObservationIgnored private var thumbMemory: [String: CGImage] = [:]
    @ObservationIgnored private var thumbOrder: [String] = []
    @ObservationIgnored private lazy var thumbStore = ThumbnailStore(dir: appData.appendingPathComponent("thumbs"))
    private var work: Task<Void, Never>?
    private var workID = 0
    private var autoCheckPending = false
    /// The person pressed Stop: no check starts by itself until "Check again" or a replug.
    private var stoppedByUser = false
    /// Edited versions (device-scoped keys) the iPhone failed to make: given up on after one failed try.
    private var renders = RenderTries()
    private var deviceID: String?
    private var lastSave = Date()

    init() {
        let env = ProcessInfo.processInfo.environment
        let demoPhone = env["PBC_DEMO_PHONE"].map(URL.init(fileURLWithPath:))
        appData = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoBackupChecker")
            .appendingPathComponent(demoPhone == nil ? "" : "demo")   // demo keeps its own saved data
        if demoPhone != nil { try? FileManager.default.removeItem(at: appData) }
        try? FileManager.default.createDirectory(at: appData, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: appData.appendingPathComponent("previews"))   // kept only while the app runs
        let saved = UserDefaults.standard.string(forKey: "driveRoot")
        let root = URL(fileURLWithPath: env["PBC_DEMO_DRIVE"] ?? saved ?? "/Volumes/MARGERY/BACKUP DATA MARGERY/Memories")
        driveRoot = root
        driveIndex = DriveIndex(root: root, cacheURL: appData.appendingPathComponent("drive-index.json"))
        hashCache = JSONStore.load([String: String].self, from: appData.appendingPathComponent("phone-hashes.json"))
        jevCache = JSONStore.load([String: JevResult].self, from: appData.appendingPathComponent("jev-verdicts.json"))
        printCache = JSONStore.load([String: Data].self, from: appData.appendingPathComponent("similar-prints.json"))
        scoreCache = JSONStore.load([String: ShotScore].self, from: appData.appendingPathComponent("preview-scores.json"))
        try? FileManager.default.removeItem(at: appData.appendingPathComponent("shot-scores.json"))   // scores from whole photos; no longer comparable
        jevPicks = JSONStore.load([String: String].self, from: appData.appendingPathComponent("jev-picks.json"))
        decisions = JSONStore.load([String: Settle.Decision].self, from: appData.appendingPathComponent("settle-decisions.json"))
        renders = RenderTries.load(from: appData.appendingPathComponent("bad-renders.json"))
        phone.onChange = { [weak self] in self?.phoneChanged() }
        if let demoPhone { phone.startDemo(folder: demoPhone) } else { phone.start() }
        driveMounted = FileManager.default.fileExists(atPath: root.path)
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDrive() }
            }
        }
    }

    private func refreshDrive() {
        driveMounted = FileManager.default.fileExists(atPath: driveRoot.path)
        if driveMounted && !checked && !stoppedByUser && work == nil && phone.catalogReady && !phone.isLocked && !bundles.isEmpty { checkAll() }
    }

    var hasJevKey: Bool { Jev.loadKey(from: appData) != nil }
    var driveAvailable: Bool { FileManager.default.fileExists(atPath: driveRoot.path) }
    var busy: Bool { work != nil }

    // MARK: what the grid shows

    var visible: [ItemBundle] {
        let f = bundles.filter { b in
            switch filter {
            case .all: return true
            case .backedUp: return Matcher.isDeletable(status(of: b))
            case .possible: if case .possible = status(of: b) { return true } else { return false }
            case .notBackedUp: return status(of: b) == .none
            case .videos: return b.primary.isVideo
            case .cleanup: return cleanup[b.id]?.isCandidate == true
            }
        }
        switch sort {
        case .newest: return f
        case .oldest: return f.reversed()
        case .largest: return f.sorted { $0.totalSize > $1.totalSize }
        }
    }

    func status(of b: ItemBundle) -> Status { bundleStatus[b.id] ?? .none }

    struct Summary { var verified = 0, possible = 0, none = 0; var verifiedBytes: Int64 = 0, possibleBytes: Int64 = 0, noneBytes: Int64 = 0 }
    var summary: Summary {
        var s = Summary()
        for b in bundles {
            switch status(of: b) {
            case .verified: s.verified += 1; s.verifiedBytes += b.totalSize
            case .possible: s.possible += 1; s.possibleBytes += b.totalSize
            case .none: s.none += 1; s.noneBytes += b.totalSize
            }
        }
        return s
    }

    var selectedBundles: [ItemBundle] { bundles.filter { selection.contains($0.id) } }
    var selectedBytes: Int64 { selectedBundles.reduce(0) { $0 + $1.totalSize } }

    /// Why "Delete from iPhone" can't run right now, in plain words; nil when it can.
    var deleteBlocker: String? {
        if selection.isEmpty { return nil }
        if busy { return "Delete opens up when the current task finishes (or press Stop)." }
        return nil
    }

    /// What the selection holds: backed up / possible copy / not backed up.
    var selectionBreakdown: (green: Int, possible: Int, none: Int) {
        var r = (green: 0, possible: 0, none: 0)
        for b in selectedBundles {
            switch status(of: b) { case .verified: r.green += 1; case .possible: r.possible += 1; case .none: r.none += 1 }
        }
        return r
    }

    /// One click from the Backed up card: show and select everything that's safe to delete.
    func selectAllBackedUp() {
        filter = .backedUp
        selection = Set(bundles.filter { Matcher.isDeletable(status(of: $0)) }.map(\.id))
    }

    /// Click with ⌘ toggles one item; with ⇧ selects the range from the last clicked item in `list`.
    func click(_ id: String, in list: [ItemBundle], shift: Bool) {
        if shift, let a = selectionAnchor, let i = list.firstIndex(where: { $0.id == a }), let j = list.firstIndex(where: { $0.id == id }) {
            selection.formUnion(list[min(i, j)...max(i, j)].map(\.id))
        } else if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        selectionAnchor = id
    }

    /// A date-first folder name for the selection, e.g. "2026-10 ".
    var suggestedFolderName: String {
        guard let d = selectedBundles.compactMap(\.primary.captureDate).min() else { return "" }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM "
        return f.string(from: d)
    }

    /// Every similar group at once: select all but each group's ★.
    func selectAllButBestEverywhere() { for g in similarGroups { selectAllButBest(g) } }


    /// Similar-shot groups, each in grid order, for the clean-up view.
    var similarGroups: [[ItemBundle]] {
        Dictionary(grouping: bundles.filter { cleanup[$0.id]?.similarGroup != nil }) { cleanup[$0.id]!.similarGroup! }
            .sorted { $0.key < $1.key }.map(\.value)
    }

    /// In one similar group: select every shot except the ★ one.
    func selectAllButBest(_ group: [ItemBundle]) {
        for b in group where cleanup[b.id]?.best != true { selection.insert(b.id) }
        for b in group where cleanup[b.id]?.best == true { selection.remove(b.id) }
    }

    // MARK: phone changes

    private func phoneChanged() {
        phoneState += 1
        // A different iPhone: everything learned about the previous one is dropped.
        if let id = phone.deviceID, let old = deviceID, id != old {
            cancel(); checked = false; sessionHashes = [:]; memberStatus = [:]; bundleStatus = [:]; cleanup = [:]; bundles = []; selection = []
        }
        if let id = phone.deviceID { deviceID = id }
        if phone.deviceName == nil { stoppedByUser = false }
        // While unplugged, keep showing what we know; running work pauses and continues on replug.
        guard phone.deviceName != nil, phone.catalogReady else { return }
        let newBundles = Bundler.bundles(phone.items)
        if newBundles != bundles {
            // A file re-made at the same path (a re-edited photo) is a different file: forget what we knew about it.
            let oldKeys = Dictionary(bundles.flatMap(\.members).map { ($0.id, cacheKey($0)) }, uniquingKeysWith: { a, _ in a })
            for m in newBundles.flatMap(\.members) where oldKeys[m.id] != nil && oldKeys[m.id] != cacheKey(m) { memberStatus[m.id] = nil }
            // Photos taken (or changed) while plugged in haven't been checked: run the check again (cached work is instant).
            if checked, newBundles.contains(where: { b in b.mediaMembers.contains { memberStatus[$0.id] == nil } }) { checked = false }
            bundles = newBundles
            selection = selection.intersection(Set(bundles.map(\.id)))
            recomputeBundleStatuses()
            pruneCleanup()
        }
        // An open preview of something that's no longer on this phone closes.
        if case .preview(let b)? = sheet, !bundles.contains(where: { $0.id == b.id && $0 == b }) { sheet = nil }
        if !phone.isLocked && !checked && !stoppedByUser && !bundles.isEmpty {
            if work == nil { checkAll() } else { autoCheckPending = true }
        }
    }

    // MARK: checking

    /// Asks the running task to stop. It stays "busy" until it has actually stopped.
    func cancel() {
        guard let work else { return }
        work.cancel()
        progress = Progress(label: "Stopping…", done: 0, total: 0)
    }

    /// Runs one task at a time. Only the task that is still current clears the busy state.
    /// A jammed connection (a preview or the previous task ended with a hang) is reopened first, so no task
    /// ever starts on a dead connection. (Not after the task: that would keep the app busy once the work is done.)
    private func startWork(_ body: @escaping @MainActor () async -> Void) {
        workID += 1
        let id = workID
        work = Task { [weak self] in
            if let self, self.phone.jammed { try? await self.waitForReplug() }
            if !Task.isCancelled { await body() }
            guard let self, self.workID == id else { return }
            self.work = nil
            self.progress = nil
            self.pause = nil
            if self.autoCheckPending { self.autoCheckPending = false; self.phoneChanged() }
        }
    }

    func recheck() { checked = false; stoppedByUser = false; checkAll() }

    /// What currently stops work that needs the drive and/or phone, if anything.
    private func blocker(drive: Bool, phone needsPhone: Bool) -> Pause? {
        if drive && !driveAvailable { return .driveUnplugged }
        if needsPhone && phone.deviceName == nil { return .phoneUnplugged }
        if needsPhone && !phone.catalogReady { return .phoneLoading }
        if needsPhone && phone.isLocked { return .phoneLocked }
        return nil
    }

    /// Runs one step. If the drive or phone drops out (or the phone stops answering), waits until
    /// it is back and runs the same step again. A jammed connection is reopened first (`waitForReplug`), so a step
    /// that timed out gets a working connection for its retry. Only cancelling stops it; other errors are passed on.
    private func resilient<T>(drive: Bool, phone needsPhone: Bool, maxTimeouts: Int = 2, _ step: () async throws -> T) async throws -> T {
        var timeouts = 0, reconnected = false, notListed = 0
        while true {
            try Task.checkCancellation()
            if let b = blocker(drive: drive, phone: needsPhone) {
                pause = b
                try await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            if needsPhone && phone.jammed { try await waitForReplug(); continue }
            do {
                let v = try await step()
                pause = nil
                return v
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A file the phone doesn't list: its list is still coming in after a (re)connect (it arrives in
                // batches), so wait for it, up to a minute. Still not listed then: it was removed on the phone.
                if error is NotOnPhone && needsPhone { notListed += 1 }
                let reason = blocker(drive: drive, phone: needsPhone)
                    ?? (error is TimedOut ? .phoneNotResponding : nil)
                    ?? (error is PhoneGone && needsPhone ? .phoneUnplugged : nil)
                    ?? (error is NotOnPhone && needsPhone && notListed <= 20 ? .phoneLoading : nil)
                guard let reason else { throw error }
                // Out of tries: hand the file back to the caller to skip or report. Callers that retry on their own
                // (maxTimeouts 1) get the error at once; the rest get a fresh connection and a full set of tries first.
                if reason == .phoneNotResponding {
                    timeouts += 1
                    if timeouts >= maxTimeouts {
                        if maxTimeouts > 1 && phone.jammed && !reconnected { reconnected = true; timeouts = 0; continue }
                        pause = nil; throw error
                    }
                    Diag.log("timeout #\(timeouts) — trying again")
                    pause = reason
                    continue
                }
                pause = reason
                saveNow()
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// The connection is jammed: a request hung and everything after it would too. Asks for a replug straight away
    /// and waits for the phone to list its photos again; the next step then runs on the fresh connection.
    /// The session is also reopened in software meanwhile, in case the phone answers that first.
    /// ponytail: the software reopen has never once worked on the owner's iPhone, so nobody waits for it any more.
    private func waitForReplug() async throws {
        saveNow()
        guard phone.deviceName != nil else { phone.reconnect(); return }   // unplugged: clears the jam; the next step waits for the replug
        Diag.log("phone jammed — asking for a replug")
        phone.reconnect()
        while phone.deviceName != nil && !phone.catalogReady {
            // A locked phone can't list its photos: say so instead.
            pause = phone.isLocked ? .phoneLocked : .phoneStuck
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Saves what has been learned so far, at most once a minute.
    private func saveIfDue() {
        if Date().timeIntervalSince(lastSave) >= 60 { saveNow() }
    }

    private func saveNow() {
        lastSave = Date()
        saveHashCache()
        let index = driveIndex
        Task { try? await index.save() }
    }

    func checkAll() {
        guard work == nil else { return }
        guard driveAvailable else { message = "Backup drive not found at \(driveRoot.path). Plug it in or choose the folder."; return }
        message = nil
        startWork { [weak self] in
            guard let self else { return }
            do { try await self.runCheck(); self.checked = true; self.lastChecked = Date() }
            catch is CancellationError { self.stoppedByUser = true; self.message = "Check stopped. Press “Check again” when you're ready." }
            catch is PhoneGone { self.message = "iPhone was disconnected. Plug it back in to continue." }
            catch { self.message = "Check stopped: \(error.localizedDescription)" }
            self.saveHashCache()
            try? await self.driveIndex.save()
        }
    }

    private func runCheck() async throws {
        let media = phone.items.filter { !$0.isSidecar }
        renders.newRun()

        progress = Progress(label: "Reading backup drive", done: 0, total: 0)
        let index = driveIndex
        _ = try await resilient(drive: true, phone: false) {
            let files = try await index.scan { n, _ in
                Task { @MainActor [weak self] in self?.progress = Progress(label: "Reading backup drive — \(n) files found", done: 0, total: 0) }
            }
            guard self.driveAvailable else { throw BackupError.driveGone }
            return files
        }

        let phoneSizes = Set(media.map(\.size))
        progress = Progress(label: "Fingerprinting matching files on the drive", done: 0, total: 0)
        let driveFiles = try await resilient(drive: true, phone: false) {
            let files = try await index.ensureHashes(forSizes: phoneSizes) { d, t in
                Task { @MainActor [weak self] in self?.progress = Progress(label: "Fingerprinting matching files on the drive", done: d, total: t) }
            }
            // Unplugged part-way: the unread ones are still unfingerprinted, so run it again after replug.
            guard self.driveAvailable else { throw BackupError.driveGone }
            return files
        }
        saveNow()
        let bySize = Dictionary(grouping: driveFiles, by: \.size)

        // Phone files worth fingerprinting: same size as a drive file, or as another phone file (duplicates).
        let phoneSizeCounts = Dictionary(grouping: media, by: \.size).mapValues(\.count)
        let toHash = PhoneItem.storedFirst(media.filter {
            (bySize[$0.size] != nil || (phoneSizeCounts[$0.size] ?? 0) > 1) && (knownHash($0) != nil || renders.shouldTry(deviceKey($0)))
        })
        var unreadable = 0
        var slow: [PhoneItem] = []
        // Reads one file. Returns false if it hung and is worth one slow retry at the end.
        // An edited version that hangs is noted as a failed try (the jam it causes is cleared by the next step).
        func read(_ item: PhoneItem, timeout: Double) async throws -> Bool {
            do {
                _ = try await resilient(drive: false, phone: true, maxTimeouts: 1) { try await self.hash(item, fresh: false, timeout: timeout) }
                return true
            }
            catch is CancellationError { throw CancellationError() }
            catch is TimedOut {
                Diag.log("skipped slow file \(item.id)")
                noteBadRender(item)
                return item.isEditedRender
            }
            catch { unreadable += 1; return true }   // the phone answered, just not with the file; it stays without a fingerprint, so it can't turn green
        }
        for (i, item) in toHash.enumerated() {
            try Task.checkCancellation()
            progress = Progress(label: "Checking photos on iPhone", done: i, total: toHash.count)
            // Already fingerprinted ones are still "read" here: that's instant and costs nothing.
            if try await !read(item, timeout: 30) { slow.append(item) }
            saveIfDue()
        }
        for (i, item) in slow.enumerated() {
            try Task.checkCancellation()
            progress = Progress(label: "Retrying slow files on iPhone (up to 2 min each)", done: i, total: slow.count)
            if try await !read(item, timeout: 120) { unreadable += 1 }
            saveIfDue()
        }

        // Possible copies: drive files taken at the same second.
        let needMeta = driveFiles.filter { !$0.metadataRead }
        for (i, f) in needMeta.enumerated() {
            try Task.checkCancellation()
            if i % 25 == 0 { progress = Progress(label: "Reading photo dates on the drive", done: i, total: needMeta.count) }
            _ = try await resilient(drive: true, phone: false) {
                let m = await index.metadata(for: f.path)
                guard self.driveAvailable else { throw BackupError.driveGone }
                return m
            }
            saveIfDue()
        }
        let all = await driveIndex.allFiles()
        var byTime: [Int: [DriveFile]] = [:]
        for f in all { if let d = f.captureDate { byTime[Int(d.timeIntervalSince1970), default: []].append(f) } }

        // Kept drive copies count only while their bytes are unchanged: re-fingerprint each.
        // ponytail: full re-read every check; skip when size+mtime match the kept file if kept videos make checks slow.
        let sizes = Dictionary(all.map { ($0.path, $0.size) }, uniquingKeysWith: { a, _ in a })
        var keptNow: [String: String] = [:]   // drive path → fingerprint now
        for item in media {
            guard let d = decisions[deviceKey(item)], d.kind == .keepDrive, keptNow[d.drivePath] == nil, sizes[d.drivePath] == d.driveSize else { continue }
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: d.drivePath)
            keptNow[d.drivePath] = await Task.detached { try? Fingerprint.sha256(fileAt: url) }.value
        }

        try Task.checkCancellation()
        for item in media {
            let t = item.captureDate.map { Int($0.timeIntervalSince1970) }
            let candidates = t.map { (($0 - 1)...($0 + 1)).flatMap { byTime[$0] ?? [] } } ?? []
            let found = Matcher.status(item: item, phoneHash: knownHash(item), sameSize: bySize[item.size] ?? [], candidates: candidates)
            let d = decisions[deviceKey(item)]
            memberStatus[item.id] = Settle.applying(d, to: found, driveSHA256: d.flatMap { keptNow[$0.drivePath] })
        }
        recomputeBundleStatuses()

        // Clean-up: exact duplicates and similar shots.
        var primaryHashes: [String: String] = [:]
        for b in bundles { if let h = knownHash(b.primary) { primaryHashes[b.id] = h } }
        var info: [String: CleanupInfo] = [:]
        for b in bundles { if let j = jevCache[deviceKey(b.primary)] { info[b.id] = CleanupInfo(jev: j.verdict, jevConfidence: j.confidence) } }
        for group in Cleanup.exactDuplicates(hashes: primaryHashes) { for id in group { info[id, default: CleanupInfo()].duplicate = true } }
        try await findSimilar(into: &info)
        try Task.checkCancellation()
        cleanup = info
        let gaveUp = media.filter { renders.gaveUp(deviceKey($0)) && knownHash($0) == nil }.count
        let notes = [
            unreadable > 0 ? "\(unreadable) file(s) couldn't be read from the iPhone; they stay unmarked." : nil,
            gaveUp > 0 ? "\(gaveUp) edited version(s) the iPhone can't make; they stay unmarked." : nil,
        ].compactMap { $0 }
        message = notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    /// A hung read of an edited version counts as one failed try of it; stored files are never given up on.
    private func noteBadRender(_ item: PhoneItem) { if item.isEditedRender { renders.failed(deviceKey(item)) } }

    private func findSimilar(into info: inout [String: CleanupInfo]) async throws {
        let stills = bundles.filter { !$0.primary.isVideo && $0.primary.captureDate != nil }.sorted { $0.primary.captureDate! < $1.primary.captureDate! }
        var needed = Set<String>()
        for (i, b) in stills.enumerated() {
            for c in stills[(i + 1)...] {
                if c.primary.captureDate!.timeIntervalSince(b.primary.captureDate!) > 600 { break }
                needed.insert(b.id); needed.insert(c.id)
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: stills.map { ($0.id, $0.primary) })
        var prints: [String: VNFeaturePrintObservation] = [:]
        var todo: [(id: String, item: PhoneItem, key: String)] = []
        for id in needed.sorted() {
            guard let item = byID[id] else { continue }
            let key = deviceKey(item)
            if let d = printCache[key], let fp = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: d) {
                prints[id] = fp
            } else {
                todo.append((id, item, key))
            }
        }
        // Fingerprints not yet known: thumbnails come from the Mac's cache or the iPhone, a few at a time,
        // and the image work runs off the main thread so the window stays responsive.
        let store = thumbStore
        var done = 0
        progress = Progress(label: "Looking for similar shots", done: 0, total: todo.count)
        try await withThrowingTaskGroup(of: (String, String, Data?).self) { group in
            var it = todo.makeIterator()
            func add() -> Bool {
                guard let (id, item, key) = it.next() else { return false }
                group.addTask { @MainActor in
                    var data = await Task.detached { store.data(for: key) }.value
                    if data == nil, let d = await self.phone.thumbnailData(id: item.id) {
                        data = d
                        Task.detached { store.put(d, for: key) }
                    }
                    guard let data else { return (id, key, nil) }
                    let archived = await Task.detached { () -> Data? in
                        guard let img = Self.downscaled(data, to: 320), let fp = try? Cleanup.featurePrint(cgImage: img) else { return nil }
                        return try? NSKeyedArchiver.archivedData(withRootObject: fp, requiringSecureCoding: true)
                    }.value
                    return (id, key, archived)
                }
                return true
            }
            for _ in 0..<4 { if !add() { break } }
            while let (id, key, archived) = try await group.next() {
                try Task.checkCancellation()
                if let archived, let fp = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: archived) {
                    prints[id] = fp
                    printCache[key] = archived
                }
                done += 1
                progress = Progress(label: "Looking for similar shots", done: done, total: todo.count)
                saveIfDue()
                _ = add()
            }
        }
        let groups = Cleanup.similarGroups(items: stills.map { var p = $0.primary; p.id = $0.id; return p }) { a, b in
            guard let x = prints[a], let y = prints[b] else { return nil }
            return Cleanup.distance(x, y)
        }
        for (n, g) in groups.enumerated() { for id in g { info[id, default: CleanupInfo()].similarGroup = n } }
        try await pickBest(groups, into: &info)
    }

    /// ★ per similar group: Apple scores every photo on the Mac; Jev settles only the close calls.
    private func pickBest(_ groups: [[String]], into info: inout [String: CleanupInfo]) async throws {
        let byID = Dictionary(uniqueKeysWithValues: bundles.map { ($0.id, $0) })
        var seen = Set<String>()
        var need: [(item: PhoneItem, key: String)] = []
        for item in groups.joined().compactMap({ byID[$0]?.primary }) where !item.isVideo && scoreCache[deviceKey(item)] == nil && seen.insert(item.id).inserted {
            need.append((item, deviceKey(item)))
        }
        // Scored from the previews (mostly already on the Mac), a few at a time off the main thread. Never the whole
        // photo: an edited version the iPhone can't make would jam the connection until a replug, just for a star.
        var done = 0
        let phaseStart = Date()
        Diag.log("pick best: \(groups.count) groups, \(groups.joined().count) shots, \(need.count) to score")
        defer { Diag.log("pick best: scoring took \(String(format: "%.1f", Date().timeIntervalSince(phaseStart))) s") }
        progress = Progress(label: "Picking the best of similar shots", done: 0, total: need.count)
        func finished(_ key: String, _ score: ShotScore?) {
            if let score { scoreCache[key] = score }
            done += 1
            progress = Progress(label: "Picking the best of similar shots", done: done, total: need.count)
            saveIfDue()
        }
        try await withThrowingTaskGroup(of: (String, ShotScore?).self) { group in
            var it = need.makeIterator()
            func add() -> Bool {
                guard let (item, key) = it.next() else { return false }
                group.addTask { @MainActor in (key, try await self.shotScore(item)) }
                return true
            }
            for _ in 0..<3 { if !add() { break } }
            while let (key, score) = try await group.next() {
                try Task.checkCancellation()
                finished(key, score)
                _ = add()
            }
        }
        // Close calls Jev hasn't answered yet are asked now (needs the key and the network); the ★ itself comes from the caches.
        if let key = Jev.loadKey(from: appData) {
            for g in groups {
                let photos = g.compactMap { byID[$0] }.filter { !$0.primary.isVideo }
                guard let pick = BestPick.pick(group: photos.map(\.id), scores: scores(photos)), pick.closeCall,
                      let a = byID[pick.best]?.primary, let b = byID[pick.runnerUp]?.primary, jevPicks[jevKey(a, b)] == nil else { continue }
                progress = Progress(label: "Asking Jev about close calls", done: 0, total: 0)
                guard let da = try await jevData(a), let db = try await jevData(b) else { continue }
                // Network trouble: ask again next time. Jev unsure: remembered as "" and Apple's pick stands.
                do { jevPicks[jevKey(a, b)] = try await Jev.pick(first: da, second: db, key: key).map { $0 == 0 ? deviceKey(a) : deviceKey(b) } ?? "" }
                catch { Diag.log("Jev pick failed: \(error)") }
            }
        }
        for g in groups { markBest(g.compactMap { byID[$0] }, into: &info) }
    }

    private func scores(_ photos: [ItemBundle]) -> [String: ShotScore] {
        Dictionary(uniqueKeysWithValues: photos.compactMap { b in scoreCache[deviceKey(b.primary)].map { (b.id, $0) } })
    }
    private func jevKey(_ a: PhoneItem, _ b: PhoneItem) -> String { [deviceKey(a), deviceKey(b)].sorted().joined(separator: "‖") }

    /// ★ for one similar group, from the cached scores and Jev's remembered close-call answers. Videos never get it.
    private func markBest(_ group: [ItemBundle], into info: inout [String: CleanupInfo]) {
        let photos = group.filter { !$0.primary.isVideo }
        for b in photos { info[b.id]?.best = false; info[b.id]?.bestReason = nil }
        let scores = scores(photos)
        guard var pick = BestPick.pick(group: photos.map(\.id), scores: scores),
              let a = photos.first(where: { $0.id == pick.best })?.primary, let b = photos.first(where: { $0.id == pick.runnerUp })?.primary else { return }
        var byJev = false
        if pick.closeCall {
            let jev = jevPicks[jevKey(a, b)]
            if jev == deviceKey(b) { swap(&pick.best, &pick.runnerUp) }
            byJev = jev?.isEmpty == false
        }
        info[pick.best, default: CleanupInfo()].best = true
        info[pick.best, default: CleanupInfo()].bestReason = byJev ? "A close call; Jev picked this one" : BestPick.reason(scores[pick.best]!)
    }

    /// After items left the phone: a duplicate with no twin left, or a similar group down to one shot, is nothing to
    /// clean up any more, and a group that lost its ★ gets a new one from the cached scores.
    private func pruneCleanup() {
        let alive = Set(bundles.map(\.id))
        guard cleanup.keys.contains(where: { !alive.contains($0) }) else { return }
        var info = cleanup.filter { alive.contains($0.key) }
        var twins: [String: [String]] = [:]
        for b in bundles where info[b.id]?.duplicate == true { twins[knownHash(b.primary) ?? b.id, default: []].append(b.id) }
        for ids in twins.values where ids.count < 2 { info[ids[0]]?.duplicate = false }
        for g in Dictionary(grouping: bundles.filter { info[$0.id]?.similarGroup != nil }, by: { info[$0.id]!.similarGroup! }).values {
            if g.count < 2 { for b in g { info[b.id]?.similarGroup = nil; info[b.id]?.best = false; info[b.id]?.bestReason = nil } }
            else { markBest(g, into: &info) }
        }
        cleanup = info
    }

    /// Apple's score for one photo, judged on its preview, or nil if it can't be scored now.
    private func shotScore(_ item: PhoneItem) async throws -> ShotScore? {
        guard let img = await thumbnail(for: item) else { return nil }
        return await Task.detached { BestPick.score(cgImage: img) }.value
    }

    /// What Jev gets to look at: the whole photo, except for an edited version, where it gets the preview
    /// (asking the iPhone to make the whole edited version can jam the connection).
    private func jevData(_ item: PhoneItem) async throws -> Data? {
        item.isEditedRender ? await thumbnailData(for: item) : try await fullDataOrSkip(item)
    }

    /// A whole photo from the phone, or nil if it can't be read now (only cancelling is passed on).
    /// Edited versions the phone can't make are skipped (one try, ever); a hang jams the connection, which the
    /// next step clears by asking for a replug.
    private func fullDataOrSkip(_ item: PhoneItem) async throws -> Data? {
        guard renders.shouldTry(deviceKey(item)) else { return nil }
        do { return try await resilient(drive: false, phone: true, maxTimeouts: 1) { try await self.phone.fullData(id: item.id) } }
        catch is CancellationError { throw CancellationError() }
        catch is TimedOut { Diag.log("skipped slow file \(item.id)"); noteBadRender(item); return nil }
        catch { return nil }
    }

    /// Upright image no bigger than `size` on its long side.
    nonisolated static func downscaled(_ source: CGImageSource?, to size: Int) -> CGImage? {
        guard let source else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: size]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
    }
    nonisolated static func downscaled(_ data: Data, to size: Int) -> CGImage? { downscaled(CGImageSourceCreateWithData(data as CFData, nil), to: size) }
    nonisolated static func downscaled(_ url: URL, to size: Int) -> CGImage? { downscaled(CGImageSourceCreateWithURL(url as CFURL, nil), to: size) }

    private func cacheKey(_ i: PhoneItem) -> String { "\(i.id)|\(i.size)|\(i.captureDate?.timeIntervalSince1970 ?? 0)" }
    private func knownHash(_ i: PhoneItem) -> String? { sessionHashes[cacheKey(i)] ?? hashCache[cacheKey(i)] }

    /// Fingerprint of a phone file. `fresh` forces a read from the phone in this session.
    private func hash(_ item: PhoneItem, fresh: Bool, timeout: Double = 30) async throws -> String {
        if let h = sessionHashes[cacheKey(item)] { return h }
        if !fresh, let h = hashCache[cacheKey(item)] { return h }
        let start = Date()
        Diag.log("read start \(item.id) \(item.size) bytes")
        let h: String
        do { h = try await Fingerprint.sha256(readChunk: phone.reader(id: item.id, timeout: timeout), size: item.size) }
        catch { Diag.log("read FAILED \(item.id) after \(String(format: "%.1f", Date().timeIntervalSince(start))) s: \(error)"); throw error }
        Diag.log("read ok \(item.id) in \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        sessionHashes[cacheKey(item)] = h
        hashCache[cacheKey(item)] = h
        return h
    }

    private func recomputeBundleStatuses() {
        var out: [String: Status] = [:]
        for b in bundles { out[b.id] = Matcher.bundleStatus(b.members.map { ($0, memberStatus[$0.id] ?? .none) }) }
        bundleStatus = out
    }

    /// Saved data is written in the background so the window never stutters (the prints file is tens of MB).
    /// One queue, so saves land in the order they were made and an older one can't overwrite a newer one.
    private static let saveQueue = DispatchQueue(label: "PhotoBackupChecker.save", qos: .utility)

    private func saveHashCache() {
        let dir = appData, hashes = hashCache, jev = jevCache, prints = printCache, bad = renders.counts, scores = scoreCache, picks = jevPicks, decided = decisions
        Self.saveQueue.async {
            try? JSONStore.save(decided, to: dir.appendingPathComponent("settle-decisions.json"))
            try? JSONStore.save(hashes, to: dir.appendingPathComponent("phone-hashes.json"))
            try? JSONStore.save(jev, to: dir.appendingPathComponent("jev-verdicts.json"))
            try? JSONStore.save(prints, to: dir.appendingPathComponent("similar-prints.json"))
            try? JSONStore.save(bad, to: dir.appendingPathComponent("bad-renders.json"))
            try? JSONStore.save(scores, to: dir.appendingPathComponent("preview-scores.json"))
            try? JSONStore.save(picks, to: dir.appendingPathComponent("jev-picks.json"))
        }
    }

    /// Key for data tied to one specific iPhone (thumbnails, similar-shot prints, Jev verdicts).
    private func deviceKey(_ i: PhoneItem) -> String { "\(deviceID ?? "?")|" + cacheKey(i) }

    /// Preview (JPEG data): saved on the Mac, else asked from the iPhone (then saved).
    private func thumbnailData(for item: PhoneItem) async -> Data? {
        let key = deviceKey(item)
        if let d = thumbStore.data(for: key) { return d }
        guard let d = await phone.thumbnailData(id: item.id) else { return nil }
        thumbStore.put(d, for: key)
        return d
    }

    /// Grid thumbnail: from memory, else the saved or fetched preview.
    func thumbnail(for item: PhoneItem) async -> CGImage? {
        let key = deviceKey(item)
        if let img = thumbMemory[key] { return img }
        guard let data = await thumbnailData(for: item), let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        thumbMemory[key] = img
        thumbOrder.append(key)
        if thumbOrder.count > 600 { thumbMemory[thumbOrder.removeFirst()] = nil }
        return img
    }

    // MARK: backup

    func backup(folderName: String) {
        guard work == nil else { message = "Something else is running. Wait for it to finish (or press Stop), then back up again."; return }
        guard driveAvailable else { message = "Backup drive not found. Plug it in first."; return }
        let chosen = selectedBundles
        let folder = driveRoot.appendingPathComponent(folderName.trimmingCharacters(in: .whitespacesAndNewlines))
        startWork { [weak self] in
            guard let self else { return }
            var entries: [ReceiptEntry] = []
            var leftOut = 0
            do {
                let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                let plan = try BackupWriter.plan(bundles: chosen, folderName: folderName, existingNames: existing)
                try BackupWriter.preflight(folder: folder, totalBytes: plan.reduce(0) { $0 + $1.item.size }, largestFile: plan.map(\.item.size).max() ?? 0)
                for (i, p) in plan.enumerated() {
                    try Task.checkCancellation()
                    self.progress = Progress(label: "Backing up to \(folder.lastPathComponent)", done: i, total: plan.count)
                    // A failed attempt leaves nothing behind (the writer removes its own temporary file),
                    // so after a replug the same file is simply copied again.
                    // An edited version that hangs once is one the iPhone can't make: no second read of it.
                    let e: ReceiptEntry
                    do {
                        e = try await self.resilient(drive: true, phone: true, maxTimeouts: p.item.isEditedRender ? 1 : 2) {
                            let job = CopyJob(item: p.item, destName: p.destName, bundleID: p.bundleID, bundleMembers: p.bundleMembers, read: self.phone.reader(id: p.item.id))
                            return try await BackupWriter.copy(job, into: folder)
                        }
                    } catch is TimedOut where p.item.isEditedRender {
                        // The iPhone can't make this edited version: leave it out and carry on; its item stays not fully backed up.
                        self.noteBadRender(p.item)
                        leftOut += 1
                        continue
                    }
                    entries.append(e)
                    self.markVerified(p.item, hash: e.sha256, path: folder.appendingPathComponent(p.destName).path)
                }
                self.message = "Backed up \(chosen.count) item\(chosen.count == 1 ? "" : "s") to \(folder.lastPathComponent)."
                    + (leftOut > 0 ? " \(leftOut) edited version(s) the iPhone couldn't make were left out; those items aren't green yet." : "")
                self.selection = []
            } catch {
                self.message = "Backup stopped after \(entries.count) file(s): \(Self.describe(error))"
            }
            if !entries.isEmpty {
                do { try BackupWriter.appendReceipt(entries, folder: folder) }
                catch { self.message = (self.message ?? "") + " Couldn't write the receipt file." }
            }
            self.recomputeBundleStatuses()
            self.saveHashCache()
            _ = try? await self.driveIndex.scan { _, _ in }
            try? await self.driveIndex.save()
        }
    }

    // MARK: settle possible copies

    /// Items whose drive match is only "possible": single photos, videos and Live Photos, as long as the
    /// drive file isn't the exact backup of something else.
    /// Also excluded: drive files kept as the backup of another iPhone photo, even one since deleted from the iPhone.
    var settleCandidates: [ItemBundle] {
        let exactPaths = Set(memberStatus.values.compactMap { if case .verified(let p) = $0 { p } else { nil } })
        return bundles.filter { b in
            guard b.kind == .single || b.kind == .live, case .possible(let p, _)? = memberStatus[b.primary.id] else { return false }
            return !exactPaths.contains(p) && !keptPaths(except: deviceKey(b.primary)).contains(p)
        }
    }

    /// Cheap per-item check for buttons; the sheet applies the full `settleCandidates` rule.
    func canSettle(_ b: ItemBundle) -> Bool {
        guard b.kind == .single || b.kind == .live, case .possible? = memberStatus[b.primary.id] else { return false }
        return true
    }

    /// Fills the settle list: both thumbnails, which is better, whether they look like the same picture, and a suggested action.
    /// `only`: the bundles to list, or nil for every possible copy.
    func loadSettleRows(only: Set<String>?) async {
        settleLoad += 1
        let load = settleLoad
        let files = Dictionary(await driveIndex.allFiles().map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        settleRows = settleCandidates.filter { only?.contains($0.id) ?? true }.compactMap { b in
            guard case .possible(let p, _)? = memberStatus[b.primary.id], let f = files[p] else { return nil }
            let px = { (w: Int?, h: Int?) in w.flatMap { w in h.map { w * $0 } } }
            return SettleRow(id: b.id, bundle: b, drive: f,
                             better: Settle.better(phonePixels: px(b.primary.pixelWidth, b.primary.pixelHeight), phoneSize: b.primary.size,
                                                   drivePixels: px(f.pixelWidth, f.pixelHeight), driveSize: f.size))
        }
        for i in settleRows.indices {
            guard !Task.isCancelled, load == settleLoad, i < settleRows.count else { return }
            let r = settleRows[i]
            var phoneImg: CGImage?
            var thumbData = thumbStore.data(for: deviceKey(r.item))
            if thumbData == nil { thumbData = await phone.thumbnailData(id: r.item.id) }
            if let d = thumbData { phoneImg = Self.downscaled(d, to: 320) }
            let driveURL = URL(fileURLWithPath: r.drive.path)
            let identity = try? Settle.identity(of: driveURL)
            let isVideo = r.item.isVideo
            let driveImg = await Task.detached { isVideo ? await Self.videoFrame(driveURL, to: 320) : Self.downscaled(driveURL, to: 320) }.value
            // Videos matched on date and length aren't compared frame by frame; photos are.
            let verdict: Settle.Verdict = isVideo ? .sameClip : Settle.verdict(difference: phoneImg.flatMap { x in driveImg.flatMap { Settle.pixelDifference(x, $0) } }, better: r.better)
            guard load == settleLoad, i < settleRows.count, settleRows[i].id == r.id, settleRows[i].drive.path == r.drive.path else { return }
            settleRows[i].identity = identity
            settleRows[i].phoneThumb = phoneImg
            settleRows[i].driveThumb = driveImg
            settleRows[i].verdict = verdict
            settleRows[i].action = Settle.suggested(for: verdict)
        }
    }

    /// Big versions of both sides for Reconcile: the iPhone file is read in full (as for the preview), the drive file shrunk.
    func reconcileImages(_ r: SettleRow) async -> (phone: CGImage?, drive: CGImage?) {
        let driveURL = URL(fileURLWithPath: r.drive.path)
        let isVideo = r.item.isVideo
        let drive = await Task.detached { isVideo ? await Self.videoFrame(driveURL, to: 1400) : Self.downscaled(driveURL, to: 1400) }.value
        guard let url = try? await previewFile(for: r.item) else { return (r.phoneThumb, drive ?? r.driveThumb) }
        let phone = await Task.detached { isVideo ? await Self.videoFrame(url, to: 1400) : Self.downscaled(url, to: 1400) }.value
        return (phone ?? r.phoneThumb, drive ?? r.driveThumb)
    }

    /// First frame of a video on the drive, for the settle list.
    nonisolated static func videoFrame(_ url: URL, to size: Int) async -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: size, height: size)
        return try? await gen.image(at: .zero).image
    }

    /// Fixes every row given an action. "Replace": the iPhone original takes the drive copy's place and the old copy
    /// goes to the drive's Trash. "Keep drive": the drive's better copy counts as the backup (remembered, with its
    /// fingerprint for the check before deleting). "Different": not the same photo, so it's left to back up (remembered).
    /// "Keep both": the original is added next to it. Live Photo videos missing from the drive are added next to the photo.
    func settle(_ actions: [String: Settle.Action]) {
        guard work == nil else { message = "Something else is running. Wait for it to finish (or press Stop), then try again."; return }
        guard driveAvailable else { message = "Backup drive not found. Plug it in first."; return }
        // Only rows whose drive match is still the one compared (a re-check may have moved on since).
        var seenPaths = Set<String>()
        let rows: [(SettleRow, Settle.Action)] = settleRows.compactMap { r in
            guard let a = actions[r.id], r.identity != nil, case .possible(let p, _)? = memberStatus[r.item.id], p == r.drive.path else { return nil }
            // One drive file never stands in for two iPhone photos: when it is already replaced or kept for another
            // (in this batch, or kept earlier), this one gets its own original added next to it instead.
            guard a == .replace || a == .keepDrive else { return (r, a) }
            let taken = !seenPaths.insert(p).inserted || keptPaths(except: deviceKey(r.item)).contains(p)
            return (r, taken ? .keepBoth : a)
        }
        startWork { [weak self] in
            guard let self else { return }
            var replaced = 0, added = 0, keptBoth = 0, changed = 0, keptDrive = 0, different = 0
            do {
                for (i, (r, action)) in rows.enumerated() {
                    try Task.checkCancellation()
                    self.progress = Progress(label: "Fixing possible copies", done: i, total: rows.count)
                    let old = URL(fileURLWithPath: r.drive.path)
                    let folder = old.deletingLastPathComponent()
                    var primaryPath = old.path
                    if action == .different {
                        self.decisions[self.deviceKey(r.item)] = Settle.Decision(kind: .different, drivePath: old.path, driveSize: r.drive.size)
                        self.memberStatus[r.item.id] = Status.none
                        self.saveDecisions()
                        self.settleRows.removeAll { $0.id == r.id }
                        different += 1
                        continue
                    } else if action == .keepDrive {
                        // Fingerprint the drive copy as it is now; changed since it was compared: leave it.
                        let hash: String? = try await self.resilient(drive: true, phone: false) {
                            guard (try? Settle.identity(of: old)) == r.identity else { return nil }
                            return try await Task.detached { try Fingerprint.sha256(fileAt: old) }.value
                        }
                        guard let hash, let size = r.identity?.size else { changed += 1; continue }
                        self.decisions[self.deviceKey(r.item)] = Settle.Decision(kind: .keepDrive, drivePath: old.path, driveSize: size, driveSHA256: hash)
                        self.memberStatus[r.item.id] = .verified(drivePath: old.path)
                        self.saveDecisions()
                        keptDrive += 1
                    } else if action == .replace {
                        let out: Settle.Outcome
                        do {
                            out = try await self.resilient(drive: true, phone: true) {
                                let job = CopyJob(item: r.item, destName: r.item.name, bundleID: r.id, bundleMembers: r.bundle.members.map(\.name), read: self.phone.reader(id: r.item.id))
                                return try await Settle.replace(job, old: old, expect: r.identity)
                            }
                        } catch Settle.SettleError.driveFileChanged { changed += 1; continue }   // edited on the drive since it was compared: leave it
                        primaryPath = out.finalPath
                        self.markVerified(r.item, hash: out.receipt.sha256, path: out.finalPath)
                        replaced += 1
                        if !out.oldTrashed { keptBoth += 1 }
                    } else {
                        let e = try await self.copyAlongside(r.item, old: old, bundle: r.bundle, into: folder)
                        primaryPath = folder.appendingPathComponent(e.destName).path
                        self.markVerified(r.item, hash: e.sha256, path: primaryPath)
                        added += 1
                    }
                    // The rest of the bundle (a Live Photo's video, an .AAE edit file) goes next to the photo, unless the drive already has that exact file.
                    for m in r.bundle.members where m.id != r.item.id {
                        if case .verified? = self.memberStatus[m.id] { continue }
                        let e = try await self.copyAlongside(m, old: URL(fileURLWithPath: primaryPath), bundle: r.bundle, into: folder)
                        self.markVerified(m, hash: e.sha256, path: folder.appendingPathComponent(e.destName).path)
                    }
                    self.settleRows.removeAll { $0.id == r.id }
                }
                var parts: [String] = []
                if keptDrive > 0 { parts.append("kept the drive's better copy for \(keptDrive) item\(keptDrive == 1 ? "" : "s")") }
                if different > 0 { parts.append("\(different) marked as a different photo; back \(different == 1 ? "it" : "them") up as usual") }
                if replaced > 0 { parts.append("replaced \(replaced) drive cop\(replaced == 1 ? "y" : "ies") with the iPhone original" + (replaced > keptBoth ? " (old ones are in the drive's Trash)" : "")) }
                if added > 0 { parts.append("added \(added) iPhone original\(added == 1 ? "" : "s") next to the drive copy") }
                if keptBoth > 0 { parts.append("\(keptBoth) old cop\(keptBoth == 1 ? "y" : "ies") couldn't go to the Trash, so both were kept") }
                if changed > 0 { parts.append("\(changed) drive file\(changed == 1 ? "" : "s") changed since the comparison and \(changed == 1 ? "was" : "were") left alone; open Fix again to compare afresh") }
                self.message = parts.isEmpty ? "Nothing to fix." : "Fixed: " + parts.joined(separator: "; ") + "."
            } catch {
                self.message = "Fixing stopped after \(replaced + added) item(s): \(Self.describe(error))"
            }
            self.recomputeBundleStatuses()
            self.saveHashCache()
            _ = try? await self.driveIndex.scan { _, _ in }
            try? await self.driveIndex.save()
        }
    }

    private func copyAlongside(_ item: PhoneItem, old: URL, bundle: ItemBundle, into folder: URL) async throws -> ReceiptEntry {
        try await resilient(drive: true, phone: true) {
            let job = CopyJob(item: item, destName: item.name, bundleID: bundle.id, bundleMembers: bundle.members.map(\.name), read: self.phone.reader(id: item.id))
            return try await Settle.alongside(job, old: old)
        }
    }

    /// Drive files kept as the backup of some iPhone photo (other than `key`'s).
    private func keptPaths(except key: String?) -> Set<String> {
        Set(decisions.filter { $0.key != key && $0.value.kind == .keepDrive }.map(\.value.drivePath))
    }

    /// Written straight away: an item already shown green must not lose its decision if the app quits mid-batch.
    private func saveDecisions() {
        let url = appData.appendingPathComponent("settle-decisions.json"), decided = decisions
        Self.saveQueue.async { try? JSONStore.save(decided, to: url) }
    }

    /// The kept drive copy this item counts as backed up by, if that's why it's green (not an exact copy).
    func keptDrive(_ item: PhoneItem) -> Settle.Decision? {
        guard let d = decisions[deviceKey(item)], d.kind == .keepDrive, case .verified(let p)? = memberStatus[item.id], p == d.drivePath else { return nil }
        return d
    }

    /// Green because the drive's better copy was kept, not because an exact copy is there.
    func keptDriveCopy(_ b: ItemBundle) -> Bool { b.mediaMembers.contains { keptDrive($0) != nil } }

    private func markVerified(_ item: PhoneItem, hash: String, path: String) {
        sessionHashes[cacheKey(item)] = hash
        hashCache[cacheKey(item)] = hash
        memberStatus[item.id] = .verified(drivePath: path)
    }

    // MARK: delete

    /// Selected items with no exact copy on the drive: deleting them loses them for good.
    var selectedUnbacked: [ItemBundle] { selectedBundles.filter { !Matcher.isDeletable(status(of: $0)) } }

    /// Green items are checked against the drive again, one at a time, right before each delete.
    /// Items that aren't green are deleted only with `includeUnbacked`, which the person ticks knowingly.
    /// `ids` and `allowUnbacked` are exactly what the delete sheet showed: anything that stopped being green since,
    /// without being in `allowUnbacked`, is kept.
    func deleteSelected(ids: Set<String>, allowUnbacked: Set<String>) {
        guard work == nil else { message = "Something else is running. Wait for it to finish (or press Stop), then delete again."; return }
        guard phone.canDelete, !ids.isEmpty else { return }
        let chosenNow = bundles.filter { ids.contains($0.id) }
        let green = chosenNow.filter { Matcher.isDeletable(status(of: $0)) }
        let others = chosenNow.filter { !Matcher.isDeletable(status(of: $0)) && allowUnbacked.contains($0.id) }
        guard green.isEmpty || driveAvailable else { message = "Backup drive not found. Plug it in first, or unselect the green items."; return }
        startWork { [weak self] in
            guard let self else { return }
            var deleted = 0, deletedUnbacked = 0, refused = 0
            var kept: [String] = []
            let chosen = green
            do {
                let media = chosen.flatMap(\.mediaMembers)
                for (i, m) in media.enumerated() where self.sessionHashes[self.cacheKey(m)] == nil && self.keptDrive(m) == nil {
                    try Task.checkCancellation()
                    self.progress = Progress(label: "Re-checking photos on iPhone before deleting", done: i, total: media.count)
                    _ = try await self.resilient(drive: false, phone: true) { try await self.hash(m, fresh: true) }
                }
                // One tile at a time: check its drive copies again, then delete it straight away.
                for (i, b) in chosen.enumerated() {
                    try Task.checkCancellation()
                    self.progress = Progress(label: "Deleting from iPhone", done: i, total: chosen.count)
                    var hashes: [String: String] = [:], paths: [String: String] = [:], keptSizes: [String: Int64] = [:]
                    for m in b.mediaMembers {
                        hashes[m.id] = self.sessionHashes[self.cacheKey(m)]
                        if case .verified(let p)? = self.memberStatus[m.id] { paths[m.id] = p }
                        // A kept drive copy is checked against itself as it was when kept.
                        if let k = self.keptDrive(m) { hashes[m.id] = k.driveSHA256; keptSizes[m.id] = k.driveSize }
                    }
                    let candidate = DeleteCandidate(bundle: b, phoneHashes: hashes, drivePaths: paths, keptSizes: keptSizes)
                    switch try await self.deleteFromPhone(b, gate: { await DeleteGate.verify([candidate]).rejected.first?.1 }) {
                    case .deleted: deleted += 1; self.logDeleted(b, backedUpAt: paths.values.sorted().first)
                    case .refused: refused += 1
                    case .kept(let why): kept.append(why)
                    }
                }
                for (i, b) in others.enumerated() {
                    try Task.checkCancellation()
                    self.progress = Progress(label: "Deleting items that aren't backed up", done: i, total: others.count)
                    switch try await self.deleteFromPhone(b, gate: { nil }) {
                    case .deleted: deletedUnbacked += 1; self.logDeleted(b, backedUpAt: nil)
                    case .refused: refused += 1
                    case .kept(let why): kept.append(why)
                    }
                }
                self.selection = []
            } catch is CancellationError {
                kept.append("stopped by you")
            } catch is PhoneGone {
                kept.append("iPhone was disconnected")
            } catch {
                kept.append(Self.describe(error))
            }
            var lines = ["Deleted \(deleted + deletedUnbacked) item(s) from your iPhone" + (deletedUnbacked > 0 ? " (\(deletedUnbacked) weren't backed up)." : ".")]
            if refused > 0 { lines.append("iPhone didn't delete \(refused).") }
            if !kept.isEmpty { lines.append("Kept some: " + kept.prefix(3).joined(separator: "; ")) }
            self.message = lines.joined(separator: " ")
            self.saveHashCache()
        }
    }

    private enum DeleteResult { case deleted, refused, kept(String) }

    /// Deletes one tile from the iPhone. A locked, unplugged or silent phone pauses it; it asks again once the phone
    /// answers, and after two silences in a row asks for a replug. `gate` (why to keep it, or nil) runs before every
    /// attempt, so green items re-check their drive copy even after a long pause.
    private func deleteFromPhone(_ b: ItemBundle, gate: () async -> String?) async throws -> DeleteResult {
        while true {
            if let why = await gate() { return .kept(why) }
            try Task.checkCancellation()
            do {
                let results = try await resilient(drive: false, phone: true) { try await self.phone.delete(ids: b.members.map(\.id)) }
                return b.members.allSatisfy({ results[$0.id] == .some(nil) }) ? .deleted : .refused
            } catch is TimedOut {
                try await waitForReplug()
            }
        }
    }

    /// A plain record of every delete, kept on the Mac: when, which files, and whether a backup existed.
    var deleteLogURL: URL { appData.appendingPathComponent("deleted-from-iphone.txt") }
    /// `backedUpAt` is captured before the delete: afterwards the item is gone and has no status.
    private func logDeleted(_ b: ItemBundle, backedUpAt path: String?) {
        let where_ = path.map { "backed up at \($0)" } ?? "NOT backed up"
        let line = "\(Date().formatted(.iso8601))\t\(b.members.map(\.name).joined(separator: " + "))\t\(where_)\n"
        if let h = try? FileHandle(forWritingTo: deleteLogURL) { _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: deleteLogURL) }
    }

    // MARK: Jev

    func classifyScreenshots() {
        guard work == nil, let key = Jev.loadKey(from: appData) else { return }
        // Screenshots Jev already judged are never sent again.
        let shots = bundles.filter { Jev.isScreenshot($0.primary) && jevCache[deviceKey($0.primary)] == nil }
        startWork { [weak self] in
            guard let self else { return }
            var failures = 0
            for (i, b) in shots.enumerated() {
                if Task.isCancelled { break }
                self.progress = Progress(label: "Asking Jev about screenshots", done: i, total: shots.count)
                do {
                    let data = try await self.resilient(drive: false, phone: true) { try await self.phone.fullData(id: b.primary.id) }
                    let (v, c) = try await Jev.classify(imageData: data, key: key)
                    self.cleanup[b.id, default: CleanupInfo()].jev = v
                    self.cleanup[b.id, default: CleanupInfo()].jevConfidence = c
                    self.jevCache[self.deviceKey(b.primary)] = JevResult(verdict: v, confidence: c)
                    self.saveIfDue()
                } catch is PhoneGone { self.message = "iPhone was disconnected."; break }
                catch { failures += 1 }
            }
            self.saveHashCache()
            if failures > 0 { self.message = "Jev couldn't check \(failures) screenshot(s)." }
            else if self.message == nil { self.message = "Checked \(shots.count) screenshot(s) with Jev." }
        }
    }

    // MARK: preview

    /// A copy of a phone file on the Mac, for preview. Copies stay in `previews/` while the app runs (up to
    /// `previewCap` bytes, least recently opened dropped first), so reopening a photo doesn't fetch it again.
    static let previewCap: Int64 = 2_000_000_000
    private var previewDir: URL { appData.appendingPathComponent("previews") }
    func previewFile(for item: PhoneItem) async throws -> URL {
        let fm = FileManager.default
        let url = previewDir.appendingPathComponent(ThumbnailStore.fileName(for: cacheKey(item)) + "." + item.ext)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64, size == item.size {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)   // most recently opened
            return url
        }
        try? fm.createDirectory(at: previewDir, withIntermediateDirectories: true)
        let part = previewDir.appendingPathComponent(UUID().uuidString + ".part")
        fm.createFile(atPath: part.path, contents: nil)
        do {
            let h = try FileHandle(forWritingTo: part)
            defer { try? h.close() }
            let read = phone.reader(id: item.id)
            var off: Int64 = 0
            while off < item.size {
                try Task.checkCancellation()   // preview closed early: stop and remove the partial copy
                let len = Int(min(Int64(Fingerprint.chunkSize), item.size - off))
                try h.write(contentsOf: try await read(off, len))
                off += Int64(len)
            }
            try? fm.removeItem(at: url)
            try fm.moveItem(at: part, to: url)
            trimPreviews(keeping: url)
            return url
        } catch {
            try? fm.removeItem(at: part)
            throw error
        }
    }

    /// Over the cap: least recently opened previews go first.
    private func trimPreviews(keeping: URL) {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: previewDir, includingPropertiesForKeys: Array(keys)) else { return }
        var entries = files.compactMap { u -> (url: URL, size: Int64, opened: Date)? in
            guard let v = try? u.resourceValues(forKeys: keys) else { return nil }
            return (u, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        entries.sort { $0.opened < $1.opened }
        for e in entries where total > Self.previewCap && e.url != keeping { try? fm.removeItem(at: e.url); total -= e.size }
    }

    static func describe(_ e: Error) -> String {
        switch e {
        case BackupError.invalidFolder(let m): return m
        case BackupError.notEnoughSpace: return "Not enough free space on the drive."
        case BackupError.fileTooLargeForFAT: return "A video is over 4 GB, which this drive's format can't hold."
        case BackupError.nameTaken(let n): return "\(n) already exists; nothing was overwritten."
        case BackupError.verifyFailed(let n): return "The copy of \(n) didn't match the original; it was removed."
        case BackupError.driveGone: return "The drive was disconnected."
        case Settle.SettleError.driveFileChanged: return "The drive's file changed since it was compared, so it was left alone."
        case BackupError.io(let code): return "The drive reported a problem: \(String(cString: strerror(code)))."
        case is PhoneGone: return "The iPhone was disconnected."
        case is NotOnPhone: return "A photo is no longer on the iPhone."
        case is ShortRead: return "The iPhone sent incomplete data."
        case is TimedOut: return "The iPhone stopped responding. Unlock it and try again."
        default: return e.localizedDescription
        }
    }
}
