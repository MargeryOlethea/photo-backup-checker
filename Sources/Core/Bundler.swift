import Foundation

/// Groups phone files the phone treats as one photo: Live Photos, edits, bursts.
/// When the phone's own grouping signals disagree, files stay separate rather than merged on a guess.
public enum Bundler {
    public static func bundles(_ items: [PhoneItem]) -> [ItemBundle] {
        // A burst shot's edited version: the iPhone lists it but never hands it over (asking jams the connection).
        // It rides along with its burst like an .AAE, so it is shown, deleted and handed over with it, never read.
        let burstStems = Set(items.filter { $0.burstUUID != nil && !$0.isSidecar }.map { $0.folder + "/" + $0.stem })
        func burstEdit(_ i: PhoneItem) -> Bool { i.isEditedRender && (i.burstUUID != nil || burstStems.contains(i.folder + "/" + i.stem)) }
        let media = items.filter { !$0.isSidecar && !burstEdit($0) }
        let sidecars = items.filter(\.isSidecar) + items.filter { !$0.isSidecar && burstEdit($0) }.map { var s = $0; s.isSidecar = true; return s }

        var groups: [[PhoneItem]] = []
        // Bursts first: same burst id.
        let bursts = Dictionary(grouping: media.filter { $0.burstUUID != nil }, by: { $0.burstUUID! })
        groups += bursts.values.map { $0 }
        // Everything else: same folder + stem, if their group ids agree.
        let rest = media.filter { $0.burstUUID == nil }
        for (_, same) in Dictionary(grouping: rest, by: { $0.folder + "/" + $0.stem }) {
            let ids = Set(same.compactMap(\.groupUUID))
            if ids.count > 1 { groups += same.map { [$0] } } else { groups.append(same) }
        }

        var out: [ItemBundle] = groups.map { make($0) }
        // Attach sidecars to the bundle holding a media file with the same folder + stem.
        var bundleFor: [String: Int] = [:]
        for (i, b) in out.enumerated() { for m in b.members where bundleFor[m.folder + "/" + m.stem] == nil { bundleFor[m.folder + "/" + m.stem] = i } }
        for s in sidecars {
            if let i = bundleFor[s.folder + "/" + s.stem] {
                out[i].members.append(s)
            } else {
                out.append(ItemBundle(id: s.id, primary: s, members: [s], kind: .single))
            }
        }
        return out.sorted {
            let a = $0.primary.captureDate ?? .distantPast, b = $1.primary.captureDate ?? .distantPast
            return a != b ? a > b : $0.id < $1.id
        }
    }

    private static func make(_ g: [PhoneItem]) -> ItemBundle {
        let sorted = g.sorted { ($0.captureDate ?? .distantPast, $0.name) < ($1.captureDate ?? .distantPast, $1.name) }
        let kind: ItemBundle.Kind
        let primary: PhoneItem
        if g.count == 1 {
            kind = .single; primary = g[0]
        } else if g.contains(where: { $0.burstUUID != nil }) {
            kind = .burst; primary = sorted[0]
        } else if g.contains(where: \.isEditedRender) {
            kind = .edited; primary = sorted.first { !$0.isEditedRender && !$0.isVideo } ?? sorted[0]
        } else if g.contains(where: \.isVideo) && g.contains(where: { !$0.isVideo }) {
            kind = .live; primary = sorted.first { !$0.isVideo }!
        } else {
            kind = .single; primary = sorted[0]
        }
        return ItemBundle(id: primary.id, primary: primary, members: [primary] + sorted.filter { $0 != primary }, kind: kind)
    }
}

private func < (a: (Date, String), b: (Date, String)) -> Bool { a.0 != b.0 ? a.0 < b.0 : a.1 < b.1 }
