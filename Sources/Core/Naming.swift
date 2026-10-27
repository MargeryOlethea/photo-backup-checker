import Foundation

/// Folder-name rules and "<label> NN.ext" numbering for backup folders.
public enum Naming {
    /// nil when the name is usable; otherwise a message for the owner.
    public static func validateFolderName(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "Type a folder name." }
        if t.rangeOfCharacter(from: .newlines) != nil { return "Folder names can't contain line breaks." }
        if t.count > 100 { return "Keep the folder name under 100 characters." }
        if t.contains("/") || t.contains(":") { return "Folder names can't contain / or :" }
        if t.hasPrefix(".") { return "Folder names can't start with a dot." }
        return nil
    }

    public static func label(forFolder folder: String) -> String {
        let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.replacingOccurrences(of: #"^\d{4}-\d{2}(-\d{2})?[\s\-_]*"#, with: "", options: .regularExpression)
        return stripped.isEmpty ? trimmed : stripped
    }

    public static func fileName(label: String, number: Int, ext: String) -> String {
        let base = "\(label) \(String(format: "%02d", number))"
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    public static func existingNumbers(label: String, in names: [String]) -> Set<Int> {
        let pattern = "^" + NSRegularExpression.escapedPattern(for: label) + #" (\d+)( edited)?(\.[^.]+)?$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        var out = Set<Int>()
        for n in names {
            let r = NSRange(n.startIndex..., in: n)
            if let m = re.firstMatch(in: n, range: r), let g = Range(m.range(at: 1), in: n), let v = Int(n[g]) { out.insert(v) }
        }
        return out
    }

    public static func nextNumbers(count: Int, label: String, existing: [String]) -> [Int] {
        let start = (existingNumbers(label: label, in: existing).max() ?? 0) + 1
        return Array(start..<(start + count))
    }
}
