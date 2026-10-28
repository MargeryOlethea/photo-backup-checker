import AppKit

/// Testing aid (PBC_SNAPSHOT_DIR, demo only). Each line written to <dir>/request is one command:
///   snap <name>          save every open window as <dir>/<name>-<n>.png
///   filter <Filter name> show that filter        select <n> / select none / select first-of <Filter name> <n>
///   sheet backup|delete|settle|ready|preview|none   open or close a sheet
///   do-settle / do-backup <folder> / do-delete green|all / status (writes status.txt)   run the real actions
/// Lets the screens be checked without screen-recording permission.
enum Snapshot {
    @MainActor static func start(dir: URL, model: AppModel) {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let req = dir.appendingPathComponent("request")
                guard let text = try? String(contentsOf: req, encoding: .utf8) else { return }
                try? FileManager.default.removeItem(at: req)
                for line in text.split(separator: "\n").map(String.init) { run(line, dir: dir, model: model) }
            }
        }
    }

    @MainActor private static func run(_ line: String, dir: URL, model: AppModel) {
        let w = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = w.first else { return }
        let arg = w.count > 1 ? w[1] : ""
        switch cmd {
        case "snap":
            for (i, win) in NSApp.windows.filter(\.isVisible).enumerated() {
                guard let v = win.contentView?.superview ?? win.contentView,
                      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(arg)-\(i).png"))
            }
        case "filter": if let f = Filter(rawValue: arg) { model.filter = f }
        case "select":
            if arg == "none" { model.selection = [] }
            else if arg.hasPrefix("first-of ") {
                let parts = arg.dropFirst(9).split(separator: " ")
                let f = Filter(rawValue: parts.dropLast().joined(separator: " ")) ?? .all
                let old = model.filter; model.filter = f
                model.selection.formUnion(model.visible.prefix(Int(parts.last ?? "1") ?? 1).map(\.id))
                model.filter = old
            } else if let n = Int(arg) { model.selection = Set(model.visible.prefix(n).map(\.id)) }
        case "sheet":
            switch arg {
            case "backup": model.sheet = .backup
            case "delete": model.sheet = .delete
            case "settle": model.sheet = .settle
            case "ready": model.sheet = .readyList
            case "preview": model.sheet = model.visible.first.map { .preview($0) }
            default: model.sheet = nil
            }
        case "do-settle":   // run every row with its suggested action
            model.settle(Dictionary(uniqueKeysWithValues: model.settleRows.compactMap { r in r.action.map { (r.id, $0) } }))
        case "do-backup": model.backup(folderName: arg)
        case "do-delete":   // "green" = only backed-up selected items; "all" = with consent for the rest
            let sel = model.selectedBundles
            let unbacked = model.selectedUnbacked
            model.deleteSelected(ids: Set(sel.map(\.id)), allowUnbacked: arg == "all" ? Set(unbacked.map(\.id)) : [])
        case "status":
            let s = model.summary
            let line = "green=\(s.verified) possible=\(s.possible) none=\(s.none) items=\(model.bundles.count) busy=\(model.busy) message=\(model.message ?? "-")\n"
            try? line.write(to: dir.appendingPathComponent("status.txt"), atomically: true, encoding: .utf8)
        case "size":
            let n = arg.split(separator: "x").compactMap { Double($0) }
            if n.count == 2, let win = NSApp.windows.first(where: \.isVisible) { win.setContentSize(NSSize(width: n[0], height: n[1])) }
        default: break
        }
    }
}
