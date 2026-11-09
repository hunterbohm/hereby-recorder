import Foundation
import LMLCore

public enum PanelText {
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    public static func stamp(_ date: Date, since start: Date?, in zone: TimeZone, locale: Locale) -> String {
        guard let start else { return clock(date, in: zone, locale: locale) }
        return elapsed(date.timeIntervalSince(start))
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    public static func startsIn(_ start: Date, now: Date) -> String {
        let delta = start.timeIntervalSince(now)
        if abs(delta) < 60 { return "Starts now" }
        if delta > 0 { return "Starts in \(Int((delta / 60).rounded(.up))) min" }
        return "Started \(Int((-delta / 60).rounded(.down))) min ago"
    }

    /// The next call's large figure and its unit: minutes under an hour, hours and minutes today, else the day.
    public static func countdown(to start: Date, end: Date?, now: Date, in zone: TimeZone, locale: Locale) -> (value: String, unit: String) {
        let delta = start.timeIntervalSince(now)
        if delta <= 0 {
            let over = end.map { now >= $0 } ?? false
            return over ? ("Ended", "") : ("Now", "started \(clock(start, in: zone, locale: locale))")
        }
        let minutes = Int((delta / 60).rounded(.up))
        if minutes < 60 { return ("\(minutes)", "min") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        if calendar.isDate(start, inSameDayAs: now) || minutes < 12 * 60 {
            let rest = minutes % 60
            return ("\(minutes / 60)", rest == 0 ? "h" : "h \(rest) min")
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(start, inSameDayAs: tomorrow) {
            return ("Tomorrow", "")
        }
        return (format(start, "EEEE", in: zone, locale: locale), "")
    }

    public static func clock(_ date: Date, in zone: TimeZone, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: date)
    }

    public static func day(_ date: Date, now: Date, in zone: TimeZone, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let time = clock(date, in: zone, locale: locale)
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow \(time)"
        }
        return "\(format(date, "EEEMMMd", in: zone, locale: locale)) \(time)"
    }

    public static func upcoming(_ date: Date, now: Date, in zone: TimeZone, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.isDate(date, inSameDayAs: now) ? clock(date, in: zone, locale: locale) : day(date, now: now, in: zone, locale: locale)
    }

    public static func past(_ date: Date, now: Date, in zone: TimeZone, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        if calendar.isDate(date, inSameDayAs: now) { return clock(date, in: zone, locale: locale) }
        if calendar.isDateInYesterday(date, relativeTo: now) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 7
        return format(date, days < 7 ? "EEE" : "MMMd", in: zone, locale: locale)
    }

    public static func speaker(_ raw: String, them name: String? = nil) -> String {
        switch raw {
        case "me": "You"
        case "them": name ?? "Them"
        case "room": "Room"
        case "call": "Call"
        default: raw
        }
    }

    public static func liveDetail(_ content: LiveContent) -> String {
        if content.sid == nil { return "Resumes 2 min after the call ends" }
        let place = content.kind == .inPerson ? "In person · mic only" : content.platform ?? "Call"
        return content.marks > 0 ? "\(place) · \(content.marks) marked" : place
    }

    public static func afterFacts(_ content: AfterContent, in zone: TimeZone, locale: Locale) -> String? {
        let parts = [content.duration.map(duration), content.endedAt.map { "ended \(clock($0, in: zone, locale: locale))" }]
        let known = parts.compactMap { $0 }
        return known.isEmpty ? nil : known.joined(separator: " · ")
    }

    public static func filing(_ state: FilingState) -> String {
        switch state {
        case .waiting: "Waiting to file"
        case .filing: "Filing"
        case .filed: "Filed"
        case .skipped: "Skipped"
        case .failed: "Filing failed"
        }
    }

    /// The home list's line for a recent call: filed is the usual case, so a filed row names only what is left to do.
    public static func recentDetail(_ content: AfterContent) -> String {
        let tag = filingTag(content)
        guard content.state == .filed, tag.hasPrefix("Filed · ") else { return tag }
        return String(tag.dropFirst("Filed · ".count))
    }

    public static func filingTag(_ content: AfterContent) -> String {
        switch content.state {
        case .filed:
            guard let review = content.review, review.tasks > 0, !review.answered else { return "Filed" }
            return "Filed · " + count(review.tasks, "task") + (review.sent ? " to approve" : " found")
        case .skipped:
            guard let reason = content.note, !reason.isEmpty else { return "Skipped" }
            return "Skipped · " + reason.prefix(1).uppercased() + reason.dropFirst()
        case .waiting, .filing, .failed:
            return filing(content.state)
        }
    }

    public static func review(_ review: PanelReview) -> (line: String, detail: String) {
        if review.answered { return ("Review answered", "Your task choices were applied") }
        return switch (review.sent, review.tasks) {
        case (true, 0): ("Review sent to your phone", "Nothing to approve")
        case (true, let tasks): ("Review sent to your phone", count(tasks, "task") + " to approve")
        case (false, 0): ("No review needed", "No tasks found")
        case (false, let tasks): ("Review not sent yet", count(tasks, "task") + " found")
        }
    }

    public static func count(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }

    private static func format(_ date: Date, _ template: String, in zone: TimeZone, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

private extension Calendar {
    func isDateInYesterday(_ date: Date, relativeTo now: Date) -> Bool {
        guard let yesterday = self.date(byAdding: .day, value: -1, to: now) else { return false }
        return isDate(date, inSameDayAs: yesterday)
    }
}
