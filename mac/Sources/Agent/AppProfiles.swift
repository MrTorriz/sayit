// AppProfiles.swift - settings of an app's own: dictating into Terminal can
// expect other words, or another language, than dictating into Mail.
//
// One small file per app, ~/.config/sayit/apps/<bundle id>.env, with its
// name on a comment line and only what differs from .env: SPEECH_LANGUAGE,
// INITIAL_PROMPT, SPOKEN_PUNCTUATION. When a recording starts, Runner passes
// the file of the app in front as SAYIT_APP_PROFILE, and sayit-transcribe
// reads it after .env. Written as .env is (EnvFile.swift), so bash reads the
// values back literally.

import AppKit
import Combine
import SwiftUI

struct AppProfile: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let values: [String: String]
    var id: String { bundleID }
}

final class AppProfileStore: ObservableObject {
    /// The keys a profile may set.
    static let keys = ["SPEECH_LANGUAGE", "INITIAL_PROMPT", "SPOKEN_PUNCTUATION"]

    static var directory: String { (Shared.configDir as NSString).appendingPathComponent("apps") }

    /// The profile file for an app, whether or not it exists; nil for an
    /// identifier that is no safe file name.
    static func path(for bundleID: String) -> String? {
        guard bundleID.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil else { return nil }
        return (directory as NSString).appendingPathComponent(bundleID + ".env")
    }

    /// The profile to pass for the app in front, if it has one.
    static func activePath() -> String? {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let path = path(for: id), FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    @Published private(set) var profiles: [AppProfile] = []
    @Published private var drafts: [String: String] = [:]
    private var pending: [String: DispatchWorkItem] = [:]

    init() { reload() }

    func reload() {
        let dir = Self.directory
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        profiles = files.filter { $0.hasSuffix(".env") }.compactMap { file in
            let path = (dir as NSString).appendingPathComponent(file)
            let id = String(file.dropLast(4))
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let first = text.components(separatedBy: "\n").first ?? ""
            let name = first.hasPrefix("# ") ? String(first.dropFirst(2)) : id
            return AppProfile(bundleID: id, name: name, values: Shared.readEnv(path))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Running apps with windows that have no profile yet, Sayit left out.
    var candidates: [(id: String, name: String)] {
        let have = Set(profiles.map(\.bundleID))
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                  !have.contains(id), seen.insert(id).inserted, Self.path(for: id) != nil else { return nil }
            return (id, app.localizedName ?? id)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func add(_ bundleID: String, name: String) {
        guard let path = Self.path(for: bundleID), !FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.createDirectory(atPath: Self.directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let header = "# " + name.components(separatedBy: .newlines).joined(separator: " ") + "\n"
        FileManager.default.createFile(atPath: path, contents: Data(header.utf8),
                                       attributes: [.posixPermissions: 0o600])
        reload()
    }

    /// Removed at the user's word, from the Settings window.
    func remove(_ bundleID: String) {
        guard let path = Self.path(for: bundleID) else { return }
        try? FileManager.default.removeItem(atPath: path)
        reload()
    }

    /// A value, the empty string meaning "as in .env": the key goes.
    func set(_ bundleID: String, _ key: String, _ rendered: String?) {
        guard Self.keys.contains(key), let path = Self.path(for: bundleID) else { return }
        try? EnvFile.write([(key: key, rendered: rendered)], path: path)
        reload()
    }

    func value(_ bundleID: String, _ key: String) -> String {
        profiles.first { $0.bundleID == bundleID }?.values[key] ?? ""
    }

    /// A choice from a list; "" removes the key.
    func choice(_ bundleID: String, _ key: String) -> Binding<String> {
        Binding(get: { self.value(bundleID, key) },
                set: { self.set(bundleID, key, $0.isEmpty ? nil : EnvFile.render($0, plain: true)) })
    }

    /// Typed text, written once typing pauses; empty removes the key.
    func text(_ bundleID: String, _ key: String) -> Binding<String> {
        let draftKey = bundleID + "/" + key
        return Binding(get: { self.drafts[draftKey] ?? self.value(bundleID, key) },
                       set: { value in
                           self.drafts[draftKey] = value
                           self.pending[draftKey]?.cancel()
                           // The store lives as long as the Settings window.
                           let work = DispatchWorkItem {
                               self.pending[draftKey] = nil
                               self.set(bundleID, key, value.isEmpty ? nil : EnvFile.render(value))
                               self.drafts[draftKey] = nil
                           }
                           self.pending[draftKey] = work
                           DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
                       })
    }

    func flush() {
        for (_, work) in pending { work.perform(); work.cancel() }
        pending.removeAll()
    }

    static func icon(_ bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
