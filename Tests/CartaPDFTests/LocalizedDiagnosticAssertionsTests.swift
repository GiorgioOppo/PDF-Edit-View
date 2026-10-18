import Foundation
import XCTest
@testable import CartaPDF

final class LocalizedDiagnosticAssertionsTests: XCTestCase {
    func testTranslatedDiagnosticFamilyMatchesWithoutAcceptingUnrelatedMessages() {
        XCTAssertTrue(diagnosticContains(L10n.tr("inventario dati font Adobe modificato"), "inventario dati font Adobe modificato"))
        XCTAssertFalse(diagnosticContains(L10n.tr("Nessuna pagina disponibile."), "inventario dati font Adobe modificato"))
        XCTAssertFalse(diagnosticContains("anything", ""))
        let created = L10n.tr("Creato \("uno.txt")")
        XCTAssertTrue(diagnosticHasPrefix(created, "Creato "))
        XCTAssertFalse(diagnosticHasPrefix("unrelated prefix " + created, "Creato "))
    }

    func testTemplatesEscapeRegexSyntaxAndKeepUserArgumentsInert() throws {
        let expression = try XCTUnwrap(diagnosticTemplateExpression("a+b[0]. {1} / {0}"))
        let rendered = "a+b[0]. user {2} %@ .*\ntext / 7"
        XCTAssertNotNil(expression.firstMatch(in: rendered, range: NSRange(rendered.startIndex..<rendered.endIndex, in: rendered)))
        let unrelated = "aaab0X unrelated"
        XCTAssertNil(expression.firstMatch(in: unrelated, range: NSRange(unrelated.startIndex..<unrelated.endIndex, in: unrelated)))
        XCTAssertNil(diagnosticTemplateExpression("{0} {1}"))
    }
}
