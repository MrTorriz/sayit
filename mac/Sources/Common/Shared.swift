// Shared.swift - what Sayit, sayit-rec and sayit-paste agree on: where the
// transient state lives and how .env is read.
//
// .env is parsed as KEY=VALUE data, never executed - the same rule the Windows
// reader follows. Only $HOME and ${HOME} are expanded; quotes are stripped; a
// later assignment wins over an earlier one, as it does when bash sources the
// file.

import Foundation

enum Shared {
    /// The run directory every sayit component uses on macOS.
    ///
    /// XDG_RUNTIME_DIR when something set it, otherwise the per-user private
    /// temporary directory (mode 0700, on disk) - the same directory
    /// `getconf DARWIN_USER_TEMP_DIR` names for the bash scripts.
    static var runDir: String {
        if let xdg = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"], !xdg.isEmpty {
            return xdg
        }
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count)
        if n > 0 && n <= buf.count {
            let path = String(cString: buf)
            return path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        return "/tmp"
    }

    static func runPath(_ name: String) -> String {
        (runDir as NSString).appendingPathComponent(name)
    }

    static var configDir: String {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config")
        return (base as NSString).appendingPathComponent("sayit")
    }

    /// Reads KEY=VALUE pairs from a .env file. Missing file = empty.
    static func readEnv(_ path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { continue }
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if let q = value.first, q == "\"" || q == "'" {
                // Quoted: up to the matching quote; anything after is a comment.
                let body = value.dropFirst()
                if let end = body.firstIndex(of: q) { value = String(body[..<end]) } else { value = String(body) }
            } else if let hash = value.range(of: "[ \t]#", options: .regularExpression) {
                value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            let home = NSHomeDirectory()
            value = value.replacingOccurrences(of: "${HOME}", with: home)
                         .replacingOccurrences(of: "$HOME", with: home)
            out[key] = value
        }
        return out
    }

    /// Writes `text` to `path` through a temporary file and a rename, so a
    /// reader never sees half of it.
    static func writeAtomically(_ text: String, to path: String) {
        let tmp = path + ".tmp.\(getpid())"
        guard FileManager.default.createFile(atPath: tmp, contents: Data(text.utf8),
                                             attributes: [.posixPermissions: 0o600]) else { return }
        if rename(tmp, path) != 0 { unlink(tmp) }
    }
}
