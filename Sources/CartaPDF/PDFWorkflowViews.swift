import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum WorkflowWorkspaceKind: String {
    case merge = "Unione PDF", split = "Divisione PDF", layout = "Impaginazione e pagine", batch = "Procedure batch"
    case watermark = "Filigrana", numbering = "Intestazioni e numerazione", crop = "Ritaglio interattivo"
}

enum WorkflowUnit: String, CaseIterable, Identifiable {
    case points = "pt", millimetres = "mm", centimetres = "cm"
    var id: String { rawValue }
    var factor: Double { switch self { case .points: return 1; case .millimetres: return 72 / 25.4; case .centimetres: return 72 / 2.54 } }
}

@MainActor
final class WorkflowController: ObservableObject {
    let model: PDFEditorModel
    let kind: WorkflowWorkspaceKind
    @Published var sources: [WorkflowSource] = []
    @Published var mergeMode: WorkflowMergeMode = .append { didSet { invalidatePlan() } }
    @Published var reverseBacks = true { didSet { invalidatePlan() } }
    @Published var keepOutlines = true { didSet { invalidatePlan() } }
    @Published var splitMode: WorkflowSplitMode = .everyN { didSet { invalidatePlan() } }
    @Published var splitCount = 10 { didSet { invalidatePlan() } }
    @Published var intervals = "tutte" { didSet { invalidatePlan() } }
    @Published var marker = "" { didSet { invalidatePlan() } }
    @Published var maxMegabytes: Double = 5 { didSet { invalidatePlan() } }
    @Published var skipMarkers = false { didSet { invalidatePlan() } }
    @Published var blankThreshold: Double = 0.002 { didSet { invalidatePlan() } }
    @Published var namePattern = "{name}-{index:03}"
    @Published var conflictPolicy: WorkflowConflictPolicy = .rename
    @Published var directory: URL?
    @Published var parts: [WorkflowPart] = []
    @Published var outputs: [WorkflowOutput] = []
    @Published var outputURLs: [URL] = []
    @Published var selectedOutput = 0
    @Published var preview: PDFDocument?
    @Published var busy = false
    @Published var progress: Double = 0
    @Published var message = ""
    @Published var error: String?
    @Published var draggedSource: UUID?
    @Published var draggedPage: UUID?
    @Published var pageOrder: [WorkflowPageToken] = []
    @Published var selectedPageToken: UUID?
    @Published var layoutMode: WorkflowLayoutMode = .organize { didSet { invalidatePlan() } }
    @Published var columns = 2 { didSet { invalidatePlan() } }
    @Published var rows = 2 { didSet { invalidatePlan() } }
    @Published var sheetWidth: Double = 841.89 { didSet { invalidatePlan() } }
    @Published var sheetHeight: Double = 595.276 { didSet { invalidatePlan() } }
    @Published var gutter: Double = 12 { didSet { invalidatePlan() } }
    @Published var overlayOpacity: Double = 0.4 { didSet { invalidatePlan() } }
    @Published var rightFirst = false { didSet { invalidatePlan() } }
    @Published var replacementRange = "1" { didSet { invalidatePlan() } }
    @Published var contentsTitle = "Indice" { didSet { invalidatePlan() } }
    @Published var selectionRange = "tutte"
    @Published var watermark = WorkflowTextSettings()
    @Published var numbering = WorkflowNumberingSettings()
    @Published var replaceNumbers = false
    @Published var cropTop: Double = 18
    @Published var cropLeft: Double = 18
    @Published var cropBottom: Double = 18
    @Published var cropRight: Double = 18
    @Published var cropUnit: WorkflowUnit = .points
    @Published var cropPageIndex = 0
    @Published var cropImage: NSImage?
    @Published var steps: [WorkflowBatchStep] = [WorkflowBatchStep(kind: .rotate)] { didSet { invalidatePlan() } }
    @Published var newStep: WorkflowBatchKind = .watermark
    @Published var batchPassword = ""
    private var task: Task<Void, Never>?
    private var sourceRevision: Int
    private let hadDocumentOwner: Bool

    init(model: PDFEditorModel, kind: WorkflowWorkspaceKind) {
        self.model = model; self.kind = kind
        sourceRevision = model.contentRevision; hadDocumentOwner = model.documentOwner != nil
        do { sources = [try model.workflowSource()] } catch { self.error = error.localizedDescription }
        pageOrder = (0..<(sources.first?.document.pageCount ?? 0)).map { WorkflowPageToken(index: $0) }
        cropPageIndex = model.currentPageIndex
        let preferences = UserDefaults.standard
        if preferences.bool(forKey: "Workflow.crop.saved") {
            cropTop = preferences.double(forKey: "Workflow.crop.top"); cropLeft = preferences.double(forKey: "Workflow.crop.left")
            cropBottom = preferences.double(forKey: "Workflow.crop.bottom"); cropRight = preferences.double(forKey: "Workflow.crop.right")
            cropUnit = WorkflowUnit(rawValue: preferences.string(forKey: "Workflow.crop.unit") ?? "pt") ?? .points
        }
        if preferences.bool(forKey: "Workflow.numbers.saved") {
            numbering.header = preferences.string(forKey: "Workflow.numbers.header") ?? ""
            numbering.footer = preferences.string(forKey: "Workflow.numbers.footer") ?? "{page} / {pages}"
            numbering.batesPrefix = preferences.string(forKey: "Workflow.numbers.prefix") ?? "DOC-"
            numbering.start = preferences.integer(forKey: "Workflow.numbers.start"); numbering.padding = preferences.integer(forKey: "Workflow.numbers.padding")
            numbering.fontSize = CGFloat(preferences.double(forKey: "Workflow.numbers.font"))
            numbering.usesBates = preferences.bool(forKey: "Workflow.numbers.bates")
        }
        if let source = sources.first { setPreview(source.document) }
        updateCropImage()
    }

    var firstSource: WorkflowSource? { sources.first }
    var selectedIndices: WorkflowRangeResult? { firstSource.flatMap { try? WorkflowEngine.parseRange(selectionRange, pageCount: $0.document.pageCount) } }
    var splitOverlap: [Int] {
        guard let source = firstSource else { return [] }
        var seen = Set<Int>(), repeated = Set<Int>()
        for raw in intervals.split(separator: ";") {
            for index in (try? WorkflowEngine.parseRange(String(raw), pageCount: source.document.pageCount).indices) ?? [] {
                if !seen.insert(index).inserted { repeated.insert(index) }
            }
        }
        return repeated.sorted()
    }
    var selectionError: String? {
        guard let source = firstSource else { return "Nessun documento." }
        do { _ = try WorkflowEngine.parseRange(selectionRange, pageCount: source.document.pageCount); return nil }
        catch { return error.localizedDescription }
    }
    var duplicateNames: [String] {
        var seen = Set<String>(), duplicates: [String] = []
        for source in sources {
            let identity = source.url?.resolvingSymlinksInPath().path ?? "\(source.title)|\(source.byteCount)"
            if !seen.insert(identity).inserted { duplicates.append(source.title) }
        }
        return duplicates
    }
    var pageFormats: [String] {
        Set(sources.flatMap(\.formats)).sorted()
    }
    var totalSelectedPages: Int { sources.reduce(0) { $0 + ((try? WorkflowEngine.parseRange($1.range, pageCount: $1.document.pageCount).indices.count) ?? 0) } }
    var conflicts: [String] {
        guard let directory else { return [] }
        return outputs.map(\.name).filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }
    func finalName(_ index: Int) -> String {
        guard outputs.indices.contains(index) else { return "" }
        guard let directory, let resolved = try? WorkflowStagedWriter.destinations(names: outputs.map(\.name), directory: directory, policy: conflictPolicy), resolved.indices.contains(index) else { return outputs[index].name }
        return resolved[index].lastPathComponent
    }
    var cropBounds: CGRect { firstSource?.document.page(at: cropPageIndex)?.bounds(for: .cropBox) ?? .zero }
    var cropValidation: String? {
        guard [cropTop, cropLeft, cropBottom, cropRight].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return "I margini devono essere numeri positivi." }
        if cropBounds.width - cropLeft - cropRight < 18 || cropBounds.height - cropTop - cropBottom < 18 { return "Il ritaglio deve lasciare almeno 18 pt per lato." }
        return nil
    }
    var existingNumbers: Int { WorkflowEngine.existingNumberingCount(model.document) }
    var batesPreview: String {
        let count = selectedIndices?.indices.count ?? 0
        guard numbering.start >= 0, numbering.start <= Int.max - count, (1...20).contains(numbering.padding) else { return "Parametri non validi" }
        func value(_ number: Int) -> String { let text = String(number); return numbering.batesPrefix + String(repeating: "0", count: max(0, numbering.padding - text.count)) + text }
        return "\(value(numbering.start)) → \(value(numbering.start + max(0, count - 1)))"
    }

    func start(_ operation: @escaping @MainActor (WorkflowController) async throws -> Void) {
        guard !busy else { return }
        error = nil; outputURLs = []; busy = true; progress = 0
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.task = nil; self.batchPassword = "" }
            do {
                self.message = "In attesa di una risorsa di elaborazione…"
                let limit = CartaPreferences.shared.concurrentJobs
                try await CartaJobLimiter.shared.withPermit(limit: limit) { try await operation(self) }
            }
            catch is CancellationError { self.message = "Operazione annullata. I documenti sorgente sono invariati." }
            catch { self.error = error.localizedDescription }
        }
    }

    func cancel() { task?.cancel() }
    func invalidatePlan() {
        guard !busy else { return }
        if !outputs.isEmpty { message = "Parametri cambiati: genera una nuova anteprima prima di salvare." }
        outputs = []; parts = []; outputURLs = []
    }
    func report(_ fraction: Double, _ text: String) { progress = min(max(fraction, 0), 1); message = text }

    func addFiles() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        addURLs(panel.urls)
    }

    func addURLs(_ urls: [URL]) {
        guard !busy else { return }
        do {
            for url in urls {
                guard let document = PDFDocument(url: url) else { throw PDFWorkspaceError.invalidPDF }
                try PDFWorkspaceDocument.unlockIfNeeded(document, name: url.lastPathComponent)
                try WorkflowEngine.validateSource(document)
                sources.append(WorkflowSource(document: document, title: url.lastPathComponent, url: url))
            }
            invalidatePlan()
        } catch { self.error = error.localizedDescription }
    }

    func moveSource(_ id: UUID, before other: UUID) {
        guard id != other, let from = sources.firstIndex(where: { $0.id == id }), let to = sources.firstIndex(where: { $0.id == other }) else { return }
        let first = sources.first?.id
        let value = sources.remove(at: from); sources.insert(value, at: from < to ? to - 1 : to)
        outputs = []; parts = []
        if sources.first?.id != first { if kind == .layout { resetFirstSource() } else { preview = nil } }
    }

    func removeSource(_ id: UUID) {
        let first = sources.first?.id
        sources.removeAll { $0.id == id }; outputs = []; parts = []
        if sources.first?.id != first { if kind == .layout { resetFirstSource() } else { preview = nil } }
    }

    private func resetFirstSource() {
        pageOrder = (0..<(firstSource?.document.pageCount ?? 0)).map { WorkflowPageToken(index: $0) }
        cropPageIndex = 0; updateCropImage()
        if let source = firstSource { setPreview(source.document) } else { preview = nil }
    }

    func buildMerge() {
        start { controller in
            if controller.mergeMode == .groups {
                let groups = WorkflowEngine.groupedSources(controller.sources)
                var results: [WorkflowOutput] = []
                for (index, group) in groups.enumerated() {
                    let result = try await WorkflowEngine.merge(group.1, keepOutline: controller.keepOutlines) { fraction, message in controller.report((Double(index) + fraction) / Double(groups.count), message) }
                    let name = WorkflowEngine.outputName(pattern: "{name}-unito", source: group.0, part: WorkflowPart(indices: Array(0..<result.pageCount), label: group.0), index: index)
                    results.append(WorkflowOutput(name: name, document: result))
                }
                controller.outputs = results
            } else {
                let result = try await WorkflowEngine.merge(controller.sources, alternate: controller.mergeMode == .alternate,
                                                            reverseBacks: controller.reverseBacks, keepOutline: controller.keepOutlines, progress: controller.report)
                controller.outputs = [WorkflowOutput(name: "Documenti uniti.pdf", document: result)]
            }
            controller.selectOutput(0)
            controller.message = "Anteprima pronta: \(controller.outputs.count) PDF. Le sorgenti non sono state modificate."
        }
    }

    func buildSplit() {
        start { controller in
            guard let source = controller.firstSource else { throw WorkflowError("Scegli un documento.") }
            let bytes = controller.maxMegabytes * 1_000_000
            guard bytes.isFinite, bytes >= 1024, bytes <= Double(Int.max / 2) else { throw WorkflowError("Dimensione massima non valida.") }
            controller.parts = try await WorkflowEngine.planSplit(source.document, mode: controller.splitMode, count: controller.splitCount,
                                                                 intervals: controller.intervals, marker: controller.marker, maxBytes: Int(bytes),
                                                                 skipMarkers: controller.skipMarkers, blankThreshold: controller.blankThreshold, progress: controller.report)
            var outputs: [WorkflowOutput] = []
            for (index, part) in controller.parts.enumerated() {
                try Task.checkCancellation()
                outputs.append(WorkflowOutput(name: WorkflowEngine.outputName(pattern: controller.namePattern, source: source.title, part: part, index: index),
                                              document: try WorkflowEngine.extract(source.document, indices: part.indices)))
                controller.report(Double(index + 1) / Double(controller.parts.count), "Anteprima parte \(index + 1)/\(controller.parts.count)")
                await Task.yield()
            }
            controller.outputs = outputs; controller.selectOutput(0)
            controller.message = "\(outputs.count) file pronti per la revisione."
        }
    }

    func renameSplitOutputs() {
        guard let source = firstSource, outputs.count == parts.count else { return }
        for index in outputs.indices { outputs[index].name = WorkflowEngine.outputName(pattern: namePattern, source: source.title, part: parts[index], index: index) }
    }

    func selectOutput(_ index: Int) { guard outputs.indices.contains(index) else { return }; selectedOutput = index; setPreview(outputs[index].document) }

    func setPreview(_ document: PDFDocument) {
        // A separate display copy prevents native form edits from changing prepared outputs.
        guard let data = document.dataRepresentation(), let copy = PDFDocument(data: data) else { preview = nil; return }
        for index in 0..<copy.pageCount { for annotation in copy.page(at: index)?.annotations ?? [] where annotation.type == "Widget" { annotation.isReadOnly = true } }
        preview = copy
    }

    func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Scegli cartella"
        if panel.runModal() == .OK { directory = panel.url }
    }

    func saveOutputs() {
        if directory == nil { chooseDirectory() }
        guard let directory, !outputs.isEmpty else { return }
        if conflictPolicy == .replace && !conflicts.isEmpty {
            let alert = NSAlert(); alert.messageText = "Sostituire \(conflicts.count) file?"
            alert.informativeText = conflicts.prefix(12).joined(separator: "\n") + "\nLe sorgenti non possono essere sovrascritte."
            alert.addButton(withTitle: "Sostituisci copie"); alert.addButton(withTitle: "Annulla")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        start { controller in
            controller.outputURLs = try await WorkflowStagedWriter.write(controller.outputs, directory: directory, policy: controller.conflictPolicy,
                                                                          protectedURLs: controller.sources.compactMap(\.url), progress: controller.report)
            controller.message = "Salvati e verificati \(controller.outputURLs.count) PDF."
        }
    }

    func revealOutputs() { if !outputURLs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outputURLs) } }
    func openSelectedOutput() {
        guard outputs.indices.contains(selectedOutput) else { return }
        model.openGeneratedDocument(outputs[selectedOutput].document, name: outputs[selectedOutput].name)
    }

    func movePage(_ id: UUID, before target: UUID) { movePage(id, before: target, preview: true) }

    func movePage(_ id: UUID, before target: UUID, preview shouldPreview: Bool) {
        guard id != target, let from = pageOrder.firstIndex(where: { $0.id == id }), let to = pageOrder.firstIndex(where: { $0.id == target }) else { return }
        let token = pageOrder.remove(at: from); pageOrder.insert(token, at: from < to ? to - 1 : to)
        if shouldPreview { previewPageOrder() }
    }

    func duplicatePage(_ token: WorkflowPageToken) {
        guard let index = pageOrder.firstIndex(where: { $0.id == token.id }) else { return }
        pageOrder.insert(WorkflowPageToken(index: token.index), at: index + 1); previewPageOrder()
    }

    func movePageBy(_ token: WorkflowPageToken, offset: Int) {
        guard let index = pageOrder.firstIndex(where: { $0.id == token.id }), pageOrder.indices.contains(index + offset) else { return }
        pageOrder.swapAt(index, index + offset); previewPageOrder()
    }

    func deletePage(_ token: WorkflowPageToken) { guard pageOrder.count > 1 else { return }; pageOrder.removeAll { $0.id == token.id }; previewPageOrder() }

    func previewPageOrder() {
        guard let source = firstSource else { return }
        do {
            let document = try WorkflowEngine.extract(source.document, indices: pageOrder.map(\.index))
            outputs = [WorkflowOutput(name: "Pagine organizzate.pdf", document: document)]; selectOutput(0)
        } catch { self.error = error.localizedDescription }
    }

    func buildLayout() {
        start { controller in
            guard let source = controller.firstSource else { throw WorkflowError("Scegli il documento base.") }
            let result: PDFDocument
            let sheet = CGSize(width: controller.sheetWidth, height: controller.sheetHeight)
            switch controller.layoutMode {
            case .organize: result = try WorkflowEngine.extract(source.document, indices: controller.pageOrder.map(\.index))
            case .replace:
                guard controller.sources.count >= 2 else { throw WorkflowError("Aggiungi il PDF con le pagine sostitutive: viene usato il secondo documento della coda.") }
                let selected = try WorkflowEngine.parseRange(controller.replacementRange, pageCount: source.document.pageCount).indices
                let replacementSource = controller.sources[1]
                let replacement = try WorkflowEngine.extract(replacementSource.document, indices: WorkflowEngine.parseRange(replacementSource.range, pageCount: replacementSource.document.pageCount).indices)
                result = try WorkflowEngine.replace(source.document, indices: selected, replacements: replacement)
            case .nUp, .booklet:
                result = try await WorkflowEngine.nUp(source.document, columns: controller.columns, rows: controller.rows, sheet: sheet,
                                                      gutter: controller.gutter, booklet: controller.layoutMode == .booklet, progress: controller.report)
            case .poster: result = try await WorkflowEngine.poster(source.document, columns: controller.columns, rows: controller.rows, sheet: sheet, overlap: controller.gutter, progress: controller.report)
            case .facing: result = try await WorkflowEngine.facing(source.document, rightFirst: controller.rightFirst, progress: controller.report)
            case .overlay:
                guard controller.sources.count >= 2 else { throw WorkflowError("Aggiungi il PDF da sovrapporre: viene usato il secondo documento della coda.") }
                result = try await WorkflowEngine.overlay(source.document, overlay: controller.sources[1].document, opacity: controller.overlayOpacity, progress: controller.report)
            case .contents: result = try WorkflowEngine.tableOfContents(source.document, title: controller.contentsTitle)
            }
            controller.outputs = [WorkflowOutput(name: "\((source.title as NSString).deletingPathExtension)-impaginato.pdf", document: result)]
            controller.selectOutput(0); controller.message = "Anteprima pronta: \(result.pageCount) pagine."
        }
    }

    func buildWatermarkPreview() {
        do {
            guard let source = firstSource else { return }
            let indices = try WorkflowEngine.parseRange(selectionRange, pageCount: source.document.pageCount).indices
            let document = try WorkflowEngine.extract(source.document, indices: Array(0..<source.document.pageCount))
            for (page, annotation) in try WorkflowEngine.watermarkAnnotations(document, indices: indices, settings: watermark) { page.addAnnotation(annotation) }
            setPreview(document); error = nil
        } catch { self.error = error.localizedDescription }
    }

    func applyWatermark() {
        do {
            try ensureLiveSource()
            guard model.canEditAnnotations else { throw PDFWorkspaceError.editingNotAllowed }
            let indices = try WorkflowEngine.parseRange(selectionRange, pageCount: model.pageCount).indices
            model.addBatchAnnotations(try WorkflowEngine.watermarkAnnotations(model.document, indices: indices, settings: watermark), actionName: "Filigrana personalizzata")
            sourceRevision = model.contentRevision
            sources = [try model.workflowSource()]; buildWatermarkPreview(); message = "Filigrana applicata. Puoi annullare dalla finestra del documento."
        } catch { self.error = error.localizedDescription }
    }

    func buildNumberingPreview() {
        do {
            guard let source = firstSource else { return }
            let document = try WorkflowEngine.extract(source.document, indices: Array(0..<source.document.pageCount))
            let indices = try WorkflowEngine.parseRange(selectionRange, pageCount: document.pageCount).indices
            if replaceNumbers { removeExistingNumbers(document) }
            for (page, annotation) in try WorkflowEngine.numberingAnnotations(document, indices: indices, name: model.fileName, settings: numbering) { page.addAnnotation(annotation) }
            setPreview(document); error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func numberPairs(_ document: PDFDocument) -> [(PDFPage, PDFAnnotation)] {
        let regex = try! NSRegularExpression(pattern: "^\\s*[0-9]+\\s*/\\s*[0-9]+\\s*$")
        return (0..<document.pageCount).compactMap(document.page(at:)).flatMap { page in
            page.annotations.filter { annotation in
                annotation.userName == "CartaPDF:workflow-numbering" || (annotation.contents.map { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil } ?? false)
            }.map { (page, $0) }
        }
    }

    private func removeExistingNumbers(_ document: PDFDocument) { for (page, annotation) in numberPairs(document) { page.removeAnnotation(annotation) } }

    func applyNumbering() {
        do { try ensureLiveSource() } catch { self.error = error.localizedDescription; return }
        guard model.canEditAnnotations else { error = PDFWorkspaceError.editingNotAllowed.localizedDescription; return }
        if existingNumbers > 0 {
            let alert = NSAlert(); alert.messageText = "Sono presenti \(existingNumbers) numerazioni."
            alert.informativeText = replaceNumbers ? "Le numerazioni riconosciute verranno sostituite. Controlla l’anteprima prima di continuare." : "La nuova numerazione può sovrapporsi a quella esistente. Controlla l’anteprima."
            alert.addButton(withTitle: replaceNumbers ? "Sostituisci" : "Aggiungi comunque"); alert.addButton(withTitle: "Annulla")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            let indices = try WorkflowEngine.parseRange(selectionRange, pageCount: model.pageCount).indices
            let added = try WorkflowEngine.numberingAnnotations(model.document, indices: indices, name: model.fileName, settings: numbering)
            model.applyWorkflowAnnotations(added, removing: replaceNumbers ? numberPairs(model.document) : [], actionName: "Intestazioni e numerazione")
            let preferences = UserDefaults.standard
            preferences.set(true, forKey: "Workflow.numbers.saved"); preferences.set(numbering.header, forKey: "Workflow.numbers.header")
            preferences.set(numbering.footer, forKey: "Workflow.numbers.footer"); preferences.set(numbering.batesPrefix, forKey: "Workflow.numbers.prefix")
            preferences.set(numbering.start, forKey: "Workflow.numbers.start"); preferences.set(numbering.padding, forKey: "Workflow.numbers.padding")
            preferences.set(Double(numbering.fontSize), forKey: "Workflow.numbers.font"); preferences.set(numbering.usesBates, forKey: "Workflow.numbers.bates")
            sourceRevision = model.contentRevision
            sources = [try model.workflowSource()]; setPreview(sources[0].document); message = "Numerazione applicata e impostazioni memorizzate."
        } catch { self.error = error.localizedDescription }
    }

    func updateCropImage() {
        guard let page = firstSource?.document.page(at: cropPageIndex)?.copy() as? PDFPage else { cropImage = nil; return }
        page.rotation = 0; cropImage = page.thumbnail(of: CGSize(width: 650, height: 850), for: .cropBox)
    }

    func applyCrop() {
        guard cropValidation == nil else { error = cropValidation; return }
        do {
            try ensureLiveSource()
            model.goToPage(cropPageIndex)
            try model.cropCurrentPage(margins: NSEdgeInsets(top: cropTop, left: cropLeft, bottom: cropBottom, right: cropRight))
            sourceRevision = model.contentRevision
            sources = [try model.workflowSource()]; updateCropImage()
            let preferences = UserDefaults.standard
            preferences.set(true, forKey: "Workflow.crop.saved"); preferences.set(cropTop, forKey: "Workflow.crop.top")
            preferences.set(cropLeft, forKey: "Workflow.crop.left"); preferences.set(cropBottom, forKey: "Workflow.crop.bottom")
            preferences.set(cropRight, forKey: "Workflow.crop.right"); preferences.set(cropUnit.rawValue, forKey: "Workflow.crop.unit")
            message = "Ritaglio applicato. Il contenuto escluso resta nel PDF; usa Oscuramento per rimuoverlo."
        } catch { self.error = error.localizedDescription }
    }

    private func ensureLiveSource() throws {
        if hadDocumentOwner && model.documentOwner == nil { throw WorkflowError("Il documento sorgente è stato chiuso. Le copie già preparate restano disponibili; riapri il documento per modificarlo.") }
        if sourceRevision != model.contentRevision {
            sources = [try model.workflowSource()]; sourceRevision = model.contentRevision
            cropPageIndex = min(cropPageIndex, max(0, model.pageCount - 1)); updateCropImage(); setPreview(sources[0].document)
            throw WorkflowError("Il documento è cambiato dall’apertura del pannello. L’anteprima è stata aggiornata: ricontrolla la selezione prima di applicare.")
        }
    }

    func executeBatch() {
        start { controller in
            controller.outputs = try await WorkflowEngine.runBatch(sources: controller.sources, steps: controller.steps, password: controller.batchPassword, progress: controller.report)
            controller.selectOutput(0); controller.message = "Procedura completata: \(controller.outputs.count) copie pronte. Scegli la cartella e salva."
        }
    }

    func savePreset() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Procedura CartaPDF.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(steps).write(to: url, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }

    func loadPreset() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { steps = try JSONDecoder().decode([WorkflowBatchStep].self, from: Data(contentsOf: url)); message = "Procedura caricata. Le password non vengono salvate nei preset." }
        catch { self.error = error.localizedDescription }
    }
}

@MainActor
extension PDFEditorModel {
    func applyWorkflowAnnotations(_ added: [(PDFPage, PDFAnnotation)], removing removed: [(PDFPage, PDFAnnotation)], actionName: String) {
        guard canEditAnnotations else { return }
        performChange(named: actionName, mutation: {
            for (page, annotation) in removed { page.removeAnnotation(annotation) }
            for (page, annotation) in added { page.addAnnotation(annotation) }
        }, inverse: { model in model.applyWorkflowAnnotations(removed, removing: added, actionName: actionName) })
    }
    func showMergeWorkspace() { WorkflowWindows.shared.show(model: self, kind: .merge) }
    func showSplitWorkspace() { WorkflowWindows.shared.show(model: self, kind: .split) }
    func showPageLayoutWorkspace() { WorkflowWindows.shared.show(model: self, kind: .layout) }
    func showBatchWorkspace() { WorkflowWindows.shared.show(model: self, kind: .batch) }
    func showWatermarkWorkspace() { WorkflowWindows.shared.show(model: self, kind: .watermark) }
    func showNumberingWorkspace() { WorkflowWindows.shared.show(model: self, kind: .numbering) }
    func showCropWorkspace() { WorkflowWindows.shared.show(model: self, kind: .crop) }
}

@MainActor
private final class WorkflowWindows: NSObject, NSWindowDelegate {
    static let shared = WorkflowWindows()
    private var windows: [NSWindowController] = []
    private var jobs: [ObjectIdentifier: WorkflowController] = [:]
    func show(model: PDFEditorModel, kind: WorkflowWorkspaceKind) {
        let controller = WorkflowController(model: model, kind: kind)
        let hosting = NSHostingController(rootView: WorkflowWorkspaceView(controller: controller))
        let window = PDFWorkspaceWindow(contentViewController: hosting)
        window.setContentSize(CGSize(width: 1120, height: 780)); window.minSize = CGSize(width: 980, height: 640)
        window.title = "CartaPDF · \(kind.rawValue)"; window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        let windowController = NSWindowController(window: window)
        windows.append(windowController); jobs[ObjectIdentifier(window)] = controller
        windowController.showWindow(nil); window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        jobs.removeValue(forKey: ObjectIdentifier(window))?.cancel(); windows.removeAll { $0.window === window }
    }
}

private struct WorkflowPDFPreview: NSViewRepresentable {
    let document: PDFDocument?
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; view.backgroundColor = .windowBackgroundColor
        view.setAccessibilityLabel("Anteprima del PDF generato")
        view.setAccessibilityHelp("Anteprima navigabile PDFKit. Controlla le copie prima di salvarle.")
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) { if view.document !== document { view.document = document; view.autoScales = true } }
}

@MainActor
struct WorkflowWorkspaceView: View {
    @ObservedObject var controller: WorkflowController
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(controller.kind.rawValue).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text("Elaborazione locale · originali invariati nelle operazioni che generano copie").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if controller.busy { ProgressView(value: controller.progress).frame(width: 150).accessibilityLabel("Avanzamento \(controller.kind.rawValue)").accessibilityValue("\(Int(controller.progress * 100)) percento"); Button("Annulla", action: controller.cancel).keyboardShortcut(.cancelAction).accessibilityLabel("Annulla \(controller.kind.rawValue)") }
            }.padding(20)
            Divider()
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch controller.kind {
                        case .merge: mergeControls
                        case .split: splitControls
                        case .layout: layoutControls
                        case .batch: batchControls
                        case .watermark: watermarkControls
                        case .numbering: numberingControls
                        case .crop: cropControls
                        }
                    }.padding(18).disabled(controller.busy)
                }.frame(minWidth: 410, idealWidth: 460, maxWidth: 540)
                VStack(spacing: 0) {
                    if controller.kind == .crop { WorkflowCropCanvas(controller: controller).padding(22) }
                    else { WorkflowPDFPreview(document: controller.preview) }
                    if !controller.outputs.isEmpty { outputControls.padding(12).background(Color(nsColor: .controlBackgroundColor)) }
                }.frame(minWidth: 430)
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                if let error = controller.error { CartaPanelAccessibilityStatus(message: error, label: "Errore \(controller.kind.rawValue)", announceOnAppear: true).foregroundStyle(.red) }
                if !controller.message.isEmpty { CartaPanelAccessibilityStatus(message: controller.message, label: "Stato \(controller.kind.rawValue)", announce: !controller.busy).font(.callout).foregroundStyle(.secondary) }
                if controller.busy { Text("Puoi annullare: gli output temporanei verranno rimossi.").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }.accessibilityIdentifier("panel.workflow.\(controller.kind.rawValue)")
    }

    private var sourceQueue: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Documenti · \(controller.totalSelectedPages) pagine selezionate").font(.headline).accessibilityAddTraits(.isHeader); Spacer(); Button("Aggiungi PDF…", action: controller.addFiles) }
            Text("Trascina i documenti o usa i pulsanti Sposta prima/dopo per riordinarli. Puoi inserire intervalli, pari, dispari o ultima.").font(.caption).foregroundStyle(.secondary)
            ForEach(controller.sources) { source in
                let position = (controller.sources.firstIndex(where: { $0.id == source.id }) ?? 0) + 1
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(source.title).font(.headline).lineLimit(2)
                        Spacer()
                        Button { moveSourceBy(source.id, offset: -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless).accessibilityLabel("Sposta prima il documento \(position), \(source.title)").disabled(controller.sources.first?.id == source.id)
                        Button { moveSourceBy(source.id, offset: 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.borderless).accessibilityLabel("Sposta dopo il documento \(position), \(source.title)").disabled(controller.sources.last?.id == source.id)
                        Button { controller.removeSource(source.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help("Rimuovi dalla coda").accessibilityLabel("Rimuovi dalla coda il documento \(position), \(source.title)").accessibilityHint("Conserva il PDF originale.")
                    }
                    Text("\(source.document.pageCount) pagine · \(ByteCountFormatter.string(fromByteCount: Int64(source.byteCount), countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                    TextField("Intervallo", text: Binding(get: { controller.sources.first(where: { $0.id == source.id })?.range ?? "" }, set: { value in
                        if let index = controller.sources.firstIndex(where: { $0.id == source.id }) { controller.sources[index].range = value; controller.invalidatePlan() }
                    })).textFieldStyle(.roundedBorder).accessibilityLabel("Pagine da usare di \(source.title)").accessibilityHint(sourceRangeHint(source))
                    if let parsed = try? WorkflowEngine.parseRange(source.range, pageCount: source.document.pageCount) {
                        if !parsed.repeatedPages.isEmpty { Text("Pagine sovrapposte ignorate: \(parsed.repeatedPages.map { String($0 + 1) }.joined(separator: ", "))").font(.caption).foregroundStyle(.orange) }
                        HStack(spacing: 5) { ForEach(Array(parsed.indices.prefix(6)), id: \.self) { index in
                            if let page = source.document.page(at: index) {
                                Image(nsImage: page.thumbnail(of: CGSize(width: 55, height: 70), for: .cropBox)).resizable().scaledToFit().frame(width: 40, height: 52).overlay(alignment: .bottomTrailing) { Text("\(index + 1)").font(.system(size: 9)).padding(2).background(.regularMaterial) }.accessibilityElement(children: .ignore).accessibilityLabel("Miniatura pagina \(index + 1) di \(source.title)")
                            }
                        }; if parsed.indices.count > 6 { Text("+\(parsed.indices.count - 6)").font(.caption) } }
                    } else {
                        Text((try? rangeError(source)) ?? "Intervallo non valido").font(.caption).foregroundStyle(.red)
                    }
                }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityElement(children: .contain).accessibilityLabel("Documento \(position), \(source.title)")
                    .onDrag { controller.draggedSource = source.id; return NSItemProvider(object: source.id.uuidString as NSString) }
                    .onDrop(of: [.text], delegate: WorkflowSourceDrop(controller: controller, target: source.id))
            }
            if !controller.duplicateNames.isEmpty { Label("File aggiunti più volte: \(controller.duplicateNames.joined(separator: ", "))", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            if controller.pageFormats.count > 1 { Text("Formati diversi: \(controller.pageFormats.joined(separator: "; "))").font(.caption).foregroundStyle(.orange) }
        }
    }

    private func rangeError(_ source: WorkflowSource) throws -> String {
        do { _ = try WorkflowEngine.parseRange(source.range, pageCount: source.document.pageCount); return "" } catch { return error.localizedDescription }
    }

    private func sourceRangeHint(_ source: WorkflowSource) -> String {
        let error = (try? rangeError(source)) ?? ""
        return error.isEmpty ? "Intervalli, pari, dispari o ultima. Il documento contiene \(source.document.pageCount) pagine." : "Errore nell’intervallo: \(error)"
    }

    private func moveSourceBy(_ id: UUID, offset: Int) {
        guard let index = controller.sources.firstIndex(where: { $0.id == id }), controller.sources.indices.contains(index + offset) else { return }
        if offset < 0 { controller.moveSource(id, before: controller.sources[index - 1].id) }
        else { controller.moveSource(controller.sources[index + 1].id, before: id) }
    }

    private func rangeError(text: String, pageCount: Int) -> String {
        do { _ = try WorkflowEngine.parseRange(text, pageCount: pageCount); return "" } catch { return error.localizedDescription }
    }

    private var mergeControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            sourceQueue
            Picker("Metodo", selection: $controller.mergeMode) { ForEach(WorkflowMergeMode.allCases) { Text($0.rawValue).tag($0) } }
            if controller.mergeMode == .alternate {
                Text("Primo PDF: fronti. Secondo PDF: retri. Le pagine vengono alternate; quelle in eccesso restano in coda.").font(.caption).foregroundStyle(.secondary)
                Toggle("Inverti l’ordine dei retri", isOn: $controller.reverseBacks)
            }
            if controller.mergeMode == .groups {
                Text("Raggruppa i nomi privi del suffisso numerico: fattura_001 e fattura_002 diventano fattura-unito.pdf. L’ordine della coda è conservato.").font(.caption).foregroundStyle(.secondary)
                ForEach(WorkflowEngine.groupedSources(controller.sources), id: \.0) { group in Text("\(group.0): \(group.1.count) documenti").font(.caption) }
            }
            Toggle("Conserva segnalibri con destinazioni valide", isOn: $controller.keepOutlines)
            Button("Genera anteprima dell’unione", action: controller.buildMerge).buttonStyle(.borderedProminent).disabled(controller.sources.isEmpty)
            copyNotice
        }
    }

    private var splitControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(controller.firstSource?.title ?? "Nessun PDF").font(.headline)
            Picker("Dividi per", selection: $controller.splitMode) { ForEach(WorkflowSplitMode.allCases) { Text($0.rawValue).tag($0) } }
            switch controller.splitMode {
            case .intervals:
                TextField("1-3; 4-6; 7-ultima", text: $controller.intervals).textFieldStyle(.roundedBorder).accessibilityLabel("Intervalli per dividere il PDF").accessibilityHint("Punto e virgola separa i file; virgola unisce pagine nello stesso file. \(controller.error ?? "")")
                Text("Punto e virgola: file separati. Virgola: pagine nello stesso file. Sono ammessi pari, dispari e ultima.").font(.caption).foregroundStyle(.secondary)
                if let source = controller.firstSource {
                    ForEach(Array(controller.intervals.split(separator: ";", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, raw in
                        if let parsed = try? WorkflowEngine.parseRange(String(raw), pageCount: source.document.pageCount) {
                            Text("\(raw) → \(parsed.indices.count) pagine: \(parsed.indices.prefix(12).map { String($0 + 1) }.joined(separator: ", "))").font(.caption)
                            WorkflowThumbnailStrip(source: source, indices: parsed.indices)
                            if !parsed.repeatedPages.isEmpty { Text("Sovrapposizioni: \(parsed.repeatedPages.map { String($0 + 1) }.joined(separator: ", "))").font(.caption).foregroundStyle(.orange) }
                        } else { Text(rangeError(text: String(raw), pageCount: source.document.pageCount)).font(.caption).foregroundStyle(.red) }
                    }
                    if !controller.splitOverlap.isEmpty { Text("Pagine presenti in più file: \(controller.splitOverlap.map { String($0 + 1) }.joined(separator: ", "))").font(.caption).foregroundStyle(.orange) }
                }
            case .everyN: Stepper("Ogni \(controller.splitCount) pagine", value: $controller.splitCount, in: 1...100_000).accessibilityLabel("Pagine per ogni parte").accessibilityValue("\(controller.splitCount) pagine")
            case .text, .barcode:
                TextField(controller.splitMode == .text ? "Testo separatore" : "Codice da cercare (vuoto = qualsiasi)", text: $controller.marker).textFieldStyle(.roundedBorder).accessibilityLabel(controller.splitMode == .text ? "Testo che separa le parti" : "Codice a barre che separa le parti").accessibilityHint(controller.splitMode == .text ? "Cerca nel testo selezionabile." : "Lascia vuoto per usare qualsiasi codice riconosciuto.")
                Toggle("Escludi le pagine separatrici", isOn: $controller.skipMarkers)
                Text(controller.splitMode == .text ? "La ricerca usa il testo già selezionabile. Per scansioni esegui prima OCR." : "Vision riconosce QR e codici a barre sul Mac. Controlla l’anteprima delle parti.").font(.caption).foregroundStyle(.secondary)
            case .blank:
                Toggle("Escludi le pagine bianche", isOn: $controller.skipMarkers)
                Slider(value: $controller.blankThreshold, in: 0...0.03) { Text("Tolleranza") }
                    .accessibilityLabel("Soglia pixel scuri per pagina bianca").accessibilityValue("\(controller.blankThreshold * 100, specifier: "%.2f") percento")
                Text("Soglia pixel scuri: \(controller.blankThreshold * 100, specifier: "%.2f")%. La classificazione va verificata in anteprima.").font(.caption).foregroundStyle(.secondary)
            case .maxBytes:
                HStack { Text("Limite"); TextField("MB", value: $controller.maxMegabytes, format: .number).frame(width: 80).accessibilityLabel("Dimensione massima per parte, in megabyte"); Text("MB").accessibilityHidden(true) }
                Text("Il limite viene verificato sui PDF effettivi. Una pagina troppo grande causa un errore; la qualità non viene ridotta automaticamente.").font(.caption).foregroundStyle(.secondary)
            case .bookmarks: Text("Ogni segnalibro principale con destinazione valida inizia una nuova parte.").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Modello nomi", text: $controller.namePattern).textFieldStyle(.roundedBorder).accessibilityLabel("Modello dei nomi delle parti").accessibilityHint("Variabili disponibili: name, index, start, end, pages, label tra parentesi graffe.").onChange(of: controller.namePattern) { _, _ in controller.renameSplitOutputs() }
            Text("Variabili: {name}, {index:03}, {start}, {end}, {pages}, {label}").font(.caption).foregroundStyle(.secondary)
            Button("Analizza e prepara anteprima", action: controller.buildSplit).buttonStyle(.borderedProminent)
            preparedOutputList
            copyNotice
        }
    }

    private var layoutControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Operazione", selection: $controller.layoutMode) { ForEach(WorkflowLayoutMode.allCases) { Text($0.rawValue).tag($0) } }
            if controller.layoutMode == .organize { pageOrganizer }
            else if controller.layoutMode == .overlay || controller.layoutMode == .replace {
                sourceQueue
                if controller.layoutMode == .overlay { Slider(value: $controller.overlayOpacity, in: 0.05...1) { Text("Opacità") }.accessibilityLabel("Opacità della sovrapposizione").accessibilityValue("\(Int(controller.overlayOpacity * 100)) percento"); Text("Opacità \(Int(controller.overlayOpacity * 100))% · le pagine del secondo PDF vengono ripetute se necessario.").font(.caption) }
                else { TextField("Pagine da sostituire, es. 2-4", text: $controller.replacementRange).textFieldStyle(.roundedBorder).accessibilityLabel("Pagine da sostituire nel primo PDF").accessibilityHint("Esempio: da 2 a 4. \(controller.error ?? "")"); Text("Il secondo PDF deve fornire lo stesso numero di pagine selezionate.").font(.caption) }
            } else if controller.layoutMode == .facing { Toggle("Prima metà destra (lettura da destra a sinistra)", isOn: $controller.rightFirst) }
            else if controller.layoutMode == .contents { TextField("Titolo del sommario", text: $controller.contentsTitle).textFieldStyle(.roundedBorder).accessibilityLabel("Titolo del sommario"); Text("Usa i segnalibri principali; in loro assenza crea una voce per ogni pagina. Ogni voce è cliccabile.").font(.caption) }
            else {
                if controller.layoutMode != .booklet {
                    Stepper("\(controller.columns) colonne", value: $controller.columns, in: 1...8).accessibilityLabel("Colonne di pagine per foglio").accessibilityValue("\(controller.columns) colonne")
                    Stepper("\(controller.rows) righe", value: $controller.rows, in: 1...8).accessibilityLabel("Righe di pagine per foglio").accessibilityValue("\(controller.rows) righe")
                }
                HStack { Text("Foglio pt"); TextField("Larghezza", value: $controller.sheetWidth, format: .number).accessibilityLabel("Larghezza del foglio, in punti"); Text("×").accessibilityHidden(true); TextField("Altezza", value: $controller.sheetHeight, format: .number).accessibilityLabel("Altezza del foglio, in punti") }
                HStack { Button("A4 orizzontale") { controller.sheetWidth = 841.89; controller.sheetHeight = 595.276 }; Button("A4 verticale") { controller.sheetWidth = 595.276; controller.sheetHeight = 841.89 } }
                HStack { Text(controller.layoutMode == .poster ? "Sovrapposizione pt" : "Spaziatura pt"); TextField("pt", value: $controller.gutter, format: .number).accessibilityLabel(controller.layoutMode == .poster ? "Sovrapposizione del poster, in punti" : "Spaziatura fra pagine, in punti") }
                if controller.layoutMode == .booklet { Text("Aggiunge pagine vuote fino a un multiplo di quattro e dispone fronte e retro consecutivi. Stampa fronte/retro con ribaltamento sul lato corto; verifica con una prova.").font(.caption).foregroundStyle(.secondary) }
            }
            Button("Genera anteprima", action: controller.buildLayout).buttonStyle(.borderedProminent)
            Text("N-up, libretto, poster, separazione scansioni e sovrapposizione generano PDF statici: il testo/vettori disegnabili restano, campi e annotazioni vengono appiattiti. Organizzazione e sostituzione conservano i campi delle pagine copiate.").font(.caption).foregroundStyle(.secondary)
            copyNotice
        }
    }

    private var pageOrganizer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(controller.pageOrder.count) pagine nell’ordine finale. Trascina le miniature; duplica, sposta o elimina prima di aprire la copia.").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 105))], spacing: 12) {
                ForEach(Array(controller.pageOrder.enumerated()), id: \.element.id) { position, token in
                    VStack(spacing: 5) {
                        if let page = controller.firstSource?.document.page(at: token.index) { Image(nsImage: page.thumbnail(of: CGSize(width: 90, height: 120), for: .cropBox)).resizable().scaledToFit().frame(height: 105).accessibilityHidden(true) }
                        Text("\(position + 1) ← origine \(token.index + 1)").font(.caption2)
                        HStack(spacing: 9) {
                            Button { controller.movePageBy(token, offset: -1) } label: { Image(systemName: "arrow.left") }.disabled(position == 0).accessibilityLabel("Sposta prima la pagina in posizione \(position + 1)")
                            Button { controller.duplicatePage(token) } label: { Image(systemName: "plus.square.on.square") }.help("Duplica in anteprima").accessibilityLabel("Duplica la pagina in posizione \(position + 1)")
                            Button { controller.movePageBy(token, offset: 1) } label: { Image(systemName: "arrow.right") }.disabled(position == controller.pageOrder.count - 1).accessibilityLabel("Sposta dopo la pagina in posizione \(position + 1)")
                            Button { controller.deletePage(token) } label: { Image(systemName: "trash") }.disabled(controller.pageOrder.count <= 1).accessibilityLabel("Elimina dalla copia la pagina in posizione \(position + 1)")
                        }.buttonStyle(.borderless)
                    }.padding(7).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8)).accessibilityElement(children: .contain).accessibilityLabel("Posizione \(position + 1), pagina originale \(token.index + 1)")
                        .onDrag { controller.draggedPage = token.id; return NSItemProvider(object: token.id.uuidString as NSString) }
                        .onDrop(of: [.text], delegate: WorkflowPageDrop(controller: controller, target: token.id))
                }
            }
        }
    }

    private var selectionControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField("Pagine: tutte, 1-3, pari…", text: $controller.selectionRange).textFieldStyle(.roundedBorder).accessibilityLabel("Pagine a cui applicare la modifica").accessibilityHint(controller.selectionError.map { "Errore: \($0)" } ?? "Sono ammessi intervalli, pari, dispari, ultima e tutte.")
            if let error = controller.selectionError { Text(error).font(.caption).foregroundStyle(.red).accessibilityLabel("Errore selezione pagine: \(error)") }
            else { Text("\(controller.selectedIndices?.indices.count ?? 0) pagine selezionate").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var watermarkControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            selectionControls
            TextField("Testo della filigrana", text: $controller.watermark.text).textFieldStyle(.roundedBorder).accessibilityLabel("Testo della filigrana")
            Picker("Carattere", selection: $controller.watermark.fontName) { ForEach(["Helvetica", "Helvetica-Bold", "Times-Roman", "Courier"], id: \.self) { Text($0).tag($0) } }
            HStack { Text("Dimensione pt"); TextField("pt", value: double($controller.watermark.fontSize), format: .number).accessibilityLabel("Dimensione del carattere della filigrana, in punti") }
            Picker("Posizione", selection: $controller.watermark.position) { ForEach(WorkflowPosition.allCases) { Text($0.rawValue).tag($0) } }
            Slider(value: $controller.watermark.opacity, in: 0.05...1) { Text("Opacità") }
                .accessibilityLabel("Opacità della filigrana").accessibilityValue("\(Int(controller.watermark.opacity * 100)) percento")
            Text("Opacità \(Int(controller.watermark.opacity * 100))%")
            ColorPicker("Colore", selection: Binding(get: { Color(nsColor: controller.watermark.color) }, set: { controller.watermark.color = NSColor($0) }), supportsOpacity: false)
            HStack { Text("Margine pt"); TextField("pt", value: double($controller.watermark.margin), format: .number).accessibilityLabel("Margine della filigrana, in punti") }
            Button("Aggiorna anteprima", action: controller.buildWatermarkPreview)
            Button("Applica al documento", action: controller.applyWatermark).buttonStyle(.borderedProminent).disabled(controller.selectionError != nil || !controller.model.canEditAnnotations)
            Text("La filigrana è un’annotazione modificabile e annullabile. La protezione del documento corrente viene conservata al salvataggio.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var numberingControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            selectionControls
            TextField("Intestazione", text: $controller.numbering.header).textFieldStyle(.roundedBorder)
            Toggle("Numerazione Bates nel piè di pagina", isOn: $controller.numbering.usesBates)
            if controller.numbering.usesBates {
                TextField("Prefisso", text: $controller.numbering.batesPrefix).textFieldStyle(.roundedBorder).accessibilityLabel("Prefisso della numerazione Bates")
                HStack { Text("Primo numero"); TextField("1", value: $controller.numbering.start, format: .number).accessibilityLabel("Primo numero Bates"); Text("Cifre"); TextField("6", value: $controller.numbering.padding, format: .number).frame(width: 50).accessibilityLabel("Cifre della numerazione Bates") }
                Text(controller.batesPreview).font(.system(.callout, design: .monospaced)).textSelection(.enabled).accessibilityLabel("Anteprima numerazione Bates").accessibilityValue(controller.batesPreview)
            } else { TextField("Piè di pagina", text: $controller.numbering.footer).textFieldStyle(.roundedBorder) }
            Text("Variabili: {page}, {pages}, {name}, {date}, {bates}").font(.caption).foregroundStyle(.secondary)
            HStack { Text("Font pt"); TextField("10", value: double($controller.numbering.fontSize), format: .number).accessibilityLabel("Dimensione del carattere della numerazione, in punti"); Text("Margine pt"); TextField("18", value: double($controller.numbering.margin), format: .number).accessibilityLabel("Margine della numerazione, in punti") }
            if controller.existingNumbers > 0 { Text("Sono state riconosciute \(controller.existingNumbers) numerazioni: verifica eventuali sovrapposizioni.").font(.caption).foregroundStyle(.orange); Toggle("Sostituisci le numerazioni riconosciute", isOn: $controller.replaceNumbers) }
            Button("Controlla spazio e anteprima", action: controller.buildNumberingPreview)
            Button("Applica al documento", action: controller.applyNumbering).buttonStyle(.borderedProminent).disabled(controller.selectionError != nil || !controller.model.canEditAnnotations)
            Text("Font, modelli e parametri Bates vengono ricordati sul Mac. Le modifiche sono annullabili insieme.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var cropControls: some View {
        VStack(alignment: .leading, spacing: 15) {
            Stepper("Pagina \(controller.cropPageIndex + 1)", value: $controller.cropPageIndex, in: 0...max(0, (controller.firstSource?.document.pageCount ?? 1) - 1)).accessibilityLabel("Pagina di anteprima del ritaglio").accessibilityValue("\(controller.cropPageIndex + 1)").onChange(of: controller.cropPageIndex) { _, _ in controller.updateCropImage() }
            Picker("Unità", selection: $controller.cropUnit) { ForEach(WorkflowUnit.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            cropField("Superiore", value: $controller.cropTop); cropField("Sinistro", value: $controller.cropLeft)
            cropField("Inferiore", value: $controller.cropBottom); cropField("Destro", value: $controller.cropRight)
            Text("Risultato: \((controller.cropBounds.width - controller.cropLeft - controller.cropRight) / controller.cropUnit.factor, specifier: "%.2f") × \((controller.cropBounds.height - controller.cropTop - controller.cropBottom) / controller.cropUnit.factor, specifier: "%.2f") \(controller.cropUnit.rawValue)")
            Text("Trascina i quattro punti sui lati dell’anteprima. La pagina è mostrata senza rotazione per allineare i margini PDF.").font(.caption).foregroundStyle(.secondary)
            if let warning = controller.cropValidation { Text(warning).foregroundStyle(.red) }
            Button("Applica ritaglio", action: controller.applyCrop).buttonStyle(.borderedProminent).disabled(controller.cropValidation != nil || !controller.model.canEditDocument)
            Button("Azzera margini") { controller.cropTop = 0; controller.cropLeft = 0; controller.cropBottom = 0; controller.cropRight = 0 }
            Text("Il ritaglio nasconde il contenuto esterno e non lo elimina. Per dati sensibili usa Oscuramento. Gli ultimi margini vengono ricordati localmente.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func cropField(_ title: String, value: Binding<Double>) -> some View {
        HStack { Text(title).frame(width: 95, alignment: .leading); TextField(title, value: Binding(get: { value.wrappedValue / controller.cropUnit.factor }, set: { value.wrappedValue = $0 * controller.cropUnit.factor }), format: .number.precision(.fractionLength(0...3)))
                .accessibilityLabel("Margine \(title.lowercased()) del ritaglio, in \(controller.cropUnit.rawValue)")
                .accessibilityHint(controller.cropValidation ?? "I margini sono regolabili da tastiera; la stessa impostazione è mostrata nei punti di trascinamento dell’anteprima.")
            Text(controller.cropUnit.rawValue).accessibilityHidden(true) }
    }

    private func double(_ value: Binding<CGFloat>) -> Binding<Double> { Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = CGFloat($0) }) }

    private var batchControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            sourceQueue
            HStack { Text("Procedura").font(.headline).accessibilityAddTraits(.isHeader); Spacer(); Button("Carica…", action: controller.loadPreset).accessibilityLabel("Carica procedura locale"); Button("Salva…", action: controller.savePreset).accessibilityLabel("Salva procedura locale") }
            ForEach($controller.steps) { $step in
                let position = (controller.steps.firstIndex(where: { $0.id == step.id }) ?? 0) + 1
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(step.kind.rawValue).font(.headline).accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button { moveStep(step.id, -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless).accessibilityLabel("Sposta prima il passaggio \(position), \(step.kind.rawValue)").disabled(controller.steps.first?.id == step.id)
                        Button { moveStep(step.id, 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.borderless).accessibilityLabel("Sposta dopo il passaggio \(position), \(step.kind.rawValue)").disabled(controller.steps.last?.id == step.id)
                        Button { controller.steps.removeAll { $0.id == step.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Rimuovi il passaggio \(position), \(step.kind.rawValue)")
                    }
                    switch step.kind {
                    case .watermark, .numbers, .bates, .extract: TextField("Testo, prefisso o intervallo", text: $step.text).textFieldStyle(.roundedBorder).accessibilityLabel(batchTextLabel(step.kind))
                    default: EmptyView()
                    }
                    switch step.kind {
                    case .rotate, .crop, .watermark, .numbers, .bates, .split, .nUp, .flatten, .jpeg:
                        HStack { Text(parameterName(step.kind)); TextField("Valore", value: $step.value, format: .number).accessibilityLabel("\(step.kind.rawValue): \(parameterName(step.kind))") }
                    default: EmptyView()
                    }
                    if [.nUp, .bates, .jpeg].contains(step.kind) { HStack { Text(step.kind == .nUp ? "Righe" : step.kind == .bates ? "Cifre" : "Qualità 0…1"); TextField("Valore", value: $step.secondary, format: .number).accessibilityLabel("\(step.kind.rawValue): \(step.kind == .nUp ? "righe" : step.kind == .bates ? "cifre" : "qualità JPEG da zero a uno")") } }
                    if step.kind == .protect { SecureField("Password delle copie", text: $controller.batchPassword).textFieldStyle(.roundedBorder).accessibilityLabel("Password per proteggere le copie finali").accessibilityHint("Non viene salvata nel preset; viene rimossa dal campo al termine."); Text("La password non entra nei preset e viene rimossa dal campo a fine elaborazione.").font(.caption) }
                }.padding(11).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8)).accessibilityElement(children: .contain).accessibilityLabel("Passaggio \(position), \(step.kind.rawValue)")
            }
            HStack { Picker("Passaggio", selection: $controller.newStep) { ForEach(WorkflowBatchKind.allCases) { Text($0.rawValue).tag($0) } }; Button("Aggiungi") { controller.steps.append(WorkflowBatchStep(kind: controller.newStep)) }.accessibilityLabel("Aggiungi il passaggio selezionato alla procedura") }
            Button("Esegui la procedura sulle copie", action: controller.executeBatch).buttonStyle(.borderedProminent).disabled(controller.sources.isEmpty || controller.steps.isEmpty)
            Text("I passaggi operano nell’ordine indicato. OCR e copie raster possono appiattire annotazioni e campi; controlla le copie prima del salvataggio. La protezione viene applicata alla copia finale.").font(.caption).foregroundStyle(.secondary)
            preparedOutputList
            copyNotice
        }
    }

    private func parameterName(_ kind: WorkflowBatchKind) -> String {
        switch kind { case .rotate: return "Gradi (multipli di 90)"; case .crop: return "Margine pt"; case .split: return "Pagine per parte"
        case .nUp: return "Colonne"; case .flatten, .jpeg: return "DPI"; case .bates: return "Primo numero"; default: return "Font pt" }
    }

    private func batchTextLabel(_ kind: WorkflowBatchKind) -> String {
        switch kind {
        case .watermark: return "Testo del passaggio filigrana"
        case .numbers: return "Modello del passaggio numerazione"
        case .bates: return "Prefisso del passaggio Bates"
        case .extract: return "Intervallo del passaggio estrazione pagine"
        default: return "Testo del passaggio \(kind.rawValue)"
        }
    }

    private func moveStep(_ id: UUID, _ offset: Int) {
        guard let index = controller.steps.firstIndex(where: { $0.id == id }), controller.steps.indices.contains(index + offset) else { return }
        controller.steps.swapAt(index, index + offset)
    }

    private var preparedOutputList: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !controller.outputs.isEmpty { Text("\(controller.outputs.count) file previsti").font(.headline) }
            ForEach(Array(controller.outputs.enumerated()), id: \.offset) { index, output in
                Button { controller.selectOutput(index) } label: {
                    HStack(alignment: .top) { Image(systemName: "doc.richtext"); VStack(alignment: .leading) { Text(controller.finalName(index)).lineLimit(2); Text("\(output.document.pageCount) pagine").font(.caption).foregroundStyle(.secondary) }; Spacer() }
                }.buttonStyle(.plain).padding(7).background(index == controller.selectedOutput ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Anteprima \(controller.finalName(index)), \(output.document.pageCount) pagine")
                    .accessibilityAddTraits(index == controller.selectedOutput ? .isSelected : [])
            }
        }
    }

    private var outputControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.outputs.count > 1 {
                Picker("Anteprima", selection: Binding(get: { controller.selectedOutput }, set: { controller.selectOutput($0) })) {
                    ForEach(Array(controller.outputs.enumerated()), id: \.offset) { Text($0.element.name).tag($0.offset) }
                }
            }
            HStack { Button("Cartella…", action: controller.chooseDirectory).accessibilityLabel("Scegli cartella delle copie").accessibilityValue(controller.directory?.path ?? "Nessuna cartella selezionata"); Text(controller.directory?.lastPathComponent ?? "Scegli la destinazione").font(.caption).lineLimit(1).accessibilityLabel("Cartella di destinazione").accessibilityValue(controller.directory?.path ?? "Non selezionata"); Spacer() }
            Picker("File esistenti", selection: $controller.conflictPolicy) { ForEach(WorkflowConflictPolicy.allCases) { Text($0.rawValue).tag($0) } }
            if !controller.conflicts.isEmpty {
                DisclosureGroup("\(controller.conflicts.count) file esistenti in conflitto") {
                    ForEach(Array(controller.conflicts.enumerated()), id: \.offset) { Text($0.element).font(.caption).foregroundStyle(.orange) }
                }.font(.caption)
            }
            HStack {
                Button("Apri copia selezionata", action: controller.openSelectedOutput)
                Button("Salva copie verificate", action: controller.saveOutputs).buttonStyle(.borderedProminent)
                if !controller.outputURLs.isEmpty { Button("Mostra nel Finder", action: controller.revealOutputs) }
            }.disabled(controller.busy)
        }
    }

    private var copyNotice: some View { Text("Le copie generate non ereditano password o firme digitali delle sorgenti. La struttura delle pagine copiate viene conservata; proteggi le copie se necessario.").font(.caption).foregroundStyle(.secondary) }
}

@MainActor
private struct WorkflowThumbnailStrip: View {
    let source: WorkflowSource
    let indices: [Int]
    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(indices.prefix(6)), id: \.self) { index in
                if let page = source.document.page(at: index) {
                    Image(nsImage: CartaThumbnailCache.shared.image(page: page, documentID: source.id.uuidString, revision: 0, index: index))
                        .resizable().scaledToFit().frame(width: 42, height: 56)
                        .overlay(alignment: .bottomTrailing) { Text("\(index + 1)").font(.system(size: 9)).padding(2).background(.regularMaterial) }
                        .accessibilityElement(children: .ignore).accessibilityLabel("Miniatura pagina \(index + 1) di \(source.title)")
                }
            }
            if indices.count > 6 { Text("+\(indices.count - 6)").font(.caption) }
        }
    }
}

private struct WorkflowSourceDrop: DropDelegate {
    let controller: WorkflowController
    let target: UUID
    func dropEntered(info: DropInfo) { MainActor.assumeIsolated { if let dragged = controller.draggedSource { controller.moveSource(dragged, before: target) } } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { MainActor.assumeIsolated { controller.draggedSource = nil }; return true }
}

private struct WorkflowPageDrop: DropDelegate {
    let controller: WorkflowController
    let target: UUID
    func dropEntered(info: DropInfo) { MainActor.assumeIsolated { if let dragged = controller.draggedPage { controller.movePage(dragged, before: target, preview: false) } } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { MainActor.assumeIsolated { controller.draggedPage = nil; controller.previewPageOrder() }; return true }
}

@MainActor
private struct WorkflowCropCanvas: View {
    @ObservedObject var controller: WorkflowController
    var body: some View {
        GeometryReader { geometry in
            let box = controller.cropBounds
            let scale = min(geometry.size.width / max(1, box.width), geometry.size.height / max(1, box.height))
            let size = CGSize(width: box.width * scale, height: box.height * scale)
            let left = min(max(0, controller.cropLeft * scale), size.width)
            let right = max(left, min(size.width, size.width - controller.cropRight * scale))
            let top = min(max(0, controller.cropTop * scale), size.height)
            let bottom = max(top, min(size.height, size.height - controller.cropBottom * scale))
            ZStack(alignment: .topLeading) {
                if let image = controller.cropImage { Image(nsImage: image).resizable().frame(width: size.width, height: size.height) }
                Rectangle().fill(.black.opacity(0.16)).frame(width: size.width, height: top)
                Rectangle().fill(.black.opacity(0.16)).frame(width: size.width, height: size.height - bottom).offset(y: bottom)
                Rectangle().fill(.black.opacity(0.16)).frame(width: left, height: bottom - top).offset(y: top)
                Rectangle().fill(.black.opacity(0.16)).frame(width: size.width - right, height: bottom - top).offset(x: right, y: top)
                Rectangle().stroke(Color.accentColor, lineWidth: 2).frame(width: right - left, height: bottom - top).offset(x: left, y: top)
                handle(at: CGPoint(x: (left + right) / 2, y: top)) { translation in controller.cropTop = min(max(0, controller.cropTop + translation.height / scale), max(0, box.height - controller.cropBottom - 18)) }
                handle(at: CGPoint(x: (left + right) / 2, y: bottom)) { translation in controller.cropBottom = min(max(0, controller.cropBottom - translation.height / scale), max(0, box.height - controller.cropTop - 18)) }
                handle(at: CGPoint(x: left, y: (top + bottom) / 2)) { translation in controller.cropLeft = min(max(0, controller.cropLeft + translation.width / scale), max(0, box.width - controller.cropRight - 18)) }
                handle(at: CGPoint(x: right, y: (top + bottom) / 2)) { translation in controller.cropRight = min(max(0, controller.cropRight - translation.width / scale), max(0, box.width - controller.cropLeft - 18)) }
            }.frame(width: size.width, height: size.height).position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("Anteprima visiva del ritaglio, pagina \(controller.cropPageIndex + 1)")
            .accessibilityValue("Margini in punti: superiore \(controller.cropTop, specifier: "%.2f"), sinistro \(controller.cropLeft, specifier: "%.2f"), inferiore \(controller.cropBottom, specifier: "%.2f"), destro \(controller.cropRight, specifier: "%.2f")")
            .accessibilityHint("Per regolare il ritaglio da tastiera usa i quattro campi dei margini nel pannello a sinistra.")
    }

    private func handle(at point: CGPoint, change: @escaping (CGSize) -> Void) -> some View {
        WorkflowCropHandle(change: change).position(point)
    }
}

private struct WorkflowCropHandle: View {
    let change: (CGSize) -> Void
    @State private var previous = CGSize.zero
    var body: some View {
        Circle().fill(Color.accentColor).overlay(Circle().stroke(.white, lineWidth: 2)).frame(width: 15, height: 15)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let delta = CGSize(width: value.translation.width - previous.width, height: value.translation.height - previous.height)
                previous = value.translation; change(delta)
            }.onEnded { _ in previous = .zero })
    }
}
