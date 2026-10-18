import AppKit
import CoreText
import PDFKit
import XCTest
@testable import CartaPDF

final class PDFConversionToolsTests: XCTestCase {
    func testImageImportCreatesPortraitAndLandscapePagesWithVisibleContent() throws {
        let portrait = try image(width: 80, height: 160, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let landscape = try image(width: 180, height: 90, color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        let data = try PDFConversionEngine.makeImagePDFData(images: [portrait, landscape])
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(pdf.pageCount, 2)
        let first = try XCTUnwrap(pdf.page(at: 0))
        let second = try XCTUnwrap(pdf.page(at: 1))
        XCTAssertLessThan(first.bounds(for: .mediaBox).width, first.bounds(for: .mediaBox).height)
        XCTAssertGreaterThan(second.bounds(for: .mediaBox).width, second.bounds(for: .mediaBox).height)
        let raster = try PDFConversionEngine.renderPage(first, dpi: 72)
        let center = try pixel(raster.image, x: raster.image.width / 2, y: raster.image.height / 2)
        XCTAssertGreaterThan(center.red, 240)
        // Quartz color conversion may slightly lift a saturated channel.
        XCTAssertLessThan(center.green, 80)
        let corner = try pixel(raster.image, x: 2, y: 2)
        XCTAssertGreaterThan(corner.red, 240)
        XCTAssertGreaterThan(corner.green, 240)
    }

    func testRenderHonorsRotatedCropGeometryAndBoundsMemoryForHugePages() throws {
        let pdf = try textPDF(text: "Cropped", size: CGSize(width: 300, height: 200))
        let page = try XCTUnwrap(pdf.page(at: 0))
        page.setBounds(CGRect(x: 50, y: 25, width: 200, height: 100), for: .cropBox)
        page.rotation = 90
        let raster = try PDFConversionEngine.renderPage(page, dpi: 72)
        XCTAssertEqual(raster.pageSize.width, 100, accuracy: 0.1)
        XCTAssertEqual(raster.pageSize.height, 200, accuracy: 0.1)
        XCTAssertEqual(raster.image.width, 100)
        XCTAssertEqual(raster.image.height, 200)
        page.rotation = 0
        page.setBounds(CGRect(x: 0, y: 0, width: 100_000, height: 1_000), for: .cropBox)
        let limited = try PDFConversionEngine.renderPage(page, dpi: 600)
        XCTAssertLessThanOrEqual(limited.image.width, 16_000)
        XCTAssertLessThanOrEqual(limited.image.width * limited.image.height, 24_100_000)
    }

    func testHiddenOCRTextIsSearchableAtItsBoundsWithoutPaintingVisibleText() throws {
        let source = try image(width: 300, height: 100, color: CGColor(gray: 1, alpha: 1))
        let target = CGRect(x: 0.1, y: 0.35, width: 0.8, height: 0.3)
        let data = try PDFConversionEngine.searchablePageData(image: source, pageSize: CGSize(width: 300, height: 100),
                                                             lines: [.init(text: "LOCAL OCR TEST", normalizedBounds: target)])
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(pdf.page(at: 0))
        XCTAssertTrue((page.string ?? "").contains("LOCAL OCR TEST"))
        let selection = page.selection(for: CGRect(x: 29, y: 34, width: 242, height: 32))
        XCTAssertTrue((selection?.string ?? "").contains("LOCAL OCR TEST"))
        let raster = try PDFConversionEngine.renderPage(page, dpi: 72)
        // A white scan remains white even where the searchable text layer was written.
        for y in stride(from: 20, through: 80, by: 3) {
            for x in stride(from: 20, through: 280, by: 3) {
                let value = try pixel(raster.image, x: x, y: y)
                XCTAssertGreaterThan(value.red, 245)
                XCTAssertGreaterThan(value.green, 245)
                XCTAssertGreaterThan(value.blue, 245)
            }
        }
    }

    func testRasterCopyPreservesPageSizeAndAnnotationAppearanceButRemovesInteractiveContent() throws {
        let pdf = try textPDF(text: "Selectable original", size: CGSize(width: 300, height: 200))
        let page = try XCTUnwrap(pdf.page(at: 0))
        XCTAssertTrue((page.string ?? "").contains("Selectable original"))
        let annotation = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 60, height: 60), forType: .square, withProperties: nil)
        annotation.interiorColor = .red
        annotation.color = .red
        page.addAnnotation(annotation)
        let sourceData = try XCTUnwrap(pdf.dataRepresentation())
        let data = try PDFConversionEngine.rasterPDFData(snapshot: sourceData, dpi: 144)
        let output = try XCTUnwrap(PDFDocument(data: data))
        let outputPage = try XCTUnwrap(output.page(at: 0))
        XCTAssertTrue((outputPage.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(outputPage.annotations.isEmpty)
        XCTAssertEqual(outputPage.bounds(for: .mediaBox).size, CGSize(width: 300, height: 200))
        let raster = try PDFConversionEngine.renderPage(outputPage, dpi: 72)
        // CGContext images expose their first row at the top; the annotation is near the bottom-left.
        let visibleAnnotation = try pixel(raster.image, x: 40, y: raster.image.height - 40)
        XCTAssertGreaterThan(visibleAnnotation.red, 230)
        XCTAssertLessThan(visibleAnnotation.green, 40)
        XCTAssertEqual(pdf.page(at: 0)?.annotations.count, 1)
        XCTAssertTrue((pdf.page(at: 0)?.string ?? "").contains("Selectable original"))
    }

    func testJPEGCopyUsesJPEGStreamAndProducesReadablePDFWithoutPromisingSmallerSize() throws {
        let pdf = try textPDF(text: "JPEG conversion", size: CGSize(width: 300, height: 200))
        let data = try PDFConversionEngine.rasterPDFData(snapshot: XCTUnwrap(pdf.dataRepresentation()), dpi: 100, jpegQuality: 0.65)
        let output = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(output.pageCount, 1)
        XCTAssertTrue((String(data: data, encoding: .isoLatin1) ?? "").contains("/DCTDecode"))
        XCTAssertGreaterThan(try PDFConversionEngine.renderPage(XCTUnwrap(output.page(at: 0)), dpi: 72).image.width, 0)
    }

    func testTextAndRTFExportContainPageTextAndPageSeparators() throws {
        let pdf = try textPDF(text: "Prima pagina", size: CGSize(width: 300, height: 200))
        let second = try textPDF(text: "Seconda pagina", size: CGSize(width: 300, height: 200))
        pdf.insert(try XCTUnwrap(second.page(at: 0)?.copy() as? PDFPage), at: 1)
        let text = PDFConversionEngine.extractedText(from: pdf)
        XCTAssertTrue(text.contains("Prima pagina"))
        XCTAssertTrue(text.contains("Seconda pagina"))
        XCTAssertTrue(text.contains("\n\n"))
        let rtf = try PDFConversionEngine.rtfData(from: pdf)
        let decoded = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertTrue(decoded.string.contains(L10n.tr("Pagina \(1)\n")))
        XCTAssertTrue(decoded.string.contains(L10n.tr("Pagina \(2)\n")))
        XCTAssertTrue(decoded.string.contains("Seconda pagina"))
    }

    func testOCRSkipsSelectablePagesAndPreservesTheirAnnotations() throws {
        let pdf = try textPDF(text: "Already searchable", size: CGSize(width: 300, height: 200))
        let note = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .text, withProperties: nil)
        note.contents = "Preserved"
        pdf.page(at: 0)?.addAnnotation(note)
        let result = try PDFConversionEngine.ocrPDFData(snapshot: XCTUnwrap(pdf.dataRepresentation()))
        XCTAssertEqual(result.recognizedPages, 0)
        XCTAssertEqual(result.skippedTextPages, 1)
        let reopened = try XCTUnwrap(PDFDocument(data: result.data))
        XCTAssertTrue((reopened.page(at: 0)?.string ?? "").contains("Already searchable"))
        XCTAssertEqual(reopened.page(at: 0)?.annotations.first?.contents, "Preserved")
    }

    func testVisionRecognizesLocalRasterScanAndProducesSelectableText() throws {
        let original = try textPDF(text: "CARTA PDF LOCAL TEST", size: CGSize(width: 600, height: 180), fontSize: 34)
        let scannedData = try PDFConversionEngine.rasterPDFData(snapshot: XCTUnwrap(original.dataRepresentation()), dpi: 200)
        let scanned = try XCTUnwrap(PDFDocument(data: scannedData))
        XCTAssertTrue((scanned.page(at: 0)?.string ?? "").isEmpty)
        let result = try PDFConversionEngine.ocrPDFData(snapshot: scannedData)
        XCTAssertEqual(result.recognizedPages, 1)
        let searchable = try XCTUnwrap(PDFDocument(data: result.data))
        let recognizedText = searchable.page(at: 0)?.string ?? ""
        XCTAssertTrue(recognizedText.uppercased().contains("CARTA"), recognizedText)
        XCTAssertTrue(recognizedText.uppercased().contains("LOCAL"), recognizedText)
    }

    private func image(width: Int, height: Int, color: CGColor) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return (data[offset], data[offset + 1], data[offset + 2])
    }

    private func textPDF(text: String, size: CGSize, fontSize: CGFloat = 20) throws -> PDFDocument {
        let data = NSMutableData()
        var bounds = CGRect(origin: .zero, size: size)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        context.textPosition = CGPoint(x: 24, y: size.height / 2)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        context.endPDFPage()
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }
}
