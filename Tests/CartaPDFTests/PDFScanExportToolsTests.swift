import AppKit
import CoreImage
import CoreText
import Foundation
import ImageIO
import PDFKit
import XCTest
@testable import CartaPDF

final class PDFScanExportToolsTests: XCTestCase {
    func testMultipageTIFFHasEveryPageAndPhysicalResolution() throws {
        let pdf = try fixture(lines: [("First", 20, 150)], size: CGSize(width: 200, height: 180))
        pdf.insert(try XCTUnwrap(pdf.page(at: 0)?.copy() as? PDFPage), at: 1)
        let data = try ScanExportEngine.tiff(snapshot: XCTUnwrap(pdf.dataRepresentation()), dpi: 144)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 1, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 0, 144, accuracy: 0.1)
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 400)
    }

    func testEPUBHasStoredFirstMimetypeValidXMLAndCRC() throws {
        let archive = try ScanExportEngine.epub(pages: ["Caffè & tè <test>\nseconda riga", "Altra pagina"], title: "Libro & test")
        let entries = try zipEntries(archive)
        XCTAssertEqual(entries.first?.0, "mimetype")
        XCTAssertEqual(String(data: entries.first!.1, encoding: .utf8), "application/epub+zip")
        XCTAssertEqual(entries.count, 5)
        for entry in entries where entry.0.hasSuffix("xml") || entry.0.hasSuffix("opf") || entry.0.hasSuffix("xhtml") {
            let parser = XMLParser(data: entry.1)
            XCTAssertTrue(parser.parse(), "\(entry.0): \(String(describing: parser.parserError))")
        }
        let content = try XCTUnwrap(entries.first(where: { $0.0 == "EPUB/content.xhtml" }))
        XCTAssertTrue(String(decoding: content.1, as: UTF8.self).contains("&amp;"))
    }

    func testCSVQuotedFieldsNewlinesAndDelimiterRoundTrip() throws {
        let rows = [["Nome", "Nota"], ["Caffè, tè", "Riga 1\nRiga \"2\""], ["", "Fine"]]
        XCTAssertEqual(try ScanCSV.parse(ScanCSV.encode(rows)), rows)
        XCTAssertEqual(try ScanCSV.parse(ScanCSV.encode(rows, delimiter: ";"), delimiter: ";"), rows)
        XCTAssertThrowsError(try ScanCSV.parse("Nome,Nota\n\"non chiusa"))
    }

    func testCSVPreservesExplicitEmptyRecordsForClearingForms() throws {
        XCTAssertEqual(try ScanCSV.parse("Nome,Cognome\nMario,Rossi\n,\n\nLuigi,Bianchi\n"),
                       [["Nome", "Cognome"], ["Mario", "Rossi"], ["", ""], ["Luigi", "Bianchi"]])
        XCTAssertEqual(try ScanCSV.parse("Nome\n\"\"\n"), [["Nome"], [""]])
        XCTAssertEqual(try ScanCSV.parse(ScanCSV.encode([[""], [""]])), [[""], [""]])
        let pdf = try fixture(lines: [], size: CGSize(width: 300, height: 200))
        let field = PDFAnnotation(bounds: CGRect(x: 30, y: 50, width: 100, height: 25), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text; field.fieldName = "Nome"; field.widgetStringValue = "Originale"
        pdf.page(at: 0)?.addAnnotation(field)
        let copies = try ScanCSV.filledDocuments(snapshot: XCTUnwrap(pdf.dataRepresentation()), rows: ScanCSV.parse("Nome\n\"\"\n"))
        XCTAssertEqual(copies.count, 1)
        let reopened = try XCTUnwrap(PDFDocument(data: copies[0]))
        XCTAssertEqual(reopened.page(at: 0)?.annotations.first?.widgetStringValue ?? "", "")
        XCTAssertEqual(field.widgetStringValue, "Originale")
    }

    func testManualAndAutomaticTablesPreserveTwoColumnRows() throws {
        let pdf = try fixture(lines: [("Alice", 20, 150), ("12", 190, 150), ("Bruno", 20, 110), ("34", 190, 110)], size: CGSize(width: 300, height: 200))
        let page = try XCTUnwrap(pdf.page(at: 0))
        let manual = try ScanCSV.table(page: page, normalizedRegion: CGRect(x: 0, y: 0, width: 1, height: 1), columns: [0.5])
        XCTAssertEqual(manual, [["Alice", "12"], ["Bruno", "34"]])
        let automatic = try ScanCSV.table(page: page, normalizedRegion: CGRect(x: 0, y: 0, width: 1, height: 1), columns: nil)
        XCTAssertEqual(automatic, manual)
    }

    func testCSVFormFillingCreatesIndependentCopiesAndRejectsMissingFields() throws {
        let pdf = try fixture(lines: [], size: CGSize(width: 300, height: 200))
        let field = PDFAnnotation(bounds: CGRect(x: 30, y: 50, width: 100, height: 25), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text; field.fieldName = "Nome"; field.widgetStringValue = "Originale"
        pdf.page(at: 0)?.addAnnotation(field)
        let snapshot = try XCTUnwrap(pdf.dataRepresentation())
        let copies = try ScanCSV.filledDocuments(snapshot: snapshot, rows: [["Nome"], ["Alice"], ["Bruno"]])
        XCTAssertEqual(copies.count, 2)
        XCTAssertEqual(PDFDocument(data: copies[0])?.page(at: 0)?.annotations.first?.widgetStringValue, "Alice")
        XCTAssertEqual(PDFDocument(data: copies[1])?.page(at: 0)?.annotations.first?.widgetStringValue, "Bruno")
        XCTAssertEqual(field.widgetStringValue, "Originale")
        XCTAssertThrowsError(try ScanCSV.filledDocuments(snapshot: snapshot, rows: [["Manca"], ["Valore"]]))
        field.isReadOnly = true
        XCTAssertThrowsError(try ScanCSV.filledDocuments(snapshot: XCTUnwrap(pdf.dataRepresentation()), rows: [["Nome"], ["Nuovo"]]))
    }

    func testCSVChoiceLabelsMapToExportValuesAndCheckboxRejectsUnknownValues() throws {
        let pdf = try fixture(lines: [], size: CGSize(width: 300, height: 200))
        let page = try XCTUnwrap(pdf.page(at: 0))
        let choice = PDFAnnotation(bounds: CGRect(x: 20, y: 110, width: 100, height: 25), forType: .widget, withProperties: nil)
        choice.widgetFieldType = .choice; choice.fieldName = "Lingua"
        choice.choices = ["Italiano", "English"]; choice.values = ["it-IT", "en-GB"]; choice.widgetStringValue = "it-IT"
        let checkbox = PDFAnnotation(bounds: CGRect(x: 20, y: 60, width: 20, height: 20), forType: .widget, withProperties: nil)
        checkbox.widgetFieldType = .button; checkbox.widgetControlType = .checkBoxControl
        checkbox.fieldName = "Accetto"; checkbox.buttonWidgetState = .offState
        page.addAnnotation(choice); page.addAnnotation(checkbox)
        let snapshot = try XCTUnwrap(pdf.dataRepresentation())
        let copies = try ScanCSV.filledDocuments(snapshot: snapshot, rows: [["Lingua", "Accetto"], ["English", " sì "], ["it-IT", "false"]])
        let first = try XCTUnwrap(PDFDocument(data: copies[0])), second = try XCTUnwrap(PDFDocument(data: copies[1]))
        let firstFields = try XCTUnwrap(first.page(at: 0)).annotations
        let secondFields = try XCTUnwrap(second.page(at: 0)).annotations
        XCTAssertEqual(firstFields.first(where: { $0.fieldName == "Lingua" })?.widgetStringValue, "en-GB")
        XCTAssertEqual(firstFields.first(where: { $0.fieldName == "Accetto" })?.buttonWidgetState, .onState)
        XCTAssertEqual(secondFields.first(where: { $0.fieldName == "Lingua" })?.widgetStringValue, "it-IT")
        XCTAssertEqual(secondFields.first(where: { $0.fieldName == "Accetto" })?.buttonWidgetState, .offState)
        XCTAssertThrowsError(try ScanCSV.filledDocuments(snapshot: snapshot, rows: [["Accetto"], ["tru"]])) {
            XCTAssertTrue($0.localizedDescription.contains("true/false"))
        }
        XCTAssertEqual(choice.widgetStringValue, "it-IT")
        XCTAssertEqual(checkbox.buttonWidgetState, .offState)
    }

    func testCSVTextFieldsRejectPasswordsAndMaximumLengthOverflow() throws {
        let pdf = try fixture(lines: [], size: CGSize(width: 300, height: 200))
        let field = PDFAnnotation(bounds: CGRect(x: 30, y: 50, width: 100, height: 25), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text; field.fieldName = "Codice"; field.maximumLength = 3; field.widgetStringValue = "ABC"
        pdf.page(at: 0)?.addAnnotation(field)
        XCTAssertThrowsError(try ScanCSV.filledDocuments(snapshot: XCTUnwrap(pdf.dataRepresentation()), rows: [["Codice"], ["ABCD"]])) {
            XCTAssertTrue($0.localizedDescription.contains("3 caratteri"))
        }
        let copies = try ScanCSV.filledDocuments(snapshot: XCTUnwrap(pdf.dataRepresentation()), rows: [["Codice"], ["XYZ"]])
        let reopened = try XCTUnwrap(PDFDocument(data: copies[0]))
        XCTAssertEqual(reopened.page(at: 0)?.annotations.first?.widgetStringValue, "XYZ")
        field.setValue(NSNumber(value: 1 << 13), forAnnotationKey: .widgetFieldFlags)
        XCTAssertTrue(field.isPasswordField)
        XCTAssertThrowsError(try ScanCSV.filledDocuments(snapshot: XCTUnwrap(pdf.dataRepresentation()), rows: [["Codice"], ["XYZ"]])) {
            XCTAssertTrue($0.localizedDescription.contains("password"))
        }
        XCTAssertEqual(field.widgetStringValue, "ABC")
    }

    func testColumnReadingOrderUsesVerticalGutter() {
        let lines = [
            AdvancedScanEngine.Line(text: "R2", bounds: CGRect(x: 0.6, y: 0.4, width: 0.3, height: 0.05), confidence: 1),
            .init(text: "L1", bounds: CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.05), confidence: 1),
            .init(text: "R1", bounds: CGRect(x: 0.6, y: 0.8, width: 0.3, height: 0.05), confidence: 1),
            .init(text: "L2", bounds: CGRect(x: 0.1, y: 0.4, width: 0.3, height: 0.05), confidence: 1)
        ]
        XCTAssertEqual(AdvancedScanEngine.readingOrder(lines, columns: true).map(\.text), ["L1", "L2", "R1", "R2"])
        XCTAssertEqual(AdvancedScanEngine.readingOrder(lines, columns: false).map(\.text), ["L1", "R1", "L2", "R2"])
        let header = AdvancedScanEngine.Line(text: "Header", bounds: CGRect(x: 0.1, y: 0.95, width: 0.8, height: 0.03), confidence: 1)
        XCTAssertEqual(AdvancedScanEngine.readingOrder([header] + lines, columns: true).map(\.text), ["Header", "L1", "L2", "R1", "R2"])
    }

    func testCleanupAndManualDeskewRetainExtentAndUseExplicitSRGB() throws {
        let pdf = try fixture(lines: [("Contrast", 30, 80)], size: CGSize(width: 200, height: 120))
        let image = try PDFConversionEngine.renderPage(XCTUnwrap(pdf.page(at: 0)), dpi: 72).image
        let output = try AdvancedScanEngine.processedImage(image, angle: -4, cleanup: true)
        XCTAssertEqual(output.width, image.width)
        XCTAssertEqual(output.height, image.height)
        XCTAssertEqual(output.colorSpace?.name, CGColorSpace.sRGB)
        XCTAssertNotEqual(output.dataProvider?.data, image.dataProvider?.data)
    }

    func testAutomaticDeskewFindsTiltedTextBaseline() throws {
        let pdf = try fixture(lines: [("Local document first line", 30, 160), ("Second line with aligned text", 30, 120), ("Third line for skew detection", 30, 80)], size: CGSize(width: 350, height: 220))
        let raster = try PDFConversionEngine.renderPage(XCTUnwrap(pdf.page(at: 0)), dpi: 144)
        let tilted = try AdvancedScanEngine.processedImage(raster.image, angle: 4, cleanup: false)
        let correction = try AdvancedScanEngine.estimatedSkew(tilted, cancellation: ScanCancellation())
        XCTAssertEqual(correction, -4, accuracy: 1.5)
    }

    func testHeaderTextDoesNotSuppressScanOCRCoverage() throws {
        let pdf = try fixture(lines: [("Intestazione", 30, 800)], size: PDFConversionEngine.a4Size)
        let page = try XCTUnwrap(pdf.page(at: 0))
        XCTAssertGreaterThan(AdvancedScanEngine.textCoverage(page), 0)
        XCTAssertLessThan(AdvancedScanEngine.textCoverage(page), 0.025)
    }

    func testCancellationIsCheckedBeforeVisionOrTIFFWork() throws {
        let cancellation = ScanCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try cancellation.check()) { XCTAssertTrue($0 is CancellationError) }
        let pdf = try fixture(lines: [], size: CGSize(width: 100, height: 100))
        XCTAssertThrowsError(try AdvancedScanEngine.process(snapshot: XCTUnwrap(pdf.dataRepresentation()), options: ScanOptions(), cancellation: cancellation))
        XCTAssertThrowsError(try ScanExportEngine.tiff(snapshot: XCTUnwrap(pdf.dataRepresentation()), cancellation: cancellation))
    }

    func testParagraphReconstructionKeepsUnicodeBlankLinesAndDehyphenates() {
        XCTAssertEqual(ScanExportEngine.normalizedParagraphs("Una riga\r\ncontinua\n\nCaffè spe-\nzzato."), "Una riga continua\n\nCaffè spezzato.")
    }

    func testNativeOCRLayerRecognizesRasterAndPreservesSearchableGeometry() throws {
        let text = try fixture(lines: [("CARTA LOCAL SCAN", 25, 100)], size: CGSize(width: 400, height: 180))
        let raster = try PDFConversionEngine.rasterPDFData(snapshot: XCTUnwrap(text.dataRepresentation()), dpi: 200)
        var options = ScanOptions(); options.automaticOrientation = false; options.deskew = false; options.retryLowConfidence = false
        let output = try AdvancedScanEngine.process(snapshot: raster, options: options)
        let reopened = try XCTUnwrap(PDFDocument(data: output.data))
        XCTAssertEqual(reopened.pageCount, 1)
        XCTAssertTrue((reopened.string ?? "").contains("CARTA"))
        XCTAssertTrue((reopened.string ?? "").contains("LOCAL"))
        XCTAssertEqual(output.reports.first?.state, "Riconosciuta")
    }

    func testPrioritizedOCRPageKeepsFinalDocumentOrder() throws {
        let pdf = try fixture(lines: [("ALPHA searchable native text", 10, 70)], size: CGSize(width: 300, height: 100))
        for word in ["BETA searchable native text", "GAMMA searchable native text"] {
            let next = try fixture(lines: [(word, 10, 70)], size: CGSize(width: 300, height: 100))
            pdf.insert(try XCTUnwrap(next.page(at: 0)?.copy() as? PDFPage), at: pdf.pageCount)
        }
        var options = ScanOptions(); options.prioritizedPage = 2
        let output = try AdvancedScanEngine.process(snapshot: XCTUnwrap(pdf.dataRepresentation()), options: options)
        XCTAssertEqual(output.processingOrder, [3, 1, 2])
        let reopened = try XCTUnwrap(PDFDocument(data: output.data))
        XCTAssertTrue((reopened.page(at: 0)?.string ?? "").hasPrefix("ALPHA"))
        XCTAssertTrue((reopened.page(at: 1)?.string ?? "").hasPrefix("BETA"))
        XCTAssertTrue((reopened.page(at: 2)?.string ?? "").hasPrefix("GAMMA"))
    }

    @MainActor
    func testOfflineHTMLPrintsStaticTextWithScriptsDisabled() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("CartaHTML-\(UUID().uuidString).html")
        defer { try? FileManager.default.removeItem(at: source) }
        try "<html><body><h1>HTML locale verificato</h1><script>document.body.innerHTML='SCRIPT EXECUTED'</script><p>Solo contenuti locali.</p></body></html>".write(to: source, atomically: true, encoding: .utf8)
        let renderer = ScanHTMLRenderer()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 794, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = renderer.webView
        renderer.load(source)
        for _ in 0..<100 {
            if renderer.ready { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(renderer.ready, renderer.message)
        guard renderer.ready else { return }
        let pdf = try await renderer.pdf()
        XCTAssertTrue((pdf.string ?? "").contains("HTML locale verificato"))
        XCTAssertFalse((pdf.string ?? "").contains("SCRIPT EXECUTED"))
        window.orderOut(nil)
    }

    @MainActor
    func testHTMLRapidSelectionExportsLatestFileAndInvalidSelectionNeverReusesOldHTML() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CartaHTML-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.html"), second = folder.appendingPathComponent("second.html"), invalid = folder.appendingPathComponent("invalid.html")
        try "<html><body>FIRST stale document</body></html>".write(to: first, atomically: true, encoding: .utf8)
        try "<html><body>SECOND selected document</body></html>".write(to: second, atomically: true, encoding: .utf8)
        try Data([0xff, 0xfe, 0xff]).write(to: invalid)
        let renderer = ScanHTMLRenderer()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 794, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = renderer.webView
        defer { window.orderOut(nil) }
        renderer.load(first); renderer.load(second)
        for _ in 0..<100 {
            if renderer.ready { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(renderer.ready, renderer.message)
        guard renderer.ready else { return }
        let pdf = try await renderer.pdf()
        XCTAssertTrue((pdf.string ?? "").contains("SECOND selected document"))
        XCTAssertFalse((pdf.string ?? "").contains("FIRST stale document"))
        renderer.load(first); renderer.load(invalid)
        let invalidMessage = renderer.message
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(renderer.ready)
        XCTAssertEqual(renderer.message, invalidMessage)
        do { _ = try await renderer.pdf(); XCTFail("Un caricamento HTML fallito non deve esportare il documento precedente.") }
        catch { XCTAssertTrue(error.localizedDescription.contains("caricamento HTML")) }
    }

    private func zipEntries(_ data: Data) throws -> [(String, Data)] {
        func value<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self).littleEndian } }
        var offset = 0, entries: [(String, Data)] = []
        while value(offset, UInt32.self) == 0x04034b50 {
            XCTAssertEqual(value(offset + 8, UInt16.self), 0)
            let crc = value(offset + 14, UInt32.self), size = Int(value(offset + 18, UInt32.self)), nameLength = Int(value(offset + 26, UInt16.self)), extra = Int(value(offset + 28, UInt16.self))
            let name = String(decoding: data[(offset + 30)..<(offset + 30 + nameLength)], as: UTF8.self)
            let start = offset + 30 + nameLength + extra, payload = Data(data[start..<(start + size)])
            XCTAssertEqual(ScanStoredZIP.crc32(payload), crc)
            entries.append((name, payload)); offset = start + size
        }
        XCTAssertEqual(value(offset, UInt32.self), 0x02014b50)
        return entries
    }

    private func fixture(lines: [(String, CGFloat, CGFloat)], size: CGSize) throws -> PDFDocument {
        let data = NSMutableData(); var bounds = CGRect(origin: .zero, size: size)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &bounds, nil))
        context.beginPDFPage(nil); context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
        for (text, x, y) in lines {
            let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
            let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            context.textPosition = CGPoint(x: x, y: y); CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        context.endPDFPage(); context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }
}
