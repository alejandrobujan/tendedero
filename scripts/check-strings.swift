// Checks the translations: every L("...") in the code has an entry in each
// language, and no language keeps entries the code no longer uses.
// Usage: swift scripts/check-strings.swift
import Foundation

let sources = URL(fileURLWithPath: "Sources/Tendedero")
let resources = sources.appendingPathComponent("Resources")
let fm = FileManager.default

// Every L("...") call. A call that is not a plain string literal cannot be
// checked, so it is reported too.
var used = Set<String>()
var problems: [String] = []
let literal = try NSRegularExpression(pattern: #"\bL\(\s*"((?:[^"\\]|\\.)*)"\s*\)"#)
let anyCall = try NSRegularExpression(pattern: #"\bL\("#)
for case let file as URL in fm.enumerator(at: sources, includingPropertiesForKeys: nil)!
where file.pathExtension == "swift" && file.lastPathComponent != "Localization.swift" {
    let text = try String(contentsOf: file, encoding: .utf8)
    let range = NSRange(text.startIndex..., in: text)
    let literals = literal.matches(in: text, range: range)
    for match in literals {
        let key = String(text[Range(match.range(at: 1), in: text)!])
        used.insert(key.replacingOccurrences(of: #"\""#, with: #"""#))
    }
    let calls = anyCall.numberOfMatches(in: text, range: range)
    if calls != literals.count {
        problems.append("\(file.lastPathComponent): \(calls - literals.count) L(...) call(s) without a plain string")
    }
}

let languages = try fm.contentsOfDirectory(atPath: resources.path)
    .filter { $0.hasSuffix(".lproj") }.sorted()
for folder in languages {
    let url = resources.appendingPathComponent(folder).appendingPathComponent("Localizable.strings")
    guard let table = NSDictionary(contentsOf: url) as? [String: String] else {
        problems.append("\(folder): Localizable.strings is missing or cannot be read")
        continue
    }
    let keys = Set(table.keys)
    for key in used.subtracting(keys).sorted() { problems.append("\(folder): missing \"\(key)\"") }
    for key in keys.subtracting(used).sorted() { problems.append("\(folder): unused \"\(key)\"") }
}

if problems.isEmpty {
    print("\(used.count) strings, all present in \(languages.map { $0.replacingOccurrences(of: ".lproj", with: "") }.joined(separator: ", "))")
} else {
    problems.forEach { print($0) }
    exit(1)
}
