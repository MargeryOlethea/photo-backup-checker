import Foundation
import Core

func bestPickTests() {
    let sharpNoFaces = ShotScore(clarity: 0.6, faces: [])
    let blurry3Faces = ShotScore(clarity: 0.1, faces: [0.9, 0.9, 0.9])
    let sharp2Good = ShotScore(clarity: 0.55, faces: [0.8, 0.7, 0.2])
    let sharp3Good = ShotScore(clarity: 0.5, faces: [0.8, 0.7, 0.6])

    check(BestPick.pick(group: ["a", "b"], scores: ["a": blurry3Faces, "b": sharpNoFaces])?.best == "b", "clear beats blurry even with more faces")
    check(BestPick.pick(group: ["a", "b"], scores: ["a": sharp2Good, "b": sharp3Good])?.best == "b", "among clear photos, more good faces wins")
    check(BestPick.pick(group: ["a", "b", "c"], scores: ["a": sharpNoFaces, "b": sharp3Good])?.best == nil, "a photo without a score: no star")
    check(BestPick.pick(group: ["a"], scores: ["a": sharpNoFaces]) == nil, "one photo: no star")

    let a = ShotScore(clarity: 0.5, faces: [0.8]), b = ShotScore(clarity: 0.52, faces: [0.82])
    let close = BestPick.pick(group: ["a", "b"], scores: ["a": a, "b": b])
    check(close?.closeCall == true && Set([close?.best, close?.runnerUp]) == ["a", "b"], "nearly equal photos are a close call")
    check(BestPick.pick(group: ["a", "b"], scores: ["a": sharpNoFaces, "b": blurry3Faces])?.closeCall == false, "clear winner is not a close call")

    check(BestPick.reason(sharp3Good) == "Sharp · 3 faces look good", "reason with faces (got \(BestPick.reason(sharp3Good)))")
    check(BestPick.reason(ShotScore(clarity: 0.5, faces: [0.9])) == "Sharp · 1 face looks good", "reason with one face")
    check(BestPick.reason(sharpNoFaces) == "Sharpest of the group", "reason without faces")

    // Jev tie-break: two images as the choice options, answer read back
    let body = (try? JSONSerialization.jsonObject(with: Jev.pickRequestBody(firstBase64: "AAA", secondBase64: "BBB"))) as? [String: Any]
    let assets = body?["assets"] as? [String: Any]
    check(assets?.count == 2, "both photos sent as assets")
    let ok = Data(#"{"answers":{"best":{"type":"choice","choice":"second","confidence":0.8}}}"#.utf8)
    check(Jev.pickAnswer(fromResponse: ok) == 1, "Jev picks the second photo")
    let unsure = Data(#"{"answers":{"best":{"type":"choice","choice":"first","confidence":0.4}}}"#.utf8)
    check(Jev.pickAnswer(fromResponse: unsure) == nil, "low-confidence Jev pick is ignored")
}
