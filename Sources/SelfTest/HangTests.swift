import Foundation
import Core

func hangTests() {
    func p(_ n: String) -> PhoneItem { PhoneItem(id: "DCIM/1/\(n)", name: n, size: 1, uti: "public.heic") }
    check(p("IMG_E0001.HEIC").isEditedRender && p("img_e0001.jpg").isEditedRender, "IMG_E files are edited versions")
    check(!p("IMG_0001.HEIC").isEditedRender, "plain file is not an edited version")
    // Files saved from other apps keep a 4-letter prefix; their edited version adds E after it.
    check(p("ECEIE5383.JPG").isEditedRender && p("DSCFE0019.JPG").isEditedRender, "XXXXE files are edited versions")
    check(!p("ECEI5383.JPG").isEditedRender && !p("BOS04114.JPEG").isEditedRender && !p("IMG_0001E.HEIC").isEditedRender, "other names are not edited versions")
    let photo = Bundler.bundles([p("ECEI5383.JPG"), p("ECEIE5383.JPG")])
    check(photo.count == 1 && photo[0].kind == .edited && photo[0].primary.name == "ECEI5383.JPG", "XXXX original and its edited version are one photo")
    let mov = "com.apple.quicktime-movie"
    let clip = Bundler.bundles([PhoneItem(id: "DCIM/1/DGKX8273.MP4", name: "DGKX8273.MP4", size: 1, uti: "public.mpeg-4"),
                                PhoneItem(id: "DCIM/1/DGKXE8273.MOV", name: "DGKXE8273.MOV", size: 1, uti: mov)])
    check(clip.count == 1 && clip[0].members.count == 2, "XXXX video and its edited version are one item")

    let order = PhoneItem.storedFirst([p("IMG_E0001.HEIC"), p("IMG_0002.HEIC"), p("IMG_E0003.JPG"), p("IMG_0004.MOV")]).map(\.name)
    check(order == ["IMG_0002.HEIC", "IMG_0004.MOV", "IMG_E0001.HEIC", "IMG_E0003.JPG"], "edited versions are read last, order kept (got \(order))")

    check(p("IMG_E1.HEIC").formatLabel == "HEIC" && p("a.jpeg").formatLabel == "JPG" && p("a.jpg").formatLabel == "JPG", "format label: HEIC / JPG")
    var h = HangTracker()
    check(h.timedOut(p("IMG_E1168.JPG")), "one edited version hanging means the connection is jammed")
    h = HangTracker()
    check(!h.timedOut(p("IMG_0001.HEIC")), "one real file hanging is just skipped")
    check(h.timedOut(p("IMG_0002.HEIC")), "two real files hanging back to back means the phone stopped answering")
    h = HangTracker()
    check(!h.timedOut(p("IMG_0001.HEIC")), "first hang")
    h.answered()
    check(!h.timedOut(p("IMG_0003.HEIC")), "an answer in between starts the count again")

    // Edited versions the iPhone can't make: one failed try and it is given up on for good (every try costs a replug).
    var t = RenderTries()
    check(t.shouldTry("e"), "an untried edited version is tried")
    t.failed("e")
    check(!t.shouldTry("e") && t.tried("e") && t.gaveUp("e"), "given up after one failed try")
    t.failed("e")
    check(t.counts["e"] == 1, "a second failure in the same check doesn't count twice")
    t.newRun()
    check(!t.shouldTry("e"), "the next check doesn't try it again")
    check(t.shouldTry("other"), "other edited versions are unaffected")

    // Saved counts; the old file only stored when each one hung (a date), which stands for one try.
    let url = tempDir().appendingPathComponent("bad-renders.json")
    check(RenderTries.load(from: url).counts == [:], "missing file: no tries")
    try! Data(#"{"a|1|2":814894418.959036,"b|1|2":814895138.9}"#.utf8).write(to: url)
    check(RenderTries.load(from: url).counts == ["a|1|2": 1, "b|1|2": 1], "old date entries count as one try")
    try! JSONStore.save(["a|1|2": 3, "c": 1], to: url)
    check(RenderTries.load(from: url).counts == ["a|1|2": 1, "c": 1], "counts are read back; old higher counts still mean given up")
    check(RenderTries.max == 1, "an edited version is given up on after one try")
}
