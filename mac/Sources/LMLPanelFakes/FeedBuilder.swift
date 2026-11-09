import Foundation
import LMLCore

/// Builds `PanelFeed` values the way the Mac receives them: as C4 `status.json` text decoded by `JSON.decoder()`.
public enum FeedBuilder {
    public typealias Object = [String: Any]

    public static func meeting(_ title: String, start: Date, end: Date? = nil, url: String? = nil,
                               note: String? = nil, brief: [String] = [], owed: [String]? = nil, with: String? = nil,
                               key: String? = nil, hermes: Object? = nil) -> Object {
        var object: Object = ["title": title, "start": iso(start), "end": end.map(iso) ?? NSNull(),
                              "meeting_url": url ?? NSNull(), "note": note ?? NSNull(), "brief": brief]
        if let owed { object["owed"] = owed }
        if let with { object["with"] = with }
        if let key { object["key"] = key }
        if let hermes { object["hermes"] = hermes }
        return object
    }

    /// The `hermes` field the mini adds to `next` and each `today` item (state is one of the contract's seven).
    public static func hermes(_ state: String, chat: Bool = false, error: String? = nil) -> Object {
        ["state": state, "chat": chat, "error": error ?? NSNull()]
    }

    public static func recent(_ sid: String, _ title: String, endedAt: Date?, state: FilingState,
                              note: String? = nil, noteURL: String? = nil, review: (sent: Bool, tasks: Int)? = nil, answered: Bool = false,
                              durationS: Int? = nil, snippet: String? = nil, summary: [String]? = nil,
                              moments: [(at: Date, text: String)]? = nil) -> Object {
        var object: Object = ["sid": sid, "title": title, "ended_at": endedAt.map(iso) ?? NSNull(), "state": state.rawValue,
                              "note": note ?? NSNull(), "note_url": noteURL ?? NSNull(),
                              "review": review.map { ["sent": $0.sent, "tasks": $0.tasks, "answered": answered] as Object } ?? NSNull()]
        if let durationS { object["duration_s"] = durationS }
        if let snippet { object["snippet"] = snippet }
        if let summary { object["summary"] = summary }
        if let moments { object["marked_moments"] = moments.map { ["at": iso($0.at), "text": $0.text] as Object } }
        return object
    }

    public static func live(_ sid: String, warnings: [(at: Date, text: String)]) -> Object {
        ["sid": sid, "warnings": warnings.enumerated().map { ["at": iso($1.at), "text": $1.text, "n": $0 + 1] as Object }]
    }

    public static func agenda(_ title: String, start: Date, end: Date, url: String? = nil, meeting: Bool = true,
                              key: String? = nil, hermes: Object? = nil) -> Object {
        var object: Object = ["title": title, "start": iso(start), "end": iso(end), "meeting_url": url ?? NSNull(), "meeting": meeting]
        if let key { object["key"] = key }
        if let hermes { object["hermes"] = hermes }
        return object
    }

    public static func feed(at: Date, next: Object? = nil, today: [Object]? = nil, recent: [Object] = [], live: Object? = nil) -> PanelFeed {
        var object: Object = ["v": 1, "at": iso(at), "next": next ?? NSNull(), "recent": recent]
        if let today { object["today"] = today }
        if let live { object["live"] = live }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSON.decoder().decode(PanelFeed.self, from: data)
    }

    public static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "America/Chicago")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
