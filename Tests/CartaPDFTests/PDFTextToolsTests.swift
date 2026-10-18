import AppKit
import PDFKit
import XCTest
@testable import CartaPDF

final class PDFTextToolsTests: XCTestCase {
    @MainActor
    func testNativeWordExportCanBeReadBack() throws {
        let text = "CartaPDF\nUn documento modificabile con accenti: città."
        let data = try PDFTextEngine.wordData(text: text)
        XCTAssertTrue(data.starts(with: [0x50, 0x4B]))
        let reopened = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        XCTAssertTrue(reopened.string.contains("città"))
        XCTAssertTrue(reopened.string.contains("CartaPDF"))
    }

    @MainActor
    func testTextPDFPaginatesAndRetainsSearchableUnicodeText() throws {
        let text = (1...250).map { "Riga \($0): documento di prova, città e qualità." }.joined(separator: "\n")
        let data = try PDFTextEngine.makePDF(from: NSAttributedString(string: text))
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(pdf.pageCount, 2)
        let extracted = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
        XCTAssertTrue(extracted.contains("Riga 250"))
        XCTAssertTrue(extracted.contains("città"))
    }

    @MainActor
    func testBookmarkUndoRedoAndPersistence() throws {
        for encrypted in [false, true] {
            let model = PDFEditorModel()
            let initialPage = try XCTUnwrap(model.currentPage)
            model.addTextAnnotation(text: "Annotazione conservata", at: CGPoint(x: 40, y: 700), on: initialPage)
            model.addFormField(name: "Nome", kind: .text, at: CGPoint(x: 40, y: 600), on: initialPage)
            if encrypted {
                let protected = try XCTUnwrap(PDFDocument(data: model.protectedCopyData(password: "test-segnalibri")))
                XCTAssertTrue(protected.unlock(withPassword: "test-segnalibri"))
                model.replaceDocument(protected, fileName: "Protetto.pdf")
            }
            let originalPage = try XCTUnwrap(model.currentPage)
            model.addBookmark(title: "Capitolo uno")
            XCTAssertEqual(model.document.outlineRoot?.numberOfChildren, 1)
            XCTAssertEqual(model.document.outlineRoot?.child(at: 0)?.label, "Capitolo uno")
            XCTAssertTrue(model.currentPage === originalPage)
            model.undo()
            XCTAssertEqual(model.document.outlineRoot?.numberOfChildren, 0)
            model.redo()
            XCTAssertEqual(model.document.outlineRoot?.child(at: 0)?.label, "Capitolo uno")
            let reopened = try XCTUnwrap(PDFDocument(data: model.serializedData()))
            XCTAssertEqual(reopened.isEncrypted, encrypted)
            if encrypted { XCTAssertTrue(reopened.unlock(withPassword: "test-segnalibri")) }
            XCTAssertEqual(reopened.pageCount, 1)
            XCTAssertEqual(reopened.outlineRoot?.numberOfChildren, 1)
            XCTAssertEqual(reopened.outlineRoot?.child(at: 0)?.label, "Capitolo uno")
            XCTAssertEqual(reopened.outlineRoot?.child(at: 0)?.destination?.page, reopened.page(at: 0))
            XCTAssertEqual(reopened.page(at: 0)?.annotations.first(where: { $0.type == "FreeText" })?.contents, "Annotazione conservata")
            let form = try XCTUnwrap(reopened.page(at: 0)?.annotations.first(where: { $0.fieldName == "Nome" }))
            XCTAssertFalse(form.isReadOnly)
        }
    }
}
