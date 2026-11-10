import SwiftUI
import AppKit
import AVKit
import Core

private func gb(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
private func mp(_ w: Int?, _ h: Int?) -> String? {
    guard let w, let h, w > 0, h > 0 else { return nil }
    let m = Double(w * h) / 1_000_000
    return String(format: m < 10 ? "%.1f MP" : "%.0f MP", m)
}
private enum Radius { static let card: CGFloat = 12, tile: CGFloat = 8, badge: CGFloat = 4 }

private extension Color {
    /// The app's highlight colour: the plum from the icon, lighter in dark mode so it stays readable.
    static let plum = Color(nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.68, green: 0.50, blue: 0.95, alpha: 1)
            : NSColor(srgbRed: 0.54, green: 0.25, blue: 0.75, alpha: 1)
    })
}

private extension Status {
    var color: Color? {
        switch self { case .verified: .green; case .possible: .orange; case .none: nil }
    }
    var label: String {
        switch self {
        case .verified: "Backed up: an exact copy is on the drive"
        case .possible(_, let r): "Possible copy, not identical. \(r)"
        case .none: "Not backed up yet"
        }
    }
}

// MARK: - Main window

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        let _ = model.phoneState
        VStack(spacing: 0) {
            StatusStrip(model: model)
            if model.bundles.isEmpty && model.phone.deviceName == nil {
                placeholder("iphone.gen3", "Plug in your iPhone", "Use the cable, unlock the phone and tap Trust if it asks.")
            } else if model.bundles.isEmpty && model.phone.isLocked {
                placeholder("lock.iphone", "Unlock your iPhone", "The app continues as soon as the phone is unlocked.")
            } else if model.bundles.isEmpty && !model.phone.catalogReady {
                placeholder("photo.on.rectangle.angled", "Reading your iPhone…", "This takes a few seconds.", spinner: true)
            } else {
                if model.showsBackup { SummaryCards(model: model) }
                FilterBar(model: model)
                Divider()
                if model.filter == .cleanup { CleanupView(model: model) } else { grid }
                if !model.selection.isEmpty { SelectionBar(model: model) }
            }
            FooterView(model: model)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Color.plum)
        .navigationTitle("Photo Backup Checker")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                DevicePill(icon: "externaldrive.fill", name: "Hard disk",
                           state: model.driveMounted ? "Connected" : model.driveChosen ? "Unplugged" : "Not chosen",
                           color: model.driveMounted ? .green : .red)
                DevicePill(icon: "iphone", name: model.phone.deviceName ?? "iPhone", state: phoneText, color: phoneColor)
            }
        }
        .sheet(item: $model.sheet) { sheet in
            Group {
                switch sheet {
                case .preview(let b): PreviewView(model: model, bundle: b, list: model.visible, onOpen: { model.sheet = .preview($0) })
                case .backup: BackupSheet(model: model)
                case .delete: DeleteSheet(model: model)
                case .settle(let only): SettleSheet(model: model, only: only)
                case .readyList: ReadyToDeleteView(model: model)
                }
            }
            .tint(Color.plum)   // a sheet is its own window and does not inherit the main window's tint
        }
    }

    private var phoneText: String {
        if model.phone.deviceName == nil { return "Unplugged" }
        if model.phone.isLocked { return "Locked" }
        return model.phone.catalogReady ? "Connected" : "Reading…"
    }
    private var phoneColor: Color {
        model.phone.deviceName == nil ? .red : model.phone.isLocked || !model.phone.catalogReady ? .orange : .green
    }

    private func placeholder(_ icon: String, _ title: String, _ detail: String, spinner: Bool = false) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 56, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(detail).foregroundStyle(.secondary)
            if spinner { ProgressView().padding(.top, 4) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        let items = model.visible
        let sections = model.grouping.sections(items, oldestFirst: model.sort == .oldest)   // one unnamed section when not grouped
        return Group {
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                    Text("Nothing here").font(.title3.weight(.medium))
                    Text("No items are “\(model.filter.rawValue)” right now.").foregroundStyle(.secondary)
                    Button("Show all") { model.filter = .all }.buttonStyle(.borderless)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10, pinnedViews: .sectionHeaders) {
                        ForEach(sections) { s in
                            Section {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: TileView.side), spacing: 10)], spacing: 10) {
                                    ForEach(s.items) { b in TileView(model: model, bundle: b, list: items).reportFrame(b.id) }
                                }
                            } header: {
                                if let title = s.title {
                                    Text(title).font(.headline).padding(.vertical, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading).background(.bar)
                                }
                            }
                        }
                    }
                    .padding(14)
                    .dragToSelect(model: model)
                }
            }
        }
    }
}

struct DevicePill: View {
    let icon: String, name: String, state: String, color: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(name).fontWeight(.medium)
            Text(state).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .help("\(name): \(state)")
    }
}

// MARK: - Pause / progress / message, shown only when there is something to say

struct StatusStrip: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            if let p = model.pause {
                Label(p.text, systemImage: "pause.circle.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(.black)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: Radius.card))
            }
            if let p = model.progress {
                HStack(spacing: 10) {
                    if p.total > 0 { ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).frame(maxWidth: 260) }
                    else { ProgressView().controlSize(.small) }
                    Text(p.total > 0 ? "\(p.label) · \(p.done) of \(p.total)" : p.label).font(.callout).monospacedDigit()
                    Spacer()
                    Button("Stop") { model.cancel() }
                }
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.card))
            }
            if !model.driveChosen {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark").foregroundStyle(.tint)
                    Text("Choose the folder on your backup drive where your photos and videos are kept.")
                        .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") { chooseDrive(model) }.disabled(model.busy)
                }
                .padding(10)
                .background(Color.plum.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.card))
            }
            if let m = model.message {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill").foregroundStyle(.tint)
                    Text(m).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    if m.hasPrefix("Deleted") {
                        Button("Show list") { NSWorkspace.shared.open(model.deleteLogURL) }.buttonStyle(.borderless)
                    }
                    Button { model.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Dismiss")
                }
                .padding(10)
                .background(Color.plum.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.card))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, model.pause == nil && model.progress == nil && model.message == nil && model.driveChosen ? 0 : 10)
        .padding(.bottom, 2)
    }
}

// MARK: - The three totals; each one is also a filter

struct SummaryCards: View {
    @Bindable var model: AppModel

    var body: some View {
        let s = model.summary
        let settle = model.settleCandidates.count
        HStack(alignment: .top, spacing: 12) {
            card(.backedUp, "checkmark.circle.fill", .green, "Backed up", s.verified, s.verifiedBytes, "Exact copy on the drive. Safe to delete from the iPhone.",
                 action: s.verified > 0 && model.phone.canDelete ? ("Select all \(s.verified)", { model.selectAllBackedUp() }) : nil)
            card(.possible, "questionmark.circle.fill", .orange, "Possible copy", s.possible, s.possibleBytes, "A similar file is on the drive, not identical. Fix it to make it green.",
                 action: settle > 0 ? ("Fix \(settle)…", { model.sheet = .settle(only: nil) }) : nil)
            card(.notBackedUp, "circle.dashed", .secondary, "Not backed up", s.none, s.noneBytes, "Only on the iPhone. Back these up before deleting.")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
    }

    private func card(_ f: Filter, _ icon: String, _ c: Color, _ title: String, _ n: Int, _ bytes: Int64, _ hint: String,
                      action: (String, () -> Void)? = nil) -> some View {
        let on = model.filter == f
        return Button { model.filter = on ? .all : f } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon).foregroundStyle(c)
                    Text(title).foregroundStyle(.secondary)
                }
                .font(.callout.weight(.medium))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(n)").font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(gb(bytes)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let action {
                        Button(action.0, action: action.1).controlSize(.small).buttonStyle(.bordered).tint(c == .secondary ? .plum : c)
                    }
                }
                Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .background(on ? c.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(on ? c.opacity(0.8) : Color.primary.opacity(0.08), lineWidth: on ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        }
        .buttonStyle(.plain)
        .help(on ? "Show everything" : "Show only “\(title)”")
    }
}

// MARK: - Filter, sort, select-all and clean-up tools

struct FilterBar: View {
    @Bindable var model: AppModel

    var body: some View {
        let shown = model.visible.count
        HStack(spacing: 12) {
            Picker("Show", selection: $model.filter) {
                ForEach(Filter.allCases.filter { model.showsBackup || !$0.needsDrive }) { Text($0.short).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                tools(compact: false, shown: shown)
                tools(compact: true, shown: shown)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func tools(compact: Bool, shown: Int) -> some View {
        HStack(spacing: 12) {
            Menu {
                Picker("Sort", selection: $model.sort) { ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.inline)
            } label: { Label(model.sort.rawValue, systemImage: "arrow.up.arrow.down") }
                .menuStyle(.borderlessButton).fixedSize().help("Sort order")
            Menu {
                Picker("Group", selection: $model.grouping) { ForEach(Grouping.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.inline)
            } label: { Label(model.grouping.rawValue, systemImage: "calendar") }
                .menuStyle(.borderlessButton).fixedSize().help("Group by day, week or month")
            Button { model.selection.formUnion(model.visible.map(\.id)) } label: {
                if compact { Image(systemName: "checkmark.circle") } else { Text("Select all \(shown)") }
            }
            .buttonStyle(.borderless).keyboardShortcut("a", modifiers: .command)
            .help("Select every item shown (⌘A)")
            Menu {
                Button("Find junk screenshots with Jev") { model.classifyScreenshots() }.disabled(!model.hasJevKey || model.busy)
                Button("Select all but ★ in every similar group") { model.selectAllButBestEverywhere() }.disabled(model.similarGroups.isEmpty)
                Divider()
                Text(model.hasJevKey ? "Jev only ever sees screenshots and close calls between similar shots." : "Add your Jev key to use Jev.")
            } label: { Label("Clean-up", systemImage: "sparkles").labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon)) }
                .menuStyle(.borderlessButton).fixedSize()
        }
    }
}

/// Lets a Label switch style at runtime.
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ s: S) { make = { AnyView(s.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

// MARK: - Bottom bar while something is selected

struct SelectionBar: View {
    let model: AppModel

    var body: some View {
        let mix = model.selectionBreakdown
        let allGreen = mix.possible == 0 && mix.none == 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("\(model.selection.count) selected").font(.headline)
                Text(gb(model.selectedBytes)).foregroundStyle(.secondary)
                Button("Clear") { model.selection = [] }.buttonStyle(.borderless).keyboardShortcut(.escape, modifiers: [])
                    .help("Clear the selection (Esc)")
                Spacer()
                Button { model.sheet = .backup } label: { Label("Back up…", systemImage: "externaldrive.badge.plus") }
                    .buttonStyle(allGreen ? AnyButtonStyle(.bordered) : AnyButtonStyle(.borderedProminent))
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(model.busy || !model.driveChosen).help("Copy the selected items to the drive (⌘B)")
                if model.phone.canDelete {
                    Button(role: .destructive) { model.sheet = .delete } label: { Label("Delete from iPhone…", systemImage: "trash") }
                        .buttonStyle(allGreen ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.bordered)).tint(.red)
                        .keyboardShortcut(.delete, modifiers: .command)
                        .disabled(model.deleteBlocker != nil).help("Delete the selected items from the iPhone (⌘⌫)")
                } else {
                    Button("Ready-to-delete list") { model.sheet = .readyList }
                        .help("This iPhone doesn't allow deleting from the Mac; get a list to delete in the Photos app.")
                }
            }
            HStack(spacing: 12) {
                if mix.green > 0 { chip(.green, "\(mix.green) backed up") }
                if mix.possible > 0 {
                    chip(.orange, "\(mix.possible) possible copy")
                    if model.selectedBundles.contains(where: model.canSettle) {
                        Button("Fix possible copies…") { model.sheet = .settle(only: model.selection) }.buttonStyle(.borderless).disabled(model.busy)
                    }
                }
                if mix.none > 0 { chip(.secondary, "\(mix.none) not backed up") }
                Spacer()
                if let why = model.deleteBlocker, model.phone.canDelete {
                    Label(why, systemImage: "info.circle").foregroundStyle(.secondary)
                } else {
                    Text("Drag to select · ⇧-click for a range · ⌘A all · Esc clear").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func chip(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 7, height: 7); Text(t) }
    }
}

/// Lets a Button switch style at runtime.
struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ s: S) { make = { AnyView(s.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

// MARK: - Delete sheet: green items are re-checked; anything else needs an explicit "I understand"

struct DeleteSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var understood = false
    // What this sheet shows is fixed when it opens; consent covers exactly these items.
    @State private var all: [ItemBundle] = []
    @State private var unbacked: [ItemBundle] = []
    @State private var tidy: [ItemBundle] = []

    var body: some View {
        let green = all.filter { !unbacked.contains($0) && !tidy.contains($0) }
        let possible = unbacked.filter { if case .possible = model.status(of: $0) { true } else { false } }.count
        let macCount = all.filter { !$0.onlyPhoneCanDelete }.count
        let phoneCount = all.count - macCount
        let deleteParts = [
            macCount > 0 ? "Delete \(macCount)" : nil,
            phoneCount > 0 ? "\(macCount > 0 ? "hand" : "Hand") \(phoneCount) to iPhone" : nil
        ].compactMap { $0 }
        let deleteTitle = deleteParts.joined(separator: " · ") + (unbacked.isEmpty ? "" : " forever")
        VStack(alignment: .leading, spacing: 14) {
            Label("Delete \(all.count) item\(all.count == 1 ? "" : "s") (\(gb(all.reduce(0) { $0 + $1.totalSize }))) from your iPhone?", systemImage: "trash")
                .font(.title3.weight(.semibold))
            if !green.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(green.count) backed up. Each is checked against its drive copy (by fingerprint) right before it's deleted. If a check fails, that item is kept.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
                    rows(green)
                }
            }
            if !tidy.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(tidy.count) duplicate\(tidy.count == 1 ? "" : "s") or similar shot\(tidy.count == 1 ? "" : "s"). One of each always stays on your iPhone (the oldest copy, or the ★). Each duplicate is checked against its copy right before it's deleted.",
                          systemImage: "square.on.square")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Similar shots aren't copies: once deleted, they're gone.").font(.callout).foregroundStyle(.secondary)
                    rows(tidy)
                }
            }
            if !unbacked.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("\(unbacked.count) \(unbacked.count == 1 ? "is" : "are") NOT backed up. \(unbacked.count == 1 ? "It" : "They") will be gone forever.", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline).foregroundStyle(.red)
                    if possible > 0 {
                        Text("\(possible) of these \(possible == 1 ? "has" : "have") a similar file on the drive that isn't identical. Consider “Review possible copies” first.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    rows(unbacked)
                    Toggle("I understand these are not backed up and can't be recovered", isOn: $understood)
                }
                .padding(12)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.card))
            }
            Text("Mac deletes leave the iPhone right away and may not go to Recently Deleted; the Shortcut puts them in Recently Deleted for 30 days. A list of everything deleted or handed over is kept on this Mac.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.busy { Label("Waiting for the current task to finish…", systemImage: "hourglass").font(.callout).foregroundStyle(.secondary) }
                if !unbacked.isEmpty && !green.isEmpty {
                    Button("Delete only the \(green.count) backed up") {
                        model.deleteSelected(ids: Set(green.map(\.id)), allowUnbacked: []); dismiss()
                    }.disabled(model.busy)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(deleteTitle, role: .destructive) {
                    model.deleteSelected(ids: Set(all.map(\.id)), allowUnbacked: understood ? Set(unbacked.map(\.id)) : []); dismiss()
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .disabled(all.isEmpty || (!unbacked.isEmpty && !understood) || model.busy)
            }
        }
        .padding(22)
        .frame(width: 600)
        .onAppear { all = model.selectedBundles; unbacked = model.selectedNeedsConsent; tidy = model.selectedCleanup }
    }

    @ViewBuilder private func rows(_ list: [ItemBundle]) -> some View {
        let mac = list.filter { !$0.onlyPhoneCanDelete }
        let phone = list.filter(\.onlyPhoneCanDelete)
        if !mac.isEmpty {
            Label("Deleted now by the Mac: \(mac.count)", systemImage: "laptopcomputer")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            strip(mac)
        }
        if !phone.isEmpty {
            Label("Handed to the iPhone Shortcut: \(phone.count). Their names go to your clipboard; run “Delete listed photos” on the iPhone afterwards.", systemImage: "iphone")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            strip(phone)
        }
    }

    private func strip(_ list: [ItemBundle]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(list) { b in
                    VStack(spacing: 2) {
                        Thumb(model: model, item: b.primary, side: 60)
                        Text(b.primary.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(width: 60)
                    }
                }
            }
        }
        .frame(height: 80)
    }
}

/// A small thumbnail of one phone item.
struct Thumb: View {
    let model: AppModel
    let item: PhoneItem
    let side: CGFloat
    @State private var image: CGImage?
    var body: some View {
        Group { if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() } else { Rectangle().fill(.quaternary) } }
            .frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: 6))
            .task(id: item.id) { image = await model.thumbnail(for: item) }
    }
}

// MARK: - Drag across tiles to select them

private struct TileFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

private extension View {
    func reportFrame(_ id: String) -> some View {
        background(GeometryReader { g in Color.clear.preference(key: TileFrames.self, value: [id: g.frame(in: .named("grid"))]) })
    }
}

/// Drag a box across tiles to add them to the selection (like Finder). Only tiles on screen count;
/// Note: no auto-scroll while dragging; ⇧-click covers ranges longer than a screen.
private struct DragToSelect: ViewModifier {
    let model: AppModel
    @State private var frames: [String: CGRect] = [:]
    @State private var rect: CGRect?
    @State private var base: Set<String> = []

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: "grid")
            .onPreferenceChange(TileFrames.self) { frames = $0 }
            .overlay(alignment: .topLeading) {
                if let rect {
                    Rectangle().fill(Color.plum.opacity(0.12))
                        .overlay(Rectangle().strokeBorder(Color.plum, lineWidth: 1))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .named("grid"))
                    .onChanged { g in
                        if rect == nil { base = model.selection }
                        let r = CGRect(x: min(g.startLocation.x, g.location.x), y: min(g.startLocation.y, g.location.y),
                                       width: abs(g.location.x - g.startLocation.x), height: abs(g.location.y - g.startLocation.y))
                        rect = r
                        model.selection = base.union(frames.filter { $0.value.intersects(r) }.map(\.key))
                    }
                    .onEnded { _ in rect = nil; model.tapBlockedUntil = Date().addingTimeInterval(0.3) }
            )
    }
}

extension View {
    fileprivate func dragToSelect(model: AppModel) -> some View { modifier(DragToSelect(model: model)) }
}

// MARK: - Footer: which drive folder, when checked, check again

struct FooterView: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(model.driveMounted ? model.driveRoot.lastPathComponent : model.driveChosen ? "Drive folder not found" : "No backup folder chosen")
                .foregroundStyle(model.driveMounted ? Color.secondary : Color.red)
                .lineLimit(1).truncationMode(.middle)
                .help(model.driveChosen ? model.driveRoot.path : "")
            Button(model.driveChosen ? "Change…" : "Choose…") { chooseDrive(model) }.buttonStyle(.borderless).disabled(model.busy)
            Spacer()
            if let t = model.lastChecked { Text("Checked \(t.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary) }
            Image(systemName: "icloud.slash").foregroundStyle(.secondary)
                .help("Photos and videos stored only in iCloud (Optimize iPhone Storage) aren't on the phone, so they aren't listed or checked.")
            Button { model.recheck() } label: { Label("Check again", systemImage: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(model.busy || model.phone.deviceName == nil)
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

@MainActor private func chooseDrive(_ model: AppModel) {
    let p = NSOpenPanel()
    p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = "Use this folder"
    p.message = "Choose the folder on your drive where your photos and videos are backed up."
    if p.runModal() == .OK, let url = p.url { model.driveRoot = url; model.recheck() }
}

// MARK: - Clean-up view: similar groups with ★, duplicates, junk screenshots

struct CleanupView: View {
    let model: AppModel

    var body: some View {
        let groups = model.similarGroups
        let dups = model.bundles.filter { model.cleanup[$0.id]?.duplicate == true }
        let junk = model.bundles.filter { model.cleanup[$0.id]?.jev == .junk }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if groups.isEmpty && dups.isEmpty && junk.isEmpty {
                    Text("Nothing to clean up yet. Similar shots and duplicates show here after a check; junk screenshots after “Find junk screenshots with Jev”.")
                        .foregroundStyle(.secondary).padding(.top, 40).frame(maxWidth: .infinity)
                }
                if !groups.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        sectionTitle("Similar shots", "★ is the app's suggestion of the one to keep (sharp first, then faces looking good). Look before deleting.")
                        Spacer()
                        Button("Select all but ★ everywhere") { model.selectAllButBestEverywhere() }
                    }
                    ForEach(groups, id: \.first!.id) { g in groupBox(g) }
                }
                if !dups.isEmpty {
                    sectionTitle("Exact duplicates", "The same photo or video saved more than once.")
                    tiles(dups)
                }
                if !junk.isEmpty {
                    sectionTitle("Screenshots Jev thinks are junk", nil)
                    tiles(junk)
                }
            }
            .padding(14)
        }
    }

    private func sectionTitle(_ t: String, _ sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.title3.weight(.semibold))
            if let sub { Text(sub).font(.callout).foregroundStyle(.secondary) }
        }
    }

    private func groupBox(_ g: [ItemBundle]) -> some View {
        let best = g.first { model.cleanup[$0.id]?.best == true }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(g.count) similar shots").font(.headline)
                if let best, let r = model.cleanup[best.id]?.bestReason { Text("★ \(r)").foregroundStyle(.secondary) }
                Spacer()
                if best != nil {
                    Button("Select all but ★") { model.selectAllButBest(g) }.help("Select the others, keep the ★ one unselected")
                }
            }
            tiles(g)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.card))
    }

    private func tiles(_ list: [ItemBundle]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: TileView.side), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(list) { b in TileView(model: model, bundle: b, list: list) }
        }
    }
}

// MARK: - One tile

struct TileView: View {
    static let side: CGFloat = 150
    let model: AppModel
    let bundle: ItemBundle
    let list: [ItemBundle]
    @State private var image: CGImage?
    @State private var hover = false

    var body: some View {
        let status: Status? = model.showsBackup ? model.status(of: bundle) : nil
        let info = model.cleanup[bundle.id]
        let selected = model.selection.contains(bundle.id)
        let shape = RoundedRectangle(cornerRadius: Radius.tile)
        ZStack {
            Group {
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
                else { Rectangle().fill(.quaternary) }
            }
            .frame(width: Self.side, height: Self.side).clipped()
            .overlay { if selected { Color.plum.opacity(0.2) } }
            .clipShape(shape)
            .contentShape(shape)
            // Click: preview (selection untouched). ⌘-click toggles, ⇧-click selects a range.
            .onTapGesture {
                guard Date() > model.tapBlockedUntil else { return }   // the end of a drag-select, not a click
                let m = NSEvent.modifierFlags
                if m.contains(.command) || m.contains(.shift) { model.click(bundle.id, in: list, shift: m.contains(.shift)) }
                else { model.sheet = .preview(bundle) }
            }

            VStack(alignment: .leading, spacing: 3) {
                if info?.best == true { pill("★ Best", fill: .yellow, text: .black).help(info?.bestReason ?? "Best of its similar shots") }
                HStack(spacing: 3) {
                    pill(bundle.primary.formatLabel)
                    if bundle.kind == .live { pill("Live") }
                    if bundle.kind == .burst { pill("Burst \(bundle.mediaMembers.count)") }
                    if !bundle.onlyPhoneCanDelete { pill("Mac deletes") }
                }
                if info?.duplicate == true { pill("Duplicate") }
                if info?.similarGroup != nil && info?.best != true { pill("Similar") }
                if let v = info?.jev { pill(v == .junk ? "Probably junk" : v == .keep ? "Probably keep" : "Jev not sure") }
            }
            .padding(6)
            .frame(width: Self.side, height: Self.side, alignment: .topLeading)
            .allowsHitTesting(false)

            HStack(spacing: 4) {
                if let status { statusIcon(status) }
                Spacer()
                if let d = bundle.primary.duration {
                    Text(String(format: "%d:%02d", Int(d) / 60, Int(d) % 60)).font(.caption2.weight(.bold)).monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white)
                }
            }
            .padding(6)
            .frame(width: Self.side, height: Self.side, alignment: .bottom)
            .allowsHitTesting(false)

            Button { model.click(bundle.id, in: list, shift: NSEvent.modifierFlags.contains(.shift)) } label: {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .medium))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, selected ? Color.plum : Color.clear)
                    .background(Circle().fill(selected ? Color.clear : Color.black.opacity(0.25)))
                    .shadow(color: .black.opacity(0.45), radius: 1.5)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(selected ? "Unselect" : "Select")
            .frame(width: Self.side, height: Self.side, alignment: .topTrailing)
        }
        .frame(width: Self.side, height: Self.side)
        .overlay(shape.strokeBorder(selected ? Color.plum : (status?.color ?? .clear).opacity(0.9), lineWidth: selected ? 3 : 2))
        .scaleEffect(hover ? 1.02 : 1)
        .animation(.easeOut(duration: 0.12), value: hover)
        .onHover { hover = $0 }
        .help([bundle.primary.name, bundle.primary.captureDate?.formatted(date: .abbreviated, time: .shortened), gb(bundle.totalSize), status?.label,
               bundle.onlyPhoneCanDelete ? "Deleted via the iPhone Shortcut" : "Deleted by the Mac"]
            .compactMap { $0 }.joined(separator: " · "))
        .task(id: bundle.id) { image = await model.thumbnail(for: bundle.primary) }
    }

    @ViewBuilder private func statusIcon(_ s: Status) -> some View {
        switch s {
        case .verified: tag("checkmark", .green)
        case .possible: tag("questionmark", .orange)
        case .none: EmptyView()
        }
    }

    private func tag(_ symbol: String, _ c: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
            .frame(width: 17, height: 17).background(c, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1))
    }

    private func pill(_ t: String, fill: Color = .black.opacity(0.55), text: Color = .white) -> some View {
        Text(t).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 2)
            .background(fill, in: RoundedRectangle(cornerRadius: Radius.badge))
            .foregroundStyle(text)
    }
}

// MARK: - Preview, with previous/next and select

struct PreviewView: View {
    let model: AppModel
    let bundle: ItemBundle
    let list: [ItemBundle]
    let onOpen: (ItemBundle) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var file: URL?
    @State private var image: CGImage?    // made off the main thread, so the window doesn't stall while flipping
    @State private var error: String?
    @State private var player: AVPlayer?   // kept here so a re-render doesn't restart the video

    var body: some View {
        let status = model.status(of: bundle)
        let i = list.firstIndex { $0.id == bundle.id }
        let selected = model.selection.contains(bundle.id)
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bundle.members.filter { !$0.isSidecar }.map(\.name).joined(separator: " + ")).font(.headline)
                    Text([bundle.primary.captureDate?.formatted(date: .long, time: .shortened), mp(bundle.primary.pixelWidth, bundle.primary.pixelHeight), gb(bundle.totalSize)]
                        .compactMap { $0 }.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let i { Text("\(i + 1) of \(list.count)").foregroundStyle(.secondary).monospacedDigit() }
                Button { go(i, -1) } label: { Image(systemName: "chevron.left") }.keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(i == nil || i == 0).help("Previous (←)")
                Button { go(i, 1) } label: { Image(systemName: "chevron.right") }.keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(i == nil || i == list.count - 1).help("Next (→)")
                Button { if selected { model.selection.remove(bundle.id) } else { model.selection.insert(bundle.id) } } label: {
                    Label(selected ? "Selected" : "Select", systemImage: selected ? "checkmark.circle.fill" : "circle")
                }.keyboardShortcut(.space, modifiers: []).help("Select or unselect (space)")
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 14) {
                if model.showsBackup {
                    Label(model.keptDriveCopy(bundle) ? "Backed up: kept the drive's better copy" : status.label, systemImage: status.color == nil ? "circle.dashed" : "circle.fill")
                        .foregroundStyle(status.color ?? .secondary)
                }
                if let r = model.cleanup[bundle.id]?.bestReason, model.cleanup[bundle.id]?.best == true {
                    Label("Best of its similar shots: \(r)", systemImage: "star.fill").foregroundStyle(.yellow)
                }
                if model.canSettle(bundle) {
                    Button("Fix…") { model.sheet = .settle(only: [bundle.id]) }.buttonStyle(.borderless).disabled(model.busy)
                        .help("Fix this possible copy: keep the better version, or compare them yourself")
                }
                Spacer()
            }
            .font(.callout)
            Group {
                if let file {
                    if bundle.primary.isVideo, let player { VideoPlayer(player: player) }
                    else if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
                    else if bundle.primary.isVideo { ProgressView().colorScheme(.dark) }
                    else { Text("Can't show this file.").foregroundStyle(.white) }
                } else if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                else { ProgressView("Loading from iPhone…").colorScheme(.dark) }
            }
            .frame(minWidth: 760, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
            .background(Color.black, in: RoundedRectangle(cornerRadius: Radius.tile))
        }
        .padding(16)
        .task(id: bundle.id) {
            player?.pause(); player = nil; file = nil; image = nil; error = nil
            do {
                let url = try await model.previewFile(for: bundle.primary)
                let isVideo = bundle.primary.isVideo
                let img = isVideo ? nil : await Task.detached { AppModel.downscaled(url, to: 3000) }.value
                guard !Task.isCancelled else { return }   // moved on to another item meanwhile
                if isVideo { player = AVPlayer(url: url) }
                image = img
                file = url
            } catch { self.error = AppModel.describe(error) }
        }
        .onDisappear { player?.pause() }
    }

    private func go(_ i: Int?, _ step: Int) {
        guard let i, list.indices.contains(i + step) else { return }
        onOpen(list[i + step])
    }
}

// MARK: - Back up sheet

struct BackupSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var chosen: String?          // an existing folder inside the backup folder, e.g. "2024/Bali"
    @State private var outside = false
    @State private var existing: [String] = []

    var body: some View {
        let problem = chosen == nil ? Naming.validateFolderName(name) : nil
        let label = Naming.label(forFolder: (trimmed as NSString).lastPathComponent)
        let first = Naming.nextNumbers(count: 1, label: label, existing: existing)[0]
        let todo = model.selectedUnbacked
        let skipped = model.selection.count - todo.count
        VStack(alignment: .leading, spacing: 14) {
            Label("Back up \(todo.count) item\(todo.count == 1 ? "" : "s") · \(gb(todo.reduce(0) { $0 + $1.totalSize }))", systemImage: "externaldrive.badge.plus")
                .font(.title3.weight(.semibold))
            if skipped > 0 {
                Text("\(skipped) of the selected item\(skipped == 1 ? " is" : "s are") already backed up and will be skipped.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Folder").font(.callout.weight(.medium))
                // The button gets its own line: beside the 440-wide name box the sheet squeezes it to nothing.
                if let chosen {
                    Label("Into: \(model.driveRoot.lastPathComponent)/\(chosen)", systemImage: "folder.fill").lineLimit(1).truncationMode(.middle)
                        .frame(width: 440, alignment: .leading)
                    Button("New folder instead") { self.chosen = nil }
                } else {
                    TextField("e.g. 2026-10 Bali", text: $name).textFieldStyle(.roundedBorder).frame(width: 440)
                        .onSubmit { if problem == nil && !label.isEmpty { start() } }
                    Button("Choose existing folder…", action: choose)
                }
                if outside {
                    Text("That folder isn't inside \(model.driveRoot.lastPathComponent). Choose one inside it, so the check can find them.").foregroundStyle(.red).font(.callout)
                }
                if label.isEmpty || trimmed.isEmpty {
                    Text("Type a name after the date, e.g. “Bali”. Starting with the date keeps folders in order.").font(.callout).foregroundStyle(.secondary)
                } else if let problem {
                    Text(problem).foregroundStyle(.red).font(.callout)
                } else {
                    Text("Saved in \(model.driveRoot.lastPathComponent)/\(trimmed)/ as “\(Naming.fileName(label: label, number: first, ext: "HEIC"))”, …"
                         + (existing.isEmpty ? "" : " The folder exists; numbering continues."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Every file is checked after copying. Nothing on the drive is ever overwritten.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Back up", action: start).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(problem != nil || label.isEmpty || todo.isEmpty || model.busy)
            }
        }
        .padding(22)
        .onAppear { if name.isEmpty { name = model.suggestedFolderName } }
        .task(id: trimmed) {
            existing = (try? FileManager.default.contentsOfDirectory(atPath: model.driveRoot.appendingPathComponent(trimmed).path)) ?? []
        }
    }

    private func start() { model.backup(folderName: trimmed); dismiss() }

    private var trimmed: String { chosen ?? name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The Mac's own folder window, opened in the backup folder. Only folders inside it count.
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.driveRoot
        panel.prompt = "Back up here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let inside = Naming.pathInside(model.driveRoot, folder: url)
        outside = inside == nil
        if let inside { chosen = inside }
    }
}

// MARK: - Fix possible copies (settle)

struct SettleSheet: View {
    let model: AppModel
    let only: Set<String>?
    @Environment(\.dismiss) private var dismiss
    @State private var leftOut: Set<String> = []
    @State private var reconciling: SettleRow?
    @State private var lastCompared: String?   // the list comes back scrolled to this row, not to the top
    @State private var loaded = false

    private func action(_ r: SettleRow) -> Settle.Action? { r.action }

    var body: some View {
        Group {
            if let r = reconciling {
                ReconcileView(model: model, row: r) { same in
                    if let same { model.remember(r, same: same); leftOut.remove(r.id) }
                    lastCompared = r.id
                    reconciling = nil
                }
            } else { list }
        }
        .padding(20)
        .frame(minWidth: 960, minHeight: 600)
        .task { await model.loadSettleRows(only: only); loaded = true }
    }

    private var list: some View {
        let rows = model.settleRows
        let comparing = rows.filter { $0.verdict == nil }.count
        let todo = rows.filter { !leftOut.contains($0.id) }.compactMap { r in action(r).map { (r.id, $0) } }
        let unsure = rows.filter { $0.verdict != nil && action($0) == nil }.count
        return VStack(alignment: .leading, spacing: 12) {
            Text("Fix possible copies").font(.title3.weight(.semibold))
            Text("The drive has a file that looks like each of these iPhone photos and videos but isn't identical. Where the iPhone's is better, it replaces the drive copy (the old one goes to the drive's Trash). Where the drive's is better, that copy is kept and the item turns green. Where the app isn't sure, press “Compare” and decide yourself.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if rows.isEmpty && loaded {
                Label("Nothing to fix: no possible copies that can be fixed right now.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else if rows.isEmpty {
                ProgressView("Comparing…").frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ScrollViewReader { proxy in
                    List(rows) { r in row(r) }.frame(minWidth: 900, minHeight: 380)
                        .onAppear { if let id = lastCompared { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            HStack(spacing: 12) {
                if comparing > 0 {
                    ProgressView().controlSize(.small)
                    Text("Comparing \(comparing)…").foregroundStyle(.secondary)
                } else {
                    Text("\(todo.count) to fix" + (unsure > 0 ? " · \(unsure) to compare" : "")).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(todo.isEmpty ? "Fix" : "Fix \(todo.count)") {
                    model.settle(Dictionary(uniqueKeysWithValues: todo)); dismiss()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(todo.isEmpty || comparing > 0 || model.busy)
                .help("Fix every ticked item above as shown")
            }
        }
    }

    @ViewBuilder private func row(_ r: SettleRow) -> some View {
        let a = action(r)
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { a != nil && !leftOut.contains(r.id) },
                                     set: { if $0 { leftOut.remove(r.id) } else { leftOut.insert(r.id) } }))
                .labelsHidden().disabled(a == nil)
            SettleSide(model: model, row: r, phone: true, img: r.phoneThumb, size: 64)
            Image(systemName: "arrow.left").foregroundStyle(.secondary)
            SettleSide(model: model, row: r, phone: false, img: r.driveThumb, size: 64)
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if r.verdict == nil { ProgressView().controlSize(.small) }
                else if let a { Label(Self.consequence(a, r), systemImage: Self.icon(a)).foregroundStyle(a == .different ? Color.secondary : .green).lineLimit(1) }
                else { Label("Not sure: compare them", systemImage: "questionmark.circle").foregroundStyle(.orange).lineLimit(1) }
                if r.verdict != nil {
                    Button(a == nil ? "Compare…" : "Compare again…") { reconciling = r }
                        .buttonStyle(a == nil ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.borderless))
                }
            }
            .frame(width: 260, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    static func consequence(_ a: Settle.Action, _ r: SettleRow) -> String {
        switch a {
        case .replace: "Replace with the iPhone original"
        case .keepDrive: "Keep the drive's copy"
        case .different: "Not the same: back up later"
        case .keepBoth: "iPhone original added next to it"
        }
    }
    static func icon(_ a: Settle.Action) -> String {
        switch a { case .replace: "arrow.left.arrow.right"; case .keepDrive: "checkmark.circle.fill"; case .different: "circle.dashed"; case .keepBoth: "plus.circle" }
    }
}

/// One side of a possible copy: picture, format, size and name, with a "better" tag.
private struct SettleSide: View {
    let model: AppModel
    let row: SettleRow
    let phone: Bool
    let img: CGImage?
    let size: CGFloat

    var body: some View {
        let r = row
        let format = phone ? r.item.formatLabel + (r.bundle.kind == .live ? " + MOV" : "")
                           : (r.drive.path as NSString).pathExtension.uppercased().replacingOccurrences(of: "JPEG", with: "JPG")
        let detail = r.item.isVideo ? length(phone ? r.item.duration : r.drive.duration)
                                    : (phone ? mp(r.item.pixelWidth, r.item.pixelHeight) : mp(r.drive.pixelWidth, r.drive.pixelHeight))
        let name = phone ? r.item.name : r.drive.path.replacingOccurrences(of: model.driveRoot.path + "/", with: "")
        let best = r.better == (phone ? .phone : .drive)
        let big = size > 100
        let info = VStack(alignment: big ? .center : .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(phone ? "iPhone" : "Drive").font(.callout.weight(.semibold))
                if best { Text("better").font(.caption2.weight(.bold)).padding(.horizontal, 4).background(.green.opacity(0.25), in: Capsule()) }
            }
            Text([format, detail, gb(phone ? r.item.size : r.drive.size)].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        let pic = Group {
            if let img { Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: big ? .fit : .fill) }
            else if big { ProgressView() }
            else { Rectangle().fill(.quaternary) }
        }
        if big {
            VStack(spacing: 8) {
                pic.frame(maxWidth: .infinity, minHeight: size, maxHeight: .infinity).background(Color.black, in: RoundedRectangle(cornerRadius: Radius.tile))
                info
            }
        } else {
            HStack(spacing: 8) {
                pic.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 6))
                info.frame(width: 170, alignment: .leading)
            }
        }
    }

    private func length(_ d: Double?) -> String? { d.map { String(format: "%d:%02d", Int($0) / 60, Int($0) % 60) } }
}

/// Both versions side by side, big, so the person can say whether they're the same photo.
private struct ReconcileView: View {
    let model: AppModel
    let row: SettleRow
    let done: (Bool?) -> Void   // same photo? nil: back without answering
    @State private var phoneImg: CGImage?
    @State private var driveImg: CGImage?

    var body: some View {
        let r = row
        VStack(alignment: .leading, spacing: 12) {
            Text(r.item.isVideo ? "Is this the same video?" : "Is this the same photo?").font(.title3.weight(.semibold))
            HStack(spacing: 16) {
                SettleSide(model: model, row: r, phone: true, img: phoneImg, size: 420)
                SettleSide(model: model, row: r, phone: false, img: driveImg, size: 420)
            }
            .frame(minWidth: 900, minHeight: 480)
            Text("Same: " + (r.better == .phone ? "the iPhone original replaces the drive copy (the old one goes to the drive's Trash)." : "the drive's copy is kept as the backup and the item turns green.")
                 + " Not the same: it stays “Not backed up”, so your next backup includes it." + (r.item.isVideo ? " Only the first frame is shown; check the length too." : ""))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Back") { done(nil) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Not the same") { done(false) }
                Button("Same") { done(true) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .task(id: r.id) {
            phoneImg = r.phoneThumb; driveImg = r.driveThumb
            let big = await model.reconcileImages(r)
            phoneImg = big.phone; driveImg = big.drive
        }
    }
}

// MARK: - Ready-to-delete list (iPhones that don't allow deleting from the Mac)

struct ReadyToDeleteView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let ready = model.bundles.filter { Matcher.isDeletable(model.status(of: $0)) }
        VStack(alignment: .leading, spacing: 10) {
            Text("Ready to delete").font(.title3.weight(.semibold))
            Text("This iPhone doesn't allow deleting from the Mac. These \(ready.count) items are exactly backed up; delete them in the Photos app or Image Capture.")
                .font(.callout).foregroundStyle(.secondary)
            List(ready) { b in
                HStack {
                    Text(b.members.filter { !$0.isSidecar }.map(\.name).joined(separator: ", "))
                    Spacer()
                    Text(b.primary.captureDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "").foregroundStyle(.secondary)
                }
            }.frame(minWidth: 520, minHeight: 360)
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
    }
}
