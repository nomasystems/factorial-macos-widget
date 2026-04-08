import Foundation

struct ShiftSegment: Equatable {
    var start: Date
    var end: Date?      // nil = ongoing
    var isBreak: Bool
}

/// Summary of a single workday for the 10-day history table
struct DaySummary: Identifiable {
    let date: Date
    let workedSeconds: TimeInterval
    let segments: [ShiftSegment]
    let holidayName: String?       // nil = normal workday

    var id: Date { date }
    var isHoliday: Bool { holidayName != nil }
}
