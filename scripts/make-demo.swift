// Builds a demo "iPhone" folder and "drive" folder from the Mac's own wallpapers, covering every case
// the app shows: exact backup (green), possible copy (amber, both directions), not backed up,
// similar shots (one blurred), a duplicate and screenshots.
// Usage: swift scripts/make-demo.swift <out-dir>   then run the app with
//   PBC_DEMO_PHONE=<out-dir>/phone PBC_DEMO_DRIVE=<out-dir>/drive
import Foundation
import ImageIO
import CoreImage
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "demo")
let phone = out.appendingPathComponent("phone"), drive = out.appendingPathComponent("drive")
try? FileManager.default.removeItem(at: out)
for d in [phone, drive.appendingPathComponent("2026-07 Lisbon"), drive.appendingPathComponent("2026-09 Bali")] {
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
}

let sources = (FileManager.default.enumerator(atPath: "/System/Library/Desktop Pictures")?.allObjects as? [String] ?? [])
    .filter { $0.lowercased().hasSuffix(".heic") || $0.lowercased().hasSuffix(".jpg") }
    .sorted()
    .map { URL(fileURLWithPath: "/System/Library/Desktop Pictures").appendingPathComponent($0) }
guard sources.count >= 30 else { fatalError("not enough wallpapers") }

let ctx = CIContext()
func image(_ url: URL, maxSize: Int) -> CGImage {
    // Decode the full picture (a wallpaper's built-in thumbnail is tiny), then scale it down.
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let full = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let scale = min(1, Double(maxSize) / Double(max(full.width, full.height)))
    let w = Int(Double(full.width) * scale), h = Int(Double(full.height) * scale)
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
    return c.makeImage()!
}
let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()
func write(_ img: CGImage, to url: URL, type: UTType, date: Date?, quality: Double = 0.9) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
    if let date { props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: fmt.string(from: date)] }
    CGImageDestinationAddImage(dest, img, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("write \(url.path)") }
}
func cropped(_ img: CGImage, _ f: Double) -> CGImage {
    let w = Double(img.width) * f, h = Double(img.height) * f
    return img.cropping(to: CGRect(x: (Double(img.width) - w) / 2, y: (Double(img.height) - h) / 2, width: w, height: h))!
}
func blurred(_ img: CGImage) -> CGImage {
    let ci = CIImage(cgImage: img).clampedToExtent().applyingGaussianBlur(sigma: 12).cropped(to: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return ctx.createCGImage(ci, from: ci.extent)!
}

var n = 1000
var when = Date(timeIntervalSince1970: 1_780_000_000)
func next() -> (String, Date) { n += 1; when += 3600 * 7; return ("IMG_\(n)", when) }
let heic = UTType.heic, jpg = UTType.jpeg
var s = sources.makeIterator()

// 12 exact backups (green)
for i in 0..<12 {
    let (name, date) = next()
    let p = phone.appendingPathComponent("\(name).HEIC")
    write(image(s.next()!, maxSize: 2400), to: p, type: heic, date: date)
    try FileManager.default.copyItem(at: p, to: drive.appendingPathComponent(i < 6 ? "2026-07 Lisbon" : "2026-09 Bali").appendingPathComponent(String(format: "%@ %02d.HEIC", i < 6 ? "Lisbon" : "Bali", i % 6 + 1)))
}
// 8 AirDrop-style JPG copies on the drive, smaller than the iPhone original (amber, iPhone better)
for i in 0..<8 {
    let (name, date) = next()
    let img = image(s.next()!, maxSize: 2400)
    write(img, to: phone.appendingPathComponent("\(name).HEIC"), type: heic, date: date)
    write(image(phone.appendingPathComponent("\(name).HEIC"), maxSize: 1200), to: drive.appendingPathComponent("2026-09 Bali/Bali \(i + 7).JPG"), type: jpg, date: date, quality: 0.6)
}
// 2 where the drive holds the bigger version (amber, drive better)
for i in 0..<2 {
    let (name, date) = next()
    let src = s.next()!
    write(image(src, maxSize: 1000), to: phone.appendingPathComponent("\(name).JPG"), type: jpg, date: date, quality: 0.7)
    write(image(src, maxSize: 2400), to: drive.appendingPathComponent("2026-07 Lisbon/Lisbon \(i + 7).HEIC"), type: heic, date: date)
}
// 1 amber that is a different picture taken the same second (must not be settled)
do {
    let (name, date) = next()
    write(image(s.next()!, maxSize: 2400), to: phone.appendingPathComponent("\(name).HEIC"), type: heic, date: date)
    write(image(s.next()!, maxSize: 2400), to: drive.appendingPathComponent("2026-07 Lisbon/Lisbon 9.JPG"), type: jpg, date: date)
}
// 8 not backed up
for _ in 0..<8 {
    let (name, date) = next()
    write(image(s.next()!, maxSize: 2400), to: phone.appendingPathComponent("\(name).HEIC"), type: heic, date: date)
}
// Similar shots: 3 frames a few seconds apart, one blurred
do {
    let base = image(s.next()!, maxSize: 2400)
    for (k, img) in [cropped(base, 0.97), blurred(cropped(base, 0.98)), cropped(base, 0.96)].enumerated() {
        n += 1
        write(img, to: phone.appendingPathComponent("IMG_\(n).HEIC"), type: heic, date: when + Double(k * 4))
    }
    when += 3600
}
// A duplicate (same bytes twice)
do {
    let (name, _) = next()
    let p = phone.appendingPathComponent("\(name).HEIC")
    write(image(s.next()!, maxSize: 2400), to: p, type: heic, date: when)
    n += 1
    try FileManager.default.copyItem(at: p, to: phone.appendingPathComponent("IMG_\(n).HEIC"))
}
// Screenshots: PNG at iPhone 13 screen size
for _ in 0..<3 {
    let (name, date) = next()
    let img = image(s.next()!, maxSize: 2532)
    let ci = CIImage(cgImage: img).transformed(by: CGAffineTransform(scaleX: 2532 / Double(img.width), y: 2532 / Double(img.width)))
        .cropped(to: CGRect(x: 0, y: 0, width: 1170, height: 2532))
    write(ctx.createCGImage(ci, from: CGRect(x: 0, y: 0, width: 1170, height: 2532))!, to: phone.appendingPathComponent("\(name).PNG"), type: .png, date: date)
}
print("demo ready: \(out.path)")
