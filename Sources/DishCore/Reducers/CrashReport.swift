// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Turns the backtrace the crash handler left on disk into something a user
// can read, check and choose to send. Nothing here transmits: the whole point
// of the local-report design is that the user sees the exact text before it
// goes anywhere, and the "send" step is their browser opening a prefilled
// issue, never a background upload.
//
// `redact` is the part that earns its keep. A backtrace picks up the home
// directory, the LAN addresses Dish was talking to, and anything key-shaped
// that happened to be on the stack. A user pasting that into a public issue
// should not be publishing their pairing key, so the scrub happens before
// they ever see the text.

import Foundation

public enum CrashReport {
    /// GitHub rejects a URL much past this, and browsers vary below it. A
    /// report that would overflow is truncated with a marker telling the user
    /// to attach the file.
    public static let maxIssueURLBytes = 6000
    public static let issueURLString = "https://github.com/TinkerNorth/dish-mac/issues/new"
    public static let issueTitle = "Crash report"
    static let truncationNotice = "\n\n[report truncated — please attach the full crash.log from the path above]"

    /// Scrubs the identifying material out of a raw backtrace: the home
    /// directory collapses to `~`, hex runs of 32 characters or more (a
    /// pairing key, a session key or a device id on a stack) become
    /// `[redacted]`, IPv4 literals become `[ip]`, and `*.local` names become
    /// `[host].local`. Home first, since it is the longest pattern; keys
    /// before addresses, since a 64-character key would otherwise survive as
    /// a long unmatched run.
    public static func redact(_ raw: String, home: String) -> String {
        let withoutHome = collapseHome(raw, home: home)
        return [
            (#"\b[0-9a-fA-F]{32,}\b"#, "[redacted]"),
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "[ip]"),
            (#"\b[A-Za-z0-9][A-Za-z0-9-]*\.local\b"#, "[host].local")
        ].reduce(withoutHome) { text, rule in replacing(pattern: rule.0, in: text, with: rule.1) }
    }

    /// The full report: a small environment header, then the redacted
    /// backtrace. This is the exact text shown to the user and the exact text
    /// the issue is prefilled with; there is no second, richer version.
    public static func build(rawLog: String, home: String, appVersion: String, system: String) -> String {
        "Dish \(appVersion)\nmacOS \(system)\n\n--- backtrace ---\n" + redact(rawLog, home: home)
    }

    /// A prefilled "new issue" URL. The body is budgeted against the ENCODED
    /// length (percent-encoding a backtrace roughly triples it), halving and
    /// retrying rather than trimming byte by byte, since the encoded size is
    /// not a linear function of the character count.
    public static func issueURL(for report: String) -> URL? {
        var body = report
        var url = issueURL(body: body)
        while let candidate = url, candidate.absoluteString.utf8.count > maxIssueURLBytes, body.count > 64 {
            body = String(body.prefix(body.count / 2))
            url = issueURL(body: body + truncationNotice)
        }
        return url
    }

    private static func issueURL(body: String) -> URL? {
        var components = URLComponents(string: issueURLString)
        components?.queryItems = [URLQueryItem(name: "title", value: issueTitle), URLQueryItem(name: "body", value: body)]
        return components?.url
    }

    private static func collapseHome(_ text: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }

    private static func replacing(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }
}
