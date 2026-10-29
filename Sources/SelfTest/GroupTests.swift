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
