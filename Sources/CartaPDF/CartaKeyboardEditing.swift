import AppKit
import PDFKit
import SwiftUI

enum CartaKeyboardAnnotationKind: String, CaseIterable, Identifiable {
    case text = "Testo", note = "Nota", rectangle = "Rettangolo", ellipse = "Ellisse"
    case link = "Collegamento web", typedName = "Nome in corsivo"
    var id: String { rawValue }
}

struct CartaKeyboardEditingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct CartaKeyboardAnnotationEntry: Identifiable {
    let page: PDFPage
    let annotation: PDFAnnotation
    let pageIndex: Int
    var id: ObjectIdentifier { ObjectIdentifier(annotation) }
    var typeLabel: String {
        switch annotation.type {
        case "FreeText": return L10n.tr("Testo")
        case "Text": return L10n.tr("Nota")
        case "Square": return L10n.tr("Rettangolo")
        case "Circle": return L10n.tr("Ellisse")
        case "Link": return L10n.tr("Collegamento")
        case "Widget": return L10n.tr("Campo modulo")
        case "Ink": return L10n.tr("Tratto a mano libera")
        case "Highlight": return L10n.tr("Evidenziazione")
        case "Stamp": return L10n.tr("Timbro")
        default: return annotation.type ?? L10n.tr("Annotazione")
        }
    }
    var content: String {
        if let action = annotation.action as? PDFActionURL { return action.url?.absoluteString ?? annotation.contents ?? "" }
        return annotation.contents ?? annotation.fieldName ?? ""
    }
    var label: String {
        let summary = content.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return L10n.tr("Pagina \(pageIndex + 1), \(typeLabel), \(summary.isEmpty ? L10n.tr("senza descrizione") : String(summary.prefix(120)))")
    }
}

enum CartaKeyboardGeometry {
    static func rectangle(x: Double, y: Double, width: Double, height: Double, within pageBounds: CGRect) throws -> CGRect {
        guard [x, y, width, height, Double(pageBounds.minX), Double(pageBounds.minY), Double(pageBounds.maxX), Double(pageBounds.maxY), Double(pageBounds.width), Double(pageBounds.height)].allSatisfy(\.isFinite),
              pageBounds.width > 0, pageBounds.height > 0 else {
            throw CartaKeyboardEditingError(L10n.tr("Coordinate e dimensioni devono essere numeri finiti."))
        }
        guard width >= 3, height >= 3 else { throw CartaKeyboardEditingError(L10n.tr("Larghezza e altezza devono essere almeno 3 pt.")) }
        guard (x + width).isFinite, (y + height).isFinite,
              x >= Double(pageBounds.minX), y >= Double(pageBounds.minY),
              x + width <= Double(pageBounds.maxX), y + height <= Double(pageBounds.maxY) else {
            throw CartaKeyboardEditingError(L10n.tr("Il riquadro deve essere interamente nell’area visibile della pagina PDF non ruotata."))
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

@MainActor
extension PDFEditorModel {
    var keyboardAnnotationEntries: [CartaKeyboardAnnotationEntry] {
        (0..<pageCount).flatMap { index -> [CartaKeyboardAnnotationEntry] in
            guard let page = document.page(at: index) else { return [] }
            return page.annotations.map { CartaKeyboardAnnotationEntry(page: page, annotation: $0, pageIndex: index) }
        }
    }

    func keyboardCanEdit(_ entry: CartaKeyboardAnnotationEntry, content: Bool = false) -> Bool {
        guard !isProcessing, canEditAnnotations, entry.page.document === document,
              entry.page.annotations.contains(where: { $0 === entry.annotation }) else { return false }
        let annotation = entry.annotation
        let flags = (annotation.value(forAnnotationKey: .flags) as? NSNumber)?.intValue ?? 0
        guard flags & ((1 << 6) | (1 << 7)) == 0 else { return false }
        if content && flags & (1 << 9) != 0 { return false }
        if annotation.type == "Link" {
            return CartaOwnedLink.identity(of: annotation) != nil
        }
        return ["Text", "FreeText", "Ink", "Highlight", "Underline", "StrikeOut", "Square", "Circle", "Line", "Stamp"].contains(annotation.type ?? "")
    }

    @discardableResult
    func createKeyboardAnnotation(kind: CartaKeyboardAnnotationKind, pageIndex: Int, content: String, bounds: CGRect) throws -> PDFAnnotation {
        guard !isProcessing, canEditAnnotations else { throw PDFWorkspaceError.editingNotAllowed }
        guard (0..<pageCount).contains(pageIndex), let page = document.page(at: pageIndex) else { throw CartaKeyboardEditingError(L10n.tr("Scegli una pagina esistente.")) }
        let validBounds = try CartaKeyboardGeometry.rectangle(x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: bounds.height, within: page.bounds(for: .cropBox))
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if [.text, .note, .typedName].contains(kind), text.isEmpty { throw CartaKeyboardEditingError(L10n.tr("Inserisci il testo o il contenuto della nota.")) }
        let type: PDFAnnotationSubtype
        switch kind {
        case .text, .typedName: type = .freeText
        case .note: type = .text
        case .rectangle: type = .square
        case .ellipse: type = .circle
        case .link: type = .link
        }
        let annotation = kind == .link ? CartaOwnedLink.annotation(bounds: validBounds)
            : PDFAnnotation(bounds: validBounds, forType: type, withProperties: nil)
        annotation.contents = text
        annotation.userName = CartaPreferences.shared.annotationAuthor
        annotation.modificationDate = Date()
        annotation.shouldPrint = true
        annotation.shouldDisplay = true
        let border = PDFBorder()
        let stroke = CartaPreferences.shared.strokeWidth
        border.lineWidth = stroke.isFinite ? min(max(stroke, 0.5), 12) : 2.5
        annotation.border = border
        switch kind {
        case .text, .typedName:
            guard textFontSize.isFinite else { throw CartaKeyboardEditingError(L10n.tr("La dimensione del carattere non è valida.")) }
            let size = min(max(textFontSize, 6), 144)
            annotation.font = NSFont(name: kind == .typedName ? "Helvetica-Oblique" : textFontName, size: size) ?? .systemFont(ofSize: size)
            annotation.fontColor = textColor
            annotation.color = .clear
            annotation.alignment = .left
            border.lineWidth = 0
        case .note:
            annotation.iconType = .note
            annotation.color = annotationColor
        case .rectangle, .ellipse:
            annotation.color = annotationColor
            annotation.interiorColor = .clear
        case .link:
            let url = try Self.keyboardWebURL(text)
            annotation.action = PDFActionURL(url: url)
            annotation.contents = url.absoluteString
            annotation.color = .systemBlue
            border.lineWidth = 1
        }
        addBatchAnnotations([(page, annotation)], actionName: L10n.tr("Aggiungi \(L10n.string(kind.rawValue).lowercased())"))
        goToPage(pageIndex)
        selectAnnotation(annotation, on: page)
        warnIfTextOverflows(annotation)
        return annotation
    }

    func setKeyboardAnnotationBounds(_ bounds: CGRect, for entry: CartaKeyboardAnnotationEntry) throws {
        guard keyboardCanEdit(entry) else { throw CartaKeyboardEditingError(L10n.tr("L’annotazione è protetta, non supportata o non appartiene più a questo documento.")) }
        let valid = try CartaKeyboardGeometry.rectangle(x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: bounds.height, within: entry.page.bounds(for: .cropBox))
        if entry.annotation.type == "Link" {
            keyboardSetLinkBounds(valid, annotation: entry.annotation, page: entry.page)
        } else {
            moveAnnotation(entry.annotation, to: valid, on: entry.page)
        }
    }

    func setKeyboardAnnotationContent(_ content: String, for entry: CartaKeyboardAnnotationEntry) throws {
        guard keyboardCanEdit(entry, content: true) else { throw CartaKeyboardEditingError(L10n.tr("Il contenuto dell’annotazione è protetto o non modificabile.")) }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if entry.annotation.type == "Text" || entry.annotation.type == "FreeText" {
            guard !text.isEmpty else { throw CartaKeyboardEditingError(L10n.tr("Il contenuto non può essere vuoto.")) }
            updateAnnotation(entry.annotation, text: text, on: entry.page)
        } else if entry.annotation.type == "Link" {
            let url = try Self.keyboardWebURL(text)
            keyboardSetDescription(url.absoluteString, action: PDFActionURL(url: url), entry: entry)
        } else {
            keyboardSetDescription(text, action: entry.annotation.action, entry: entry)
        }
    }

    func deleteKeyboardAnnotation(_ entry: CartaKeyboardAnnotationEntry) throws {
        guard keyboardCanEdit(entry) else { throw CartaKeyboardEditingError(L10n.tr("L’annotazione è protetta o non può essere eliminata con questo strumento.")) }
        if entry.annotation.type == "Link" { removeWebLink(entry.annotation, from: entry.page) }
        else { removeAnnotation(entry.annotation, from: entry.page) }
    }

    private func keyboardSetLinkBounds(_ bounds: CGRect, annotation: PDFAnnotation, page: PDFPage) {
        guard bounds != annotation.bounds else { return }
        let previous = annotation.bounds
        performChange(named: L10n.tr("Posizione e dimensioni collegamento"), relayout: false, mutation: {
            annotation.bounds = bounds
        }, inverse: { model in model.keyboardSetLinkBounds(previous, annotation: annotation, page: page) })
        pdfView?.annotationsChanged(on: page)
    }

    private func keyboardSetDescription(_ text: String?, action: PDFAction?, entry: CartaKeyboardAnnotationEntry) {
        let previous = entry.annotation.contents, previousAction = entry.annotation.action
        let previousDate = entry.annotation.modificationDate
        guard previous != text || (action as? PDFActionURL)?.url != (previousAction as? PDFActionURL)?.url else { return }
        keyboardRestoreDescription(text, action: action, date: Date(), entry: entry, previousText: previous, previousAction: previousAction, previousDate: previousDate)
    }

    private func keyboardRestoreDescription(_ text: String?, action: PDFAction?, date: Date?, entry: CartaKeyboardAnnotationEntry, previousText: String?, previousAction: PDFAction?, previousDate: Date?) {
        performChange(named: L10n.tr("Modifica contenuto annotazione"), relayout: false, mutation: {
            entry.annotation.contents = text
            entry.annotation.action = action
            entry.annotation.modificationDate = date
        }, inverse: { model in
            model.keyboardRestoreDescription(previousText, action: previousAction, date: previousDate, entry: entry, previousText: text, previousAction: action, previousDate: date)
        })
        pdfView?.annotationsChanged(on: entry.page)
    }

    private static func keyboardWebURL(_ text: String) throws -> URL {
        guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty else {
            throw CartaKeyboardEditingError(L10n.tr("Inserisci un indirizzo completo con https:// oppure http:// e un nome host."))
        }
        return url
    }

    func showKeyboardEditingWorkspace() {
        CartaPanelController.present(CartaKeyboardEditingView(model: self), title: L10n.tr("Annotazioni da tastiera"), width: 920, height: 740)
    }
}

@MainActor
final class CartaKeyboardEditingController: ObservableObject {
    let model: PDFEditorModel
    private let hadDocumentOwner: Bool
    @Published var selectedID: ObjectIdentifier?
    @Published var kind: CartaKeyboardAnnotationKind = .text
    @Published var pageNumber = 1
    @Published var content = ""
    @Published var x: Double = 36
    @Published var y: Double = 36
    @Published var width: Double = 240
    @Published var height: Double = 60
    @Published var message = ""
    @Published var error: String?

    init(model: PDFEditorModel) {
        self.model = model
        hadDocumentOwner = model.documentOwner != nil
        pageNumber = model.currentPageIndex + 1
        resetGeometry()
        if let annotation = model.selectedAnnotation { selectedID = ObjectIdentifier(annotation); loadSelection() }
    }

    var selected: CartaKeyboardAnnotationEntry? { model.keyboardAnnotationEntries.first { $0.id == selectedID } }
    var targetPage: PDFPage? { selected?.page ?? model.document.page(at: pageNumber - 1) }
    var canChangeGeometry: Bool { selected.map { model.keyboardCanEdit($0) } ?? false }
    var canChangeContent: Bool { selected.map { model.keyboardCanEdit($0, content: true) } ?? false }
    var statusDescription: String { error.map { L10n.tr("Errore: \($0)") } ?? message }
    var boundsDescription: String {
        guard let page = targetPage else { return L10n.tr("Nessuna pagina disponibile.") }
        let box = page.bounds(for: .cropBox)
        return L10n.tr("Area visibile: X da \(Double(box.minX), specifier: "%.2f") a \(Double(box.maxX), specifier: "%.2f") pt; Y da \(Double(box.minY), specifier: "%.2f") a \(Double(box.maxY), specifier: "%.2f") pt. Rotazione pagina: \(page.rotation) gradi.")
    }

    func newAnnotation() {
        selectedID = nil
        model.selectAnnotation(nil, on: nil)
        pageNumber = min(max(1, model.currentPageIndex + 1), model.pageCount)
        content = ""; error = nil; message = L10n.tr("Compila i campi, poi scegli Crea annotazione.")
        resetGeometry()
    }

    func resetGeometry() {
        guard selectedID == nil, let page = targetPage else { return }
        let box = page.bounds(for: .cropBox)
        let inset = min(36, max(0, min(box.width, box.height) / 8))
        x = Double(box.minX + inset); y = Double(box.minY + inset)
        width = Double(min(240, max(3, box.width - 2 * inset)))
        height = Double(min(kind == .note ? 26 : 60, max(3, box.height - 2 * inset)))
        if kind == .note { width = min(26, width) }
    }

    func loadSelection() {
        guard let entry = selected else { return }
        pageNumber = entry.pageIndex + 1
        content = entry.content
        let bounds = entry.annotation.bounds
        x = Double(bounds.minX); y = Double(bounds.minY); width = Double(bounds.width); height = Double(bounds.height)
        error = nil; message = model.keyboardCanEdit(entry) ? L10n.tr("Annotazione selezionata.") : L10n.tr("Annotazione consultabile in sola lettura. Moduli e collegamenti esterni a CartaPDF restano protetti.")
        model.goToPage(entry.pageIndex)
        model.selectAnnotation(entry.annotation, on: entry.page)
    }

    func synchronizeSelection() {
        if selectedID != nil && selected == nil {
            selectedID = nil; content = ""; message = L10n.tr("L’annotazione selezionata non è più presente. Scegline un’altra o creane una nuova.")
        }
    }

    func create() {
        execute {
            guard let page = targetPage else { throw CartaKeyboardEditingError(L10n.tr("Scegli una pagina esistente.")) }
            let bounds = try CartaKeyboardGeometry.rectangle(x: x, y: y, width: width, height: height, within: page.bounds(for: .cropBox))
            let annotation = try model.createKeyboardAnnotation(kind: kind, pageIndex: pageNumber - 1, content: content, bounds: bounds)
            selectedID = ObjectIdentifier(annotation)
            loadSelection()
            message = L10n.tr("Annotazione creata sulla pagina \(pageNumber). La modifica può essere annullata.")
        }
    }

    func applyGeometry() {
        execute {
            guard let entry = selected else { throw CartaKeyboardEditingError(L10n.tr("Seleziona un’annotazione ancora presente.")) }
            let bounds = try CartaKeyboardGeometry.rectangle(x: x, y: y, width: width, height: height, within: entry.page.bounds(for: .cropBox))
            try model.setKeyboardAnnotationBounds(bounds, for: entry)
            message = L10n.tr("Posizione e dimensioni aggiornate.")
        }
    }

    func applyContent() {
        execute {
            guard let entry = selected else { throw CartaKeyboardEditingError(L10n.tr("Seleziona un’annotazione ancora presente.")) }
            try model.setKeyboardAnnotationContent(content, for: entry)
            loadSelection()
            message = L10n.tr("Contenuto aggiornato.")
        }
    }

    func deleteSelected() {
        execute {
            guard let entry = selected else { throw CartaKeyboardEditingError(L10n.tr("Seleziona un’annotazione ancora presente.")) }
            try model.deleteKeyboardAnnotation(entry)
            selectedID = nil; content = ""
            message = L10n.tr("Annotazione eliminata. Usa Annulla per ripristinarla.")
        }
    }

    private func execute(_ operation: () throws -> Void) {
        error = nil
        do {
            guard !hadDocumentOwner || model.documentOwner != nil else { throw CartaKeyboardEditingError(L10n.tr("Il documento è stato chiuso. Riaprilo prima di modificare le annotazioni.")) }
            try operation()
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
private struct CartaKeyboardEditingView: View {
    @ObservedObject var model: PDFEditorModel
    @StateObject private var controller: CartaKeyboardEditingController
    @AccessibilityFocusState private var statusFocused: Bool

    init(model: PDFEditorModel) {
        self.model = model
        _controller = StateObject(wrappedValue: CartaKeyboardEditingController(model: model))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.tr("Annotazioni da tastiera")).font(.title2.bold())
                Spacer()
                Button(L10n.tr("Annulla modifica")) { model.undo() }.disabled(!model.canUndo || model.isProcessing)
                Button(L10n.tr("Ripeti modifica")) { model.redo() }.disabled(!model.canRedo || model.isProcessing)
            }
            Text(L10n.tr("Crea e modifica con campi e pulsanti. Coordinate in punti PDF non ruotati, con origine in basso a sinistra: la rotazione cambia la vista, non X e Y."))
                .font(.callout).foregroundStyle(.secondary)
            HSplitView {
                VStack(alignment: .leading) {
                    Button(L10n.tr("Nuova annotazione"), action: controller.newAnnotation).keyboardShortcut("n", modifiers: [.command, .shift])
                    List(selection: $controller.selectedID) {
                        ForEach(model.keyboardAnnotationEntries) { entry in
                            Text(entry.label).lineLimit(3).tag(entry.id)
                                .accessibilityLabel(model.keyboardCanEdit(entry) ? L10n.tr("\(entry.label), modificabile") : L10n.tr("\(entry.label), sola lettura"))
                        }
                    }
                    .accessibilityLabel(L10n.tr("Annotazioni del documento. Usa i tasti freccia per selezionare."))
                    Text(L10n.tr("\(model.keyboardAnnotationEntries.count) annotazioni")).font(.caption)
                }.frame(minWidth: 240, idealWidth: 290)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let selected = controller.selected {
                            Text(L10n.tr("\(selected.typeLabel) · pagina \(selected.pageIndex + 1)")).font(.headline)
                            Button(L10n.tr("Ricarica i valori selezionati"), action: controller.loadSelection)
                        } else {
                            Picker(L10n.tr("Tipo di annotazione"), selection: $controller.kind) {
                                ForEach(CartaKeyboardAnnotationKind.allCases) { Text(L10n.string($0.rawValue)).tag($0) }
                            }
                            Stepper(L10n.tr("Pagina: \(controller.pageNumber)"), value: $controller.pageNumber, in: 1...max(1, model.pageCount))
                            if controller.kind == .typedName { Text(L10n.tr("Inserisce il nome come testo in corsivo. Non aggiunge una firma digitale né un certificato.")).font(.caption) }
                        }
                        GroupBox(L10n.tr("Contenuto o indirizzo web")) {
                            TextEditor(text: $controller.content).frame(minHeight: 90)
                                .accessibilityLabel(L10n.tr("Contenuto dell’annotazione o indirizzo HTTP o HTTPS"))
                                .disabled(controller.selected != nil && !controller.canChangeContent)
                        }
                        if controller.selected != nil {
                            Button(L10n.tr("Salva contenuto"), action: controller.applyContent).disabled(!controller.canChangeContent)
                        }
                        GroupBox(L10n.tr("Posizione e dimensioni in punti")) {
                            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                                numericField(L10n.tr("X, origine orizzontale"), value: $controller.x)
                                numericField(L10n.tr("Y, origine verticale"), value: $controller.y)
                                numericField(L10n.tr("Larghezza"), value: $controller.width)
                                numericField(L10n.tr("Altezza"), value: $controller.height)
                            }.padding(8)
                        }.disabled(controller.selected != nil && !controller.canChangeGeometry)
                        Text(controller.boundsDescription).font(.caption).textSelection(.enabled)
                        if controller.selected != nil {
                            Button(L10n.tr("Applica posizione e dimensioni"), action: controller.applyGeometry)
                                .disabled(!controller.canChangeGeometry).keyboardShortcut(.return, modifiers: .command)
                            Button(L10n.tr("Elimina annotazione"), role: .destructive, action: controller.deleteSelected)
                                .disabled(!controller.canChangeGeometry)
                        } else {
                            Button(L10n.tr("Crea annotazione"), action: controller.create).buttonStyle(.borderedProminent)
                                .disabled(!model.canEditAnnotations).keyboardShortcut(.return, modifiers: .command)
                        }
                    }.padding(16)
                }.frame(minWidth: 420)
            }.disabled(model.isProcessing)
            Text(controller.statusDescription.isEmpty ? L10n.tr("Seleziona un’annotazione o scegli Nuova annotazione.") : controller.statusDescription)
                .foregroundStyle(controller.error == nil ? Color.secondary : Color.red)
                .accessibilityFocused($statusFocused)
        }.padding(20).frame(minWidth: 820, minHeight: 620)
            .onChange(of: controller.selectedID) { _, _ in controller.loadSelection() }
            .onChange(of: controller.pageNumber) { _, _ in controller.resetGeometry() }
            .onChange(of: controller.kind) { _, _ in controller.resetGeometry() }
            .onChange(of: model.contentRevision) { _, _ in controller.synchronizeSelection() }
            .onChange(of: controller.statusDescription) { _, value in if !value.isEmpty { statusFocused = true } }
    }

    private func numericField(_ title: String, value: Binding<Double>) -> some View {
        GridRow {
            Text(title)
            TextField(L10n.tr("\(title) in punti"), value: value, format: .number.precision(.fractionLength(0...3)))
                .labelsHidden().textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.tr("\(title), in punti PDF non ruotati"))
        }
    }
}
