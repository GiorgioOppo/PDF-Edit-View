import AppKit
import PDFKit
import XCTest
@testable import CartaPDF

final class PDFPageToolsTests: XCTestCase {
    @MainActor
    func testPageOperationsPreserveObjectsAndUndoIndividually() throws {
        let model = PDFEditorModel()
        let original = try XCTUnwrap(model.currentPage)
        model.duplicateCurrentPage()
        XCTAssertEqual(model.pageCount, 2)
        let duplicate = try XCTUnwrap(model.currentPage)
        XCTAssertFalse(original === duplicate)
        model.insertBlankPage()
        XCTAssertEqual(model.pageCount, 3)
        let blank = try XCTUnwrap(model.currentPage)
        model.moveCurrentPage(by: -2)
        XCTAssertTrue(model.document.page(at: 0) === blank)
        model.reversePages()
        XCTAssertTrue(model.document.page(at: 0) === duplicate)
        XCTAssertTrue(model.document.page(at: 2) === blank)
        model.undo()
        XCTAssertTrue(model.document.page(at: 0) === blank)
        model.undo()
        XCTAssertTrue(model.document.page(at: 2) === blank)
        model.undo()
        XCTAssertEqual(model.pageCount, 2)
        model.undo()
        XCTAssertEqual(model.pageCount, 1)
        XCTAssertTrue(model.document.page(at: 0) === original)
    }

    @MainActor
    func testCropPersistenceAndUndo() throws {
        let model = PDFEditorModel()
        let page = try XCTUnwrap(model.currentPage)
        let original = page.bounds(for: .cropBox)
        try model.cropCurrentPage(margins: NSEdgeInsets(top: 20, left: 10, bottom: 30, right: 40))
        XCTAssertEqual(page.bounds(for: .cropBox), CGRect(x: 10, y: 30, width: original.width - 50, height: original.height - 50))
        let saved = try XCTUnwrap(PDFDocument(data: model.serializedData()))
        let savedBounds = try XCTUnwrap(saved.page(at: 0)?.bounds(for: .cropBox))
        XCTAssertEqual(savedBounds.minX, page.bounds(for: .cropBox).minX, accuracy: 0.01)
        XCTAssertEqual(savedBounds.minY, page.bounds(for: .cropBox).minY, accuracy: 0.01)
        XCTAssertEqual(savedBounds.width, page.bounds(for: .cropBox).width, accuracy: 0.01)
        XCTAssertEqual(savedBounds.height, page.bounds(for: .cropBox).height, accuracy: 0.01)
        model.undo()
        XCTAssertEqual(page.bounds(for: .cropBox), original)
        XCTAssertThrowsError(try model.cropCurrentPage(margins: NSEdgeInsets(top: 900, left: 0, bottom: 0, right: 0)))
        XCTAssertEqual(page.bounds(for: .cropBox), original)
    }

    @MainActor
    func testExtractionRangeAndPageCopies() throws {
        let model = PDFEditorModel()
        model.insertBlankPage()
        model.insertBlankPage()
        XCTAssertEqual(try PDFEditorModel.parsePageRange("1-2, 3, 2", pageCount: 3), [0, 1, 2])
        XCTAssertThrowsError(try PDFEditorModel.parsePageRange("0, 4", pageCount: 3))
        XCTAssertThrowsError(try PDFEditorModel.parsePageRange("3-1", pageCount: 3))
        let result = try model.extractedDocument(pageIndexes: [2, 0])
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertEqual(model.pageCount, 3)
        XCTAssertFalse(result.page(at: 0) === model.document.page(at: 2))
    }

    @MainActor
    func testFormsPersistOriginalFlagsAndUndoValues() throws {
        let model = PDFEditorModel()
        let page = try XCTUnwrap(model.currentPage)
        model.addFormField(name: "Nome", kind: .text, at: CGPoint(x: 80, y: 700), on: page)
        model.addFormField(name: "Accetto", kind: .checkbox, at: CGPoint(x: 80, y: 650), on: page)
        model.addFormField(name: "Lingua", kind: .choice, at: CGPoint(x: 80, y: 600), on: page, choices: ["Italiano", "English"])
        XCTAssertEqual(model.formFields.count, 3)
        let text = try XCTUnwrap(model.formFields.first(where: { $0.name == "Nome" }))
        let checkbox = try XCTUnwrap(model.formFields.first(where: { $0.name == "Accetto" }))
        let choice = try XCTUnwrap(model.formFields.first(where: { $0.name == "Lingua" }))
        XCTAssertTrue(text.editable)
        XCTAssertTrue(text.annotation.isReadOnly)
        model.setFormValue("Mario", for: text)
        model.setFormValue("true", for: checkbox)
        model.setFormValue("English", for: choice)
        XCTAssertEqual(text.annotation.widgetStringValue, "Mario")
        XCTAssertEqual(checkbox.annotation.buttonWidgetState, .onState)
        XCTAssertEqual(choice.annotation.widgetStringValue, "English")
        let saved = try XCTUnwrap(PDFDocument(data: model.serializedData()))
        let savedText = try XCTUnwrap(saved.page(at: 0)?.annotations.first(where: { $0.fieldName == "Nome" }))
        XCTAssertEqual(savedText.widgetStringValue, "Mario")
        XCTAssertFalse(savedText.isReadOnly)
        XCTAssertEqual(saved.page(at: 0)?.annotations.first(where: { $0.fieldName == "Accetto" })?.buttonWidgetState, .onState)
        model.undo(); model.undo(); model.undo()
        XCTAssertEqual(text.annotation.widgetStringValue ?? "", "")
        XCTAssertEqual(checkbox.annotation.buttonWidgetState, .offState)
        XCTAssertEqual(choice.annotation.widgetStringValue, "Italiano")
        model.redo(); model.redo(); model.redo()
        XCTAssertEqual(text.annotation.widgetStringValue, "Mario")
    }

    @MainActor
    func testReadOnlyFormsCannotBeEdited() throws {
        let source = PDFEditorModel()
        let field = PDFAnnotation(bounds: CGRect(x: 80, y: 80, width: 100, height: 25), forType: .widget, withProperties: nil)
        field.fieldName = "Fisso"
        field.widgetFieldType = .text
        field.widgetStringValue = "Originale"
        field.isReadOnly = true
        source.currentPage?.addAnnotation(field)
        let model = PDFEditorModel()
        model.replaceDocument(source.document, fileName: "Modulo.pdf")
        model.setFormValue("Modificato", for: field)
        XCTAssertEqual(field.widgetStringValue, "Originale")
        XCTAssertFalse(model.canUndo)
    }

    @MainActor
    func testProtectedCopyDoesNotChangeSource() throws {
        let model = PDFEditorModel()
        XCTAssertThrowsError(try model.protectedCopyData(password: ""))
        let data = try model.protectedCopyData(password: "password-test")
        let protected = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertTrue(protected.isLocked)
        XCTAssertFalse(protected.unlock(withPassword: "errata"))
        XCTAssertTrue(protected.unlock(withPassword: "password-test"))
        XCTAssertFalse(model.document.isEncrypted)
        XCTAssertFalse(model.canUndo)
        model.replaceDocument(protected, fileName: "Protetto.pdf")
        let reprotected = try XCTUnwrap(PDFDocument(data: model.protectedCopyData(password: "nuova-password")))
        XCTAssertTrue(reprotected.isLocked)
        XCTAssertFalse(reprotected.unlock(withPassword: "password-test"))
        XCTAssertTrue(reprotected.unlock(withPassword: "nuova-password"))
    }

    @MainActor
    func testDocumentTransformationsRetainUndoHistoryAndFormFlags() throws {
        let model = PDFEditorModel()
        model.rotateCurrentPage()
        let previous = model.document
        let replacement = PDFEditorModel().document
        model.applyDocumentTransformation(replacement, actionName: "Trasforma")
        XCTAssertTrue(model.document === replacement)
        model.undo()
        XCTAssertTrue(model.document === previous)
        XCTAssertEqual(model.currentPage?.rotation, 90)
        model.undo()
        XCTAssertEqual(model.currentPage?.rotation, 0)
        model.redo(); model.redo()
        XCTAssertTrue(model.document === replacement)
    }

    @MainActor
    func testWatermarkAndNumberingEachFormSingleUndoAction() throws {
        let model = PDFEditorModel()
        model.insertBlankPage()
        model.addWatermark(text: "RISERVATO")
        model.addPageNumbers()
        XCTAssertEqual(model.document.page(at: 0)?.annotations.count, 2)
        XCTAssertEqual(model.document.page(at: 1)?.annotations.last?.contents, "2 / 2")
        model.undo()
        XCTAssertEqual(model.document.page(at: 0)?.annotations.count, 1)
        model.undo()
        XCTAssertEqual(model.document.page(at: 0)?.annotations.count, 0)
    }

    @MainActor
    func testSplitCreatesIndividualPDFsAndRefusesOverwrite() throws {
        let model = PDFEditorModel()
        model.fileName = "Documento.pdf"
        model.insertBlankPage()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CartaPDF-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try model.splitPDF(to: directory)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].lastPathComponent, "Documento-001.pdf")
        XCTAssertEqual(PDFDocument(url: files[0])?.pageCount, 1)
        let original = try Data(contentsOf: files[0])
        XCTAssertThrowsError(try model.splitPDF(to: directory))
        XCTAssertEqual(try Data(contentsOf: files[0]), original)
        XCTAssertEqual(model.pageCount, 2)
    }

    @MainActor
    func testBatesNumbersPaddingAndUndo() throws {
        let model = PDFEditorModel()
        model.insertBlankPage()
        try model.addBatesNumbers(prefix: "CASE-", start: 42, padding: 6)
        XCTAssertEqual(model.document.page(at: 0)?.annotations.last?.contents, "CASE-000042")
        XCTAssertEqual(model.document.page(at: 1)?.annotations.last?.contents, "CASE-000043")
        model.undo()
        XCTAssertEqual(model.document.page(at: 0)?.annotations.count, 0)
        model.redo()
        XCTAssertEqual(model.document.page(at: 1)?.annotations.last?.contents, "CASE-000043")
        XCTAssertThrowsError(try model.addBatesNumbers(prefix: "", start: Int.max, padding: 6))
    }
}
