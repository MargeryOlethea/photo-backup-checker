import Foundation

/// Plain-text diagnostic log: ~/Library/Application Support/PhotoBackupChecker/debug.log (kept under ~5 MB).
enum Diag {
    private static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PhotoBackupChecker/debug.log")
    private static let queue = DispatchQueue(label: "diag")
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    static func log(_ line: String) {
        let text = "\(stamp.string(from: Date())) \(line)\n"
        queue.async {
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 5_000_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        }
    }
}
