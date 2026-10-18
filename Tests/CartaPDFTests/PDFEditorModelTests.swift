import AppKit
import PDFKit
import XCTest
@testable import CartaPDF

final class PDFEditorModelTests: XCTestCase {
    @MainActor
    func testNewDocumentHasPrintableA4PageAndRoundTrips() throws {
        let model = PDFEditorModel()
        XCTAssertEqual(model.pageCount, 1)
        let page = try XCTUnwrap(model.currentPage)
        XCTAssertEqual(page.bounds(for: .mediaBox).width, 595.276, accuracy: 0.01)
        XCTAssertEqual(page.bounds(for: .mediaBox).height, 841.89, accuracy: 0.01)
        let reopened = try XCTUnwrap(PDFDocument(data: model.serializedData()))
        XCTAssertEqual(reopened.pageCount, 1)
    }

    @MainActor
    func testTextAndInkAnnotationsPersistAndSupportUndoRedo() throws {
        let model = PDFEditorModel()
        let page = try XCTUnwrap(model.currentPage)
        model.addTextAnnotation(text: "Testo aggiunto", at: CGPoint(x: 70, y: 700), on: page)
        XCTAssertEqual(page.annotations.count, 1)
        XCTAssertEqual(page.annotations.first?.contents, "Testo aggiunto")
        model.addInkAnnotation(points: [CGPoint(x: 20, y: 30), CGPoint(x: 60, y: 90)], on: page)
        XCTAssertEqual(page.annotations.count, 2)
        let ink = try XCTUnwrap(page.annotations.last)
        XCTAssertEqual(ink.type, "Ink")
        XCTAssertGreaterThan(ink.bounds.width, 40)
        let reopened = try XCTUnwrap(PDFDocument(data: model.serializedData()))
        XCTAssertEqual(reopened.page(at: 0)?.annotations.count, 2)
        model.undo()
        XCTAssertEqual(page.annotations.count, 1)
        model.undo()
        XCTAssertEqual(page.annotations.count, 0)
        model.redo()
        model.redo()
        XCTAssertEqual(page.annotations.count, 2)
    }

    @MainActor
    func testAnnotationEditingAndRemovalUndoIndividually() throws {
        let model = PDFEditorModel()
        let page = try XCTUnwrap(model.currentPage)
        model.addNote(text: "Originale", at: CGPoint(x: 70, y: 700), on: page)
        let note = try XCTUnwrap(page.annotations.first)
        model.updateAnnotation(note, text: "Modificata", on: page)
        XCTAssertEqual(note.contents, "Modificata")
        model.removeAnnotation(note, from: page)
        XCTAssertTrue(page.annotations.isEmpty)
        model.undo()
        XCTAssertTrue(page.annotations.first === note)
        model.undo()
        XCTAssertEqual(note.contents, "Originale")
        model.redo()
        XCTAssertEqual(note.contents, "Modificata")
    }

    @MainActor
    func testImportCopiesPagesAndPreservesPageOwnershipThroughUndo() throws {
        let model = PDFEditorModel()
        let source = PDFEditorModel()
        let sourcePage = try XCTUnwrap(source.currentPage)
        sourcePage.rotation = 90
        source.addNote(text: "Nota sorgente", at: CGPoint(x: 80, y: 700), on: sourcePage)
        try model.insertPages(from: source.document)
        XCTAssertEqual(model.pageCount, 2)
        let inserted = try XCTUnwrap(model.document.page(at: 1))
        XCTAssertFalse(inserted === sourcePage)
        XCTAssertTrue(sourcePage.document === source.document)
        XCTAssertEqual(inserted.rotation, 90)
        model.rotateCurrentPage()
        XCTAssertEqual(inserted.rotation, 180)
        XCTAssertEqual(sourcePage.rotation, 90)
        let importedNote = try XCTUnwrap(inserted.annotations.first)
        model.updateAnnotation(importedNote, text: "Nota inserita", on: inserted)
        XCTAssertEqual(sourcePage.annotations.first?.contents, "Nota sorgente")
        model.undo()
        XCTAssertEqual(importedNote.contents, "Nota sorgente")
        model.undo()
        XCTAssertEqual(inserted.rotation, 90)
        model.undo()
        XCTAssertEqual(model.pageCount, 1)
        model.redo()
        XCTAssertEqual(model.pageCount, 2)
        XCTAssertTrue(model.document.page(at: 1) === inserted)
        model.goToPage(1)
        model.deleteCurrentPage()
        XCTAssertEqual(model.pageCount, 1)
        model.undo()
        XCTAssertTrue(model.document.page(at: 1) === inserted)
    }

    @MainActor
    func testFreeTextResizeAndUndoRestoreOriginalBounds() throws {
        let model = PDFEditorModel()
        let page = try XCTUnwrap(model.currentPage)
        model.addTextAnnotation(text: "Breve", at: CGPoint(x: 80, y: 700), on: page)
        let text = try XCTUnwrap(page.annotations.first)
        let originalBounds = text.bounds
        model.updateAnnotation(text, text: Array(repeating: "Una riga di testo più lunga.", count: 18).joined(separator: "\n"), on: page)
        XCTAssertGreaterThan(text.bounds.height, originalBounds.height)
        model.undo()
        XCTAssertEqual(text.bounds, originalBounds)
        XCTAssertEqual(text.contents, "Breve")
    }

    @MainActor
    func testLastPageCannotBeDeletedAndNavigationClamps() {
        let model = PDFEditorModel()
        model.deleteCurrentPage()
        XCTAssertEqual(model.pageCount, 1)
        XCTAssertFalse(model.canUndo)
        model.goToPage(-1)
        model.goToPage(99)
        model.nextPage()
        XCTAssertEqual(model.currentPageIndex, 0)
        model.zoomOut()
        XCTAssertFalse(model.autoScales)
        model.actualSize()
        XCTAssertEqual(model.scale, 1)
        model.fitToWindow()
        XCTAssertTrue(model.autoScales)
    }

    @MainActor
    func testNativeWidgetLockDoesNotChangeSavedReadOnlyFlag() throws {
        let model = PDFEditorModel()
        let source = PDFEditorModel()
        let page = try XCTUnwrap(source.currentPage)
        let widget = PDFAnnotation(bounds: CGRect(x: 40, y: 40, width: 100, height: 30), forType: .widget, withProperties: nil)
        widget.widgetFieldType = .text
        widget.fieldName = "Nome"
        widget.widgetStringValue = "Esempio"
        widget.isReadOnly = false
        page.addAnnotation(widget)
        model.replaceDocument(source.document, fileName: "Campi.pdf")
        XCTAssertTrue(widget.isReadOnly)
        let reopened = try XCTUnwrap(PDFDocument(data: model.serializedData()))
        let savedWidget = try XCTUnwrap(reopened.page(at: 0)?.annotations.first)
        XCTAssertFalse(savedWidget.isReadOnly)
        XCTAssertEqual(savedWidget.widgetStringValue, "Esempio")
        XCTAssertTrue(widget.isReadOnly)
    }

    @MainActor
    func testEncryptedPDFRoundTripPreservesPasswordProtection() throws {
        let initial = PDFEditorModel()
        let encryptedData = try XCTUnwrap(initial.document.dataRepresentation(options: [
            PDFDocumentWriteOption.ownerPasswordOption: "proprietario",
            PDFDocumentWriteOption.userPasswordOption: "lettore"
        ]))
        let encrypted = try XCTUnwrap(PDFDocument(data: encryptedData))
        XCTAssertTrue(encrypted.isLocked)
        XCTAssertTrue(encrypted.unlock(withPassword: "lettore"))
        let model = PDFEditorModel()
        model.replaceDocument(encrypted, fileName: "Protetto.pdf")
        let reopened = try XCTUnwrap(PDFDocument(data: model.serializedData()))
        XCTAssertTrue(reopened.isEncrypted)
        XCTAssertTrue(reopened.isLocked)
        XCTAssertTrue(reopened.unlock(withPassword: "lettore"))
    }

    @MainActor
    func testDocumentBecomesDirtyAndReturnsCleanAfterUndo() throws {
        let document = PDFWorkspaceDocument()
        XCTAssertFalse(document.isDocumentEdited)
        document.model.rotateCurrentPage()
        XCTAssertTrue(document.isDocumentEdited)
        document.model.undo()
        XCTAssertFalse(document.isDocumentEdited)
        document.model.redo()
        XCTAssertTrue(document.isDocumentEdited)
        XCTAssertFalse(try document.data(ofType: "com.adobe.pdf").isEmpty)
    }
}
