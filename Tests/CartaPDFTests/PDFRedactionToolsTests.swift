import AppKit
import PDFKit
import XCTest
@testable import CartaPDF

final class PDFRedactionToolsTests: XCTestCase {
    @MainActor
    func testRedactionOutputContainsOnlyRasterPixelsAndNoOriginalTextMetadataOrAnnotations() throws {
        let source = try makeSource()
        source.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Titolo segreto originale"]
        let page = try XCTUnwrap(source.page(at: 0))
        let note = PDFAnnotation(bounds: CGRect(x: 210, y: 220, width: 20, height: 20), forType: .text, withProperties: nil)
        note.contents = "Nota privata da non conservare"
        page.addAnnotation(note)
        XCTAssertTrue((source.string ?? "").contains("SEGRETO"))
        let sanitized = try PDFRasterSanitizer.sanitizedDocument(source, regions: [PDFRedactionRegion(pageIndex: 0, bounds: CGRect(x: 30, y: 40, width: 90, height: 35))], dpi: 72)
        let data = try XCTUnwrap(sanitized.dataRepresentation())
        let reopened = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(reopened.pageCount, 1)
        XCTAssertTrue((reopened.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(reopened.findString("SEGRETO", withOptions: []).isEmpty)
        XCTAssertTrue(try XCTUnwrap(reopened.page(at: 0)).annotations.isEmpty)
        XCTAssertNotEqual(reopened.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Titolo segreto originale")
        XCTAssertEqual(page.annotations.first?.contents, "Nota privata da non conservare")
        XCTAssertTrue((source.string ?? "").contains("SEGRETO"))
    }

    @MainActor
    func testMasksCoverTheSelectedSourcePixelsForEveryRotationAndNonzeroCropOrigin() throws {
        for rotation in [0, 90, 180, 270] {
            let source = try makeSource()
            let page = try XCTUnwrap(source.page(at: 0))
            page.setBounds(CGRect(x: 20, y: 30, width: 220, height: 160), for: .cropBox)
            page.rotation = rotation
            let selected = CGRect(x: 45, y: 55, width: 50, height: 40)
            let baseline = try PDFRasterSanitizer.renderedImage(page, masks: [], dpi: 72)
            let masked = try PDFRasterSanitizer.renderedImage(page, masks: [selected], dpi: 72)
            let transform = page.transform(for: .cropBox)
            let displayBounds = page.bounds(for: .cropBox).applying(transform)
            let target = selected.applying(transform).offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)
            let center = CGPoint(x: target.midX, y: target.midY)
            let before = try pixel(baseline.image, x: Int(center.x), y: Int(center.y))
            let after = try pixel(masked.image, x: Int(center.x), y: Int(center.y))
            XCTAssertGreaterThan(before.blue, 150, "rotation \(rotation) source region should be blue")
            XCTAssertLessThan(before.red, 60)
            XCTAssertLessThan(after.red, 5, "rotation \(rotation)")
            XCTAssertLessThan(after.green, 5)
            XCTAssertLessThan(after.blue, 5)
            for testPoint in [CGPoint(x: target.minX + 1, y: target.minY + 1),
                              CGPoint(x: target.maxX - 1, y: target.minY + 1),
                              CGPoint(x: target.minX + 1, y: target.maxY - 1),
                              CGPoint(x: target.maxX - 1, y: target.maxY - 1)] {
                let corner = try pixel(masked.image, x: Int(testPoint.x), y: Int(testPoint.y))
                XCTAssertLessThan(corner.red + corner.green + corner.blue, 15, "mask corner rotation \(rotation)")
            }
            let untouchedPoint = CGPoint(x: 110, y: 90).applying(transform)
            let untouched = try pixel(masked.image, x: Int(untouchedPoint.x - displayBounds.minX),
                                      y: Int(untouchedPoint.y - displayBounds.minY))
            XCTAssertGreaterThan(untouched.blue, 150)
            XCTAssertLessThan(untouched.red, 60)
            let output = try PDFRasterSanitizer.sanitizedDocument(source, regions: [PDFRedactionRegion(pageIndex: 0, bounds: selected)], dpi: 72)
            let outputPage = try XCTUnwrap(output.page(at: 0))
            XCTAssertEqual(outputPage.rotation, 0)
            XCTAssertEqual(outputPage.bounds(for: .mediaBox).width, displayBounds.width, accuracy: 0.01)
            XCTAssertEqual(outputPage.bounds(for: .mediaBox).height, displayBounds.height, accuracy: 0.01)
            let outputRaster = try PDFRasterSanitizer.renderedImage(outputPage, masks: [], dpi: 72)
            let exported = try pixel(outputRaster.image, x: Int(center.x), y: Int(center.y))
            XCTAssertLessThan(exported.red, 5)
            XCTAssertLessThan(exported.green, 5)
            XCTAssertLessThan(exported.blue, 5)
        }
    }

    @MainActor
    func testRedactionClipsMasksToCropAndRejectsAbsentOrInvalidAreas() throws {
        let source = try makeSource()
        let page = try XCTUnwrap(source.page(at: 0))
        page.setBounds(CGRect(x: 20, y: 30, width: 220, height: 160), for: .cropBox)
        XCTAssertThrowsError(try PDFRasterSanitizer.sanitizedDocument(source, regions: []))
        XCTAssertThrowsError(try PDFRasterSanitizer.sanitizedDocument(source, regions: [PDFRedactionRegion(pageIndex: 7, bounds: CGRect(x: 40, y: 50, width: 10, height: 10))]))
        XCTAssertThrowsError(try PDFRasterSanitizer.sanitizedDocument(source, regions: [PDFRedactionRegion(pageIndex: 0, bounds: CGRect(x: 500, y: 500, width: 10, height: 10))]))
        let clipped = try PDFRasterSanitizer.sanitizedDocument(source, regions: [PDFRedactionRegion(pageIndex: 0, bounds: CGRect(x: -10, y: -10, width: 100, height: 100))], dpi: 72)
        XCTAssertEqual(clipped.pageCount, 1)
        XCTAssertEqual(clipped.page(at: 0)?.bounds(for: .mediaBox), CGRect(x: 0, y: 0, width: 220, height: 160))
    }

    @MainActor
    func testShapesPersistAndUndoAndTextComparisonNormalizesWhitespace() throws {
        let model = PDFEditorModel()
        let page = try XCTUnwrap(model.currentPage)
        model.addShapeAnnotation(in: CGRect(x: 30, y: 40, width: 70, height: 60), on: page, ellipse: false)
        model.addShapeAnnotation(in: CGRect(x: 100, y: 130, width: 80, height: 60), on: page, ellipse: true)
        XCTAssertEqual(page.annotations.map(\.type), ["Square", "Circle"])
        let reopened = try XCTUnwrap(PDFDocument(data: model.serializedData()))
        XCTAssertEqual(reopened.page(at: 0)?.annotations.count, 2)
        model.undo()
        XCTAssertEqual(page.annotations.count, 1)
        model.redo()
        XCTAssertEqual(page.annotations.count, 2)
        let a = try makeSource(), b = try makeSource(text: "SEGRETO    originale")
        XCTAssertTrue(PDFTextComparison(left: a, right: b).changedPages.isEmpty)
        let c = try makeSource(text: "SEGRETO modificato")
        XCTAssertEqual(PDFTextComparison(left: a, right: c).changedPages, [0])
        b.insert(try XCTUnwrap(b.page(at: 0)?.copy() as? PDFPage), at: 1)
        XCTAssertEqual(PDFTextComparison(left: a, right: b).changedPages, [1])
    }

    @MainActor
    func testLinksRoundTripAndOnlyLinksCreatedByThisAppAreRemoved() throws {
        let model = PDFEditorModel()
        let page = try XCTUnwrap(model.currentPage)
        let url = try XCTUnwrap(URL(string: "https://example.com/documento"))
        model.addWebLink(url, in: CGRect(x: 40, y: 50, width: 100, height: 35), on: page)
        let link = try XCTUnwrap(page.annotations.first)
        XCTAssertEqual((link.action as? PDFActionURL)?.url, url)
        let reopened = try XCTUnwrap(PDFDocument(data: model.serializedData()))
        let saved = try XCTUnwrap(reopened.page(at: 0)?.annotations.first)
        XCTAssertEqual((saved.action as? PDFActionURL)?.url, url)
        XCTAssertTrue((saved.value(forAnnotationKey: .name) as? String)?.hasPrefix("CartaPDF-Link-") == true)
        model.removeWebLink(link, from: page)
        XCTAssertTrue(page.annotations.isEmpty)
        model.undo()
        XCTAssertEqual(page.annotations.count, 1)
        let sourceLink = PDFAnnotation(bounds: CGRect(x: 200, y: 50, width: 100, height: 35), forType: .link, withProperties: nil)
        page.addAnnotation(sourceLink)
        model.removeWebLink(sourceLink, from: page)
        XCTAssertEqual(page.annotations.count, 2)
    }

    @MainActor
    private func makeSource(text: String = "SEGRETO originale") throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var box = CGRect(x: 0, y: 0, width: 300, height: 260)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(box)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 40, y: 50, width: 80, height: 60))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (text as NSString).draw(at: CGPoint(x: 30, y: 140), withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (red: Int, green: Int, blue: Int) {
        let width = image.width, height = image.height
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = ((height - 1 - min(max(y, 0), height - 1)) * width + min(max(x, 0), width - 1)) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }
}
