import AppKit
import AppIntents
import PDFKit
import XCTest
@testable import CartaPDF

final class CartaWorkspaceServicesTests: XCTestCase {
    @MainActor
    func testRecoveryAndVersionsPreserveEncryptionAndDoNotTouchOriginal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CartaSnapshotStore(baseURL: folder)
        let model = PDFEditorModel()
        let data = try model.protectedCopyData(password: "locale-test")
        let source = folder.appendingPathComponent("Originale.pdf")
        let entry = try store.write(data: data, name: "Originale.pdf", source: source, kind: "Recovery")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(entry.encrypted)
        let recovered = try XCTUnwrap(PDFDocument(data: store.data(for: entry)))
        XCTAssertTrue(recovered.isLocked)
        XCTAssertTrue(recovered.unlock(withPassword: "locale-test"))
        XCTAssertEqual(recovered.pageCount, 1)
        for index in 0..<23 { _ = try store.write(data: data, name: "\(index)", source: source, kind: "Versions") }
        XCTAssertEqual(store.entries(kind: "Versions").count, 20)
        store.removeRecovery(id: entry.id)
        XCTAssertTrue(store.entries(kind: "Recovery").isEmpty)
    }

    @MainActor
    func testReadingStateAndPreferencesPersistInIsolatedStores() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CartaSnapshotStore(baseURL: folder)
        let url = folder.appendingPathComponent("Documento.pdf")
        let state = CartaReadingState(page: 7, scale: 1.4, autoScales: false, displayMode: 1, showSidebar: false)
        try store.storeReading(state, for: url)
        XCTAssertEqual(store.readingState(for: url), state)
        let suite = "CartaPDF-Tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = CartaPreferences(defaults: defaults)
        preferences.strokeWidth = 4
        preferences.sidebarWidth = 245
        preferences.annotationAuthor = "Autore locale"
        preferences.shortcuts["focusSearch:"] = "g"
        let reopened = CartaPreferences(defaults: defaults)
        XCTAssertEqual(reopened.strokeWidth, 4)
        XCTAssertEqual(reopened.sidebarWidth, 245)
        XCTAssertEqual(reopened.annotationAuthor, "Autore locale")
        XCTAssertEqual(reopened.shortcuts["focusSearch:"], "g")
    }

    @MainActor
    func testAnnotationMoveAndStyleUndoIndependently() throws {
        let model = PDFEditorModel()
        let livePage = try XCTUnwrap(model.currentPage)
        model.addTextAnnotation(text: "Testo", at: CGPoint(x: 100, y: 700), on: livePage)
        let annotation = try XCTUnwrap(livePage.annotations.first)
        let before = annotation.bounds
        model.moveAnnotation(annotation, to: before.offsetBy(dx: 15, dy: -20), on: livePage)
        XCTAssertNotEqual(annotation.bounds, before)
        model.selectAnnotation(annotation, on: livePage)
        model.textFontSize = 32
        model.textColor = .systemBlue
        model.applySelectedTextStyle()
        XCTAssertEqual(annotation.font?.pointSize, 32)
        model.undo()
        XCTAssertEqual(annotation.font?.pointSize, 18)
        model.undo()
        XCTAssertEqual(annotation.bounds, before)
    }

    @MainActor
    func testImageStampAppearancePersistsAfterPDFReopen() throws {
        let model = PDFEditorModel(), page = try XCTUnwrap(model.currentPage)
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 160,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let stamp = CartaImageStampAnnotation(bounds: CGRect(x: 100, y: 100, width: 120, height: 60), image: try XCTUnwrap(context.makeImage()))
        model.addBatchAnnotations([(page, stamp)], actionName: "Timbro")
        let reopened = try XCTUnwrap(PDFDocument(data: model.serializedData()))
        let rendered = try PDFConversionEngine.renderPage(XCTUnwrap(reopened.page(at: 0)), dpi: 72)
        let pixels = try CartaVisualEngine.pixels(rendered.image, width: 595, height: 842)
        XCTAssertGreaterThan(pixels.enumerated().filter { $0.offset % 4 == 0 && $0.element > 220 && pixels[$0.offset + 1] < 80 }.count, 3000)
        XCTAssertEqual(reopened.page(at: 0)?.annotations.count, 1)
    }

    func testInkSmoothingPreservesEndsAndSharpCorners() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 20)]
        let output = CartaInkGeometry.smoothed(points)
        XCTAssertEqual(output.first, points.first)
        XCTAssertEqual(output.last, points.last)
        XCTAssertEqual(output[1], points[1])
    }

    @MainActor
    func testVisualComparisonAndDuplicateDetectionUseActualPixels() throws {
        let a = PDFEditorModel(), b = PDFEditorModel()
        b.addTextAnnotation(text: "Differenza visibile", at: CGPoint(x: 70, y: 700), on: try XCTUnwrap(b.currentPage))
        let first = try PDFConversionEngine.renderPage(XCTUnwrap(a.currentPage), dpi: 72).image
        let second = try PDFConversionEngine.renderPage(XCTUnwrap(b.currentPage), dpi: 72).image
        XCTAssertEqual(try CartaVisualEngine.difference(left: first, right: first).changedFraction, 0)
        XCTAssertGreaterThan(try CartaVisualEngine.difference(left: first, right: second).changedFraction, 0)
        try a.insertPages(from: a.document)
        XCTAssertEqual(try CartaVisualEngine.duplicatePairs(snapshot: a.serializedData()).count, 1)
    }

    @MainActor
    func testAutomationMergeAndRefusalToOverwriteSources() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a.pdf"), b = folder.appendingPathComponent("b.pdf")
        try PDFEditorModel().serializedData().write(to: a)
        try PDFEditorModel().serializedData().write(to: b)
        let merged = try CartaAutomation.merge([a.path, b.path])
        XCTAssertEqual(PDFDocument(data: merged)?.pageCount, 2)
        XCTAssertThrowsError(try CartaAutomation.write(merged, to: a.path, sources: [a.path], overwrite: true))
        XCTAssertEqual(PDFDocument(url: a)?.pageCount, 1)
    }

    func testGlobalLimiterBoundsConcurrencyAndCancelsWaiters() async throws {
        actor Counter {
            var active = 0; var maximum = 0
            func enter() { active += 1; maximum = max(maximum, active) }
            func leave() { active -= 1 }
        }
        let limiter = CartaJobLimiter(), counter = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await limiter.withPermit(limit: 2) {
                        await counter.enter()
                        try await Task.sleep(for: .milliseconds(5))
                        await counter.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        let maximum = await counter.maximum
        XCTAssertEqual(maximum, 2)
        try await limiter.acquire(limit: 1)
        let waiter = Task { try await limiter.acquire(limit: 1) }
        await Task.yield(); waiter.cancel()
        do { try await waiter.value; XCTFail("Il job in attesa doveva annullarsi.") } catch is CancellationError { }
        await limiter.release()
    }

    func testAtomicWriterRefusesConflictsAndCancellationKeepsPreviousBytes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("output.dat")
        let original = Data("originale".utf8)
        try CartaFileIO.atomicWrite(original, to: url, replaceExisting: false)
        XCTAssertThrowsError(try CartaFileIO.atomicWrite(Data("nuovo".utf8), to: url, replaceExisting: false))
        XCTAssertEqual(try Data(contentsOf: url), original)
        actor Gate {
            var continuation: CheckedContinuation<Void, Never>?
            var open = false
            func wait() async { if !open { await withCheckedContinuation { continuation = $0 } } }
            func release() { open = true; continuation?.resume(); continuation = nil }
        }
        let gate = Gate()
        let writer = Task.detached {
            await gate.wait()
            try CartaFileIO.atomicWrite(Data(repeating: 42, count: 8_000_000), to: url)
        }
        writer.cancel()
        await gate.release()
        do { try await writer.value; XCTFail("Scrittura annullata deve interrompersi prima del commit.") } catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["output.dat"])
        try CartaFileIO.atomicWrite(Data("nuovo".utf8), to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data("nuovo".utf8))
    }

    @MainActor
    func testNativeAppIntentReturnsAnIndependentReadableMergedFile() async throws {
        let data = try PDFEditorModel().serializedData()
        let intent = CartaMergeIntent()
        intent.documents = [IntentFile(data: data, filename: "A.pdf", type: .pdf), IntentFile(data: data, filename: "B.pdf", type: .pdf)]
        let result = try await intent.perform()
        let file = try XCTUnwrap(result.value)
        XCTAssertEqual(PDFDocument(data: file.data)?.pageCount, 2)
        XCTAssertEqual(PDFDocument(data: data)?.pageCount, 1)
    }

    @MainActor
    func testUntitledDocumentsRetainIndependentVersionHistories() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CartaSnapshotStore(baseURL: folder), data = try PDFEditorModel().serializedData()
        for index in 0..<23 { _ = try store.write(data: data, name: "A-\(index)", source: nil, kind: "Versions", documentID: "A") }
        for index in 0..<23 { _ = try store.write(data: data, name: "B-\(index)", source: nil, kind: "Versions", documentID: "B") }
        XCTAssertEqual(store.entries(kind: "Versions").filter { $0.documentID == "A" }.count, 20)
        XCTAssertEqual(store.entries(kind: "Versions").filter { $0.documentID == "B" }.count, 20)
    }

    @MainActor
    func testCancellingVisualWorkersAlwaysClearsBusyState() async throws {
        let data = try PDFEditorModel().serializedData()
        let compare = CartaVisualState(left: data, right: data)
        compare.compare()
        try await Task.sleep(for: .milliseconds(5))
        compare.task?.cancel()
        await compare.task?.value
        XCTAssertFalse(compare.busy)
        let duplicates = CartaVisualState(left: data)
        duplicates.duplicates()
        duplicates.task?.cancel()
        await duplicates.task?.value
        XCTAssertFalse(duplicates.busy)
    }

    @MainActor
    func testVisualComparisonWorkerRetainsPDFDocumentsDuringRasterization() async throws {
        let left = PDFEditorModel(), right = PDFEditorModel()
        right.addTextAnnotation(text: "Differenza reale", at: CGPoint(x: 80, y: 700), on: try XCTUnwrap(right.currentPage))
        let state = CartaVisualState(left: try left.serializedData(), right: try right.serializedData())
        state.compare()
        await state.task?.value
        XCTAssertNotNil(state.image)
        XCTAssertTrue(state.message.contains("Pixel diversi:"), state.message)
        let image = try XCTUnwrap(state.image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let pixels = try CartaVisualEngine.pixels(image, width: 700, height: 900)
        XCTAssertGreaterThan(pixels.enumerated().filter { $0.offset % 4 == 0 && $0.element > 220 && pixels[$0.offset + 1] < 80 }.count, 50)
    }

    @MainActor
    func testMalformedInputsAndLargePageCountHaveBoundedRenderingAndSafeExtraction() throws {
        for bytes in [Data(), Data("non è un PDF".utf8), Data("%PDF-1.7\ntrailer\n<< /Root 99 0 R >>\n%%EOF".utf8)] {
            XCTAssertNil(PDFDocument(data: bytes))
        }
        let model = PDFEditorModel(), page = try XCTUnwrap(model.currentPage)
        let large = PDFDocument()
        for index in 0..<1000 { large.insert(try XCTUnwrap(page.copy() as? PDFPage), at: index) }
        let data = try XCTUnwrap(large.dataRepresentation())
        let reopened = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(reopened.pageCount, 1000)
        model.replaceDocument(reopened, fileName: "Mille pagine.pdf")
        let extracted = try model.extractedDocument(pageIndexes: [0, 499, 999])
        XCTAssertEqual(extracted.pageCount, 3)
        let raster = try PDFConversionEngine.renderPage(XCTUnwrap(extracted.page(at: 2)), dpi: 72)
        XCTAssertLessThanOrEqual(raster.image.width * raster.image.height, 24_000_000)
        model.selectAnnotation(nil, on: nil)
        model.addTextAnnotation(text: String(repeating: "Testo molto lungo. ", count: 500), at: CGPoint(x: 20, y: 800), on: try XCTUnwrap(model.currentPage))
        XCTAssertTrue((model.statusMessage ?? "").contains("supera il riquadro"))
    }
}
