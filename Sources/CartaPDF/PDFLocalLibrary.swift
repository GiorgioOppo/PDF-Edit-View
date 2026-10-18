import AppKit
import AVFoundation
import Combine
import Darwin
import PDFKit
import UniformTypeIdentifiers

struct LibraryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var bookmark: Data?
    var title: String
    var tags: [String] = []
    var category = ""
    var pageTexts: [String]
    var indexedAt = Date()
    var modificationDate: Date?
    var url: URL { URL(fileURLWithPath: path) }
}

struct LibrarySearchHit: Identifiable {
    var id: String { "\(entryID)-\(page)" }
    let entryID: UUID
    let title: String
    let page: Int
    let excerpt: String
}

enum LibraryEngine {
    static func indexedEntry(url: URL) throws -> LibraryEntry {
        guard let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.allowsCopying else { throw ScanToolError.message("\(url.lastPathComponent): PDF protetto o contenuto non copiabile.") }
        let texts = (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }
        let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        return LibraryEntry(path: url.path, bookmark: bookmark, title: url.deletingPathExtension().lastPathComponent,
                            pageTexts: texts, modificationDate: date)
    }

    static func hits(entries: [LibraryEntry], query: String) -> [LibrarySearchHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var hits: [LibrarySearchHit] = []
        for entry in entries {
            for (page, text) in entry.pageTexts.enumerated() {
                guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
                let lower = text.index(range.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
                let upper = text.index(range.upperBound, offsetBy: 100, limitedBy: text.endIndex) ?? text.endIndex
                let excerpt = String(text[lower..<upper]).replacingOccurrences(of: "\n", with: " ")
                hits.append(.init(entryID: entry.id, title: entry.title, page: page + 1, excerpt: excerpt))
            }
        }
        return hits
    }

    static func proposedName(text: String, pattern: String, template: String) throws -> String? {
        let expression = try NSRegularExpression(pattern: pattern)
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let replacement = expression.replacementString(for: match, in: text, offset: 0, template: template)
        let components = replacement.components(separatedBy: CharacterSet(charactersIn: "/:\0\n\r"))
        let sanitized = components.joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty, sanitized != ".", sanitized != "..", sanitized.utf8.count < 220 else { throw ScanToolError.message("Il nome ricavato non è valido o è troppo lungo.") }
        return sanitized.lowercased().hasSuffix(".pdf") ? sanitized : sanitized + ".pdf"
    }
}

@MainActor
final class LocalPDFLibrary: ObservableObject {
    static let shared = LocalPDFLibrary()
    @Published var entries: [LibraryEntry] = []
    @Published var hits: [LibrarySearchHit] = []
    @Published var message = "La biblioteca conserva collegamenti ai file e un indice testuale sul Mac."
    @Published var busy = false
    let storageURL: URL
    private var work: Task<Void, Never>?

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CartaPDF/Library.json")
        do {
            if FileManager.default.fileExists(atPath: self.storageURL.path) {
                entries = try JSONDecoder().decode([LibraryEntry].self, from: Data(contentsOf: self.storageURL))
            }
        } catch { message = "Indice non leggibile: \(error.localizedDescription). Il file è stato conservato." }
    }

    func save() throws {
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: storageURL, options: .atomic)
    }

    func importFiles(_ urls: [URL]) {
        guard !busy else { return }
        busy = true
        work = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { () -> ([LibraryEntry], [String]) in
                var entries: [LibraryEntry] = [], errors: [String] = []
                for url in urls {
                    if Task.isCancelled { break }
                    do { entries.append(try autoreleasepool { try LibraryEngine.indexedEntry(url: url) }) }
                    catch { errors.append(error.localizedDescription) }
                }
                return (entries, errors)
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard let self else { return }
            for incoming in result.0 {
                if let index = self.entries.firstIndex(where: { $0.path == incoming.path }) {
                    var updated = incoming; updated.id = self.entries[index].id
                    updated.tags = self.entries[index].tags; updated.category = self.entries[index].category
                    self.entries[index] = updated
                } else { self.entries.append(incoming) }
            }
            do { try self.save(); self.message = "Indicizzati \(result.0.count) documenti." + (result.1.isEmpty ? "" : "\n" + result.1.joined(separator: "\n")) }
            catch { self.message = error.localizedDescription }
            self.busy = false; self.work = nil
        }
    }

    func resolve(_ entry: LibraryEntry) -> URL {
        guard let bookmark = entry.bookmark else { return entry.url }
        var stale = false
        return (try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)) ?? entry.url
    }

    func search(_ query: String) async {
        let snapshot = entries
        let worker = Task.detached(priority: .userInitiated) { LibraryEngine.hits(entries: snapshot, query: query) }
        let results = await worker.value
        guard !Task.isCancelled else { return }
        hits = results
    }

    func update(id: UUID, tags: String, category: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].tags = Array(Set(tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted()
        entries[index].category = category.trimmingCharacters(in: .whitespaces)
        do { try save(); message = "Etichette salvate localmente." } catch { message = error.localizedDescription }
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        do { try save(); message = "Collegamento rimosso dalla biblioteca. Il PDF è stato conservato." } catch { message = error.localizedDescription }
    }

    func rename(id: UUID, filename: String) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let original = resolve(entries[index]), destination = original.deletingLastPathComponent().appendingPathComponent(filename)
        guard original != destination else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw ScanToolError.message("Esiste già \(filename). Nessun file sovrascritto.") }
        try FileManager.default.moveItem(at: original, to: destination)
        NSDocumentController.shared.document(for: original)?.fileURL = destination
        entries[index].path = destination.path
        entries[index].title = destination.deletingPathExtension().lastPathComponent
        entries[index].bookmark = try? destination.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        try save()
    }
}

@MainActor
final class LibraryFolderWatcher: ObservableObject {
    enum Action: String, CaseIterable, Identifiable, Sendable { case text = "Estrai TXT", ocr = "Copia OCR", tiff = "TIFF multipagina"; var id: String { rawValue } }
    struct Product: Sendable { let data: Data; let suffix: String }
    typealias Converter = @Sendable (URL, Action, ScanCancellation) throws -> Product
    @Published var input: URL?
    @Published var output: URL?
    @Published var action: Action = .text
    @Published var active = false
    @Published var logs: [String] = []
    private var source: DispatchSourceFileSystemObject?
    private var debounce: Task<Void, Never>?
    private var job: Task<Void, Never>?
    private var fingerprints: [String: String] = [:]
    private var failedFingerprints: [String: String] = [:]
    private var cancellation = ScanCancellation()
    private var generation = UUID()
    private let converter: Converter
    private let scanDelayNanoseconds: UInt64

    init(converter: Converter? = nil, scanDelayNanoseconds: UInt64 = 1_000_000_000) {
        let nativeConverter: Converter = { url, action, token in try LibraryFolderWatcher.convertFile(url, action: action, cancellation: token) }
        self.converter = converter ?? nativeConverter
        self.scanDelayNanoseconds = scanDelayNanoseconds
    }

    nonisolated static func convertFile(_ url: URL, action: Action, cancellation: ScanCancellation) throws -> Product {
        try cancellation.check()
        guard let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.allowsCopying,
              action == .text || pdf.allowsPrinting, let snapshot = pdf.dataRepresentation() else {
            throw ScanToolError.message("PDF protetto o non esportabile")
        }
        switch action {
        case .text:
            let text = ScanExportEngine.normalizedParagraphs(PDFConversionEngine.extractedText(from: pdf))
            guard !text.isEmpty else { throw PDFConversionError.noText }
            return Product(data: Data(text.utf8), suffix: ".txt")
        case .tiff: return Product(data: try ScanExportEngine.tiff(snapshot: snapshot, cancellation: cancellation), suffix: ".tiff")
        case .ocr: return Product(data: try AdvancedScanEngine.process(snapshot: snapshot, options: ScanOptions(), cancellation: cancellation).data, suffix: "-OCR.pdf")
        }
    }

    func start() {
        guard let input, let output,
              input.resolvingSymlinksInPath().standardizedFileURL != output.resolvingSymlinksInPath().standardizedFileURL else {
            logs.append("Scegli due cartelle diverse, anche quando usi un collegamento simbolico."); return
        }
        stop()
        let descriptor = open(input.path, O_EVTONLY)
        guard descriptor >= 0 else { logs.append("La cartella non è accessibile."); return }
        cancellation = ScanCancellation()
        let id = generation
        let monitor = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        monitor.setEventHandler { [weak self] in guard self?.generation == id else { return }; self?.scheduleScan() }
        monitor.setCancelHandler { close(descriptor) }
        source = monitor; active = true; monitor.resume()
        logs.append("Monitoraggio attivo mentre CartaPDF è aperto; i file esistenti vengono elaborati una volta.")
        scheduleScan()
    }

    func stop() {
        generation = UUID()
        active = false; source?.cancel(); source = nil
        debounce?.cancel(); debounce = nil; job?.cancel(); job = nil; cancellation.cancel()
        failedFingerprints.removeAll()
    }

    private func scheduleScan() {
        guard active else { return }
        debounce?.cancel()
        let id = generation, delay = scanDelayNanoseconds
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, self.active, self.generation == id else { return }
            self.scanDirectory()
        }
    }

    private func scanDirectory() {
        guard job == nil, active, let input, let output else { return }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles])
                .filter { $0.pathExtension.lowercased() == "pdf" }
            var pending: [(URL, String)] = []
            var recentFile = false
            for file in files {
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
                guard values.isRegularFile == true, let date = values.contentModificationDate else { continue }
                if Date().timeIntervalSince(date) <= 1 { recentFile = true; continue }
                let fingerprint = "\(output.resolvingSymlinksInPath().standardizedFileURL.path)-\(action.rawValue)-\(values.fileSize ?? 0)-\(date.timeIntervalSince1970)"
                if fingerprints[file.path] != fingerprint && failedFingerprints[file.path] != fingerprint { pending.append((file, fingerprint)) }
            }
            guard !pending.isEmpty else { if recentFile { scheduleScan() }; return }
            let action = self.action, token = cancellation, id = generation
            let converter = self.converter, limit = CartaPreferences.shared.concurrentJobs
            let receiver = LibraryWeakReference(self)
            let filesToProcess = pending.sorted { $0.0.path < $1.0.path }
            job = Task { [weak self] in
                let worker = Task.detached(priority: .utility) {
                  try await CartaJobLimiter.shared.withPermit(limit: limit) {
                    for (url, fingerprint) in filesToProcess {
                        do {
                            try token.check()
                            let product = try converter(url, action, token)
                            try token.check()
                            let base = url.deletingPathExtension().lastPathComponent
                            var target = output.appendingPathComponent(base + product.suffix), version = 2
                            while FileManager.default.fileExists(atPath: target.path) { target = output.appendingPathComponent(base + "-\(version)" + product.suffix); version += 1 }
                            try CartaFileIO.atomicWrite(product.data, to: target, replaceExisting: false)
                            let message = "Creato \(target.lastPathComponent)"
                            await MainActor.run { receiver.value?.record(url: url, fingerprint: fingerprint, message: message, succeeded: true, generation: id) }
                        } catch {
                            if error is CancellationError { break }
                            do { try token.check() } catch { break }
                            let message = "\(url.lastPathComponent): \(error.localizedDescription)"
                            await MainActor.run { receiver.value?.record(url: url, fingerprint: fingerprint, message: message, succeeded: false, generation: id) }
                        }
                    }
                  }
                }
                do { try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel(); token.cancel() }) }
                catch {
                    if !(error is CancellationError), let self, self.generation == id { self.logs.append(error.localizedDescription) }
                }
                guard let self, self.generation == id else { return }
                self.job = nil
                if self.active { self.scheduleScan() }
            }
        } catch { logs.append(error.localizedDescription) }
    }

    private func record(url: URL, fingerprint: String, message: String, succeeded: Bool, generation id: UUID) {
        guard active, generation == id else { return }
        // A canceled conversion is never acknowledged: the unchanged source is eligible on restart.
        if succeeded { fingerprints[url.path] = fingerprint; failedFingerprints.removeValue(forKey: url.path) }
        else { failedFingerprints[url.path] = fingerprint }
        logs.append(message); logs = Array(logs.suffix(200))
    }
}

private final class LibraryWeakReference<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

@MainActor
final class LibrarySpeechController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var speaking = false
    @Published var paused = false
    @Published var message = "Usa esclusivamente le voci già installate sul Mac."
    @Published var voiceIdentifier = ""
    @Published var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    let voices = AVSpeechSynthesisVoice.speechVoices().sorted { $0.name < $1.name }
    private let synthesizer = AVSpeechSynthesizer()
    override init() { super.init(); synthesizer.delegate = self; voiceIdentifier = voices.first(where: { $0.language.hasPrefix("it") })?.identifier ?? voices.first?.identifier ?? "" }
    func read(_ text: String) {
        stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { message = "Nessun testo selezionabile. Esegui prima l’OCR."; return }
        guard let voice = voices.first(where: { $0.identifier == voiceIdentifier }) else { message = "Nessuna voce installata disponibile."; return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice; utterance.rate = rate
        speaking = true; paused = false; message = "Lettura locale con \(voice.name)."
        synthesizer.speak(utterance)
    }
    func togglePause() { if paused { synthesizer.continueSpeaking() } else { synthesizer.pauseSpeaking(at: .word) }; paused.toggle() }
    func stop() { synthesizer.stopSpeaking(at: .immediate); speaking = false; paused = false }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.speaking = false; self?.paused = false; self?.message = "Lettura terminata." }
    }
}
