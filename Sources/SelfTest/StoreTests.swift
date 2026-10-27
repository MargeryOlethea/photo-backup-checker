import Foundation
import Core

func storeTests() {
    let dir = tempDir()
    let url = dir.appendingPathComponent("v.json")
    check(JSONStore.load([String: Int].self, from: url) == [:], "missing store loads empty")
    try? JSONStore.save(["a": 1], to: url)
    check(JSONStore.load([String: Int].self, from: url) == ["a": 1], "store round-trips")
    try! Data("garbage".utf8).write(to: url)
    check(JSONStore.load([String: Int].self, from: url) == [:], "damaged store loads empty instead of crashing")

    let thumbs = ThumbnailStore(dir: dir.appendingPathComponent("thumbs"))
    check(thumbs.data(for: "DCIM/100APPLE/IMG_1.HEIC|5|10") == nil, "missing thumbnail is nil")
    thumbs.put(Data([1, 2, 3]), for: "DCIM/100APPLE/IMG_1.HEIC|5|10")
    check(thumbs.data(for: "DCIM/100APPLE/IMG_1.HEIC|5|10") == Data([1, 2, 3]), "thumbnail round-trips")
    check(thumbs.data(for: "DCIM/100APPLE/IMG_1.HEIC|6|10") == nil, "different size is a different thumbnail")
}
