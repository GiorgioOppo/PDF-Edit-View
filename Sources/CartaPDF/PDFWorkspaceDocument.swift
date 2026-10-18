import AppKit
import PDFKit
import SwiftUI

@MainActor
@objc(PDFWorkspaceDocument)
final class PDFWorkspaceDocument: NSDocument {
    let model = PDFEditorModel()
    private let recoveryID = UUID()
    private var recoveryWork: DispatchWorkItem?
    private var readingWork: DispatchWorkItem?

    override class var readableTypes: [String] { ["com.adobe.pdf"] }
    override class var writableTypes: [String] { ["com.adobe.pdf"] }
    override class var autosavesInPlace: Bool { false }
    override class func isNativeType(_ type: String) -> Bool { type == "com.adobe.pdf" }
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }

    override init() {
        super.init()
        model.documentOwner = self
        hasUndoManager = true
        // Every PDF editing command supplies an explicit undo group.
        undoManager?.groupsByEvent = false
        fileType = "com.adobe.pdf"
    }

    override var fileURL: URL? {
        didSet {
            let name = fileURL?.lastPathComponent ?? L10n.tr("Senza titolo.pdf")
            if Thread.isMainThread {
                MainActor.assumeIsolated { updateFileIdentity(name: name) }
            } else {
                DispatchQueue.main.async { [weak self] in self?.updateFileIdentity(name: name) }
            }
        }
    }

    private func updateFileIdentity(name: String) {
        model.fileName = name
        let key = "CartaPDF." + (fileURL.map(CartaSnapshotStore.identity(for:)) ?? "Untitled")
        for controller in windowControllers {
            controller.window?.setFrameAutosaveName(key)
            controller.window?.saveFrame(usingName: key)
        }
    }

    override func read(from data: Data, ofType typeName: String) throws {
        try Self.onMainThread {
            guard let pdf = PDFDocument(data: data) else { throw PDFWorkspaceError.invalidPDF }
            try Self.unlockIfNeeded(pdf, name: fileURL?.lastPathComponent ?? L10n.tr("PDF protetto"))
            guard pdf.pageCount > 0 else { throw PDFWorkspaceError.invalidPDF }
            model.replaceDocument(pdf, fileName: fileURL?.lastPathComponent ?? L10n.tr("Senza titolo.pdf"))
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        try model.serializedData()
    }

    override func makeWindowControllers() {
        model.restoreReadingState()
        let hosting = NSHostingController(rootView: ContentView(model: model).environment(\.locale, L10n.currentLocale))
        let window = PDFWorkspaceWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 1200, height: 820))
        window.contentMinSize = NSSize(width: 880, height: 650)
        window.title = displayName
        window.titleVisibility = .visible
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.center()
        let frameKey = "CartaPDF." + (fileURL.map(CartaSnapshotStore.identity(for:)) ?? "Untitled")
        window.setFrameAutosaveName(frameKey)
        _ = window.setFrameUsingName(frameKey)
        let controller = NSWindowController(window: window)
        addWindowController(controller)
    }

    func scheduleReadingPersistence() {
        readingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.model.persistReadingState() }
        readingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func scheduleRecovery() {
        recoveryWork?.cancel()
        guard CartaPreferences.shared.recoveryEnabled else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isDocumentEdited else { CartaSnapshotStore.shared.removeRecovery(id: self.recoveryID); return }
            do {
                _ = try CartaSnapshotStore.shared.write(data: self.model.serializedData(), name: self.model.fileName,
                                                       source: self.fileURL, kind: "Recovery", id: self.recoveryID)
            } catch { self.model.statusMessage = L10n.tr("Recupero automatico non riuscito: \(error.localizedDescription)") }
        }
        recoveryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            if error == nil {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.recoveryWork?.cancel()
                    CartaSnapshotStore.shared.removeRecovery(id: self.recoveryID)
                    if let data = try? Data(contentsOf: url) {
                        _ = try? CartaSnapshotStore.shared.write(data: data, name: url.lastPathComponent, source: url, kind: "Versions")
                    }
                    self.model.persistReadingState()
                }
            }
            completionHandler(error)
        }
    }

    override func close() {
        recoveryWork?.cancel()
        readingWork?.cancel()
        model.persistReadingState()
        model.cancelProcessing()
        CartaSnapshotStore.shared.removeRecovery(id: recoveryID)
        super.close()
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        guard model.canPrint else { throw PDFWorkspaceError.printingNotAllowed }
        let info = printInfo.copy() as! NSPrintInfo
        for (key, value) in printSettings { info.dictionary()[key] = value }
        guard let operation = model.document.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) else {
            throw PDFWorkspaceError.invalidPDF
        }
        return operation
    }

    static func unlockIfNeeded(_ pdf: PDFDocument, name: String) throws {
        guard pdf.isLocked else { return }
        var failed = false
        while pdf.isLocked {
            let alert = NSAlert()
            alert.messageText = L10n.tr("Password del PDF")
            alert.informativeText = failed
                ? L10n.tr("La password non è corretta. Riprova per aprire “\(name)”.")
                : L10n.tr("Inserisci la password per aprire “\(name)”.")
            alert.alertStyle = .informational
            alert.addButton(withTitle: L10n.tr("Apri"))
            alert.addButton(withTitle: L10n.tr("Annulla"))
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            field.placeholderString = L10n.tr("Password")
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
            }
            if pdf.unlock(withPassword: field.stringValue) { return }
            failed = true
        }
    }

    /// NSDocument's read entry point is nonisolated even when opening is configured serially.
    private nonisolated static func onMainThread<T>(_ body: @MainActor () throws -> T) rethrows -> T {
        if Thread.isMainThread {
            return try MainActor.assumeIsolated { try body() }
        }
        return try DispatchQueue.main.sync {
            try MainActor.assumeIsolated { try body() }
        }
    }
}

/// Native search and formatting text editors keep their undo history separate from PDF edits.
@MainActor
final class PDFWorkspaceWindow: NSWindow {
    private let textEditingUndoManager = UndoManager()

    override var undoManager: UndoManager? {
        if firstResponder is NSTextView { return textEditingUndoManager }
        return super.undoManager
    }
}
