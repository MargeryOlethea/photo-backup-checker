import Foundation
import ImageIO
import UniformTypeIdentifiers

/// TypeSafe's Jev model, asked one question per screenshot: junk, keep, or unsure.
/// Only screenshots are ever sent; everything else stays on the Mac.
public enum Jev {
    public enum Verdict: String, Codable, Sendable { case junk, keep, unsure }
    public enum JevError: Error { case tooSmall, badResponse, http(Int) }

    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let minConfidence = 0.6

    /// iPhone 13 screenshots: PNG at the screen's exact pixel size.
    public static func isScreenshot(_ item: PhoneItem) -> Bool {
        guard item.uti == UTType.png.identifier, let w = item.pixelWidth, let h = item.pixelHeight else { return false }
        return Set([w, h]) == [1170, 2532]
    }

    public static func requestBody(jpegBase64: String) -> Data {
        let body: [String: Any] = [
            "model": "jev-latest",
            "state": ["screenshot": "shot"],
            "assets": ["shot": ["type": "image", "format": "jpg", "data_base64": jpegBase64]],
            "questions": ["verdict": [
                "type": "choice",
                "instructions": "This is a screenshot from someone's phone. Is it junk they can delete, or something worth keeping?",
                "criteria": [
                    "junk": "Throwaway: memes, loading screens, accidental shots, old receipts or confirmations, outdated info, duplicates of things saved elsewhere.",
                    "keep": "Worth keeping: tickets, IDs, addresses, saved chats or notes with lasting value, personal moments, important records.",
                    "unsure": "Not clear from the image.",
                ],
            ]],
        ]
        return try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    public static func verdict(fromResponse data: Data) throws -> (Verdict, Double) {
        struct Answer: Decodable { let choice: String; let confidence: Double }
        struct Resp: Decodable { let answers: [String: Answer] }
        guard let a = (try? JSONDecoder().decode(Resp.self, from: data))?.answers["verdict"],
              let v = Verdict(rawValue: a.choice) else { throw JevError.badResponse }
        let trusted = (0...1).contains(a.confidence) && a.confidence >= minConfidence
        return (trusted ? v : .unsure, a.confidence)
    }

    public static func loadKey(from dir: URL) -> String? {
        guard let s = try? String(contentsOf: dir.appendingPathComponent("jev.key"), encoding: .utf8) else { return nil }
        let k = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return k.isEmpty ? nil : k
    }

    /// Upright JPEG, long side ≤ 1568 px, short side ≥ 280 px (Jev's limits).
    public static func prepareImage(_ data: Data) throws -> Data {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { throw JevError.badResponse }
        let long = max(w, h), short = min(w, h)
        let scale = min(1, 1568 / Double(long))
        guard Double(short) * scale >= 280 else { throw JevError.tooSmall }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(1568, long),
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw JevError.badResponse }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { throw JevError.badResponse }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw JevError.badResponse }
        return out as Data
    }

    public static func classify(imageData: Data, key: String, session: URLSession = .shared) async throws -> (Verdict, Double) {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("true", forHTTPHeaderField: "TypeSafe-Danger-Zone-Images")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = requestBody(jpegBase64: try prepareImage(imageData).base64EncodedString())
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw JevError.http(code) }
        return try verdict(fromResponse: data)
    }
}
