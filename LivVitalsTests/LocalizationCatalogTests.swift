import Foundation
import Testing
@testable import LivVitals

/// Reads `LivVitals/Localizable.xcstrings` itself, so a translation that drifts from its key fails here. The same
/// rules run outside the tests in `scripts/check-strings.py` (`make check-strings`).
struct LocalizationCatalogTests {
    private struct Catalog: Decodable {
        let strings: [String: Entry]
    }

    private struct Entry: Decodable {
        let extractionState: String?
        let localizations: [String: Localization]?
    }

    /// A plain unit, or variations (plural, device) that each hold another localization.
    private struct Localization: Decodable {
        let stringUnit: Unit?
        let variations: [String: [String: Localization]]?
    }

    private struct Unit: Decodable {
        let state: String?
        let value: String?
    }

    /// One translation unit of the catalog, with where it sits.
    private struct Found {
        let key: String
        let locale: String
        let path: [String]
        let unit: Unit

        var label: String { "\(key) [\(locale)\(path.map { " " + $0 }.joined())]" }
        var isPlural: Bool { path.first == "plural" }
    }

    /// Every format specifier. Group 1 is an explicit position (`2` in `%2$@`); group 2 is the type (`lld`, `@`).
    private static let specifier = /%(?:(\d+)\$)?[-+ 0#]*(?:\d+|\*)?(?:\.\d+)?((?:hh|h|ll|l|L|q|z|t|j)?[@dDuUxXoOfeEgGcCsSpaF])/
    private static let count = /%(?:\d+\$)?[-+ 0#]*\d*(?:hh|h|ll|l|L|q|z|t|j)?[dDuUoxX]/
    /// A specifier left in rendered text: nothing in front of the type but an optional position or length.
    private static let rawSpecifier = /%(?:\d+\$)?(?:hh|h|ll|l|L|q|z|t|j)?[@dDuUxXoOfeEgGcCsSpaF]/

    private static func load() throws -> Catalog {
        let file = URL(filePath: #filePath)
            .deletingLastPathComponent() // LivVitalsTests
            .deletingLastPathComponent() // the repository
            .appending(path: "LivVitals/Localizable.xcstrings")
        return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: file))
    }

    private static func found(in catalog: Catalog) -> [Found] {
        catalog.strings.flatMap { key, entry in
            (entry.localizations ?? [:]).flatMap { locale, localization in
                units(localization).map { Found(key: key, locale: locale, path: $0.path, unit: $0.unit) }
            }
        }
    }

    /// Every unit under a localization, through its plural and device variations.
    private static func units(_ localization: Localization, path: [String] = []) -> [(path: [String], unit: Unit)] {
        var result: [(path: [String], unit: Unit)] = []
        if let unit = localization.stringUnit { result.append((path, unit)) }
        for (kind, cases) in localization.variations ?? [:] {
            for (choice, body) in cases {
                result += units(body, path: path + [kind, choice])
            }
        }
        return result
    }

    /// The argument types of a format, in order-free form: `%2$@` and `%@` are both `%@`, so a translation may reorder.
    private static func types(_ text: String) -> [String] {
        text.replacing("%%", with: "").matches(of: specifier).map { "%" + $0.output.2 }.sorted()
    }

    private static func positionsAreComplete(_ text: String) -> Bool {
        let matches = text.replacing("%%", with: "").matches(of: specifier)
        let positions = matches.compactMap { $0.output.1.flatMap { Int($0) } }
        if positions.isEmpty { return true }
        return positions.count == matches.count && Set(positions) == Set(1...matches.count)
    }

    @Test func everyEntryIsCurrentAndEveryTranslationHasText() throws {
        let catalog = try Self.load()
        #expect(catalog.strings.count > 200)
        for (key, entry) in catalog.strings {
            #expect(entry.extractionState != "stale", "\(key) is stale")
        }
        for unit in Self.found(in: catalog) {
            #expect(unit.unit.state != "stale", "\(unit.label) is stale")
            #expect(!(unit.unit.value ?? "").trimmingCharacters(in: .whitespaces).isEmpty, "\(unit.label) is empty")
        }
    }

    @Test func everyVariationUsesTheSpecifiersOfItsKey() throws {
        for unit in Self.found(in: try Self.load()) {
            let value = unit.unit.value ?? ""
            #expect(Self.types(value) == Self.types(unit.key), "\(unit.label) has \(Self.types(value)), its key has \(Self.types(unit.key))")
        }
    }

    @Test func explicitArgumentPositionsAreOneToNAndEachUsed() throws {
        for unit in Self.found(in: try Self.load()) {
            #expect(Self.positionsAreComplete(unit.unit.value ?? ""), "\(unit.label) numbers its arguments unevenly")
        }
    }

    @Test func everyPluralFormShowsItsNumber() throws {
        for unit in Self.found(in: try Self.load()) where unit.isPlural {
            #expect((unit.unit.value ?? "").contains(Self.count), "\(unit.label) does not show its number")
        }
    }

    /// Sample values for a format's arguments, typed as its specifiers say: a string for `%@`, a number otherwise.
    private static func sampleArguments(_ format: String) -> [CVarArg] {
        var byPosition: [Int: CVarArg] = [:]
        for (index, match) in format.replacing("%%", with: "").matches(of: specifier).enumerated() {
            let position = match.output.1.flatMap { Int($0) } ?? index + 1
            let type = match.output.2
            let sample: CVarArg
            if type == "@" {
                sample = NSString(string: "sample")
            } else if type.last.map({ "fFeEgGaA".contains($0) }) == true {
                sample = 2.5
            } else {
                sample = 2
            }
            byPosition[position] = sample
        }
        return (0..<(byPosition.keys.max() ?? 0)).map { byPosition[$0 + 1] ?? 0 }
    }

    @Test func everyStringWithArgumentsRendersWithoutARawSpecifier() throws {
        let catalog = try Self.load()
        for unit in Self.found(in: catalog) where !Self.types(unit.key).isEmpty {
            let format = unit.unit.value ?? unit.key
            let rendered = String(format: format, arguments: Self.sampleArguments(format))
            #expect(rendered.firstMatch(of: Self.rawSpecifier) == nil, "\(unit.label) renders as \(rendered)")
        }
        // Plain (not plural) keys also go through the bundle's own lookup, which is what the app uses for them.
        for (key, entry) in catalog.strings where !Self.types(key).isEmpty && entry.localizations?["en"]?.variations == nil {
            let format = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
            let rendered = String(format: format, arguments: Self.sampleArguments(format))
            #expect(rendered.firstMatch(of: Self.rawSpecifier) == nil, "\(key) renders as \(rendered)")
        }
    }
}
