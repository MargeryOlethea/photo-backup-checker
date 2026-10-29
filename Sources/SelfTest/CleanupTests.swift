import Foundation
import Core

func cleanupTests() {
    let dup = Cleanup.exactDuplicates(hashes: ["a": "h1", "b": "h2", "c": "h1", "d": "h3", "e": "h1"])
    check(dup.count == 1 && Set(dup[0]) == ["a", "c", "e"], "exact duplicates grouped by hash only")

    let t = Date(timeIntervalSince1970: 1_700_000_000)
    func it(_ id: String, _ sec: Double, burst: String? = nil) -> PhoneItem {
        PhoneItem(id: id, name: id, size: 1, captureDate: t.addingTimeInterval(sec), uti: "public.jpeg", burstUUID: burst)
    }
    let items = [it("p1", 0), it("p2", 30), it("far", 40), it("late", 20 * 60), it("b1", 5000, burst: "B"), it("b2", 5001, burst: "B")]
    let dist: (String, String) -> Float? = { a, b in
        let close: Set<Set<String>> = [["p1", "p2"], ["p1", "late"]]
        return close.contains([a, b]) ? 0.1 : 0.9
    }
    let groups = Cleanup.similarGroups(items: items, distance: dist).map(Set.init)
    check(groups.contains(["p1", "p2"]), "close pair within 10 min grouped")
    check(!groups.contains { $0.contains("late") }, "close pair 20 min apart not grouped")
    check(!groups.contains { $0.contains("far") }, "far pair not grouped")
    check(groups.contains(["b1", "b2"]), "burst members grouped regardless of distance")
}

func keeperTests() {
    let groups = [["old", "dup1", "dup2"], ["star", "s1"]]
    check(Cleanup.keepers(selected: ["old", "dup1", "dup2", "star", "s1"], groups: groups) == ["old", "star"], "a fully selected group keeps its first member")
    check(Cleanup.keepers(selected: ["dup1", "dup2", "s1"], groups: groups).isEmpty, "a group with an unselected member keeps nothing extra")
    check(Cleanup.keepers(selected: [], groups: groups).isEmpty, "nothing selected, nothing kept")
    // A photo that is both a duplicate and a similar shot: keepers of both groups stay.
    check(Cleanup.keepers(selected: ["a", "b", "c"], groups: [["a", "b"], ["c", "b"]]) == ["a", "c"], "overlapping groups each keep their own")
}
