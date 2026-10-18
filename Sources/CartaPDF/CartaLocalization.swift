import Foundation

/// A translation key plus inert argument values. Arguments are substituted in
/// one pass after lookup: user text is never interpreted as a format string.
struct CartaLocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let key: String
    let arguments: [String]

    init(stringLiteral value: String) {
        key = value
        arguments = []
    }

    init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    struct StringInterpolation: StringInterpolationProtocol {
        fileprivate var key: String
        fileprivate var arguments: [String]

        init(literalCapacity: Int, interpolationCount: Int) {
            key = ""
            key.reserveCapacity(literalCapacity + interpolationCount * 3)
            arguments = []
            arguments.reserveCapacity(interpolationCount)
        }

        mutating func appendLiteral(_ literal: String) { key += literal }

        mutating func appendInterpolation<Value>(_ value: Value) {
            appendArgument(String(describing: value))
        }

        mutating func appendInterpolation<Value: CVarArg>(_ value: Value, specifier: String) {
            appendArgument(String(format: specifier, locale: L10n.currentLocale, arguments: [value]))
        }

        private mutating func appendArgument(_ value: String) {
            key += "{\(arguments.count)}"
            arguments.append(value)
        }
    }
}

/// App language follows the ordered system/per-app language preferences at
/// launch. It never changes AppleLanguages or any other system preference.
enum L10n {
    static let supportedLanguages = ["en", "it", "es", "de", "fr", "zh-Hans", "zh-Hant", "ja"]
    static let language = resolveLanguage(preferredLanguages: Locale.preferredLanguages)
    static let currentLocale = Locale(identifier: language)

    static func tr(_ message: CartaLocalizedMessage) -> String {
        render(message, language: language)
    }

    /// Use for an explicit internal display key held by an enum or model.
    /// Document contents, identifiers and user-entered strings are not keys.
    static func string(_ key: String) -> String {
        tr(CartaLocalizedMessage(stringLiteral: key))
    }

    static func resolveLanguage(preferredLanguages: [String]) -> String {
        for preference in preferredLanguages {
            let parts = preference.replacingOccurrences(of: "_", with: "-")
                .lowercased().split(separator: "-").map(String.init)
            guard let base = parts.first else { continue }
            if base == "zh" {
                if parts.contains("hant") { return "zh-Hant" }
                if parts.contains("hans") { return "zh-Hans" }
                return parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) ? "zh-Hant" : "zh-Hans"
            }
            if ["en", "it", "es", "de", "fr", "ja"].contains(base) { return base }
        }
        return "en"
    }

    static func render(_ message: CartaLocalizedMessage, language: String,
                       translations: [String: String]? = nil) -> String {
        let dictionary = translations ?? localizedStrings(for: language)
        let template = dictionary[message.key] ?? localizedStrings(for: "en")[message.key] ?? message.key
        return substitute(template, arguments: message.arguments)
    }

    /// Numbered placeholders allow translators to reorder arguments. A single
    /// pass prevents braces or percent signs inside user values being evaluated.
    static func substitute(_ template: String, arguments: [String]) -> String {
        var result = ""
        var cursor = template.startIndex
        while cursor < template.endIndex {
            if template[cursor] == "{", let end = template[cursor...].firstIndex(of: "}") {
                let digits = template[template.index(after: cursor)..<end]
                if !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                   let index = Int(digits), arguments.indices.contains(index) {
                    result += arguments[index]
                    cursor = template.index(after: end)
                    continue
                }
            }
            result.append(template[cursor])
            cursor = template.index(after: cursor)
        }
        return result
    }

    static func localizedStrings(for language: String) -> [String: String] {
        catalogues[language] ?? [:]
    }

    private static let catalogues: [String: [String: String]] = {
        let roots = resourceSearchRoots()
        var result: [String: [String: String]] = [:]
        for language in supportedLanguages {
            for directory in localizationDirectories(language: language, roots: roots) {
                let url = directory.appendingPathComponent("Localizable.strings")
                guard let data = try? Data(contentsOf: url),
                      let strings = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String],
                      !strings.isEmpty else { continue }
                result[language] = strings
                break
            }
        }
        return result
    }()

    static func resourceSearchRoots(bundleURLs: [URL]? = nil, resourceURLs: [URL]? = nil) -> [URL] {
        let locator = Bundle(for: CartaLocalizationBundleLocator.self)
        let bundles = bundleURLs ?? [Bundle.main.bundleURL, locator.bundleURL]
        let resources = resourceURLs ?? [Bundle.main.resourceURL, locator.resourceURL].compactMap { $0 }
        // XCTest's product and resources are siblings. Installed applications
        // deliberately do not search sibling directories or the working dir.
        var roots = resources + bundles + bundles.filter { $0.pathExtension == "xctest" }.map { $0.deletingLastPathComponent() }
        #if DEBUG
        if bundleURLs == nil && resourceURLs == nil,
           let path = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"] ?? ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_URL"] {
            roots.insert(URL(fileURLWithPath: path), at: 0)
        }
        #endif
        var seen = Set<URL>()
        return roots.filter { seen.insert($0.standardizedFileURL).inserted }
    }

    static func localizationDirectories(language: String, roots: [URL]) -> [URL] {
        // SwiftPM has used both flat bundles and Contents/Resources bundles.
        // Raw URLs avoid the fatal generated Bundle.module accessor.
        roots.flatMap { root -> [URL] in
            let package = root.appendingPathComponent("CartaPDF_CartaPDF.bundle", isDirectory: true)
            return [root, root.appendingPathComponent("Contents/Resources", isDirectory: true),
                    package, package.appendingPathComponent("Contents/Resources", isDirectory: true)]
                .flatMap { base in
                    // Some SwiftPM versions normalize script subtags to lower
                    // case. Both layouts work on case-sensitive APFS volumes.
                    [language, language.lowercased()].flatMap { code in
                        [base.appendingPathComponent("\(code).lproj", isDirectory: true),
                         base.appendingPathComponent("Localization/\(code).lproj", isDirectory: true)]
                    }
                }
        }
    }
}

private final class CartaLocalizationBundleLocator: NSObject {}
