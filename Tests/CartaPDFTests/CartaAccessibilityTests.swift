import AppKit
import PDFKit
import XCTest
@testable import CartaPDF

final class CartaAccessibilityTests: XCTestCase {
    func testTabTraversalLeavesDocumentAtBothEndsInsteadOfTrappingFocus() {
        XCTAssertEqual(CartaAnnotationFocusRoute.tab(selected: nil, count: 0, backwards: false), .leaveDocument)
        XCTAssertEqual(CartaAnnotationFocusRoute.tab(selected: nil, count: 3, backwards: false), .select(0))
        XCTAssertEqual(CartaAnnotationFocusRoute.tab(selected: 0, count: 3, backwards: true), .leaveDocument)
        XCTAssertEqual(CartaAnnotationFocusRoute.tab(selected: 2, count: 3, backwards: false), .leaveDocument)
        XCTAssertEqual(CartaAnnotationFocusRoute.tab(selected: nil, count: 3, backwards: true), .select(2))
        XCTAssertEqual(CartaAnnotationFocusRoute.tab(selected: 1, count: 3, backwards: false), .select(2))
    }

    @MainActor
    func testNativeDocumentAccessibilityActionsNavigateActualPages() throws {
        let model = PDFEditorModel()
        model.duplicateCurrentPage()
        model.goToPage(0)
        let view = EditablePDFView(frame: NSRect(x: 0, y: 0, width: 700, height: 800))
        view.editorModel = model; model.attachPDFView(view); view.configureAccessibleActions()
        let actions = try XCTUnwrap(view.accessibilityCustomActions())
        XCTAssertEqual(actions.map(\.name), [L10n.tr("Annotazioni da tastiera"), L10n.tr("Pagina successiva"), L10n.tr("Pagina precedente")])
        XCTAssertTrue(try XCTUnwrap(actions[1].handler)())
        XCTAssertEqual(model.currentPageIndex, 1)
        XCTAssertFalse(try XCTUnwrap(actions[1].handler)())
        XCTAssertTrue(try XCTUnwrap(actions[2].handler)())
        XCTAssertEqual(model.currentPageIndex, 0)
    }

    @MainActor
    func testNativeDialogFieldsExposeTheirLabelsIncludingSecurePasswordFields() throws {
        let name = NSTextField(string: ""), password = NSSecureTextField(string: "")
        _ = PDFEditorModel.formAccessory(labels: ["Titolo del documento", "Password di apertura"], fields: [name, password])
        XCTAssertEqual(name.accessibilityLabel(), "Titolo del documento")
        XCTAssertEqual(password.accessibilityLabel(), "Password di apertura")
    }

    @MainActor
    func testLockedAnnotationsCannotBeChangedByAlternateEditingPaths() throws {
        for flag in [64, 128, 512] {
            let model = PDFEditorModel(), page = try XCTUnwrap(model.currentPage)
            model.addTextAnnotation(text: "Contenuto protetto", at: CGPoint(x: 100, y: 700), on: page)
            let annotation = try XCTUnwrap(page.annotations.first)
            annotation.setValue(NSNumber(value: flag), forAnnotationKey: .flags)
            model.updateAnnotation(annotation, text: "Modifica vietata", on: page)
            model.selectAnnotation(annotation, on: page); model.textFontSize = 48; model.applySelectedTextStyle()
            XCTAssertEqual(annotation.contents, "Contenuto protetto")
            XCTAssertEqual(annotation.font?.pointSize, 18)
            if flag != 512 { model.removeAnnotation(annotation, from: page); XCTAssertTrue(page.annotations.contains { $0 === annotation }) }
            let reopened = try XCTUnwrap(PDFDocument(data: model.serializedData()))
            XCTAssertEqual(reopened.page(at: 0)?.annotations.first?.contents, "Contenuto protetto")
        }
    }
}
