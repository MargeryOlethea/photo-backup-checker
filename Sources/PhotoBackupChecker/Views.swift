import SwiftUI
import AppKit
import AVKit
import Core

private func gb(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

private extension Status {
    var color: Color? {
        switch self { case .verified: .green; case .possible: .orange; case .none: nil }
    }
    var label: String {
        switch self {
        case .verified: "Backed up (exact copy on the drive)"
        case .possible(_, let r): "Possible copy, not proven identical. \(r)"
        case .none: "Not backed up yet"
        }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var preview: ItemBundle?
    @State private var showBackup = false
    @State private var confirmDelete = false
    @State private var showReadyList = false

    var body: some View {
        let _ = model.phoneState
        VStack(spacing: 0) {
            SummaryBar(model: model)
            Divider()
            if model.bundles.isEmpty && model.phone.deviceName == nil {
                placeholder("Plug in your iPhone, unlock it, and tap Trust.")
            } else if model.bundles.isEmpty && model.phone.isLocked {
                placeholder("Unlock your iPhone to continue.")
            } else if model.bundles.isEmpty && !model.phone.catalogReady {
                placeholder("Reading your iPhone…", spinner: true)
            } else {
                toolbar
                Divider()
                grid
            }
        }
        .sheet(item: $preview) { PreviewView(model: model, bundle: $0) }
        .sheet(isPresented: $showBackup) { BackupSheet(model: model) }
        .sheet(isPresented: $showReadyList) { ReadyToDeleteView(model: model) }
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete) {
            Button("Delete from iPhone", role: .destructive) { model.deleteSelected() }
        } message: {
            Text("Every copy is checked against the drive again first. This may not go to Recently Deleted on your phone.")
        }
    }

    private var deleteTitle: String {
        let s = model.deleteSummary
        return "Delete \(s.count) item\(s.count == 1 ? "" : "s") (\(gb(s.bytes))) from your iPhone?"
    }

    private func placeholder(_ text: String, spinner: Bool = false) -> some View {
        VStack(spacing: 12) {
            if spinner { ProgressView() }
            Text(text).font(.title3).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $model.filter) { ForEach(Filter.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 230)
            Picker("Sort", selection: $model.sort) { ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 150)
            Button("Select all shown") { model.selection.formUnion(model.visible.map(\.id)) }
            Button("Clear") { model.selection = [] }.disabled(model.selection.isEmpty)
            Spacer()
            Text("\(model.selection.count) selected").foregroundStyle(.secondary)
            Button("Back up selected…") { showBackup = true }.disabled(model.selection.isEmpty || model.busy)
            if model.phone.canDelete {
                Button("Delete selected", role: .destructive) { confirmDelete = true }
                    .disabled(!model.selectionAllVerified || model.busy)
                    .help(model.selectionAllVerified ? "" : "Only green (exactly backed up) items can be deleted.")
            } else {
                Button("Ready-to-delete list") { showReadyList = true }
            }
            Button("Check screenshots with Jev") { model.classifyScreenshots() }
                .disabled(!model.hasJevKey || model.busy)
                .help(model.hasJevKey ? "Sends only screenshots to TypeSafe's Jev." : "Add your key to use this.")
        }
        .padding(10)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                ForEach(model.visible) { b in
                    TileView(model: model, bundle: b, selected: model.selection.contains(b.id),
                             onToggle: { if model.selection.contains(b.id) { model.selection.remove(b.id) } else { model.selection.insert(b.id) } },
                             onOpen: { preview = b })
                }
            }.padding(10)
        }
    }
}

struct SummaryBar: View {
    @Bindable var model: AppModel

    var body: some View {
        let s = model.summary
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 18) {
                light("Hard disk", model.driveMounted ? "Connected" : "Unplugged", model.driveMounted ? .green : .red)
                light("iPhone", phoneText, model.phone.deviceName == nil ? .red : model.phone.isLocked ? .orange : .green)
                Spacer()
            }
            if let p = model.pause {
                Label(p.text, systemImage: "pause.circle.fill")
                    .font(.callout.bold()).foregroundStyle(.black)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.85)).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: 18) {
                stat(.green, "Backed up", s.verified, s.verifiedBytes)
                stat(.orange, "Possible copy", s.possible, s.possibleBytes)
                stat(.secondary, "Not backed up", s.none, s.noneBytes)
                Spacer()
                Text(model.driveMounted ? model.driveRoot.path : "Drive not found: \(model.driveRoot.path)")
                    .font(.caption).foregroundStyle(model.driveMounted ? Color.secondary : Color.red).lineLimit(1).truncationMode(.middle)
                Button("Change…", action: chooseDrive).disabled(model.busy)
                Button("Check again") { model.recheck() }.disabled(model.busy || model.phone.deviceName == nil)
            }
            if let p = model.progress {
                HStack {
                    if p.total > 0 { ProgressView(value: Double(p.done), total: Double(p.total)).frame(width: 220) } else { ProgressView().controlSize(.small) }
                    Text(p.total > 0 ? "\(p.label) — \(p.done) of \(p.total)" : p.label).font(.callout)
                    Button("Cancel") { model.cancel() }
                }
            }
            if let m = model.message { Text(m).font(.callout).foregroundStyle(.primary) }
            Text("Shows items stored on this phone. If Optimize iPhone Storage is on, some originals are in iCloud and won't appear.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private var phoneText: String {
        if model.phone.deviceName == nil { return "Unplugged" }
        if model.phone.isLocked { return "Locked" }
        return model.phone.catalogReady ? "Connected" : "Reading…"
    }

    private func light(_ name: String, _ state: String, _ c: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 10, height: 10)
            Text("\(name): ").font(.callout.bold()) + Text(state).font(.callout)
        }
    }

    private func stat(_ c: Color, _ title: String, _ n: Int, _ bytes: Int64) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).stroke(c, lineWidth: 3).frame(width: 14, height: 14)
            Text("\(title): \(n) (\(gb(bytes)))").font(.callout)
        }
    }

    private func chooseDrive() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = "Use this folder"
        if p.runModal() == .OK, let url = p.url { model.driveRoot = url; model.recheck() }
    }
}

struct TileView: View {
    let model: AppModel
    let bundle: ItemBundle
    let selected: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void
    @State private var image: CGImage?

    var body: some View {
        let status = model.status(of: bundle)
        let info = model.cleanup[bundle.id]
        ZStack(alignment: .topLeading) {
            Group {
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
                else { Rectangle().fill(.quaternary) }
            }
            .frame(width: 120, height: 120).clipped()
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(status.color ?? .clear, lineWidth: 4))
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)   // click the picture: preview; selection is untouched

            VStack(alignment: .leading, spacing: 3) {
                if bundle.kind != .single { badge(bundle.kind == .live ? "Live" : bundle.kind == .edited ? "Edited" : "Burst \(bundle.mediaMembers.count)") }
                if info?.duplicate == true { badge("Duplicate", .red) }
                if info?.similarGroup != nil { badge("Similar", .purple) }
                if let v = info?.jev { badge(v == .junk ? "Probably junk" : v == .keep ? "Probably keep" : "Not sure", v == .junk ? .red : .gray) }
            }.padding(6)

            if let d = bundle.primary.duration {
                Text(String(format: "%d:%02d", Int(d) / 60, Int(d) % 60)).font(.caption2.bold()).padding(3)
                    .background(.black.opacity(0.6)).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 3))
                    .frame(width: 120, height: 120, alignment: .bottomTrailing).padding(-2)
            }
            Button(action: onToggle) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? Color.white : Color.white, selected ? Color.blue : Color.black.opacity(0.35))
                    .shadow(radius: 1)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(selected ? "Unselect" : "Select")
            .frame(width: 120, height: 120, alignment: .topTrailing)
        }
        .frame(width: 120, height: 120)
        .help("\(bundle.primary.name) — \(status.label)")
        .task(id: bundle.id) { image = await model.thumbnail(for: bundle.primary) }
    }

    private func badge(_ t: String, _ c: Color = .black) -> some View {
        Text(t).font(.caption2.bold()).padding(.horizontal, 4).padding(.vertical, 1)
            .background(c.opacity(0.7)).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

struct PreviewView: View {
    let model: AppModel
    let bundle: ItemBundle
    @Environment(\.dismiss) private var dismiss
    @State private var file: URL?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(bundle.members.filter { !$0.isSidecar }.map(\.name).joined(separator: " + ")).font(.headline)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(model.status(of: bundle).label).font(.callout).foregroundStyle(model.status(of: bundle).color ?? .secondary)
            Group {
                if let file {
                    if bundle.primary.isVideo { VideoPlayer(player: AVPlayer(url: file)) }
                    else if let img = NSImage(contentsOf: file) { Image(nsImage: img).resizable().scaledToFit() }
                    else { Text("Can't show this file.") }
                } else if let error { Text(error).foregroundStyle(.red) }
                else { ProgressView("Loading from iPhone…") }
            }.frame(minWidth: 700, minHeight: 500)
        }
        .padding()
        .task {
            do { file = try await model.previewFile(for: bundle.primary) }
            catch { self.error = AppModel.describe(error) }
        }
        .onDisappear { if let file { try? FileManager.default.removeItem(at: file) } }
    }
}

struct BackupSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        let problem = Naming.validateFolderName(name)
        let label = Naming.label(forFolder: name)
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: model.driveRoot.appendingPathComponent(name.trimmingCharacters(in: .whitespacesAndNewlines)).path)) ?? []
        let first = Naming.nextNumbers(count: 1, label: label, existing: existing)[0]
        VStack(alignment: .leading, spacing: 12) {
            Text("Back up \(model.selection.count) item\(model.selection.count == 1 ? "" : "s")").font(.headline)
            TextField("Folder name, e.g. 2026-10 Bali", text: $name).textFieldStyle(.roundedBorder).frame(width: 380)
            if !name.isEmpty, let problem { Text(problem).foregroundStyle(.red).font(.callout) }
            else if problem == nil {
                Text("Saved in Memories/\(name.trimmingCharacters(in: .whitespacesAndNewlines))/ as \(Naming.fileName(label: label, number: first, ext: "HEIC")), …"
                     + (existing.isEmpty ? "" : " (folder exists; numbering continues)"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Back up") { model.backup(folderName: name); dismiss() }.keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
        }
        .padding(20)
    }
}

struct ReadyToDeleteView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let ready = model.bundles.filter { Matcher.isDeletable(model.status(of: $0)) }
        VStack(alignment: .leading, spacing: 10) {
            Text("This iPhone doesn't allow deleting from the Mac. These \(ready.count) items are exactly backed up; delete them in the Photos app or Image Capture.")
                .font(.callout)
            List(ready) { b in
                HStack {
                    Text(b.members.filter { !$0.isSidecar }.map(\.name).joined(separator: ", "))
                    Spacer()
                    Text(b.primary.captureDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "").foregroundStyle(.secondary)
                }
            }.frame(minWidth: 520, minHeight: 360)
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding()
    }
}
