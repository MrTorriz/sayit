// Corrections.swift - wordlist rules from a correction: the text as you
// fixed it, set against the dictation it came from.
//
// Learn From Selection in Sayit's menu reads the text you selected after
// correcting it, finds the recent dictation it matches, and proposes each
// small replacement (one to three words for one to three words) as a rule
// for you to confirm; bin/sayit-learn writes them. Nothing is read or
// learned unless you ask. What is left out, as the Linux listener this
// replaces did: numbers, changes of case only, single common words, and
// anything that is not a replacement inside the dictation.
//
// Foundation only: mac/tests/CorrectionsTests.swift builds it on its own.

import Foundation

struct Correction: Equatable, Hashable {
    let heard: String
    let right: String
}

enum Corrections {
    /// Words that make no rule on their own: too common to replace everywhere.
    static let common: Set<String> = [
        "och", "att", "det", "som", "en", "ett", "är", "av", "för", "med", "till", "den", "de", "om", "så",
        "men", "har", "inte", "jag", "du", "vi", "ni", "kan", "var", "på", "i", "nu", "då", "här", "där",
        "vad", "när", "hur", "ja", "nej", "eller", "the", "a", "an", "and", "of", "to", "in", "is", "it",
    ]

    /// Longest replacement, in words on either side.
    static let maxWords = 3
    /// Share of words the selection must have in common with a dictation.
    static let minSimilarity = 0.5

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// A word as the wordlist compares it: case aside, punctuation around it aside.
    static func key(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols)).lowercased()
    }

    /// Words joined, without the punctuation at either end of the phrase.
    static func phrase(_ words: ArraySlice<String>) -> String {
        words.joined(separator: " ").trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
    }

    /// Pairs of indices (in a, in b) of a longest common subsequence of keys.
    static func alignment(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let ka = a.map(key), kb = b.map(key)
        let n = ka.count, m = kb.count
        guard n > 0, m > 0 else { return [] }
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = ka[i] == kb[j] && !ka[i].isEmpty ? table[i + 1][j + 1] + 1
                                                               : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n && j < m {
            if ka[i] == kb[j] && !ka[i].isEmpty {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    /// How alike two texts are, 0 to 1: the words in common over the longer.
    static func similarity(_ a: String, _ b: String) -> Double {
        let wa = words(a), wb = words(b)
        guard !wa.isEmpty, !wb.isEmpty else { return 0 }
        return Double(alignment(wa, wb).count) / Double(max(wa.count, wb.count))
    }

    /// The dictation the corrected text came from: the most alike of
    /// `dictations`, the first of equals, if alike enough.
    static func source(of corrected: String, in dictations: [String]) -> Int? {
        var best: (index: Int, score: Double)?
        for (i, d) in dictations.enumerated() {
            let s = similarity(d, corrected)
            if s >= minSimilarity, s > (best?.score ?? 0) { best = (i, s) }
        }
        return best?.index
    }

    /// The replacements that turn `original` into `corrected`, as rules.
    static func propose(original: String, corrected: String) -> [Correction] {
        let a = words(original), b = words(corrected)
        let pairs = alignment(a, b)
        guard !pairs.isEmpty else { return [] }
        var out: [Correction] = []
        var previous = (-1, -1)
        for next in pairs + [(a.count, b.count)] {
            let heardWords = a[(previous.0 + 1)..<next.0], rightWords = b[(previous.1 + 1)..<next.1]
            previous = next
            guard (1...maxWords).contains(heardWords.count), (1...maxWords).contains(rightWords.count) else { continue }
            let heard = phrase(heardWords), right = phrase(rightWords)
            guard heard.count >= 3, !right.isEmpty, heard.lowercased() != right.lowercased(),
                  heard.rangeOfCharacter(from: .decimalDigits) == nil,
                  right.rangeOfCharacter(from: .decimalDigits) == nil,
                  !(heardWords.count == 1 && common.contains(key(heardWords.first ?? ""))) else { continue }
            let rule = Correction(heard: heard, right: right)
            if !out.contains(rule) { out.append(rule) }
        }
        return out
    }
}
