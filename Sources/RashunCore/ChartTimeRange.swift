import Foundation

public enum ChartTimeRange: String, CaseIterable, Hashable {
    case day = "Day"
    case week = "Week"
    case month = "Month"
    case all = "All"

    public func rangeBounds(now: Date, calendar: Calendar = .current) -> (start: Date?, end: Date?) {
        switch self {
        case .day:
            let interval = calendar.dateInterval(of: .day, for: now)
            return (interval?.start, interval?.end)
        case .week:
            let interval = calendar.dateInterval(of: .weekOfYear, for: now)
            return (interval?.start, interval?.end)
        case .month:
            let interval = calendar.dateInterval(of: .month, for: now)
            return (interval?.start, interval?.end)
        case .all:
            return (nil, nil)
        }
    }
}
