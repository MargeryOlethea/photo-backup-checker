import Foundation
import Core

func hangTests() {
    func p(_ n: String) -> PhoneItem { PhoneItem(id: "DCIM/1/\(n)", name: n, size: 1, uti: "public.heic") }
    check(p("IMG_E0001.HEIC").isEditedRender && p("img_e0001.jpg").isEditedRender, "IMG_E files are edited versions")
    check(!p("IMG_0001.HEIC").isEditedRender, "plain file is not an edited version")

    let order = PhoneItem.storedFirst([p("IMG_E0001.HEIC"), p("IMG_0002.HEIC"), p("IMG_E0003.JPG"), p("IMG_0004.MOV")]).map(\.name)
    check(order == ["IMG_0002.HEIC", "IMG_0004.MOV", "IMG_E0001.HEIC", "IMG_E0003.JPG"], "edited versions are read last, order kept (got \(order))")

    var h = HangTracker()
    check(h.shouldRead(p("IMG_E1.JPG")), "edited versions are read while the phone still makes them")
    check(!h.timedOut(p("IMG_E1168.JPG")), "an edited version hanging never counts as a stuck phone")
    check(!h.shouldRead(p("IMG_E2.JPG")), "after one edited version hangs, the rest wait for a replug")
    check(h.shouldRead(p("IMG_0009.HEIC")), "stored files are still read after an edited version hangs")
    check(!h.timedOut(p("IMG_0001.HEIC")), "one real file hanging is just skipped")
    check(!h.timedOut(p("IMG_E3.JPG")), "an edited version in between changes nothing")
    check(h.timedOut(p("IMG_0002.HEIC")), "two real files hanging back to back means the phone is stuck")
    h.answered()
    check(!h.timedOut(p("IMG_0003.HEIC")), "an answer in between starts the count again")
    check(!h.shouldRead(p("IMG_E4.JPG")), "an answer doesn't unblock edited versions; only a replug does")
}
