import Foundation
import Core

private let d0 = Date(timeIntervalSince1970: 1_700_000_000)
private func item(_ name: String, folder: String = "DCIM/100APPLE", size: Int64 = 100, date: Date = d0, uti: String = "public.heic",
                  w: Int? = 3024, h: Int? = 4032, dur: Double? = nil, group: String? = nil, burst: String? = nil, sidecar: Bool = false) -> PhoneItem {
    PhoneItem(id: "\(folder)/\(name)", name: name, size: size, captureDate: date, uti: uti, pixelWidth: w, pixelHeight: h,
              duration: dur, groupUUID: group, burstUUID: burst, isSidecar: sidecar)
}

func matchTests() {
    // Bundler
    let live = Bundler.bundles([item("IMG_0010.HEIC", group: "G1"), item("IMG_0010.MOV", uti: "com.apple.quicktime-movie", dur: 2.5, group: "G1")])
    check(live.count == 1 && live[0].kind == .live && live[0].members.count == 2, "Live pair is one bundle")
    check(live.first?.primary.name == "IMG_0010.HEIC", "Live primary is the photo")

    let edited = Bundler.bundles([item("IMG_0001.HEIC"), item("IMG_E0001.HEIC"), item("IMG_0001.AAE", uti: "com.apple.photos.aae", sidecar: true)])
    check(edited.count == 1 && edited[0].kind == .edited, "edited trio is one bundle")
    check(edited.first?.primary.name == "IMG_0001.HEIC", "edited primary is the original")
    check(edited.first?.members.filter(\.isSidecar).count == 1, "AAE kept as sidecar member")

    let burst = Bundler.bundles([item("IMG_0100.JPG", burst: "B"), item("IMG_0101.JPG", burst: "B"), item("IMG_0102.JPG", burst: "B")])
    check(burst.count == 1 && burst[0].kind == .burst && burst[0].members.count == 3, "burst of 3 is one bundle")

    let conflict = Bundler.bundles([item("IMG_0200.HEIC", group: "X"), item("IMG_0200.MOV", uti: "com.apple.quicktime-movie", group: "Y")])
    check(conflict.count == 2, "conflicting group ids stay separate")

    let otherFolder = Bundler.bundles([item("IMG_0300.HEIC", folder: "DCIM/100APPLE"), item("IMG_0300.HEIC", folder: "DCIM/140APPLE")])
    check(otherFolder.count == 2, "same name in different folders stays separate")

    // Matcher
    let p = item("IMG_0010.HEIC", size: 100)
    let same = DriveFile(path: "/d/x.HEIC", size: 100, modified: d0, sha256: "abc")
    check(Matcher.status(item: p, phoneHash: "abc", sameSize: [same], candidates: []) == .verified(drivePath: "/d/x.HEIC"), "hash match is verified")
    check(Matcher.status(item: p, phoneHash: "zzz", sameSize: [same], candidates: []) == .none, "same size different hash is not verified")
    check(Matcher.status(item: p, phoneHash: nil, sameSize: [same], candidates: []) == .none, "no phone hash is not verified")

    let conv = DriveFile(path: "/d/IMG_0010.JPG", size: 55, modified: d0, captureDate: d0.addingTimeInterval(0.5), pixelWidth: 4032, pixelHeight: 3024, metadataRead: true)
    let s = Matcher.status(item: p, phoneHash: "abc", sameSize: [], candidates: [conv])
    if case .possible(let path, _) = s { check(path == "/d/IMG_0010.JPG", "possible points at candidate") } else { check(false, "date+shape match is possible") }
    check(!Matcher.isDeletable(s), "possible is never deletable")
    check(!Matcher.isDeletable(.none), "none is not deletable")
    check(Matcher.isDeletable(.verified(drivePath: "/d/x")), "verified is deletable")

    let wrongShape = DriveFile(path: "/d/y.JPG", size: 55, modified: d0, captureDate: d0, pixelWidth: 1000, pixelHeight: 1000, metadataRead: true)
    check(Matcher.status(item: p, phoneHash: nil, sameSize: [], candidates: [wrongShape]) == .none, "different shape is not a possible copy")

    let vid = item("IMG_0011.MOV", uti: "com.apple.quicktime-movie", dur: 10.0)
    let vidCopy = DriveFile(path: "/d/v.mp4", size: 9, modified: d0, captureDate: d0, duration: 10.6, metadataRead: true)
    if case .possible = Matcher.status(item: vid, phoneHash: nil, sameSize: [], candidates: [vidCopy]) { check(true, "") } else { check(false, "video same date and duration is possible") }

    // Bundle status
    let photo = item("IMG_0010.HEIC"), movie = item("IMG_0010.MOV", uti: "com.apple.quicktime-movie")
    let aae = item("IMG_0010.AAE", uti: "com.apple.photos.aae", sidecar: true)
    let partial = Matcher.bundleStatus([(photo, .verified(drivePath: "/d/a")), (movie, .none)])
    if case .possible = partial { check(true, "") } else { check(false, "photo verified + live video missing is possible") }
    check(!Matcher.isDeletable(partial), "partial bundle not deletable")
    check(Matcher.bundleStatus([(photo, .verified(drivePath: "/d/a")), (movie, .verified(drivePath: "/d/b")), (aae, .none)]) == .verified(drivePath: "/d/a"),
          "unmatched AAE does not block verified")
    check(Matcher.bundleStatus([(photo, .none), (movie, .none)]) == .none, "nothing matched is none")
}
