// CorrectionsTests.swift - unit tests for the rules Learn From Selection
// proposes: which replacements count, and which dictation a correction is
// matched to. Built and run by mac/tests/run.sh with Corrections.swift alone.

import Foundation

@main
enum CorrectionsTests {
    static var checks = 0
    static var failures = 0

    static func check(_ ok: Bool, _ what: String, line: Int = #line) {
        checks += 1
        if !ok {
            failures += 1
            print("FAIL CorrectionsTests.swift:\(line): \(what)")
        }
    }

    static func main() {
        let dictated = "Jag kör kubernetis och jason i git hub varje dag."
        let fixed = "Jag kör Kubernetes och JSON i GitHub varje dag."
        let rules = Corrections.propose(original: dictated, corrected: fixed)
        check(rules == [Correction(heard: "kubernetis", right: "Kubernetes"), Correction(heard: "jason", right: "JSON"),
                        Correction(heard: "git hub", right: "GitHub")], "three replacements, got \(rules)")

        check(Corrections.propose(original: "Hej Kalle.", corrected: "hej kalle").isEmpty, "case and punctuation only")
        check(Corrections.propose(original: "Det kostar fem kronor", corrected: "Det kostar 5 kronor").isEmpty,
              "numbers are left out")
        check(Corrections.propose(original: "jag och du", corrected: "jag eller du").isEmpty,
              "a single common word is left out")
        check(Corrections.propose(original: "ett två tre fyra fem sex", corrected: "ett sju åtta nio tio elva").isEmpty,
              "a rewrite of more than three words is left out")
        check(Corrections.propose(original: "skriv det här", corrected: "skriv det här nu direkt").isEmpty,
              "an addition is no replacement")
        check(Corrections.propose(original: "", corrected: "något").isEmpty, "nothing dictated, nothing learned")
        let first = Corrections.propose(original: "kubernetis är bra", corrected: "Kubernetes är bra")
        check(first == [Correction(heard: "kubernetis", right: "Kubernetes")], "the first word can be corrected, got \(first)")
        let last = Corrections.propose(original: "vi använder jason", corrected: "vi använder JSON.")
        check(last == [Correction(heard: "jason", right: "JSON")], "and the last, its full stop aside, got \(last)")
        let twice = Corrections.propose(original: "jason och mer jason", corrected: "JSON och mer JSON")
        check(twice.count == 1, "the same rule once")

        let dictations = ["Helt annan text om väder och vind.", dictated, "Kort."]
        check(Corrections.source(of: fixed, in: dictations) == 1, "the matching dictation is found")
        check(Corrections.source(of: "Något helt annat som inte sades", in: dictations) == nil, "no match, no source")
        check(Corrections.similarity("a b c d", "a b c d") == 1, "the same text is fully alike")

        print("CorrectionsTests: \(checks - failures) of \(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
