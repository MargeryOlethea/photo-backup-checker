import Foundation
import Core

func hangTests() {
    func p(_ n: String) -> PhoneItem { PhoneItem(id: "DCIM/1/\(n)", name: n, size: 1, uti: "public.heic") }
    check(p("IMG_E0001.HEIC").isEditedRender && p("img_e0001.jpg").isEditedRender, "IMG_E files are edited versions")
    check(!p("IMG_0001.HEIC").isEditedRender, "plain file is not an edited version")

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

    // Edited versions the iPhone can't make: one try per check, given up on after 3 failed checks.
    var t = RenderTries()
    check(t.shouldTry("e"), "an untried edited version is tried")
    t.failed("e")
    check(!t.shouldTry("e") && t.tried("e") && !t.gaveUp("e"), "after a failed try it waits for the next check")
    t.failed("e")
    check(t.counts["e"] == 1, "a second failure in the same check doesn't count twice")
    t.newRun()
    check(t.shouldTry("e"), "the next check tries it again")
    t.failed("e"); t.newRun(); t.failed("e"); t.newRun()
    check(!t.shouldTry("e") && t.gaveUp("e") && t.counts["e"] == 3, "given up after 3 failed checks")
    check(t.shouldTry("other"), "other edited versions are unaffected")

    // Saved counts; the old file only stored when each one hung (a date), which stands for one try.
    let url = tempDir().appendingPathComponent("bad-renders.json")
    check(RenderTries.load(from: url).counts == [:], "missing file: no tries")
    try! Data(#"{"a|1|2":814894418.959036,"b|1|2":814895138.9}"#.utf8).write(to: url)
    check(RenderTries.load(from: url).counts == ["a|1|2": 1, "b|1|2": 1], "old date entries count as one try")
    try! JSONStore.save(["a|1|2": 3, "c": 2], to: url)
    check(RenderTries.load(from: url).counts == ["a|1|2": 3, "c": 2], "counts are read back")
    check(RenderTries.max == 3, "an edited version is given up on after 3 tries")
}
