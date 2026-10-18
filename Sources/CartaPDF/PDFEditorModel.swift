import AppKit
import Combine
import PDFKit
import UniformTypeIdentifiers

/// Owns the editable PDF and routes every supported mutation through the document's undo manager.
@MainActor
final class PDFEditorModel: NSObject, ObservableObject {
    let localHistoryID = UUID().uuidString
    @Published var document: PDFDocument
    @Published var fileName = L10n.tr("Senza titolo.pdf")
    @Published var currentPageIndex = 0
    @Published var selectedThumbnailIndex: Int? = 0
    @Published var searchQuery = ""
    @Published var searchResults: [PDFSelection] = []
    @Published var searchResultIndex = -1
    @Published var isSearching = false
    @Published var scale: CGFloat = 1
    @Published var autoScales = true
    @Published var displayMode: PDFDisplayMode = .singlePageContinuous
    @Published var showSidebar = true
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var activeTool: EditorTool = .select
    @Published var annotationColor: NSColor = .systemYellow
    @Published var textFontSize: CGFloat = 18
    @Published var textFontName = "Helvetica"
    @Published var textColor: NSColor = .black
    @Published private(set) var contentRevision = 0
    @Published private(set) var selectedText = ""
    @Published var isProcessing = false
    @Published var processingProgress: Double = 0
    @Published var processingMessage: String?
    @Published var selectedAnnotation: PDFAnnotation?
    weak var selectedAnnotationPage: PDFPage?
    var processingTask: Task<Void, Never>?
    var processingIdentifier: UUID?

    weak var documentOwner: PDFWorkspaceDocument?
    weak var pdfView: PDFView?

    private let standaloneUndoManager = UndoManager()
    private var searchObservers: [NSObjectProtocol] = []
    private var searchGeneration = 0
    private var searchBuffer: [PDFSelection] = []
    private var searchFlush: DispatchWorkItem?
    private var replaceResultsAtFlush = true
    // PDFKit can otherwise edit form widgets outside our undoable editing commands.
    private var formReadOnlyStates: [ObjectIdentifier: (annotation: PDFAnnotation, readOnly: Bool)] = [:]

    override init() {
        document = Self.makeBlankDocument()
        super.init()
        standaloneUndoManager.groupsByEvent = false
    }

    deinit {
        searchObservers.forEach(NotificationCenter.default.removeObserver)
    }

    var pageCount: Int { document.pageCount }
    var currentPage: PDFPage? {
        guard (0..<pageCount).contains(currentPageIndex) else { return nil }
        return document.page(at: currentPageIndex)
    }
    var canEditAnnotations: Bool { !document.isLocked && document.allowsCommenting }
    var canEditPages: Bool { !document.isLocked && document.allowsDocumentAssembly }
    var canEditDocument: Bool { !document.isLocked && document.allowsDocumentChanges }
    var canFillForms: Bool { !document.isLocked && document.allowsFormFieldEntry }
    var canPrint: Bool { !document.isLocked && document.allowsPrinting }
    var canUndo: Bool { editingUndoManager.canUndo }
    var canRedo: Bool { editingUndoManager.canRedo }

    private var editingUndoManager: UndoManager {
        documentOwner?.undoManager ?? standaloneUndoManager
    }

    func replaceDocument(_ newDocument: PDFDocument, fileName: String) {
        cancelSearch()
        restoreFormReadOnlyStates()
        formReadOnlyStates.removeAll()
        document = newDocument
        self.fileName = fileName
        currentPageIndex = 0
        selectedThumbnailIndex = pageCount > 0 ? 0 : nil
        searchQuery = ""
        searchResults = []
        searchResultIndex = -1
        activeTool = .select
        selectedAnnotation = nil
        selectedAnnotationPage = nil
        errorMessage = nil
        statusMessage = newDocument.allowsCommenting && newDocument.allowsDocumentAssembly
            ? nil : L10n.tr("Questo PDF limita alcune operazioni di modifica.")
        editingUndoManager.removeAllActions()
        disableNativeFormEditing()
        if let pdfView {
            pdfView.document = document
            pdfView.autoScales = autoScales
        }
        contentRevision &+= 1
    }

    func attachPDFView(_ view: PDFView) {
        let firstAttachment = pdfView !== view
        let changedDocument = view.document !== document
        if firstAttachment {
            pdfView = view
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, self.pdfView === view else { return }
                self.objectWillChange.send()
            }
        }
        disableNativeFormEditing()
        if changedDocument { view.document = document }
        view.displayMode = displayMode
        view.displaysPageBreaks = true
        view.autoScales = autoScales
        if !autoScales { view.scaleFactor = scale }
        if firstAttachment || changedDocument, let page = currentPage { view.go(to: page) }
    }

    func notifyViewStateChanged() {
        guard let pdfView else { return }
        if let page = pdfView.currentPage {
            let index = document.index(for: page)
            if index != NSNotFound, index < pageCount {
                if currentPageIndex != index { currentPageIndex = index }
                if selectedThumbnailIndex != index { selectedThumbnailIndex = index }
            }
        }
        if abs(scale - pdfView.scaleFactor) > 0.001 { scale = pdfView.scaleFactor }
        if autoScales != pdfView.autoScales { autoScales = pdfView.autoScales }
        let text = pdfView.currentSelection?.string ?? ""
        if selectedText != text { selectedText = text }
        documentOwner?.scheduleReadingPersistence()
    }

    func goToPage(_ index: Int) {
        guard (0..<pageCount).contains(index), let page = document.page(at: index) else { return }
        if currentPageIndex != index { currentPageIndex = index }
        if selectedThumbnailIndex != index { selectedThumbnailIndex = index }
        pdfView?.go(to: page)
    }

    func previousPage() { goToPage(currentPageIndex - 1) }
    func nextPage() { goToPage(currentPageIndex + 1) }

    func zoomIn() { setScale((pdfView?.scaleFactor ?? scale) * 1.2) }
    func zoomOut() { setScale((pdfView?.scaleFactor ?? scale) / 1.2) }
    func actualSize() { setScale(1) }

    func fitToWindow() {
        autoScales = true
        pdfView?.autoScales = true
        if let pdfView { scale = pdfView.scaleFactor }
    }

    private func setScale(_ value: CGFloat) {
        autoScales = false
        scale = min(max(value, 0.1), 8)
        pdfView?.autoScales = false
        pdfView?.scaleFactor = scale
        if let pdfView { scale = pdfView.scaleFactor }
    }

    func search() {
        cancelSearch()
        searchResultIndex = -1
        replaceResultsAtFlush = true
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !document.isLocked else {
            searchResults = []
            pdfView?.highlightedSelections = nil
            statusMessage = nil
            return
        }
        isSearching = true
        statusMessage = L10n.tr("Ricerca in corso…")
        let generation = searchGeneration
        let center = NotificationCenter.default
        searchObservers.append(center.addObserver(forName: .PDFDocumentDidFindMatch, object: document, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.searchGeneration == generation,
                      let match = notification.userInfo?[PDFDocumentFoundSelectionKey] as? PDFSelection else { return }
                match.color = NSColor.systemTeal.withAlphaComponent(0.3)
                self.searchBuffer.append(match)
                self.scheduleSearchFlush()
            }
        })
        searchObservers.append(center.addObserver(forName: .PDFDocumentDidEndFind, object: document, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.searchGeneration == generation else { return }
                self.flushSearchBuffer()
                self.isSearching = false
                self.statusMessage = self.searchResults.isEmpty ? L10n.tr("Nessun risultato.") : L10n.tr("\(self.searchResults.count) risultati trovati.")
            }
        })
        document.beginFindString(query, withOptions: .caseInsensitive)
    }

    func nextSearchResult() {
        guard !searchResults.isEmpty else { return }
        searchResultIndex = (searchResultIndex + 1) % searchResults.count
        revealSearchResult(focusDocument: true)
    }

    func previousSearchResult() {
        guard !searchResults.isEmpty else { return }
        searchResultIndex = (searchResultIndex - 1 + searchResults.count) % searchResults.count
        revealSearchResult(focusDocument: true)
    }

    func chooseSearchResult(_ index: Int) {
        guard searchResults.indices.contains(index) else { return }
        searchResultIndex = index
        revealSearchResult(focusDocument: true)
    }

    private func scheduleSearchFlush() {
        guard searchFlush == nil else { return }
        let item = DispatchWorkItem { [weak self] in self?.flushSearchBuffer() }
        searchFlush = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
    }
    private func flushSearchBuffer() {
        searchFlush?.cancel()
        searchFlush = nil
        if replaceResultsAtFlush { searchResults = []; replaceResultsAtFlush = false }
        searchResults.append(contentsOf: searchBuffer)
        searchBuffer.removeAll(keepingCapacity: true)
        pdfView?.highlightedSelections = searchResults
        if searchResultIndex == -1, !searchResults.isEmpty { searchResultIndex = 0; revealSearchResult() }
    }

    private func revealSearchResult(focusDocument: Bool = false) {
        guard searchResults.indices.contains(searchResultIndex) else { return }
        let selection = searchResults[searchResultIndex]
        for (index, result) in searchResults.enumerated() {
            result.color = index == searchResultIndex ? NSColor.systemPurple.withAlphaComponent(0.4) : NSColor.systemTeal.withAlphaComponent(0.3)
        }
        let oldScale = pdfView?.scaleFactor
        pdfView?.setCurrentSelection(selection, animate: true)
        pdfView?.go(to: selection)
        if !autoScales, let oldScale { pdfView?.scaleFactor = oldScale }
        pdfView?.highlightedSelections = searchResults
        if focusDocument, let pdfView { pdfView.window?.makeFirstResponder(pdfView) }
        if let page = selection.pages.first {
            let index = document.index(for: page)
            if index != NSNotFound {
                currentPageIndex = index
                selectedThumbnailIndex = index
            }
        }
    }

    private func cancelSearch() {
        searchGeneration &+= 1
        searchObservers.forEach(NotificationCenter.default.removeObserver)
        searchObservers.removeAll()
        searchFlush?.cancel()
        searchFlush = nil
        searchBuffer.removeAll()
        if document.isFinding { document.cancelFindString() }
        isSearching = false
    }

    func highlightSelection() {
        guard requireAnnotationPermission(), let selection = pdfView?.currentSelection,
              !(selection.string ?? L10n.tr("")).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if canEditAnnotations { statusMessage = L10n.tr("Seleziona prima il testo da evidenziare.") }
            return
        }
        var annotations: [(PDFPage, PDFAnnotation)] = []
        for line in selection.selectionsByLine() {
            for page in line.pages where belongsToDocument(page) {
                let bounds = line.bounds(for: page).intersection(page.bounds(for: .cropBox))
                guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = annotationColor.withAlphaComponent(0.55)
                annotation.contents = line.string
                stamp(annotation)
                annotations.append((page, annotation))
            }
        }
        guard !annotations.isEmpty else { return }
        addAnnotations(annotations, actionName: L10n.tr("Evidenzia testo"))
        pdfView?.clearSelection()
    }

    func addTextAnnotation(text: String, at point: CGPoint, on page: PDFPage) {
        guard requireAnnotationPermission(), belongsToDocument(page), let text = nonempty(text) else { return }
        let pageBounds = page.bounds(for: .cropBox)
        let width = min(320, max(40, pageBounds.width - 24))
        let size = min(max(textFontSize, 6), 144)
        let font = NSFont(name: textFontName, size: size) ?? NSFont.systemFont(ofSize: size)
        let measured = (text as NSString).boundingRect(with: NSSize(width: width - 12, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        let height = min(max(40, ceil(measured.height) + 14), max(40, pageBounds.height - 24))
        let bounds = boundedRect(at: point, size: CGSize(width: width, height: height), on: page)
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        annotation.font = font
        annotation.fontColor = textColor
        annotation.color = .clear
        annotation.alignment = .left
        annotation.contents = text
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        stamp(annotation)
        addAnnotations([(page, annotation)], actionName: L10n.tr("Aggiungi testo"))
        warnIfTextOverflows(annotation)
    }

    func addNote(text: String, at point: CGPoint, on page: PDFPage) {
        guard requireAnnotationPermission(), belongsToDocument(page), let text = nonempty(text) else { return }
        let annotation = PDFAnnotation(bounds: boundedRect(at: point, size: CGSize(width: 26, height: 26), on: page), forType: .text, withProperties: nil)
        annotation.contents = text
        annotation.color = annotationColor
        annotation.iconType = .note
        stamp(annotation)
        addAnnotations([(page, annotation)], actionName: L10n.tr("Aggiungi nota"))
    }

    func addInkAnnotation(points: [CGPoint], on page: PDFPage) {
        guard requireAnnotationPermission(), belongsToDocument(page) else { return }
        let pageBounds = page.bounds(for: .cropBox)
        let filtered = points.filter { $0.x.isFinite && $0.y.isFinite }
        let points = (CartaPreferences.shared.smoothInk ? CartaInkGeometry.smoothed(filtered) : filtered).map {
            CGPoint(x: min(max($0.x, pageBounds.minX), pageBounds.maxX), y: min(max($0.y, pageBounds.minY), pageBounds.maxY))
        }
        guard points.count > 1, let first = points.first,
              points.contains(where: { hypot($0.x - first.x, $0.y - first.y) > 0.5 }) else { return }
        let minX = points.map(\.x).min()!
        let maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!
        let maxY = points.map(\.y).max()!
        let bounds = CGRect(x: minX - 3, y: minY - 3, width: maxX - minX + 6, height: maxY - minY + 6).intersection(pageBounds)
        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: first.x - bounds.minX, y: first.y - bounds.minY))
        for point in points.dropFirst() {
            path.line(to: CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY))
        }
        annotation.add(path)
        annotation.color = annotationColor.withAlphaComponent(1)
        let border = PDFBorder()
        border.lineWidth = CartaPreferences.shared.strokeWidth
        annotation.border = border
        stamp(annotation)
        addAnnotations([(page, annotation)], actionName: L10n.tr("Disegna"))
    }

    func updateAnnotation(_ annotation: PDFAnnotation, text: String, on page: PDFPage) {
        guard requireAnnotationPermission(), belongsToDocument(page),
              page.annotations.contains(where: { $0 === annotation }),
              annotation.type == "Text" || annotation.type == "FreeText",
              let text = nonempty(text), annotation.contents != text else { return }
        let flags = (annotation.value(forAnnotationKey: .flags) as? NSNumber)?.intValue ?? 0
        guard flags & ((1 << 6) | (1 << 7) | (1 << 9)) == 0 else {
            errorMessage = L10n.tr("L’annotazione non consente modifiche al contenuto.")
            return
        }
        var bounds = annotation.bounds
        if annotation.type == "FreeText" {
            let pageBounds = page.bounds(for: .cropBox)
            let font = annotation.font ?? NSFont.systemFont(ofSize: 18)
            let measured = (text as NSString).boundingRect(with: NSSize(width: max(8, bounds.width - 12), height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
            let height = min(max(40, ceil(measured.height) + 14), pageBounds.height)
            bounds.origin.y = max(pageBounds.minY, bounds.maxY - height)
            bounds.size.height = height
        }
        setAnnotationContents(annotation, text: text, bounds: bounds, modificationDate: Date(), on: page)
    }

    private func setAnnotationContents(_ annotation: PDFAnnotation, text: String?, bounds: CGRect, modificationDate: Date?, on page: PDFPage) {
        let previous = annotation.contents
        let previousBounds = annotation.bounds
        let previousDate = annotation.modificationDate
        performChange(named: L10n.tr("Modifica annotazione"), relayout: false, mutation: {
            annotation.contents = text
            annotation.bounds = bounds
            annotation.modificationDate = modificationDate
        }, inverse: { model in
            model.setAnnotationContents(annotation, text: previous, bounds: previousBounds, modificationDate: previousDate, on: page)
        })
        warnIfTextOverflows(annotation)
    }

    func removeAnnotation(_ annotation: PDFAnnotation, from page: PDFPage) {
        guard requireAnnotationPermission(), belongsToDocument(page),
              page.annotations.contains(where: { $0 === annotation }),
              annotation.type != "Widget", annotation.type != "Link" else { return }
        let flags = (annotation.value(forAnnotationKey: .flags) as? NSNumber)?.intValue ?? 0
        guard flags & ((1 << 6) | (1 << 7)) == 0 else {
            errorMessage = L10n.tr("L’annotazione è protetta e non può essere eliminata.")
            return
        }
        removeAnnotations([(page, annotation)], actionName: L10n.tr("Elimina annotazione"))
    }

    private func addAnnotations(_ annotations: [(PDFPage, PDFAnnotation)], actionName: String) {
        performChange(named: actionName, relayout: false, mutation: {
            for (page, annotation) in annotations { page.addAnnotation(annotation) }
        }, inverse: { model in model.removeAnnotations(annotations, actionName: actionName) })
    }

    private func removeAnnotations(_ annotations: [(PDFPage, PDFAnnotation)], actionName: String) {
        performChange(named: actionName, relayout: false, mutation: {
            for (page, annotation) in annotations { page.removeAnnotation(annotation) }
        }, inverse: { model in model.addAnnotations(annotations, actionName: actionName) })
    }

    func rotateCurrentPage() {
        guard requirePagePermission(), let page = currentPage else { return }
        setRotation(of: page, to: (page.rotation + 90) % 360)
    }

    private func setRotation(of page: PDFPage, to rotation: Int) {
        let previous = page.rotation
        performChange(named: L10n.tr("Ruota pagina"), mutation: {
            page.rotation = rotation
        }, inverse: { model in model.setRotation(of: page, to: previous) })
    }

    func deleteCurrentPage() {
        guard requirePagePermission() else { return }
        guard pageCount > 1 else {
            statusMessage = L10n.tr("Il documento deve contenere almeno una pagina.")
            return
        }
        guard let page = currentPage else { return }
        removePages([(currentPageIndex, page)], actionName: L10n.tr("Elimina pagina"))
    }

    func insertPDF() {
        guard requirePagePermission() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = L10n.tr("Inserisci")
        panel.message = L10n.tr("Le pagine verranno inserite dopo quella corrente.")
        guard panel.runModal() == .OK else { return }
        do {
            var pages: [PDFPage] = []
            for url in panel.urls {
                guard let imported = PDFDocument(url: url) else { throw PDFWorkspaceError.invalidPDF }
                try PDFWorkspaceDocument.unlockIfNeeded(imported, name: url.lastPathComponent)
                guard imported.allowsCopying else { throw PDFWorkspaceError.copyingNotAllowed }
                for index in 0..<imported.pageCount {
                    guard let copy = imported.page(at: index)?.copy() as? PDFPage else { throw PDFWorkspaceError.invalidPDF }
                    pages.append(copy)
                }
            }
            insertCopiedPages(pages, after: currentPageIndex)
        } catch {
            if (error as NSError).code != NSUserCancelledError { errorMessage = error.localizedDescription }
        }
    }

    /// Noninteractive counterpart used by imports and verification. The source retains its pages.
    func insertPages(from imported: PDFDocument, after index: Int? = nil) throws {
        guard canEditPages else { throw PDFWorkspaceError.editingNotAllowed }
        guard !imported.isLocked else { throw PDFWorkspaceError.lockedPDF }
        guard imported.allowsCopying else { throw PDFWorkspaceError.copyingNotAllowed }
        var copies: [PDFPage] = []
        for sourceIndex in 0..<imported.pageCount {
            guard let page = imported.page(at: sourceIndex)?.copy() as? PDFPage else { throw PDFWorkspaceError.invalidPDF }
            copies.append(page)
        }
        insertCopiedPages(copies, after: index ?? currentPageIndex)
    }

    private func insertCopiedPages(_ pages: [PDFPage], after index: Int) {
        guard !pages.isEmpty else { return }
        let start = min(max(index + 1, 0), pageCount)
        insertPages(pages.enumerated().map { (start + $0.offset, $0.element) }, actionName: L10n.tr("Inserisci pagine"))
        goToPage(start)
    }

    private func insertPages(_ indexedPages: [(Int, PDFPage)], actionName: String) {
        performChange(named: actionName, mutation: {
            for (index, page) in indexedPages.sorted(by: { $0.0 < $1.0 }) {
                document.insert(page, at: min(index, document.pageCount))
            }
            disableNativeFormEditing()
        }, inverse: { model in model.removePages(indexedPages, actionName: actionName) })
    }

    private func removePages(_ indexedPages: [(Int, PDFPage)], actionName: String) {
        performChange(named: actionName, mutation: {
            for (_, page) in indexedPages.reversed() {
                let index = document.index(for: page)
                if index != NSNotFound { document.removePage(at: index) }
            }
        }, inverse: { model in model.insertPages(indexedPages, actionName: actionName) })
    }

    func performChange(named name: String, relayout: Bool = true, mutation: () -> Void, inverse: @escaping @MainActor (PDFEditorModel) -> Void) {
        cancelSearch()
        searchResults = []
        searchResultIndex = -1
        pdfView?.highlightedSelections = nil
        let manager = editingUndoManager
        let needsGroup = !manager.isUndoing && !manager.isRedoing
        if needsGroup { manager.beginUndoGrouping() }
        manager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { inverse(model) }
        }
        mutation()
        if let selectedAnnotation, let page = selectedAnnotationPage,
           !page.annotations.contains(where: { $0 === selectedAnnotation }) { selectAnnotation(nil, on: nil) }
        manager.setActionName(name)
        if needsGroup { manager.endUndoGrouping() }
        statusMessage = name
        contentRevision &+= 1
        currentPageIndex = min(max(currentPageIndex, 0), max(0, pageCount - 1))
        selectedThumbnailIndex = pageCount > 0 ? currentPageIndex : nil
        if relayout { pdfView?.layoutDocumentView() }
        if let page = currentPage { pdfView?.annotationsChanged(on: page) }
        if relayout, let page = currentPage { pdfView?.go(to: page) }
        documentOwner?.scheduleRecovery()
    }

    func undo() {
        guard editingUndoManager.canUndo else { return }
        editingUndoManager.undo()
        objectWillChange.send()
    }

    func redo() {
        guard editingUndoManager.canRedo else { return }
        editingUndoManager.redo()
        objectWillChange.send()
    }

    func save() { documentOwner?.save(nil) }
    func saveAs() { documentOwner?.saveAs(nil) }

    func printDocument() {
        guard canPrint else {
            errorMessage = PDFWorkspaceError.printingNotAllowed.localizedDescription
            return
        }
        documentOwner?.printDocument(nil)
    }

    func applyDocumentTransformation(_ replacement: PDFDocument, actionName: String) {
        guard !document.isLocked, !replacement.isLocked, replacement.pageCount > 0,
              canEditDocument else {
            errorMessage = PDFWorkspaceError.editingNotAllowed.localizedDescription
            return
        }
        swapDocument(replacement, pageIndex: currentPageIndex, actionName: actionName)
    }

    private func swapDocument(_ replacement: PDFDocument, pageIndex: Int, actionName: String) {
        let previous = document
        let previousIndex = currentPageIndex
        performChange(named: actionName, mutation: {
            restoreFormReadOnlyStates()
            formReadOnlyStates.removeAll()
            document = replacement
            currentPageIndex = min(max(pageIndex, 0), max(0, replacement.pageCount - 1))
            disableNativeFormEditing()
            pdfView?.document = replacement
        }, inverse: { model in
            model.swapDocument(previous, pageIndex: previousIndex, actionName: actionName)
        })
    }

    func serializedData(options: [AnyHashable: Any]? = nil) throws -> Data {
        guard !document.isLocked else { throw PDFWorkspaceError.lockedPDF }
        restoreFormReadOnlyStates()
        defer { disableNativeFormEditing() }
        let result = options.map { document.dataRepresentation(options: $0) } ?? document.dataRepresentation()
        guard let data = result else { throw PDFWorkspaceError.cannotSave }
        return data
    }

    /// A detached, explicitly unprotected worker copy. Never use this to overwrite the source.
    func unprotectedWorkingSnapshot() throws -> Data {
        guard !document.isLocked, document.allowsCopying else { throw PDFWorkspaceError.copyingNotAllowed }
        restoreFormReadOnlyStates()
        defer { disableNativeFormEditing() }
        let copy = PDFDocument()
        for index in 0..<pageCount {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { throw PDFWorkspaceError.invalidPDF }
            copy.insert(page, at: copy.pageCount)
        }
        copy.documentAttributes = document.documentAttributes
        guard let data = copy.dataRepresentation() else { throw PDFWorkspaceError.cannotSave }
        return data
    }

    func formWasOriginallyReadOnly(_ annotation: PDFAnnotation) -> Bool {
        formReadOnlyStates[ObjectIdentifier(annotation)]?.readOnly ?? annotation.isReadOnly
    }

    func lockNativeFormEditing() { disableNativeFormEditing() }

    func copyPagePreservingFormFlags(_ page: PDFPage) -> PDFPage? {
        restoreFormReadOnlyStates()
        defer { disableNativeFormEditing() }
        return page.copy() as? PDFPage
    }

    private func disableNativeFormEditing() {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.type == "Widget" {
                let key = ObjectIdentifier(annotation)
                if formReadOnlyStates[key] == nil { formReadOnlyStates[key] = (annotation, annotation.isReadOnly) }
                annotation.isReadOnly = true
            }
        }
    }

    private func restoreFormReadOnlyStates() {
        for state in formReadOnlyStates.values { state.annotation.isReadOnly = state.readOnly }
    }

    private func requireAnnotationPermission() -> Bool {
        guard canEditAnnotations else {
            errorMessage = L10n.tr("Questo PDF non consente la modifica delle annotazioni.")
            return false
        }
        return true
    }

    private func requirePagePermission() -> Bool {
        guard canEditPages else {
            errorMessage = L10n.tr("Questo PDF non consente di inserire, eliminare o ruotare pagine.")
            return false
        }
        return true
    }

    private func belongsToDocument(_ page: PDFPage) -> Bool { document.index(for: page) != NSNotFound }
    private func nonempty(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func stamp(_ annotation: PDFAnnotation) {
        annotation.modificationDate = Date()
        annotation.userName = CartaPreferences.shared.annotationAuthor
    }

    private func boundedRect(at point: CGPoint, size: CGSize, on page: PDFPage) -> CGRect {
        let pageBounds = page.bounds(for: .cropBox)
        let width = min(size.width, pageBounds.width)
        let height = min(size.height, pageBounds.height)
        return CGRect(x: min(max(point.x, pageBounds.minX), pageBounds.maxX - width),
                      y: min(max(point.y - height, pageBounds.minY), pageBounds.maxY - height),
                      width: width, height: height)
    }

    private static func makeBlankDocument() -> PDFDocument {
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 595.276, height: 841.89)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else {
            preconditionFailure(L10n.tr("Impossibile creare il contesto PDF."))
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.endPDFPage()
        context.closePDF()
        guard let document = PDFDocument(data: data as Data) else {
            preconditionFailure(L10n.tr("Impossibile creare il documento PDF iniziale."))
        }
        document.documentAttributes = [PDFDocumentAttribute.creatorAttribute: "CartaPDF", PDFDocumentAttribute.titleAttribute: L10n.tr("Senza titolo")]
        return document
    }
}

enum PDFWorkspaceError: LocalizedError {
    case invalidPDF, lockedPDF, cannotSave, editingNotAllowed, copyingNotAllowed, printingNotAllowed

    var errorDescription: String? {
        switch self {
        case .invalidPDF: return L10n.tr("Il file non è un PDF valido o non contiene pagine leggibili.")
        case .lockedPDF: return L10n.tr("Il documento PDF è protetto da password.")
        case .cannotSave: return L10n.tr("Non è stato possibile generare il PDF da salvare.")
        case .editingNotAllowed: return L10n.tr("Il PDF non consente questa modifica.")
        case .copyingNotAllowed: return L10n.tr("Il PDF da inserire non consente di copiarne le pagine.")
        case .printingNotAllowed: return L10n.tr("Il PDF non consente la stampa.")
        }
    }
}
