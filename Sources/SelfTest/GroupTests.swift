import Core
import Foundation

func groupTests() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    cal.locale = Locale(identifier: "en_US")
    cal.firstWeekday = 2   // Monday
    func b(_ n: String, _ ymd: String?) -> ItemBundle {
        let d = ymd.map { s -> Date in let p = s.split(separator: "-").map { Int($0)! }; return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))! }
        let p = PhoneItem(id: n, name: n, size: 1, captureDate: d, uti: "public.heic")
        return ItemBundle(id: n, primary: p, members: [p], kind: .single)
    }
    // Newest first, as the grid shows them; "c" and "d" are 2 days apart in the same week, "a" is in another month.
    let items = [b("d", "2025-10-15"), b("c", "2025-10-13"), b("x", nil), b("b", "2025-10-05"), b("a", "2025-09-30")]

    let none = Grouping.none.sections(items, calendar: cal)
    check(none.count == 1 && none[0].title == nil && none[0].items.map(\.id) == ["d", "c", "x", "b", "a"], "not grouped: one unnamed section, order kept")

    let months = Grouping.month.sections(items, calendar: cal)
    check(months.map(\.title) == ["October 2025", "September 2025", "No date"], "months newest first, undated last")
    check(months[0].items.map(\.id) == ["d", "c", "b"] && months[2].items.map(\.id) == ["x"], "items keep their order inside a month")

    let weeks = Grouping.week.sections(items, calendar: cal)
    check(weeks.map(\.title) == ["Week of October 13, 2025", "Week of September 29, 2025", "No date"], "weeks start on the calendar's first weekday; a week can span two months")
    check(weeks[1].items.map(\.id) == ["b", "a"], "October 5 and September 30 fall in the same Monday week")

    let days = Grouping.day.sections(items, oldestFirst: true, calendar: cal)
    check(days.map(\.title) == ["Tuesday, September 30, 2025", "Sunday, October 5, 2025", "Monday, October 13, 2025", "Wednesday, October 15, 2025", "No date"], "oldest first flips the sections; undated still last")

    check(Grouping.month.sections([], calendar: cal).isEmpty, "no items: no sections")
}

func burstEditTests() {
    let t = Date(timeIntervalSince1970: 1_790_587_258)
    func it(_ name: String, burst: String? = nil, sidecar: Bool = false) -> PhoneItem {
        PhoneItem(id: "DCIM/202609_a/" + name, name: name, size: 10, captureDate: t, uti: "public.jpeg", burstUUID: burst, isSidecar: sidecar)
    }
    let items = [it("IMG_2245.JPG", burst: "B"), it("IMG_2246.JPG", burst: "B"), it("IMG_E2245.JPG"), it("IMG_E2246.JPG", burst: "B"),
                 it("IMG_2245.AAE", sidecar: true), it("IMG_3000.JPG"), it("IMG_E3000.JPG")]
    let bundles = Bundler.bundles(items)
    let burst = bundles.first { $0.kind == .burst }
    check(bundles.count == 2 && burst != nil, "a burst's edited shots join the burst instead of showing as their own photos")
    if let burst {
        check(Set(burst.mediaMembers.map(\.name)) == ["IMG_2245.JPG", "IMG_2246.JPG"], "only the burst's originals count as its photos")
        check(burst.members.count == 5, "edited shots and .AAE stay with the burst, so they go when it's deleted")
        check(!burst.readableMembers.contains(where: \.isEditedRender), "a burst's edited shots are never read from the iPhone")
        check(burst.onlyPhoneCanDelete, "a burst with edits is still handed to the iPhone Shortcut")
        let plan = (try? BackupWriter.plan(bundles: [burst], folderName: "2026-09 Trip", existingNames: [])) ?? []
        check(plan.count == 3 && !plan.contains(where: { $0.item.isEditedRender }), "backing up a burst copies its originals and .AAE, not its edited shots")
    }
    let edited = bundles.first { $0.kind == .edited }
    check(edited?.readableMembers.contains(where: \.isEditedRender) == true, "an ordinary edited photo still backs up its edited version")
}
