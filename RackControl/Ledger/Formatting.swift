import Foundation

// ---------------------------------------------------------------------------
// Formatting shared by all three tabs. Mirrors web/app.js exactly - same
// integer-cents math, same UTC-midnight date handling - so the phone and the
// browser never disagree about what a balance or a date means for the same
// underlying row.
// ---------------------------------------------------------------------------

let staleDays = 3

/// The same UTC calendar the private helpers below use, exposed for the
/// settings sheet's date conversions. One calendar, so a date can never be
/// read in UTC and written back in local time.
let utcCalendarPublic: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private let utcCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

/// "YYYY-MM-DD" -> UTC midnight. Parsed by hand rather than with
/// ISO8601DateFormatter, which defaults to requiring a time component and
/// rejects a date-only string outright.
private func utcMidnight(_ dateStr: String) -> Date? {
    let parts = dateStr.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var comps = DateComponents()
    comps.year = parts[0]
    comps.month = parts[1]
    comps.day = parts[2]
    return utcCalendar.date(from: comps)
}

/// Days between a "YYYY-MM-DD" and `nowMs` - the SERVER's clock (Summary.now),
/// never Date(), so a phone with its own clock drifted or in a different
/// timezone reports the same staleness the hub would.
func daysBetween(_ dateStr: String, nowMs: Double) -> Int? {
    guard let d = utcMidnight(dateStr) else { return nil }
    let today = utcCalendar.startOfDay(for: Date(timeIntervalSince1970: nowMs / 1000))
    return Int((today.timeIntervalSince(d) / 86400).rounded())
}

func formatShortDate(_ dateStr: String) -> String {
    guard let d = utcMidnight(dateStr) else { return dateStr }
    let f = DateFormatter()
    f.dateFormat = "MMM d"
    f.timeZone = TimeZone(identifier: "UTC")
    return f.string(from: d)
}

func relativeDay(_ days: Int) -> String {
    if days <= 0 { return "today" }
    if days == 1 { return "yesterday" }
    return "\(days) days ago"
}

/// Integer cents -> "$1,234.56" (or "−$4.20"). Never a Double at any step -
/// see the spec's "all money is integer cents" rule. `abs` first, sign
/// prepended after, so a negative balance doesn't produce "-$-4.20".
func formatCents(_ cents: Int) -> String {
    let neg = cents < 0
    let magnitude = abs(cents)
    let dollars = magnitude / 100
    let remainder = magnitude % 100
    let nf = NumberFormatter()
    nf.numberStyle = .decimal
    let dollarsStr = nf.string(from: NSNumber(value: dollars)) ?? String(dollars)
    return "\(neg ? "\u{2212}" : "")$\(dollarsStr).\(String(format: "%02d", remainder))"
}

/// Milliseconds -> "4 minutes ago". Mirrors relativeMinutes() in web/app.js so
/// the phone and the browser word the same gap identically. Clamped at zero:
/// both timestamps come from the hub's clock, but a negative would still read
/// as nonsense rather than as "just now".
func relativeMinutes(_ ms: Double) -> String {
    let mins = Int((max(0, ms) / 60000).rounded())
    if mins < 1 { return "just now" }
    if mins == 1 { return "1 minute ago" }
    if mins < 60 { return "\(mins) minutes ago" }
    let hours = Int((Double(mins) / 60).rounded())
    return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
}

// ---------------------------------------------------------------------------
// Hand-typed money and dates, for the settings sheet. Mirrors
// web/settings.js's centsFromInput/centsToInput exactly, so the same typed
// string produces the same integer on the phone and in the browser.
// ---------------------------------------------------------------------------

/// "420.5" -> 42050. Nil if it is not money.
///
/// String arithmetic, never `Double(text) * 100`: 8.29 * 100 is
/// 828.9999999999999, and rounding that away works right up until the one
/// amount where it does not.
func centsFromInput(_ text: String) -> Int? {
    let cleaned = text.filter { !"$, \t".contains($0) }
    guard !cleaned.isEmpty else { return nil }
    let parts = cleaned.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count <= 2,
        let whole = parts.first.flatMap({ $0.isEmpty ? "0" : String($0) }),
        whole.allSatisfy(\.isNumber), let dollars = Int(whole)
    else { return nil }
    guard parts.count == 2 else { return dollars * 100 }
    let frac = String(parts[1])
    guard frac.count <= 2, frac.allSatisfy(\.isNumber), !frac.isEmpty,
        let cents = Int(frac + String(repeating: "0", count: 2 - frac.count))
    else { return nil }
    return dollars * 100 + cents
}

/// Integer cents -> what belongs in a text field: "420.00". No "$", no commas -
/// it is about to be parsed back, not read.
func centsToInput(_ cents: Int?) -> String {
    guard let cents else { return "" }
    return "\(cents / 100).\(String(format: "%02d", cents % 100))"
}

/// "YYYY-MM-DD" -> a Date at UTC midnight, for a DatePicker to bind to.
func dateFromISO(_ dateStr: String?) -> Date? {
    guard let dateStr else { return nil }
    let parts = dateStr.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var comps = DateComponents()
    comps.year = parts[0]
    comps.month = parts[1]
    comps.day = parts[2]
    return utcCalendarPublic.date(from: comps)
}

/// A Date -> "YYYY-MM-DD", read in UTC.
///
/// UTC on the way out as well as in. A DatePicker hands back local midnight,
/// and formatting that in the device's own timezone west of Greenwich yields
/// the PREVIOUS day - so a payday saved on the 4th comes back as the 3rd.
func isoFromDate(_ date: Date) -> String {
    let c = utcCalendarPublic.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

/// "Fri, Sep 4" - a payday is a day of the WEEK to most people, so it says so.
func formatDayName(_ dateStr: String) -> String {
    guard let d = dateFromISO(dateStr) else { return dateStr }
    let f = DateFormatter()
    f.dateFormat = "EEE, MMM d"
    f.timeZone = TimeZone(identifier: "UTC")
    return f.string(from: d)
}
