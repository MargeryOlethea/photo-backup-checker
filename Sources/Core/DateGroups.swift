import Foundation

/// How the grid is split into dated sections. The person picks one in the filter bar.
public enum Grouping: String, CaseIterable, Identifiable, Sendable {
    case none = "Not grouped", day = "By day", week = "By week", month = "By month"
    public var id: String { rawValue }

    /// Splits `items` (already filtered and sorted) into sections. Items keep their order inside a section;
    /// sections run newest first (`oldestFirst` flips them); items with no capture date come last as "No date".
    public func sections(_ items: [ItemBundle], oldestFirst: Bool = false, calendar: Calendar = .current) -> [GridSection] {
        guard let unit else { return [GridSection(id: "all", title: nil, items: items)] }
        var byStart: [Date: [ItemBundle]] = [:], undated: [ItemBundle] = []
        for b in items {
            if let d = b.primary.captureDate, let start = calendar.dateInterval(of: unit, for: d)?.start { byStart[start, default: []].append(b) }
            else { undated.append(b) }
        }
        var out = byStart.keys.sorted(by: oldestFirst ? (<) : (>)).map {
            GridSection(id: "\($0.timeIntervalSince1970)", title: title(for: $0, calendar: calendar), items: byStart[$0]!)
        }
        if !undated.isEmpty { out.append(GridSection(id: "undated", title: "No date", items: undated)) }
        return out
    }

    private var unit: Calendar.Component? {
        switch self {
        case .none: nil
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    private func title(for start: Date, calendar: Calendar) -> String {
        let style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        switch self {
        case .day: return start.formatted(style.weekday(.wide).day().month(.wide).year())
        case .week: return "Week of " + start.formatted(style.day().month(.wide).year())
        case .month: return start.formatted(style.month(.wide).year())
        case .none: return ""
        }
    }
}

public struct GridSection: Identifiable, Sendable {
    public let id: String
    public let title: String?     // nil: the one unnamed section when not grouped
    public let items: [ItemBundle]
}
