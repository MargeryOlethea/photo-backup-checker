import Foundation
import Vision
import CoreGraphics

/// How good one photo is: clarity (Apple's overall image score, blur pulls it down) and each face's quality.
public struct ShotScore: Codable, Equatable, Sendable {
    public var clarity: Double
    public var faces: [Double]
    public init(clarity: Double, faces: [Double]) { self.clarity = clarity; self.faces = faces }

    public var goodFaces: Int { faces.filter { $0 >= BestPick.goodFace }.count }
    public var faceQuality: Double { faces.isEmpty ? 0 : faces.reduce(0, +) / Double(faces.count) }
}

public struct Pick: Equatable, Sendable {
    public var best: String
    public var runnerUp: String
    public var closeCall: Bool
}

/// The ★ in a group of similar shots: clear first, then the most faces that look good.
public enum BestPick {
    static let goodFace = 0.5
    static let clearMargin = 0.15
    static let closeMargin = 0.05

    /// nil when there's nothing to choose from or any photo couldn't be scored (no star beats a wrong star).
    public static func pick(group: [String], scores: [String: ShotScore]) -> Pick? {
        guard group.count >= 2 else { return nil }
        let scored = group.compactMap { id in scores[id].map { (id, $0) } }
        guard scored.count == group.count, let top = scored.map(\.1.clarity).max() else { return nil }
        func clear(_ s: ShotScore) -> Bool { s.clarity >= top - clearMargin }
        let ranked = scored.sorted { x, y in
            let a = x.1, b = y.1
            if clear(a) != clear(b) { return clear(a) }
            if a.goodFaces != b.goodFaces { return a.goodFaces > b.goodFaces }
            if a.faceQuality != b.faceQuality { return a.faceQuality > b.faceQuality }
            return a.clarity > b.clarity
        }
        let (a, b) = (ranked[0].1, ranked[1].1)
        let close = clear(a) && clear(b) && a.goodFaces == b.goodFaces
            && abs(a.faceQuality - b.faceQuality) < closeMargin && abs(a.clarity - b.clarity) < closeMargin
        return Pick(best: ranked[0].0, runnerUp: ranked[1].0, closeCall: close)
    }

    public static func reason(_ s: ShotScore) -> String {
        switch s.goodFaces {
        case 0: "Sharpest of the group"
        case 1: "Sharp · 1 face looks good"
        case let n: "Sharp · \(n) faces look good"
        }
    }

    /// Scores one photo with Apple's on-device image analysis. nil if it can't be scored on this Mac.
    public static func score(cgImage: CGImage) -> ShotScore? {
        guard #available(macOS 15, *) else { return nil }
        let aesthetics = VNCalculateImageAestheticsScoresRequest()
        let faces = VNDetectFaceCaptureQualityRequest()
        guard (try? VNImageRequestHandler(cgImage: cgImage).perform([aesthetics, faces])) != nil,
              let a = aesthetics.results?.first else { return nil }
        let q: [Double] = (faces.results ?? []).compactMap { f in
            guard let q = f.faceCaptureQuality else { return nil }
            // Turned away from the camera (more than about 25°) doesn't count as looking good.
            let away = abs(f.yaw?.doubleValue ?? 0) > 0.45 || abs(f.pitch?.doubleValue ?? 0) > 0.45
            return away ? min(Double(q), goodFace - 0.1) : Double(q)
        }
        return ShotScore(clarity: Double(a.overallScore), faces: q)
    }
}
