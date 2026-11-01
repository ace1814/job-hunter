import Foundation

/// Decides when the morning refresh runs. It runs once a day, as soon as the app is open at or
/// after the chosen hour, so a Mac that wakes late still gets it.
public enum MorningSchedule {
    public static func isDue(at date: Date, hour: Int?, lastRun: String?, calendar: Calendar = .current) -> Bool {
        guard let hour else { return false }
        return lastRun != Day.key(for: date, calendar: calendar) && calendar.component(.hour, from: date) >= hour
    }
}
