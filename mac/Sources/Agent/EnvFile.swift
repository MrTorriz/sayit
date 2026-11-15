// EnvFile.swift - writes the Settings window's choices back into .env the way
// a person editing it would: the assignment's own line changes, and every
// comment, blank line and other setting stays where it was.
//
// bash sources .env and Shared.readEnv parses it, so a value is written in a
// form both read back literally: plain when it is a bare word, else in double
// quotes, or in single quotes when it holds $, `, \ or ", which double quotes
// would not keep. Foundation only: mac/tests/ConfigTests.swift builds it.

import Foundation

enum EnvFile {
    /// `value` as it goes after KEY=. `plain` allows a bare word without
    /// quotes (numbers, 0 and 1, names such as XBUTTON2).
    static func render(_ value: String, plain: Bool = false) -> String {
        // One line: a line break would end the assignment.
        var v = value.components(separatedBy: .newlines).joined(separator: " ")
        if plain, !v.isEmpty, v.range(of: "^[A-Za-z0-9_.+-]+$", options: .regularExpression) != nil {
            return v
        }
        let special = v.contains { "$`\\\"".contains($0) }
        if !special { return "\"" + v + "\"" }
        if !v.contains("'") { return "'" + v + "'" }
        // Both kinds of quote and a character only single quotes keep: no
        // quoting holds all of it, so the straight double quotes turn curly.
        v = v.replacingOccurrences(of: "\"", with: "\u{201D}")
        return v.contains { "$`\\".contains($0) } ? "'" + v.replacingOccurrences(of: "'", with: "\u{2019}") + "'"
                                                    : "\"" + v + "\""
    }

    /// A path for .env: under the home folder as "$HOME/…", so the file still
    /// reads right on another account, else as it is.
    static func renderPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        let rest = path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : nil
        if let rest = rest, !rest.contains(where: { "$`\\\"\n".contains($0) }) {
            return "\"$HOME/" + rest + "\""
        }
        return render(path)
    }

    /// `text` with KEY set to `rendered` (the output of render or
    /// renderPath). The last active assignment of KEY is rewritten in place,
    /// keeping an `export ` before it and a comment after it; without one, a
    /// line is added at the end. Commented-out examples are left alone.
    static func set(_ key: String, rendered: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let pattern = "^([ \\t]*(?:export[ \\t]+)?)" + NSRegularExpression.escapedPattern(for: key) + "[ \\t]*=(.*)$"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        for i in lines.indices.reversed() {
            let line = lines[i] as NSString
            guard let m = re.firstMatch(in: lines[i], range: NSRange(location: 0, length: line.length)) else { continue }
            let prefix = line.substring(with: m.range(at: 1))
            let rest = line.substring(with: m.range(at: 2))
            lines[i] = prefix + key + "=" + rendered + tail(of: rest)
            return lines.joined(separator: "\n")
        }
        // A new line, after the last line with text.
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        lines.append(key + "=" + rendered)
        return lines.joined(separator: "\n") + "\n"
    }

    /// `text` without any active assignment of KEY: the setting falls back to
    /// its default, or to the file read before this one.
    static func remove(_ key: String, in text: String) -> String {
        let pattern = "^[ \\t]*(?:export[ \\t]+)?" + NSRegularExpression.escapedPattern(for: key) + "[ \\t]*="
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        return text.components(separatedBy: "\n").filter { line in
            re.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) == nil
        }.joined(separator: "\n")
    }

    /// What follows an assignment's value on its line: a trailing comment.
    private static func tail(of rest: String) -> String {
        let r = rest.drop(while: { $0 == " " || $0 == "\t" })
        if let q = r.first, q == "\"" || q == "'" {
            guard let end = r.dropFirst().firstIndex(of: q) else { return "" }
            return String(r[r.index(after: end)...])
        }
        if let hash = rest.range(of: "[ \\t]+#", options: .regularExpression) { return String(rest[hash.lowerBound...]) }
        return ""
    }

    /// Sets each pair in the file at `path` and writes it back through a
    /// temporary file and a rename, keeping the file's permissions.
    /// A nil `rendered` removes the key.
    static func write(_ pairs: [(key: String, rendered: String?)], path: String) throws {
        var text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        for p in pairs {
            if let r = p.rendered { text = set(p.key, rendered: r, in: text) } else { text = remove(p.key, in: text) }
        }
        let mode = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
        let tmp = path + ".tmp.\(getpid())"
        try Data(text.utf8).write(to: URL(fileURLWithPath: tmp))
        if let mode = mode { chmod(tmp, mode_t(mode)) }
        guard rename(tmp, path) == 0 else {
            unlink(tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
