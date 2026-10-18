import AppKit
import CoreText
import PDFKit
import XCTest
@testable import CartaPDF

final class PDFLocalLibraryTests: XCTestCase {
    @MainActor
    func testLibraryJSONPersistsTagsCategoriesAndRemovalLeavesOriginal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("documento.pdf")
        try document("Caffè locale").write(to: source)
        let storage = folder.appendingPathComponent("Library.json")
        let library = LocalPDFLibrary(storageURL: storage)
        let entry = try LibraryEngine.indexedEntry(url: source); library.entries = [entry]
        library.update(id: entry.id, tags: "lavoro, fattura, lavoro", category: "Contabilità")
        let reopened = LocalPDFLibrary(storageURL: storage)
        XCTAssertEqual(reopened.entries.count, 1)
        XCTAssertEqual(reopened.entries[0].tags, ["fattura", "lavoro"])
        XCTAssertEqual(reopened.entries[0].category, "Contabilità")
        reopened.remove(id: entry.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(LocalPDFLibrary(storageURL: storage).entries.isEmpty)
    }

    func testCrossDocumentSearchFindsAccentInsensitivePageExcerpts() {
        let entries = [LibraryEntry(path: "/tmp/a.pdf", title: "A", pageTexts: ["Nessun risultato", "Il caffè è pronto"]),
                       LibraryEntry(path: "/tmp/b.pdf", title: "B", pageTexts: ["CAFFE locale"])]
        let hits = LibraryEngine.hits(entries: entries, query: "caffe")
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits.map(\.page), [2, 1])
        XCTAssertTrue(hits[0].excerpt.contains("caffè"))
    }

    func testRegexRenameUsesCaptureAndSanitizesPathSeparators() throws {
        XCTAssertEqual(try LibraryEngine.proposedName(text: "Fattura 2026/42", pattern: "Fattura ([0-9/]+)", template: "Documento-$1"), "Documento-2026_42.pdf")
        XCTAssertNil(try LibraryEngine.proposedName(text: "nessun dato", pattern: "Fattura ([0-9]+)", template: "$1"))
        XCTAssertThrowsError(try LibraryEngine.proposedName(text: "Test", pattern: "[", template: "$1"))
    }

    @MainActor
    func testRenameRefusesConflictsAndUpdatesLinkedFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("originale.pdf"), conflict = folder.appendingPathComponent("esistente.pdf")
        try document("Test").write(to: source); try document("Altro").write(to: conflict)
        let entry = try LibraryEngine.indexedEntry(url: source)
        let library = LocalPDFLibrary(storageURL: folder.appendingPathComponent("indice.json")); library.entries = [entry]
        XCTAssertThrowsError(try library.rename(id: entry.id, filename: "esistente.pdf"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        try library.rename(id: entry.id, filename: "nuovo.pdf")
        XCTAssertEqual(library.entries[0].url.lastPathComponent, "nuovo.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("nuovo.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testWatchedFolderProcessesExistingPDFLocallyAndPreservesSource() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let input = folder.appendingPathComponent("input"), output = folder.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = input.appendingPathComponent("test.pdf")
        try document("Testo monitorato").write(to: source)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10)], ofItemAtPath: source.path)
        let watcher = LibraryFolderWatcher(); watcher.input = input; watcher.output = output; watcher.action = .text
        watcher.start(); defer { watcher.stop() }
        let result = output.appendingPathComponent("test.txt")
        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: result.path) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path), watcher.logs.joined(separator: "\n"))
        XCTAssertTrue(try String(contentsOf: result).contains("Testo monitorato"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testWatcherStopRestartDoesNotAcknowledgeCancelledFilesOrAcceptOldCallbacks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let input = folder.appendingPathComponent("input"), output = folder.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["uno", "due"] {
            let source = input.appendingPathComponent(name + ".pdf")
            try document("Testo \(name)").write(to: source)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10)], ofItemAtPath: source.path)
        }
        let probe = WatchCancellationProbe()
        let watcher = LibraryFolderWatcher(converter: { url, action, token in
            try probe.convert(url, action: action, token: token)
        }, scanDelayNanoseconds: 20_000_000)
        watcher.input = input; watcher.output = output; watcher.action = .text
        watcher.start()
        defer { watcher.stop(); probe.releaseOldWorker() }
        for _ in 0..<100 {
            if probe.startedCount > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(probe.startedCount, 1)
        watcher.stop(); watcher.start()
        for _ in 0..<100 {
            if probe.firstWasCancelled { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(probe.firstWasCancelled)
        // Deliver a delayed completion from the previous session after restarting.
        probe.releaseOldWorker()
        for _ in 0..<200 {
            let results = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            if results.filter({ $0.pathExtension == "txt" }).count == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let results = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).filter { $0.pathExtension == "txt" }
        XCTAssertEqual(Set(results.map(\.lastPathComponent)), Set(["uno.txt", "due.txt"]), watcher.logs.joined(separator: "\n"))
        XCTAssertEqual(probe.startedCount, 3, "Una conversione annullata e due conversioni reali dopo il riavvio.")
        XCTAssertEqual(watcher.logs.filter { diagnosticHasPrefix($0, "Creato ") }.count, 2)
        XCTAssertFalse(watcher.logs.contains(where: { $0.contains("CancellationError") }))
        for file in results { XCTAssertTrue(try String(contentsOf: file).contains("Testo")) }
        XCTAssertTrue(watcher.active)
    }

    @MainActor
    func testWatcherRejectsOutputSymlinkToInputFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let input = folder.appendingPathComponent("input"), alias = folder.appendingPathComponent("same-folder")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: input)
        let watcher = LibraryFolderWatcher(); watcher.input = input; watcher.output = alias
        watcher.start(); defer { watcher.stop() }
        XCTAssertFalse(watcher.active)
        XCTAssertTrue(watcher.logs.last.map { diagnosticContains($0, "collegamento simbolico") } == true)
    }

    @MainActor
    func testWatcherNewOutputFolderReprocessesSuccessfulSource() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let input = folder.appendingPathComponent("input"), first = folder.appendingPathComponent("first"), second = folder.appendingPathComponent("second")
        for directory in [input, first, second] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = input.appendingPathComponent("documento.pdf")
        try document("Output distinti").write(to: source)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10)], ofItemAtPath: source.path)
        let watcher = LibraryFolderWatcher(scanDelayNanoseconds: 20_000_000)
        watcher.input = input; watcher.output = first; watcher.action = .text
        watcher.start(); defer { watcher.stop() }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: first.appendingPathComponent("documento.txt").path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        watcher.stop(); watcher.output = second; watcher.start()
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: second.appendingPathComponent("documento.txt").path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("documento.txt")), try String(contentsOf: second.appendingPathComponent("documento.txt")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    private func document(_ text: String) throws -> Data {
        let data = NSMutableData(); var bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        context.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])), context)
        context.endPDFPage(); context.closePDF(); return data as Data
    }
}

private final class WatchCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let oldWorkerRelease = DispatchSemaphore(value: 0)
    private var count = 0
    private var cancelled = false
    var startedCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    var firstWasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func releaseOldWorker() { oldWorkerRelease.signal() }
    func convert(_ url: URL, action: LibraryFolderWatcher.Action, token: ScanCancellation) throws -> LibraryFolderWatcher.Product {
        lock.lock(); count += 1; let call = count; lock.unlock()
        if call == 1 {
            let deadline = Date(timeIntervalSinceNow: 5)
            while Date() < deadline {
                do { try token.check() }
                catch {
                    lock.lock(); cancelled = true; lock.unlock()
                    _ = oldWorkerRelease.wait(timeout: .now() + 5)
                    throw CancellationError()
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
            throw ScanToolError.message("La regressione attendeva l’annullamento della prima conversione.")
        }
        return try LibraryFolderWatcher.convertFile(url, action: action, cancellation: token)
    }
}
