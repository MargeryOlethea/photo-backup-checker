import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Core

private func png(_ w: Int, _ h: Int) -> Data {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
    return out as Data
}

func jevTests() {
    func shot(_ uti: String, _ w: Int, _ h: Int) -> PhoneItem { PhoneItem(id: "x", name: "x", size: 1, uti: uti, pixelWidth: w, pixelHeight: h) }
    check(Jev.isScreenshot(shot("public.png", 1170, 2532)), "portrait iPhone 13 PNG is a screenshot")
    check(Jev.isScreenshot(shot("public.png", 2532, 1170)), "landscape iPhone 13 PNG is a screenshot")
    check(!Jev.isScreenshot(shot("public.jpeg", 1170, 2532)), "JPEG is never a screenshot")
    check(Jev.isScreenshot(shot("public.png", 1179, 2556)), "iPhone 15 PNG is a screenshot")
    check(Jev.isScreenshot(shot("public.png", 1320, 2868)), "iPhone 16 Pro Max PNG is a screenshot")
    check(Jev.isScreenshot(shot("public.png", 750, 1334)), "iPhone 8 PNG is a screenshot")
    check(!Jev.isScreenshot(shot("public.png", 360, 780)), "tiny PNG is not a screenshot")
    check(!Jev.isScreenshot(shot("public.png", 1000, 1500)), "other-size PNG is not a screenshot")
    check(!Jev.isScreenshot(shot("public.png", 4032, 3024)), "camera-sized PNG is not a screenshot")

    let body = Jev.requestBody(jpegBase64: "AAAA")
    let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    let q = ((json?["questions"] as? [String: Any])?["verdict"]) as? [String: Any]
    check(json?["model"] as? String == "jev-latest", "model jev-latest")
    check(q?["type"] as? String == "choice", "choice question")
    check(Set(((q?["criteria"] as? [String: Any]) ?? [:]).keys) == ["junk", "keep", "unsure"], "criteria junk/keep/unsure")
    let asset = ((json?["assets"] as? [String: Any])?["shot"]) as? [String: Any]
    check(asset?["format"] as? String == "jpg" && asset?["data_base64"] as? String == "AAAA", "image asset jpg base64")

    func resp(_ c: String, _ conf: Double) -> Data {
        Data(#"{"model":"jev-1","answers":{"verdict":{"type":"choice","choice":"\#(c)","confidence":\#(conf),"probabilities":{"junk":0.9,"keep":0.05,"unsure":0.05}}},"usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)
    }
    let v = try? Jev.verdict(fromResponse: resp("junk", 0.9))
    check(v?.0 == .junk && v?.1 == 0.9, "maps junk 0.9")
    check((try? Jev.verdict(fromResponse: resp("junk", 0.4)))?.0 == .unsure, "low confidence becomes unsure")
    checkThrows("garbage response throws") { _ = try Jev.verdict(fromResponse: Data("nope".utf8)) }

    let dir = tempDir()
    check(Jev.loadKey(from: dir) == nil, "missing key file → nil")
    try! Data("  abc\n".utf8).write(to: dir.appendingPathComponent("jev.key"))
    check(Jev.loadKey(from: dir) == "abc", "key trimmed")

    if let out = try? Jev.prepareImage(png(1170, 2532)),
       let src = CGImageSourceCreateWithData(out as CFData, nil),
       let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
        check(p[kCGImagePropertyPixelHeight] as? Int == 1568, "resized long side to 1568")
        check(CGImageSourceGetType(src) as String? == UTType.jpeg.identifier, "re-encoded as JPEG")
    } else { check(false, "prepareImage works on a screenshot") }
    checkThrows("too-small image throws") { _ = try Jev.prepareImage(png(200, 400)) }
}
