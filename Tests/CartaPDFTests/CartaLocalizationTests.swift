import Foundation
import XCTest
@testable import CartaPDF

final class CartaLocalizationTests: XCTestCase {
    func testOrderedSystemPreferencesRegionalMatchingAndEnglishFallback() {
        XCTAssertEqual(L10n.resolveLanguage(preferredLanguages: []), "en")
        XCTAssertEqual(L10n.resolveLanguage(preferredLanguages: ["ko-KR", "ar-SA"]), "en")
        XCTAssertEqual(L10n.resolveLanguage(preferredLanguages: ["ko-KR", "es-MX", "it-IT"]), "es")
        for language in ["it", "es", "en", "de", "fr", "ja"] {
            XCTAssertEqual(L10n.resolveLanguage(preferredLanguages: ["\(language)-ZZ"]), language)
            XCTAssertEqual(L10n.resolveLanguage(preferredLanguages: [language.uppercased() + "_ZZ"]), language)
        }
        XCTAssertEqual(L10n.language, L10n.resolveLanguage(preferredLanguages: Locale.preferredLanguages))
        XCTAssertEqual(L10n.currentLocale.identifier, Locale(identifier: L10n.language).identifier)
    }

    func testChineseScriptTakesPriorityOverRegion() {
        XCTAssertEqual(L10n.resolveLanguage(preferredLanguages: ["zh"]), "zh-Hans")
        for region in ["CN", "SG", "MY"] {
            XCTAssertEqual(L10n.resolveLanguage(preferredLanguages: ["zh-\(region)"]), "zh-Hans")
        }
        for region in ["TW", "HK", "MO"] {
            XCTAssertEqual(L10n.resolveLanguage(preferredLanguages: ["zh-\(region)"]), "zh-Hant")
        }
        XCTAssertEqual(L10n.resolveLanguage(preferredLanguages: ["zh-Hans-TW"]), "zh-Hans")
        XCTAssertEqual(L10n.resolveLanguage(preferredLanguages: ["zh-Hant-CN"]), "zh-Hant")
        XCTAssertEqual(L10n.resolveLanguage(preferredLanguages: ["ko", "zh_Hant_HK", "en"]), "zh-Hant")
    }

    func testArgumentsCanBeReorderedWithoutEvaluatingUserContents() {
        let userText = "a.pdf {1} %@ %n \"日本語\""
        let message: CartaLocalizedMessage = "Pagina \(7) di \(userText)"
        XCTAssertEqual(message.key, "Pagina {0} di {1}")
        XCTAssertEqual(message.arguments, ["7", userText])
        XCTAssertEqual(L10n.render(message, language: "ja", translations: [message.key: "{1} の {0} ページ"]), "\(userText) の 7 ページ")
        XCTAssertEqual(L10n.substitute("{0} {0} {9} {x} 100%", arguments: ["{1}%@"]), "{1}%@ {1}%@ {9} {x} 100%")
        XCTAssertEqual(L10n.substitute("{99999999999999999999999999999999999}", arguments: ["safe"]), "{99999999999999999999999999999999999}")
    }

    func testSpecifierFormatsOnlyTheValue() {
        let message: CartaLocalizedMessage = "Angolo \(12.5, specifier: "%.1f")°"
        XCTAssertEqual(message.key, "Angolo {0}°")
        XCTAssertEqual(message.arguments, [String(format: "%.1f", locale: L10n.currentLocale, 12.5)])
    }

    func testEnglishFallbackAndUnknownKeysRemainReadable() {
        let cancel: CartaLocalizedMessage = "Annulla"
        XCTAssertEqual(L10n.render(cancel, language: "unsupported"), "Cancel")
        XCTAssertEqual(L10n.render(cancel, language: "it", translations: [:]), "Cancel")
        XCTAssertEqual(L10n.render("Unregistered diagnostic", language: "unsupported"), "Unregistered diagnostic")
    }

    func testAllEightCataloguesArePackagedWithTheSameKeysAndPlaceholders() throws {
        let english = L10n.localizedStrings(for: "en")
        XCTAssertFalse(english.isEmpty, "English localization must be available from built resources")
        for language in L10n.supportedLanguages {
            let catalogue = L10n.localizedStrings(for: language)
            XCTAssertEqual(Set(catalogue.keys), Set(english.keys), "Missing keys for \(language)")
            for (key, value) in catalogue {
                XCTAssertFalse(value.isEmpty, "Empty \(language) value for \(key)")
                XCTAssertEqual(placeholders(key), placeholders(value), "Changed placeholders for \(language): \(key)")
            }
        }
    }

    func testResourceDiscoveryIncludesTestProductsWithoutSearchingAnInstalledAppsNeighbors() {
        let test = URL(fileURLWithPath: "/products/CartaPDFTests.xctest")
        let app = URL(fileURLWithPath: "/Applications/CartaPDF.app")
        XCTAssertTrue(L10n.resourceSearchRoots(bundleURLs: [test], resourceURLs: []).contains(test.deletingLastPathComponent()))
        XCTAssertFalse(L10n.resourceSearchRoots(bundleURLs: [app], resourceURLs: []).contains(app.deletingLastPathComponent()))
        let directories = L10n.localizationDirectories(language: "en", roots: [URL(fileURLWithPath: "/products")])
        XCTAssertTrue(directories.contains(URL(fileURLWithPath: "/products/CartaPDF_CartaPDF.bundle/en.lproj", isDirectory: true)))
        XCTAssertTrue(directories.contains(URL(fileURLWithPath: "/products/CartaPDF_CartaPDF.bundle/Contents/Resources/en.lproj", isDirectory: true)))
        let chinese = L10n.localizationDirectories(language: "zh-Hans", roots: [URL(fileURLWithPath: "/products")])
        XCTAssertTrue(chinese.contains(URL(fileURLWithPath: "/products/CartaPDF_CartaPDF.bundle/zh-hans.lproj", isDirectory: true)))
    }

    private func placeholders(_ value: String) -> Set<String> {
        let expression = try! NSRegularExpression(pattern: "\\{[0-9]+\\}")
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return Set(expression.matches(in: value, range: range).compactMap { Range($0.range, in: value).map { String(value[$0]) } })
    }
}
