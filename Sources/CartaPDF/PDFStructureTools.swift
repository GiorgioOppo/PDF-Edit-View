import AppKit
import CoreGraphics
import CryptoKit
import ImageIO
import PDFKit
import Security
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PDFStructureWorkspaceState: ObservableObject {
    @Published private(set) var data: Data
    @Published private(set) var pageCount = 0
    @Published private(set) var images: [PDFEmbeddedImage] = []
    @Published private(set) var attachments: [PDFEmbeddedFile] = []
    @Published private(set) var layers: [PDFOptionalLayer] = []
    @Published private(set) var runs: [PDFOriginalTextRun] = []
    @Published private(set) var report: [PDFPreflightItem] = []
    @Published private(set) var signatures: [PDFSignatureVerification] = []
    @Published private(set) var identities: [PDFLocalIdentity] = []
    @Published var error: String?
    @Published var status: String?
    @Published private(set) var encrypted = false
    @Published private(set) var originalTextLimit: String?
    @Published private(set) var isWriting = false
    @Published private(set) var jobMessage = ""
    private var jobIdentifier: UUID?
    private var writeTask: Task<Void, Never>?
    let sourceURL: URL?
    let sourceName: String
    var engine: PDFStructureDocument { get throws { try PDFStructureDocument(data: data) } }

    init(data: Data, sourceURL: URL?, name: String) throws {
        self.data = data; self.sourceURL = sourceURL; sourceName = name
        try reload()
    }
    func reload() throws {
        let reader = try engine; pageCount = try reader.pageIDs().count; encrypted = reader.encrypted
        report = try reader.preflight()
        if encrypted { images = []; attachments = []; layers = []; runs = []; return }
        images = try reader.embeddedImages(); attachments = try reader.embeddedFiles(); layers = try reader.optionalLayers()
        do { runs = try reader.originalTextRuns(); originalTextLimit = nil }
        catch { runs = []; originalTextLimit = error.localizedDescription }
    }
    func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { self.error = error.localizedDescription }
    }
    @discardableResult
    func saveCopy(_ result: Data, suffix: String, verifySignature: Bool = false, archival: Bool = false) throws -> Bool {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (sourceName as NSString).deletingPathExtension + " " + suffix + ".pdf"
        panel.message = L10n.tr("Salva una copia separata. Il documento originale rimane invariato.")
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        try ensureCopyDestination(url)
        let sourceURL = self.sourceURL
        runBackground(message: L10n.tr("Verifica e salvataggio della copia…"), work: {
            try Task.checkCancellation()
            let archivalSummary: String?
            if archival {
                if let declared = PDFArchiveValidator.declaredProfile(data: result) {
                    let report = PDFArchiveValidator.validate(data: result, profile: declared)
                    archivalSummary = L10n.tr("Profilo dichiarato: \(declared.title). Esito: \(report.verdict.title), \(report.unverifiedCount) regole non verificate.")
                } else { archivalSummary = L10n.tr("Profilo PDF/A non riconosciuto nei metadati generati. Apri Validazione PDF/A per il rapporto.") }
            } else { archivalSummary = nil }
            try Task.checkCancellation()
            let expectedPages = try PDFStructureDocument(data: result).pageIDs().count
            guard let provider = CGDataProvider(data: result as CFData), let verification = CGPDFDocument(provider),
                  !verification.isEncrypted, verification.numberOfPages == expectedPages, expectedPages > 0 else {
                throw PDFStructureError.malformed(L10n.tr("la copia non supera la verifica del numero di pagine"))
            }
            if let sourceURL, sourceURL.resolvingSymlinksInPath().standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL {
                throw PDFStructureError.unsupported(L10n.tr("l’output coincide con l’originale"))
            }
            try CartaFileIO.atomicWrite(result, to: url)
            let written = try Data(contentsOf: url, options: .mappedIfSafe)
            guard SHA256.hash(data: written) == SHA256.hash(data: result) else { throw PDFStructureError.malformed(L10n.tr("verifica dei byte salvati")) }
            return (data: result, archivalSummary: archivalSummary)
        }, completion: { [weak self] saved in
            guard let self else { return }
            self.data = saved.data; try self.reload()
            self.signatures = verifySignature ? try PDFLocalCertificateEngine.verify(saved.data) : []
            self.status = L10n.tr("Copia verificata e salvata: \(url.lastPathComponent)")
            if let summary = saved.archivalSummary { self.status = (self.status ?? "") + ". " + summary }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        })
        return true
    }
    private func ensureCopyDestination(_ url: URL) throws {
        if let sourceURL, sourceURL.resolvingSymlinksInPath().standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL {
            throw PDFStructureError.unsupported(L10n.tr("scegli un file diverso dall’originale"))
        }
    }
    private func runBackground<T: Sendable>(message: String, work: @escaping @Sendable () async throws -> T,
                                           completion: @escaping @MainActor (T) throws -> Void) {
        guard !isWriting else { return }
        let identifier = UUID(), limit = CartaPreferences.shared.concurrentJobs
        jobIdentifier = identifier; isWriting = true; jobMessage = message
        let worker = Task.detached(priority: .userInitiated) {
            try await CartaJobLimiter.shared.withPermit(limit: limit) { try await work() }
        }
        writeTask = Task { @MainActor [weak self] in
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, self.jobIdentifier == identifier else { return }
                self.isWriting = false; self.jobIdentifier = nil; self.writeTask = nil
                do { try completion(result) } catch { self.error = error.localizedDescription }
            } catch {
                guard let self, self.jobIdentifier == identifier else { return }
                self.isWriting = false; self.jobIdentifier = nil; self.writeTask = nil
                if error is CancellationError { self.status = L10n.tr("Operazione annullata.") }
                else { self.error = error.localizedDescription }
            }
        }
    }
    func cancelWrite() {
        jobIdentifier = nil; writeTask?.cancel(); writeTask = nil
        isWriting = false; status = L10n.tr("Operazione annullata.")
    }
    private func exportBytes(_ bytes: Data, to url: URL, message: String) throws {
        try ensureCopyDestination(url)
        runBackground(message: L10n.tr("Scrittura del file…"), work: { try CartaFileIO.atomicWrite(bytes, to: url); return true }, completion: { [weak self] _ in self?.status = message })
    }
    func setLabels(startPage: Int, number: Int, prefix: String, style: PDFStructureDocument.PageLabelStyle) {
        perform { try saveCopy(engine.setPageLabels(startPage: startPage, firstNumber: number, prefix: prefix, style: style), suffix: L10n.tr("numerato")) }
    }
    func chooseAttachments(portfolio: Bool) {
        perform {
            let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
            panel.message = portfolio ? L10n.tr("Scegli i file da incorporare nella raccolta PDF.") : L10n.tr("Scegli i file da incorporare come allegati.")
            guard panel.runModal() == .OK else { return }
            let urls = panel.urls
            runBackground(message: L10n.tr("Lettura degli allegati locali…"), work: {
                try urls.map { url -> (name: String, data: Data) in
                    try Task.checkCancellation()
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 256 * 1024 * 1024 else { throw PDFStructureError.limit }
                    return (url.lastPathComponent, try Data(contentsOf: url))
                }
            }, completion: { [weak self] files in
                guard let self, !files.isEmpty else { return }
                let result = portfolio ? try PDFNativeProfileConverter.portfolioIndex(files: files) : try self.engine.addingAttachments(files)
                try self.saveCopy(result, suffix: portfolio ? L10n.tr("raccolta") : L10n.tr("con allegati"))
            })
        }
    }
    func exportAttachment(_ file: PDFEmbeddedFile) {
        perform {
            let bytes = try engine.extractAttachment(file)
            let panel = NSSavePanel(); panel.nameFieldStringValue = (file.name as NSString).lastPathComponent
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try exportBytes(bytes, to: url, message: L10n.tr("Allegato estratto senza eseguirlo: \(url.lastPathComponent)"))
        }
    }
    func deleteAttachment(_ file: PDFEmbeddedFile) {
        perform { try saveCopy(engine.removingAttachment(file), suffix: L10n.tr("senza allegato")) }
    }
    func exportImage(_ image: PDFEmbeddedImage) {
        perform {
            let result = try engine.extractImage(image)
            let panel = NSSavePanel(); panel.nameFieldStringValue = L10n.tr("Immagine-\(image.id.number).\(result.fileExtension)")
            panel.allowedContentTypes = [UTType(filenameExtension: result.fileExtension) ?? .data]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try exportBytes(result.data, to: url, message: L10n.tr("Immagine estratta alla risoluzione incorporata: \(url.lastPathComponent)"))
        }
    }
    func chooseReplacementImage(_ image: PDFEmbeddedImage) {
        perform {
            let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
            panel.message = L10n.tr("Sostituisce questo oggetto immagine in tutte le pagine che lo utilizzano. La trasparenza viene composta su bianco.")
            guard panel.runModal() == .OK, let url = panel.url,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil), let replacement = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            try saveCopy(engine.replaceImage(image.id, with: replacement), suffix: L10n.tr("immagine sostituita"))
        }
    }
    func changeLayer(_ layer: PDFOptionalLayer, visible: Bool) {
        perform { try saveCopy(engine.setLayerVisibility(layer.id, visible: visible), suffix: L10n.tr("livelli")) }
    }
    func replaceText(_ run: PDFOriginalTextRun, text: String) {
        perform { try saveCopy(engine.replaceOriginalText(run, with: text), suffix: L10n.tr("testo modificato")) }
    }
    func makeArchivalCopy() {
        perform {
            guard let source = PDFDocument(data: data) else { throw PDFStructureError.malformed(L10n.tr("documento")) }
            let result = try PDFNativeProfileConverter.redraw(source, archival: true)
            try saveCopy(result, suffix: L10n.tr("PDF-A CoreGraphics"), archival: true)
        }
    }
    func preparePrintProfile() {
        perform {
            let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "icc") ?? .data, UTType(filenameExtension: "icm") ?? .data]
            panel.message = L10n.tr("Scegli un profilo ICC di stampa CMYK locale. Si aggiunge un OutputIntent; non si certifica PDF/X.")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let bytes = try Data(contentsOf: url)
            guard let space = CGColorSpace(iccData: bytes as CFData), space.model == .cmyk,
                  let source = PDFDocument(data: data) else { throw PDFStructureError.unsupported(L10n.tr("profilo ICC CMYK non valido")) }
            try saveCopy(PDFNativeProfileConverter.redraw(source, outputProfile: space, condition: url.lastPathComponent), suffix: L10n.tr("stampa ICC"))
        }
    }
    func authorTags(language: String, role: String, descriptions: [String]) {
        perform { try saveCopy(engine.tagPages(language: language, tags: descriptions.map { .init(role: role, description: $0) }), suffix: L10n.tr("tag accessibili")) }
    }
    func exportReport() {
        perform {
            let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "Preflight.txt"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let text = report.map { "[\($0.severity)] \($0.title)\n\($0.detail)" }.joined(separator: "\n\n")
            try exportBytes(Data(text.utf8), to: url, message: L10n.tr("Rapporto preflight salvato: \(url.lastPathComponent)"))
        }
    }
    func loadIdentities() { perform { identities = try PDFLocalCertificateEngine.identities() } }
    func sign(identityID: String, reason: String) {
        perform {
            guard let identity = identities.first(where: { $0.id == identityID }) else { throw PDFStructureError.unsupported(L10n.tr("seleziona un certificato con chiave privata")) }
            let result = try PDFLocalCertificateEngine.sign(data, identity: identity.identity, reason: reason)
            try saveCopy(result, suffix: L10n.tr("firmato"), verifySignature: true)
        }
    }
    func verifySignatures() { perform { signatures = try PDFLocalCertificateEngine.verify(data); if signatures.isEmpty { status = L10n.tr("Nessun oggetto firma CMS trovato in questo snapshot.") } } }
    func chooseFileToVerify() {
        perform {
            let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]; panel.message = L10n.tr("Verifica i byte originali del file selezionato, senza risalvarlo con PDFKit.")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let bytes = try Data(contentsOf: url); signatures = try PDFLocalCertificateEngine.verify(bytes)
            status = L10n.tr("Verifica offline del file: \(url.lastPathComponent). Nessuna richiesta di rete.")
        }
    }
}

@MainActor
private final class PDFStructureWindowController: NSWindowController, NSWindowDelegate {
    private static var sessions: [PDFStructureWindowController] = []
    private let workspace: PDFStructureWorkspaceState
    init(state: PDFStructureWorkspaceState, section: PDFStructureSection) {
        workspace = state
        let window = NSWindow(contentViewController: NSHostingController(rootView: PDFStructureWorkspaceView(state: state, initialSection: section)))
        window.title = L10n.tr("Struttura PDF · ") + state.sourceName
        window.setContentSize(NSSize(width: 1040, height: 780)); window.minSize = NSSize(width: 840, height: 620)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]; window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self; Self.sessions.append(self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowWillClose(_ notification: Notification) { workspace.cancelWrite(); Self.sessions.removeAll { $0 === self } }
}

@MainActor
extension PDFEditorModel {
    func showStructureWorkspace() { openStructureWorkspace(.structure) }
    func showPreflightWorkspace() { openStructureWorkspace(.preflight) }
    func showCertificateWorkspace() { openStructureWorkspace(.certificates) }
    func showOriginalContentWorkspace() { openStructureWorkspace(.originalContent) }
    private func openStructureWorkspace(_ section: PDFStructureSection) {
        guard !isProcessing else { return }
        do {
            // Clean files must retain their exact bytes, particularly for CMS
            // signatures. PDFKit serialization would rewrite their ByteRange.
            let bytes: Data
            let url = documentOwner?.fileURL
            if let owner = documentOwner, !owner.isDocumentEdited, let url { bytes = try Data(contentsOf: url) }
            else { bytes = try serializedData() }
            let state = try PDFStructureWorkspaceState(data: bytes, sourceURL: url, name: fileName)
            PDFStructureWindowController(state: state, section: section).showWindow(nil)
        } catch { errorMessage = error.localizedDescription }
    }
}
