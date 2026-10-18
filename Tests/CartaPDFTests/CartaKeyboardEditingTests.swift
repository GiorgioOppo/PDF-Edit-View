import AppKit
import PDFKit
import XCTest
@testable import CartaPDF

final class CartaKeyboardEditingTests: XCTestCase {
    @MainActor
    func testEveryCreationKindPersistsAndIsOneUndoableDocumentChange() throws {
        for kind in CartaKeyboardAnnotationKind.allCases {
            let owner = PDFWorkspaceDocument(), model = owner.model
            let content = kind == .link ? "https://example.com/percorso" : "Contenuto accessibile"
            let annotation = try model.createKeyboardAnnotation(kind: kind, pageIndex: 0, content: content, bounds: CGRect(x: 40, y: 90, width: 250, height: 70))
            // PDFKit may also insert a Popup companion for a Text annotation.
            XCTAssertEqual(model.currentPage?.annotations.filter { $0.type != "Popup" }.count, 1)
            XCTAssertTrue(owner.isDocumentEdited)
            let saved = try XCTUnwrap(PDFDocument(data: model.serializedData()))
            let reopened = try XCTUnwrap(saved.page(at: 0)?.annotations.first { $0.type == annotation.type })
            XCTAssertEqual(reopened.contents, content)
            XCTAssertEqual(reopened.type, annotation.type)
            if kind == .link { XCTAssertEqual((reopened.action as? PDFActionURL)?.url?.absoluteString, content) }
            model.undo()
            XCTAssertTrue(model.currentPage?.annotations.isEmpty == true)
            XCTAssertFalse(owner.isDocumentEdited)
            model.redo()
            XCTAssertTrue(model.currentPage?.annotations.contains { $0 === annotation } == true)
        }
    }

    @MainActor
    func testControllerEditsSelectedTextNumericallyAndRestoresExactGeometryOnUndo() throws {
        let model = PDFEditorModel()
        let initial = CGRect(x: 40, y: 100, width: 240, height: 60)
        let annotation = try model.createKeyboardAnnotation(kind: .text, pageIndex: 0, content: "Originale", bounds: initial)
        let controller = CartaKeyboardEditingController(model: model)
        XCTAssertEqual(controller.selected?.annotation, annotation)
        XCTAssertTrue(controller.selected?.label.contains("Pagina 1, Testo, Originale") == true)
        controller.x = 140; controller.y = 180; controller.width = 190; controller.height = 90
        controller.applyGeometry()
        XCTAssertNil(controller.error)
        let moved = CGRect(x: 140, y: 180, width: 190, height: 90)
        XCTAssertEqual(annotation.bounds, moved)
        controller.content = "Testo aggiornato da tastiera, con contenuto più lungo."
        controller.applyContent()
        XCTAssertNil(controller.error)
        let reopened = try XCTUnwrap(PDFDocument(data: model.serializedData()))
        let text = try XCTUnwrap(reopened.page(at: 0)?.annotations.first)
        XCTAssertEqual(text.contents, controller.content)
        XCTAssertEqual(text.bounds.minX, moved.minX, accuracy: 0.01)
        XCTAssertEqual(text.bounds.width, moved.width, accuracy: 0.01)
        model.undo()
        XCTAssertEqual(annotation.contents, "Originale")
        XCTAssertEqual(annotation.bounds, moved)
        model.undo()
        XCTAssertEqual(annotation.bounds, initial)
        model.redo(); model.redo()
        XCTAssertTrue(annotation.contents?.contains("aggiornato") == true)
    }

    @MainActor
    func testOwnedLinkSupportsNumericGeometryURLChangeAndDeleteWithIndependentUndo() throws {
        let model = PDFEditorModel()
        let initial = CGRect(x: 30, y: 80, width: 150, height: 30)
        let annotation = try model.createKeyboardAnnotation(kind: .link, pageIndex: 0, content: "https://example.com/prima", bounds: initial)
        let entry = try XCTUnwrap(model.keyboardAnnotationEntries.first)
        let moved = initial.offsetBy(dx: 60, dy: 100)
        try model.setKeyboardAnnotationBounds(moved, for: entry)
        try model.setKeyboardAnnotationContent("https://example.org/seconda", for: entry)
        let saved = try XCTUnwrap(PDFDocument(data: model.serializedData()))
        let link = try XCTUnwrap(saved.page(at: 0)?.annotations.first)
        XCTAssertEqual((link.action as? PDFActionURL)?.url?.absoluteString, "https://example.org/seconda")
        XCTAssertEqual(link.bounds.minX, moved.minX, accuracy: 0.01)
        try model.deleteKeyboardAnnotation(entry)
        XCTAssertTrue(model.keyboardAnnotationEntries.isEmpty)
        model.undo()
        XCTAssertTrue(model.currentPage?.annotations.first === annotation)
        model.undo()
        XCTAssertEqual((annotation.action as? PDFActionURL)?.url?.absoluteString, "https://example.com/prima")
        model.undo()
        XCTAssertEqual(annotation.bounds, initial)
        model.undo()
        XCTAssertTrue(model.keyboardAnnotationEntries.isEmpty)
    }

    @MainActor
    func testProtectedWidgetsForeignLinksAndLockedAnnotationsRemainUnchanged() throws {
        let model = PDFEditorModel(), page = try XCTUnwrap(model.currentPage)
        let foreignLink = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 120, height: 30), forType: .link, withProperties: nil)
        foreignLink.action = PDFActionURL(url: try XCTUnwrap(URL(string: "https://example.com")))
        let widget = PDFAnnotation(bounds: CGRect(x: 20, y: 70, width: 120, height: 30), forType: .widget, withProperties: nil)
        widget.widgetFieldType = .text; widget.fieldName = "Modulo"; widget.widgetStringValue = "Originale"
        let readOnly = PDFAnnotation(bounds: CGRect(x: 20, y: 120, width: 120, height: 30), forType: .text, withProperties: nil)
        readOnly.contents = "Immutabile"; readOnly.setValue(NSNumber(value: 1 << 6), forAnnotationKey: .flags)
        let locked = PDFAnnotation(bounds: CGRect(x: 20, y: 170, width: 120, height: 30), forType: .square, withProperties: nil)
        locked.setValue(NSNumber(value: 1 << 7), forAnnotationKey: .flags)
        [foreignLink, widget, readOnly, locked].forEach(page.addAnnotation)
        let originalAnnotations = Set(page.annotations.map(ObjectIdentifier.init))
        let revision = model.contentRevision
        for entry in model.keyboardAnnotationEntries {
            let original = entry.annotation.bounds
            XCTAssertFalse(model.keyboardCanEdit(entry))
            XCTAssertThrowsError(try model.setKeyboardAnnotationBounds(original.offsetBy(dx: 10, dy: 10), for: entry))
            XCTAssertThrowsError(try model.setKeyboardAnnotationContent("Mutazione vietata", for: entry))
            XCTAssertThrowsError(try model.deleteKeyboardAnnotation(entry))
            XCTAssertEqual(entry.annotation.bounds, original)
        }
        XCTAssertEqual(model.contentRevision, revision)
        XCTAssertEqual(Set(page.annotations.map(ObjectIdentifier.init)), originalAnnotations)
        XCTAssertEqual(widget.widgetStringValue, "Originale")
        XCTAssertFalse(model.canUndo)
    }

    @MainActor
    func testLockedContentsBlocksContentButAllowsGeometryAndDescriptionUndo() throws {
        let model = PDFEditorModel()
        let annotation = try model.createKeyboardAnnotation(kind: .rectangle, pageIndex: 0, content: "Descrizione iniziale", bounds: CGRect(x: 40, y: 80, width: 120, height: 50))
        let entry = try XCTUnwrap(model.keyboardAnnotationEntries.first)
        try model.setKeyboardAnnotationContent("Descrizione accessibile aggiornata", for: entry)
        XCTAssertEqual(annotation.contents, "Descrizione accessibile aggiornata")
        model.undo()
        XCTAssertEqual(annotation.contents, "Descrizione iniziale")
        annotation.setValue(NSNumber(value: (1 << 9) | (1 << 2)), forAnnotationKey: .flags)
        XCTAssertFalse(model.keyboardCanEdit(entry, content: true))
        XCTAssertThrowsError(try model.setKeyboardAnnotationContent("Vietato", for: entry))
        let moved = annotation.bounds.offsetBy(dx: 20, dy: 40)
        try model.setKeyboardAnnotationBounds(moved, for: entry)
        XCTAssertEqual(annotation.bounds, moved)
        XCTAssertEqual(annotation.contents, "Descrizione iniziale")
    }

    @MainActor
    func testFiniteGeometryUsesUnrotatedPDFCoordinatesAndRejectsInvalidCreation() throws {
        let owner = PDFWorkspaceDocument(), model = owner.model, page = try XCTUnwrap(owner.model.currentPage)
        page.setBounds(CGRect(x: 100, y: 200, width: 300, height: 400), for: .cropBox)
        page.rotation = 90
        for values in [(Double.nan, 210.0, 20.0, 30.0), (110.0, Double.infinity, 20.0, 30.0), (110.0, 210.0, -2.0, 30.0), (390.0, 210.0, 30.0, 30.0)] {
            XCTAssertThrowsError(try CartaKeyboardGeometry.rectangle(x: values.0, y: values.1, width: values.2, height: values.3, within: page.bounds(for: .cropBox)))
        }
        XCTAssertThrowsError(try model.createKeyboardAnnotation(kind: .link, pageIndex: 0, content: "file:///private/tmp/test", bounds: CGRect(x: 110, y: 210, width: 100, height: 50)))
        XCTAssertThrowsError(try model.createKeyboardAnnotation(kind: .text, pageIndex: 9, content: "Testo", bounds: CGRect(x: 110, y: 210, width: 100, height: 50)))
        XCTAssertFalse(owner.isDocumentEdited)
        XCTAssertFalse(model.canUndo)
        let annotation = try model.createKeyboardAnnotation(kind: .ellipse, pageIndex: 0, content: "Forma", bounds: CGRect(x: 110, y: 210, width: 100, height: 50))
        let saved = try XCTUnwrap(PDFDocument(data: model.serializedData()))
        XCTAssertEqual(saved.page(at: 0)?.rotation, 90)
        XCTAssertEqual(saved.page(at: 0)?.annotations.first?.bounds.minX ?? 0, 110, accuracy: 0.01)
        XCTAssertEqual(annotation.bounds.minY, 210)
        XCTAssertTrue(CartaKeyboardEditingController(model: model).boundsDescription.contains("90 gradi"))
    }

    @MainActor
    func testRealEncryptedCommentPermissionsProcessingAndStaleSelectionsAreEnforced() throws {
        let source = PDFEditorModel()
        let original = try source.createKeyboardAnnotation(kind: .note, pageIndex: 0, content: "Riservata", bounds: CGRect(x: 40, y: 80, width: 30, height: 30))
        let data = try source.serializedData(options: [PDFDocumentWriteOption.ownerPasswordOption: "proprietario", PDFDocumentWriteOption.userPasswordOption: "lettore", PDFDocumentWriteOption.accessPermissionsOption: NSNumber(value: 0)])
        let protected = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertTrue(protected.unlock(withPassword: "lettore"))
        let restricted = PDFEditorModel(); restricted.replaceDocument(protected, fileName: "Limitato.pdf")
        XCTAssertFalse(restricted.canEditAnnotations)
        let entry = try XCTUnwrap(restricted.keyboardAnnotationEntries.first)
        XCTAssertThrowsError(try restricted.createKeyboardAnnotation(kind: .text, pageIndex: 0, content: "Vietato", bounds: CGRect(x: 100, y: 100, width: 100, height: 30)))
        XCTAssertThrowsError(try restricted.setKeyboardAnnotationContent("Vietato", for: entry))
        XCTAssertThrowsError(try restricted.deleteKeyboardAnnotation(entry))
        XCTAssertEqual(entry.annotation.contents, "Riservata")
        let old = try XCTUnwrap(source.keyboardAnnotationEntries.first)
        source.isProcessing = true
        XCTAssertThrowsError(try source.setKeyboardAnnotationBounds(original.bounds.offsetBy(dx: 10, dy: 0), for: old))
        source.isProcessing = false
        let controller = CartaKeyboardEditingController(model: source)
        source.replaceDocument(PDFEditorModel().document, fileName: "Altro.pdf")
        controller.synchronizeSelection()
        XCTAssertNil(controller.selectedID)
        XCTAssertThrowsError(try source.deleteKeyboardAnnotation(old))
        XCTAssertEqual(original.contents, "Riservata")
        XCTAssertTrue(source.currentPage?.annotations.isEmpty == true)
    }
}
