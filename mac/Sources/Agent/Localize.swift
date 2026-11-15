// Localize.swift - Sayit speaks the Mac's language where it has a
// translation: Contents/Resources/<language>.lproj/Localizable.strings, built
// from mac/Resources. The English text is the key, so English needs no table
// and a string without a translation stays English.
//
// SwiftUI looks a literal Text("...") up by itself; everything built in code
// (menu titles, figures with their units, labels chosen at run time) goes
// through L(). Dates and month names follow the same language (statsLocale).

import Foundation

/// The language the app shows: the first of the user's languages that it has
/// a translation for, else English.
let appLanguage = Bundle.main.preferredLocalizations.first ?? "en"

/// `key` in the app's language.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// A format in the app's language, filled in: L("%@ words", "1 204").
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}
