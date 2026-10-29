import Foundation
import Vision
import CoreGraphics

/// Finds clean-up candidates on the Mac: exact duplicates and groups of similar shots.
public enum Cleanup {
    public static func exactDuplicates(hashes: [String: String]) -> [[String]] {
        Dictionary(grouping: hashes.keys, by: { hashes[$0]! })
            .values.filter { $0.count >= 2 }.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }

    /// Which of `selected` must stay on the iPhone: the first member of every group that is selected in full.
    /// Callers put the keeper first (the oldest duplicate, the ★ of similar shots), so deleting never takes a whole group.
    public static func keepers(selected: Set<String>, groups: [[String]]) -> Set<String> {
        Set(groups.compactMap { g in g.allSatisfy(selected.contains) ? g.first : nil })
    }

    /// Similar shots: taken within `window` seconds of each other and visually close, or in the same burst.
    public static func similarGroups(items: [PhoneItem], distance: (String, String) -> Float?,
                                     threshold: Float = 0.35, window: TimeInterval = 600) -> [[String]] {
        var seen = Set<String>()
        let sorted = items.filter { $0.captureDate != nil && seen.insert($0.id).inserted }.sorted { $0.captureDate! < $1.captureDate! }
        var parent = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0.id) })
        func find(_ x: String) -> String { var x = x; while parent[x]! != x { x = parent[x]! }; return x }
        func unite(_ a: String, _ b: String) { parent[find(a)] = find(b) }

        for (i, a) in sorted.enumerated() {
            for b in sorted[(i + 1)...] {
                if b.captureDate!.timeIntervalSince(a.captureDate!) > window { break }
                if let d = distance(a.id, b.id), d <= threshold { unite(a.id, b.id) }
            }
        }
        for (_, same) in Dictionary(grouping: sorted.filter { $0.burstUUID != nil }, by: { $0.burstUUID! }) {
            for m in same.dropFirst() { unite(same[0].id, m.id) }
        }
        let order = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($1.id, $0) })
        return Dictionary(grouping: sorted.map(\.id), by: find).values
            .filter { $0.count >= 2 }
            .map { $0.sorted { order[$0]! < order[$1]! } }
            .sorted { order[$0[0]]! < order[$1[0]]! }
    }

    public static func featurePrint(cgImage: CGImage) throws -> VNFeaturePrintObservation {
        let req = VNGenerateImageFeaturePrintRequest()
        try VNImageRequestHandler(cgImage: cgImage).perform([req])
        guard let obs = req.results?.first else { throw CocoaError(.featureUnsupported) }
        return obs
    }

    public static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float? {
        var d: Float = 0
        return (try? a.computeDistance(&d, to: b)) != nil ? d : nil
    }
}
