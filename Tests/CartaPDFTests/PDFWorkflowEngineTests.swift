import AppKit
import CoreText
import CoreImage
import PDFKit
import XCTest
@testable import CartaPDF

final class PDFWorkflowEngineTests: XCTestCase {
    @MainActor
    private func document(_ labels: [String], size: CGSize = CGSize(width: 595.276, height: 841.89), color: CGColor? = nil) throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        let context = try XCTUnwrap(CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil))
        for label in labels {
            context.beginPDFPage(nil)
            context.setFillColor(color ?? CGColor(gray: 1, alpha: 1)); context.fill(box)
            if !label.isEmpty {
                let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
                context.textPosition = CGPoint(x: 40, y: size.height - 70); CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    @MainActor
    private func text(_ document: PDFDocument, _ index: Int) -> String { document.page(at: index)?.string ?? "" }

    @MainActor
    func testRangeSyntaxNormalizesSeparatorsReportsOverlapAndRejectsInvalidTokens() throws {
        let parsed = try WorkflowEngine.parseRange("1 – 3, 3; ultima", pageCount: 5)
        XCTAssertEqual(parsed.indices, [0, 1, 2, 4]); XCTAssertEqual(parsed.repeatedPages, [2])
        XCTAssertEqual(try WorkflowEngine.parseRange("pari", pageCount: 5).indices, [1, 3])
        XCTAssertEqual(try WorkflowEngine.parseRange("dispari", pageCount: 5).indices, [0, 2, 4])
        XCTAssertThrowsError(try WorkflowEngine.parseRange("3-1", pageCount: 5))
        XCTAssertThrowsError(try WorkflowEngine.parseRange("1,,2", pageCount: 5))
        XCTAssertThrowsError(try WorkflowEngine.parseRange("ultima-8", pageCount: 5))
    }

    @MainActor
    func testOrderedMergePreservesSelectionsPageIndependenceAndMappedOutlines() async throws {
        let first = try document(["A1", "A2"]), second = try document(["B1", "B2"])
        let root = PDFOutline(), leaf = PDFOutline(); root.insertChild(leaf, at: 0)
        leaf.label = "Seconda"; leaf.destination = PDFDestination(page: first.page(at: 1)!, at: CGPoint(x: 0, y: 800)); first.outlineRoot = root
        var fractions: [Double] = []
        let result = try await WorkflowEngine.merge([WorkflowSource(document: first, title: "A.pdf", range: "2"), WorkflowSource(document: second, title: "B.pdf")]) { fraction, _ in fractions.append(fraction) }
        XCTAssertEqual(result.pageCount, 3)
        XCTAssertTrue(text(result, 0).contains("A2")); XCTAssertTrue(text(result, 1).contains("B1"))
        XCTAssertEqual(first.pageCount, 2); XCTAssertFalse(result.page(at: 0) === first.page(at: 1))
        XCTAssertEqual(fractions.count, 3); XCTAssertEqual(fractions.last, 1); XCTAssertEqual(fractions, fractions.sorted())
        let reopened = try XCTUnwrap(PDFDocument(data: WorkflowEngine.serialized(result)))
        XCTAssertEqual(reopened.outlineRoot?.numberOfChildren, 2)
        XCTAssertEqual(reopened.outlineRoot?.child(at: 0)?.child(at: 0)?.label, "Seconda")
        XCTAssertEqual(reopened.outlineRoot?.child(at: 0)?.child(at: 0)?.destination?.page, reopened.page(at: 0))
    }

    @MainActor
    func testFrontBackMergeAndFilenameGroupsPreserveQueueOrder() async throws {
        let front = try document(["FRONT1", "FRONT2"]), backs = try document(["BACK2", "BACK1"])
        let result = try await WorkflowEngine.merge([WorkflowSource(document: front, title: "front.pdf"), WorkflowSource(document: backs, title: "back.pdf")], alternate: true, reverseBacks: true)
        for (index, expected) in ["FRONT1", "BACK1", "FRONT2", "BACK2"].enumerated() { XCTAssertTrue(text(result, index).contains(expected)) }
        let sources = [WorkflowSource(document: front, title: "pratica_002.pdf"), WorkflowSource(document: backs, title: "pratica_001.pdf"), WorkflowSource(document: front, title: "altro-001.pdf")]
        let groups = WorkflowEngine.groupedSources(sources)
        XCTAssertEqual(groups.map(\.0), ["pratica", "altro"])
        XCTAssertEqual(groups[0].1.map(\.title), ["pratica_002.pdf", "pratica_001.pdf"])
    }

    @MainActor
    func testSplitIntervalsFixedSizeNamesAndBookmarks() async throws {
        let source = try document((1...6).map { "PAGE-\($0)" })
        let fixed = try await WorkflowEngine.planSplit(source, mode: .everyN, count: 2)
        XCTAssertEqual(fixed.map(\.indices), [[0, 1], [2, 3], [4, 5]])
        let ranged = try await WorkflowEngine.planSplit(source, mode: .intervals, intervals: "1-2; 4,6")
        XCTAssertEqual(ranged.map(\.indices), [[0, 1], [3, 5]])
        XCTAssertEqual(WorkflowEngine.outputName(pattern: "{name}-{index:03}-{start}-{end}-{pages}", source: "Prova.pdf", part: ranged[1], index: 1), "Prova-002-4-6-2.pdf")
        let root = PDFOutline()
        for (label, index) in [("Prima", 0), ("Seconda", 3)] {
            let leaf = PDFOutline(); root.insertChild(leaf, at: root.numberOfChildren); leaf.label = label; leaf.destination = PDFDestination(page: source.page(at: index)!, at: .zero)
        }
        source.outlineRoot = root
        let bookmarked = try await WorkflowEngine.planSplit(source, mode: .bookmarks)
        XCTAssertEqual(bookmarked.map(\.indices), [[0, 1, 2], [3, 4, 5]])
        XCTAssertEqual(bookmarked.map(\.label), ["Prima", "Seconda"])
    }

    @MainActor
    func testTextAndBlankSeparatorsAreDetectedWithoutChangingSource() async throws {
        let source = try document(["PRIMA", "testo", "NEW capitolo", "corpo", "NEW finale", "fine"])
        let parts = try await WorkflowEngine.planSplit(source, mode: .text, marker: "NEW", skipMarkers: true)
        XCTAssertEqual(parts.map(\.indices), [[0, 1], [3], [5]])
        let blanks = try document(["UNO", "", "DUE", "", "TRE"])
        let separated = try await WorkflowEngine.planSplit(blanks, mode: .blank, skipMarkers: true, blankThreshold: 0)
        XCTAssertEqual(separated.map(\.indices), [[0], [2], [4]])
        XCTAssertEqual(blanks.pageCount, 5)
    }

    @MainActor
    func testMaximumSizeMeasuresActualOutputsAndRejectsOversizedSinglePage() async throws {
        let source = try document(["UNO", "DUE", "TRE"])
        let one = try WorkflowEngine.serialized(WorkflowEngine.extract(source, indices: [0])).count
        let two = try WorkflowEngine.serialized(WorkflowEngine.extract(source, indices: [0, 1])).count
        XCTAssertGreaterThan(two, one)
        let limit = max(1024, one + (two - one) / 2)
        let parts = try await WorkflowEngine.planSplit(source, mode: .maxBytes, maxBytes: limit)
        XCTAssertGreaterThan(parts.count, 1)
        for part in parts { XCTAssertLessThanOrEqual(try WorkflowEngine.serialized(WorkflowEngine.extract(source, indices: part.indices)).count, limit) }
        do { _ = try await WorkflowEngine.planSplit(source, mode: .maxBytes, maxBytes: 1024); XCTFail("La pagina deve superare il limite") }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }

    @MainActor
    func testVisionBarcodeSeparatorUsesLocalQRCodePayload() async throws {
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data("CARTA-CHAPTER-42".utf8), forKey: "inputMessage")
        let image = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let raster = try XCTUnwrap(CIContext(options: [.useSoftwareRenderer: true]).createCGImage(image, from: image.extent))
        let qrDocument = try XCTUnwrap(PDFDocument(data: PDFConversionEngine.makeImagePDFData(images: [raster])))
        let source = try document(["PRIMA", "DOPO"])
        source.insert(qrDocument.page(at: 0)!.copy() as! PDFPage, at: 1)
        let parts = try await WorkflowEngine.planSplit(source, mode: .barcode, marker: "CHAPTER-42", skipMarkers: true)
        XCTAssertEqual(parts.map(\.indices), [[0], [2]])
    }

    @MainActor
    func testNUpAndBookletRetainVectorTextAndCorrectGeometry() async throws {
        let source = try document((1...8).map { "PAGE-\($0)" })
        let sheet = CGSize(width: 841.89, height: 595.276)
        let grid = try await WorkflowEngine.nUp(source, columns: 2, rows: 2, sheet: sheet)
        XCTAssertEqual(grid.pageCount, 2)
        XCTAssertEqual(grid.page(at: 0)?.bounds(for: .mediaBox).width ?? 0, sheet.width, accuracy: 0.01)
        for number in 1...4 { XCTAssertTrue(text(grid, 0).contains("PAGE-\(number)")) }
        let booklet = try await WorkflowEngine.nUp(source, columns: 2, rows: 1, sheet: sheet, booklet: true)
        XCTAssertEqual(booklet.pageCount, 4)
        XCTAssertTrue(text(booklet, 0).contains("PAGE-8")); XCTAssertTrue(text(booklet, 0).contains("PAGE-1"))
        XCTAssertTrue(text(booklet, 1).contains("PAGE-2")); XCTAssertTrue(text(booklet, 1).contains("PAGE-7"))
        XCTAssertEqual(source.pageCount, 8)
    }

    @MainActor
    func testFacingPosterOverlayAndPageReplacementProduceExpectedPages() async throws {
        let source = try document(["PAESAGGIO"], size: CGSize(width: 800, height: 400))
        let facing = try await WorkflowEngine.facing(source)
        XCTAssertEqual(facing.pageCount, 2)
        XCTAssertEqual(facing.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 400, height: 400))
        let poster = try await WorkflowEngine.poster(source, columns: 2, rows: 2, sheet: CGSize(width: 300, height: 400), overlap: 12)
        XCTAssertEqual(poster.pageCount, 4)
        XCTAssertEqual(poster.page(at: 3)?.bounds(for: .mediaBox).size, CGSize(width: 300, height: 400))
        let base = try document(["BASE"], color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let over = try document(["OVER"], color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        let combined = try await WorkflowEngine.overlay(base, overlay: over, opacity: 0.5)
        XCTAssertTrue(text(combined, 0).contains("BASE")); XCTAssertTrue(text(combined, 0).contains("OVER"))
        let image = try PDFConversionEngine.renderPage(combined.page(at: 0)!, dpi: 36).image
        let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
        let offset = image.bytesPerRow * (image.height / 2) + (image.width / 2) * 4
        XCTAssertGreaterThan(bytes[offset], 50); XCTAssertGreaterThan(bytes[offset + 2], 50)
        let three = try document(["A", "B", "C"]), replacement = try document(["SOSTITUITA"])
        let replaced = try WorkflowEngine.replace(three, indices: [1], replacements: replacement)
        XCTAssertTrue(text(replaced, 1).contains("SOSTITUITA")); XCTAssertTrue(text(three, 1).contains("B"))
    }

    @MainActor
    func testDynamicHeadersBatesFitAndClickableContentsPersist() throws {
        let source = try document(["PRIMO", "SECONDO"])
        var numbering = WorkflowNumberingSettings(); numbering.header = "{name} · {page}/{pages}"; numbering.usesBates = true; numbering.start = 42
        let annotations = try WorkflowEngine.numberingAnnotations(source, indices: [0, 1], name: "Prova.pdf", settings: numbering)
        XCTAssertEqual(annotations.count, 4)
        XCTAssertEqual(annotations[0].1.contents, "Prova · 1/2"); XCTAssertEqual(annotations[1].1.contents, "DOC-000042")
        for (page, annotation) in annotations { page.addAnnotation(annotation) }
        XCTAssertEqual(WorkflowEngine.existingNumberingCount(source), 4)
        numbering.batesPrefix = String(repeating: "MOLTO-LUNGO", count: 30)
        XCTAssertThrowsError(try WorkflowEngine.numberingAnnotations(source, indices: [0], name: "Prova.pdf", settings: numbering))
        let contents = try WorkflowEngine.tableOfContents(source)
        XCTAssertEqual(contents.pageCount, 3)
        let reopened = try XCTUnwrap(PDFDocument(data: WorkflowEngine.serialized(contents)))
        let links = reopened.page(at: 0)?.annotations.filter { $0.type == "Link" } ?? []
        XCTAssertEqual(links.count, 2); XCTAssertEqual(links.first?.destination?.page, reopened.page(at: 1))
    }

    @MainActor
    func testWatermarkSettingsAndPageOrganizerPreviewKeepOriginalUnchanged() throws {
        let model = PDFEditorModel(), source = try document(["A", "B"])
        model.replaceDocument(source, fileName: "Prova.pdf")
        let controller = WorkflowController(model: model, kind: .layout)
        controller.duplicatePage(controller.pageOrder[0])
        XCTAssertEqual(controller.outputs.first?.document.pageCount, 3)
        XCTAssertEqual(model.pageCount, 2)
        controller.movePage(controller.pageOrder[2].id, before: controller.pageOrder[0].id)
        XCTAssertTrue(controller.outputs.first.map { text($0.document, 0).contains("B") } ?? false)
        var settings = WorkflowTextSettings(); settings.text = "RISERVATO"; settings.fontSize = 24; settings.position = .bottomRight; settings.opacity = 0.4
        let annotation = try XCTUnwrap(WorkflowEngine.watermarkAnnotations(source, indices: [0], settings: settings).first?.1)
        XCTAssertEqual(annotation.alignment, .right); XCTAssertEqual(annotation.font?.pointSize, 24)
        XCTAssertEqual((annotation.value(forAnnotationKey: WorkflowWatermarkAnnotation.opacityKey) as? NSNumber)?.doubleValue ?? 0, 0.4, accuracy: 0.01)
        let blank = try document([""])
        settings.color = .black
        let visible = try XCTUnwrap(WorkflowEngine.watermarkAnnotations(blank, indices: [0], settings: settings).first?.1)
        blank.page(at: 0)?.addAnnotation(visible)
        let copied = try WorkflowEngine.extract(blank, indices: [0])
        let reopened = try XCTUnwrap(PDFDocument(data: WorkflowEngine.serialized(copied)))
        let image = try PDFConversionEngine.renderPage(reopened.page(at: 0)!, dpi: 72).image
        let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
        let minimum = stride(from: 0, to: bytes.count, by: 4).map { bytes[$0] }.min() ?? 255
        XCTAssertGreaterThan(minimum, 100)
        XCTAssertLessThan(minimum, 230)
    }

    @MainActor
    func testPreviewInvalidationOverlapMetricUnitsAndChangedSourceGuard() throws {
        let model = PDFEditorModel()
        model.replaceDocument(try document(["A", "B", "C"]), fileName: "Prova.pdf")
        let controller = WorkflowController(model: model, kind: .layout)
        controller.previewPageOrder(); XCTAssertEqual(controller.outputs.count, 1)
        controller.columns = 3; XCTAssertTrue(controller.outputs.isEmpty)
        controller.intervals = "1-2; 2,3"; XCTAssertEqual(controller.splitOverlap, [1])
        XCTAssertEqual(WorkflowUnit.millimetres.factor * 25.4, 72, accuracy: 0.0001)
        XCTAssertEqual(WorkflowUnit.centimetres.factor * 2.54, 72, accuracy: 0.0001)
        controller.cropLeft = Double(controller.cropBounds.width)
        XCTAssertNotNil(controller.cropValidation)
        controller.cropLeft = 18
        let oldBounds = model.currentPage?.bounds(for: .cropBox)
        model.rotateCurrentPage()
        controller.applyCrop()
        XCTAssertTrue(controller.error.map { diagnosticContains($0, "cambiato") } ?? false)
        XCTAssertEqual(model.currentPage?.bounds(for: .cropBox), oldBounds)
    }

    @MainActor
    func testStagedWriterRenamesConflictsAndRollsBackCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Workflow-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try WorkflowEngine.serialized(document(["ORIGINALE"]))
        let first = directory.appendingPathComponent("uno.pdf"); try original.write(to: first)
        let outputs = [WorkflowOutput(name: "uno.pdf", document: try document(["NUOVO1"])), WorkflowOutput(name: "due.pdf", document: try document(["NUOVO2"]))]
        var task: Task<[URL], Error>!
        task = Task { try await WorkflowStagedWriter.write(outputs, directory: directory, policy: .replace) { fraction, _ in if fraction >= 0.9 { task.cancel() } } }
        do { _ = try await task.value; XCTFail("La cancellazione deve interrompere la conferma") } catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: first), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("due.pdf").path))
        let written = try await WorkflowStagedWriter.write(outputs, directory: directory, policy: .rename)
        XCTAssertEqual(written[0].lastPathComponent, "uno-2.pdf"); XCTAssertEqual(written.count, 2)
        XCTAssertEqual(try Data(contentsOf: first), original)
        XCTAssertEqual(PDFDocument(url: written[1])?.pageCount, 1)
        XCTAssertThrowsError(try WorkflowStagedWriter.destinations(names: ["x.pdf", "x.pdf"], directory: directory, policy: .fail))
    }

    @MainActor
    func testBatchPipelineExecutesOrderedStepsWithoutChangingSourcesOrSavingPasswordPreset() async throws {
        let source = try document(["A", "B", "C", "D"])
        var rotate = WorkflowBatchStep(kind: .rotate); rotate.value = 90
        var split = WorkflowBatchStep(kind: .split); split.value = 2
        let steps = [rotate, WorkflowBatchStep(kind: .reverse), split, WorkflowBatchStep(kind: .numbers), WorkflowBatchStep(kind: .protect)]
        let outputs = try await WorkflowEngine.runBatch(sources: [WorkflowSource(document: source, title: "Prova.pdf")], steps: steps, password: "test-privato")
        XCTAssertEqual(outputs.count, 2); XCTAssertTrue(text(outputs[0].document, 0).contains("D"))
        XCTAssertEqual(outputs[0].document.page(at: 0)?.rotation, 90); XCTAssertEqual(source.page(at: 0)?.rotation, 0)
        let protected = try XCTUnwrap(PDFDocument(data: WorkflowEngine.serialized(outputs[0].document, password: outputs[0].password)))
        XCTAssertTrue(protected.isLocked); XCTAssertTrue(protected.unlock(withPassword: "test-privato"))
        let preset = try JSONEncoder().encode(steps)
        XCTAssertFalse(String(data: preset, encoding: .utf8)?.contains("test-privato") ?? true)
        XCTAssertEqual(try JSONDecoder().decode([WorkflowBatchStep].self, from: preset).count, steps.count)
    }
}
