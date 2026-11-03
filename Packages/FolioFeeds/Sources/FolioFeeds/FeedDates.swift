import Foundation

/// Dates as feeds write them: RFC 822 in RSS ("Mon, 2 Nov 2026 20:11:24 EST",
/// often without the weekday or seconds) and ISO 8601 in Atom and JSON Feed
/// ("2026-11-02T22:39:00", with or without a zone or fractions).
public enum FeedDates {
    public static func parse(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.first?.isNumber == true, value.contains("-"), let date = iso8601(value) { return date }
        return rfc822(value) ?? iso8601(value)
    }

    /// North American zone names some feeds still use; formatters don't
    /// all know them.
    private static let zones: [String: String] = [
        "UT": "+0000", "UTC": "+0000", "GMT": "+0000", "Z": "+0000",
        "EST": "-0500", "EDT": "-0400", "CST": "-0600", "CDT": "-0500",
        "MST": "-0700", "MDT": "-0600", "PST": "-0800", "PDT": "-0700",
        "CET": "+0100", "CEST": "+0200", "BST": "+0100",
    ]

    static func rfc822(_ value: String) -> Date? {
        var parts = value.replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
        // The weekday adds nothing and is sometimes wrong.
        if let first = parts.first, first.first?.isLetter == true { parts.removeFirst() }
        guard parts.count >= 4 else { return nil }
        if let zone = parts.last, let offset = zones[zone.uppercased()] { parts[parts.count - 1] = offset }
        if parts.count == 4 { parts.append("+0000") }  // no zone: assume UTC
        // "-0000" means "zone unknown"; read it as UTC.
        let normalized = parts.joined(separator: " ")
        for format in ["d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm Z", "d MMM yy HH:mm:ss Z", "d MMM yy HH:mm Z"] {
            if let date = formatter(format).date(from: normalized) { return date }
        }
        return nil
    }

    static func iso8601(_ value: String) -> Date? {
        if let date = isoFormatter([.withInternetDateTime, .withFractionalSeconds]).date(from: value)
            ?? isoFormatter([.withInternetDateTime]).date(from: value) {
            return date
        }
        // No zone ("2026-11-02T22:39:00") or just a day ("2026-11-02"): UTC.
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mmZ", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            if let date = formatter(format).date(from: value) { return date }
        }
        return nil
    }

    // Formatters are expensive to make and not documented as thread-safe on
    // every platform: one per thread.
    private static func formatter(_ format: String) -> DateFormatter {
        let key = "folio.feeddate." + format
        if let cached = Thread.current.threadDictionary[key] as? DateFormatter { return cached }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        Thread.current.threadDictionary[key] = formatter
        return formatter
    }

    private static func isoFormatter(_ options: ISO8601DateFormatter.Options) -> ISO8601DateFormatter {
        let key = "folio.feeddate.iso.\(options.rawValue)"
        if let cached = Thread.current.threadDictionary[key] as? ISO8601DateFormatter { return cached }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        Thread.current.threadDictionary[key] = formatter
        return formatter
    }
}
