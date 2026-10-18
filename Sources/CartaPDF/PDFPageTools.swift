import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor
extension PDFEditorModel {
    func insertBlankPage() {
        guard requireAdvancedPermission(canEditPages) else { return }
        let blank = PDFEditorModel()
        do { try insertPages(from: blank.document) }
        catch { errorMessage = error.localizedDescription }
    }

    func duplicateCurrentPage() {
        guard requireAdvancedPermission(canEditPages), let page = currentPage,
              let copy = copyPagePreservingFormFlags(page) else { return }
        let pages = orderedPages()
        var duplicated = pages
        duplicated.insert(copy, at: currentPageIndex + 1)
        reorderPages(duplicated, actionName: L10n.tr("Duplica pagina"))
        goToPage(currentPageIndex + 1)
    }

    func moveCurrentPage(by offset: Int) {
        guard requireAdvancedPermission(canEditPages) else { return }
        let target = currentPageIndex + offset
        guard (0..<pageCount).contains(target), target != currentPageIndex else { return }
        var pages = orderedPages()
        let page = pages.remove(at: currentPageIndex)
        pages.insert(page, at: target)
        reorderPages(pages, actionName: L10n.tr("Sposta pagina"))
        goToPage(target)
    }

    func reversePages() {
        guard requireAdvancedPermission(canEditPages), pageCount > 1 else { return }
        let nextIndex = pageCount - 1 - currentPageIndex
        reorderPages(Array(orderedPages().reversed()), actionName: L10n.tr("Inverti pagine"))
        goToPage(nextIndex)
    }

    private func orderedPages() -> [PDFPage] { (0..<pageCount).compactMap(document.page(at:)) }

    private func reorderPages(_ pages: [PDFPage], actionName: String) {
        let previous = orderedPages()
        performChange(named: actionName, mutation: {
            while document.pageCount > 0 { document.removePage(at: 0) }
            for (index, page) in pages.enumerated() { document.insert(page, at: index) }
            lockNativeFormEditing()
        }, inverse: { model in model.reorderPages(previous, actionName: actionName) })
    }

    func extractPages() {
        guard requireAdvancedPermission(!document.isLocked && document.allowsCopying) else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("Estrai pagine")
        alert.informativeText = L10n.tr("Indica le pagine, ad esempio 1-3, 5. L’originale rimane invariato.")
        let field = NSTextField(string: "\(currentPageIndex + 1)")
        field.frame = NSRect(x: 0, y: 0, width: 310, height: 26)
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.tr("Estrai"))
        alert.addButton(withTitle: L10n.tr("Annulla"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let indices = try Self.parsePageRange(field.stringValue, pageCount: pageCount)
            let extracted = try extractedDocument(pageIndexes: indices)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = L10n.tr("Pagine estratte.pdf")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try ensureCopyDestination(url)
            guard let data = extracted.dataRepresentation() else { throw PDFWorkspaceError.cannotSave }
            try data.write(to: url, options: .atomic)
            statusMessage = L10n.tr("Estratte \(indices.count) pagine.")
        } catch { errorMessage = error.localizedDescription }
    }

    func splitPDF() {
        guard requireAdvancedPermission(!document.isLocked && document.allowsCopying) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L10n.tr("Dividi qui")
        panel.message = L10n.tr("Crea un PDF per ogni pagina. I file esistenti non verranno sovrascritti.")
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            let files = try splitPDF(to: directory)
            statusMessage = L10n.tr("Creati \(files.count) PDF nella cartella scelta.")
        } catch { errorMessage = error.localizedDescription }
    }

    func splitPDF(to directory: URL) throws -> [URL] {
        guard !document.isLocked, document.allowsCopying else { throw PDFWorkspaceError.copyingNotAllowed }
        let manager = FileManager.default
        let base = (fileName as NSString).deletingPathExtension.replacingOccurrences(of: "/", with: "-")
        let width = max(3, String(pageCount).count)
        let destinations = (0..<pageCount).map { index in
            let number = String(index + 1)
            let padded = String(repeating: "0", count: max(0, width - number.count)) + number
            return directory.appendingPathComponent("\(base)-\(padded).pdf")
        }
        guard destinations.allSatisfy({ !manager.fileExists(atPath: $0.path) }) else {
            throw PDFAdvancedToolError(L10n.tr("La cartella contiene già uno dei PDF da creare. Scegli una cartella diversa."))
        }
        let staging = directory.appendingPathComponent(".CartaPDF-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        for index in 0..<pageCount {
            let pageDocument = try extractedDocument(pageIndexes: [index])
            guard let data = pageDocument.dataRepresentation() else { throw PDFWorkspaceError.cannotSave }
            try data.write(to: staging.appendingPathComponent(destinations[index].lastPathComponent), options: .atomic)
        }
        var written: [URL] = []
        do {
            for destination in destinations {
                try manager.moveItem(at: staging.appendingPathComponent(destination.lastPathComponent), to: destination)
                written.append(destination)
            }
        } catch {
            for url in written { try? manager.removeItem(at: url) }
            throw error
        }
        return written
    }

    func extractedDocument(pageIndexes: [Int]) throws -> PDFDocument {
        guard !document.isLocked, document.allowsCopying else { throw PDFWorkspaceError.copyingNotAllowed }
        guard !pageIndexes.isEmpty, pageIndexes.allSatisfy({ (0..<pageCount).contains($0) }) else {
            throw PDFAdvancedToolError(L10n.tr("L’intervallo contiene pagine non valide."))
        }
        let result = PDFDocument()
        result.documentAttributes = document.documentAttributes
        for index in pageIndexes {
            guard let page = document.page(at: index), let copy = copyPagePreservingFormFlags(page) else { throw PDFWorkspaceError.invalidPDF }
            result.insert(copy, at: result.pageCount)
        }
        return result
    }

    static func parsePageRange(_ text: String, pageCount: Int) throws -> [Int] {
        var result: [Int] = []
        for item in text.replacingOccurrences(of: "–", with: "-").split(separator: ",", omittingEmptySubsequences: false) {
            let ends = item.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(ends.count),
                  let first = Int(ends[0].trimmingCharacters(in: .whitespaces)), first > 0, first <= pageCount else {
                throw PDFAdvancedToolError(L10n.tr("Intervallo non valido. Usa ad esempio 1-3, 5."))
            }
            let last: Int
            if ends.count == 2 {
                guard let value = Int(ends[1].trimmingCharacters(in: .whitespaces)), value >= first, value <= pageCount else {
                    throw PDFAdvancedToolError(L10n.tr("L’intervallo supera le pagine del documento o è invertito."))
                }
                last = value
            } else { last = first }
            for number in first...last where !result.contains(number - 1) { result.append(number - 1) }
        }
        guard !result.isEmpty else { throw PDFAdvancedToolError(L10n.tr("Seleziona almeno una pagina.")) }
        return result
    }

    func cropCurrentPage() {
        guard requireAdvancedPermission(canEditDocument), currentPage != nil else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("Ritaglia pagina")
        alert.informativeText = L10n.tr("Margini da rimuovere in punti PDF (72 pt = 1 pollice). Il contenuto fuori dal ritaglio viene nascosto, non cancellato.")
        let labels = [L10n.tr("Superiore"), L10n.tr("Sinistro"), L10n.tr("Inferiore"), L10n.tr("Destro")]
        let fields = labels.map { _ in NSTextField(string: "18") }
        alert.accessoryView = Self.formAccessory(labels: labels, fields: fields)
        alert.addButton(withTitle: L10n.tr("Ritaglia"))
        alert.addButton(withTitle: L10n.tr("Annulla"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let numbers = try fields.map { field -> CGFloat in
                guard let value = Double(field.stringValue.replacingOccurrences(of: ",", with: ".")), value.isFinite else {
                    throw PDFAdvancedToolError(L10n.tr("Inserisci margini numerici validi."))
                }
                return CGFloat(value)
            }
            try cropCurrentPage(margins: NSEdgeInsets(top: numbers[0], left: numbers[1], bottom: numbers[2], right: numbers[3]))
        } catch { errorMessage = error.localizedDescription }
    }

    func cropCurrentPage(margins: NSEdgeInsets) throws {
        guard canEditDocument, let page = currentPage else { throw PDFWorkspaceError.editingNotAllowed }
        let values = [margins.top, margins.left, margins.bottom, margins.right]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw PDFAdvancedToolError(L10n.tr("I margini devono essere positivi.")) }
        let old = page.bounds(for: .cropBox)
        let width = old.width - margins.left - margins.right
        let height = old.height - margins.top - margins.bottom
        guard width.isFinite, height.isFinite, width >= 18, height >= 18 else {
            throw PDFAdvancedToolError(L10n.tr("Il ritaglio deve lasciare almeno 18 punti di larghezza e altezza."))
        }
        let bounds = CGRect(x: old.minX + margins.left, y: old.minY + margins.bottom,
                            width: width, height: height)
        setCropBounds(bounds, of: page)
    }

    private func setCropBounds(_ bounds: CGRect, of page: PDFPage) {
        let previous = page.bounds(for: .cropBox)
        performChange(named: L10n.tr("Ritaglia pagina"), mutation: { page.setBounds(bounds, for: .cropBox) }, inverse: { model in
            model.setCropBounds(previous, of: page)
        })
    }

    func addWatermark() {
        guard requireAdvancedPermission(canEditAnnotations) else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("Aggiungi filigrana")
        alert.informativeText = L10n.tr("Il testo verrà sovrapposto al centro di tutte le pagine.")
        let field = NSTextField(string: L10n.tr("BOZZA"))
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 26)
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.tr("Aggiungi"))
        alert.addButton(withTitle: L10n.tr("Annulla"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        addWatermark(text: field.stringValue)
    }

    func addWatermark(text: String) {
        guard requireAdvancedPermission(canEditAnnotations) else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let annotations = orderedPages().map { page -> (PDFPage, PDFAnnotation) in
            let bounds = page.bounds(for: .cropBox)
            let size = max(14, min(60, bounds.width / max(8, CGFloat(value.count)) * 1.4))
            let rect = CGRect(x: bounds.minX + 12, y: bounds.midY - size, width: bounds.width - 24, height: size * 2)
            let annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
            annotation.contents = value
            annotation.font = NSFont.boldSystemFont(ofSize: size)
            annotation.fontColor = NSColor.gray.withAlphaComponent(0.3)
            annotation.color = .clear
            annotation.alignment = .center
            let border = PDFBorder(); border.lineWidth = 0; annotation.border = border
            return (page, annotation)
        }
        addBatchAnnotations(annotations, actionName: L10n.tr("Aggiungi filigrana"))
    }

    func addPageNumbers() {
        guard requireAdvancedPermission(canEditAnnotations) else { return }
        let annotations = orderedPages().enumerated().map { index, page -> (PDFPage, PDFAnnotation) in
            let bounds = page.bounds(for: .cropBox)
            let annotation = PDFAnnotation(bounds: CGRect(x: bounds.midX - 60, y: bounds.minY + 12, width: 120, height: 20), forType: .freeText, withProperties: nil)
            annotation.contents = "\(index + 1) / \(pageCount)"
            annotation.font = NSFont.systemFont(ofSize: 10)
            annotation.fontColor = .darkGray
            annotation.color = .clear
            annotation.alignment = .center
            let border = PDFBorder(); border.lineWidth = 0; annotation.border = border
            return (page, annotation)
        }
        addBatchAnnotations(annotations, actionName: L10n.tr("Numera pagine"))
    }

    func addBatesNumbers() {
        guard requireAdvancedPermission(canEditAnnotations) else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("Numerazione Bates")
        alert.informativeText = L10n.tr("Aggiunge un identificatore progressivo al piè di pagina di ogni pagina.")
        let prefix = NSTextField(string: "DOC-")
        let start = NSTextField(string: "1")
        let padding = NSTextField(string: "6")
        alert.accessoryView = Self.formAccessory(labels: [L10n.tr("Prefisso"), L10n.tr("Primo numero"), L10n.tr("Cifre minime")], fields: [prefix, start, padding])
        alert.addButton(withTitle: L10n.tr("Numera"))
        alert.addButton(withTitle: L10n.tr("Annulla"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let startValue = Int(start.stringValue), let paddingValue = Int(padding.stringValue) else {
            errorMessage = L10n.tr("Numero iniziale e cifre minime devono essere numeri interi.")
            return
        }
        do { try addBatesNumbers(prefix: prefix.stringValue, start: startValue, padding: paddingValue) }
        catch { errorMessage = error.localizedDescription }
    }

    func addBatesNumbers(prefix: String, start: Int, padding: Int) throws {
        guard canEditAnnotations else { throw PDFWorkspaceError.editingNotAllowed }
        guard start >= 0, (1...20).contains(padding), start <= Int.max - pageCount else {
            throw PDFAdvancedToolError(L10n.tr("Usa un numero iniziale positivo e da 1 a 20 cifre minime."))
        }
        let annotations = orderedPages().enumerated().map { index, page -> (PDFPage, PDFAnnotation) in
            let value = String(start + index)
            let text = prefix + String(repeating: "0", count: max(0, padding - value.count)) + value
            let bounds = page.bounds(for: .cropBox)
            let annotation = PDFAnnotation(bounds: CGRect(x: bounds.minX + 18, y: bounds.minY + 10, width: max(20, bounds.width - 36), height: 20), forType: .freeText, withProperties: nil)
            annotation.contents = text
            annotation.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            annotation.fontColor = .black
            annotation.color = .clear
            annotation.alignment = .right
            let border = PDFBorder(); border.lineWidth = 0; annotation.border = border
            return (page, annotation)
        }
        addBatchAnnotations(annotations, actionName: L10n.tr("Numerazione Bates"))
    }

    func addBatchAnnotations(_ annotations: [(PDFPage, PDFAnnotation)], actionName: String) {
        guard !annotations.isEmpty, requireAdvancedPermission(canEditAnnotations) else { return }
        performChange(named: actionName, mutation: {
            for (page, annotation) in annotations {
                annotation.modificationDate = Date()
                page.addAnnotation(annotation)
            }
            lockNativeFormEditing()
        }, inverse: { model in model.removeBatchAnnotations(annotations, actionName: actionName) })
    }

    private func removeBatchAnnotations(_ annotations: [(PDFPage, PDFAnnotation)], actionName: String) {
        performChange(named: actionName, mutation: {
            for (page, annotation) in annotations { page.removeAnnotation(annotation) }
        }, inverse: { model in model.addBatchAnnotations(annotations, actionName: actionName) })
    }

    func editMetadata() {
        guard requireAdvancedPermission(canEditDocument) else { return }
        let attributes = document.documentAttributes ?? [:]
        let keys: [PDFDocumentAttribute] = [.titleAttribute, .authorAttribute, .subjectAttribute, .keywordsAttribute]
        let fields = keys.map { key -> NSTextField in
            if let keywords = attributes[key] as? [String] { return NSTextField(string: keywords.joined(separator: ", ")) }
            return NSTextField(string: attributes[key] as? String ?? "")
        }
        let alert = NSAlert()
        alert.messageText = L10n.tr("Proprietà del documento")
        alert.accessoryView = Self.formAccessory(labels: [L10n.tr("Titolo"), L10n.tr("Autore"), L10n.tr("Oggetto"), L10n.tr("Parole chiave")], fields: fields)
        alert.addButton(withTitle: L10n.tr("Salva proprietà"))
        alert.addButton(withTitle: L10n.tr("Annulla"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var changed = attributes
        for (index, key) in keys.enumerated() {
            if index == 3 { changed[key] = fields[index].stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            else { changed[key] = fields[index].stringValue }
        }
        setMetadata(changed)
    }

    func setMetadata(_ attributes: [AnyHashable: Any]?) {
        guard requireAdvancedPermission(canEditDocument) else { return }
        let previous = document.documentAttributes
        performChange(named: L10n.tr("Modifica proprietà"), mutation: { document.documentAttributes = attributes }, inverse: { model in model.setMetadata(previous) })
    }

    func protectPDFCopy() {
        guard requireAdvancedPermission(canEditDocument) else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("Proteggi una copia con password")
        alert.informativeText = L10n.tr("La copia richiederà una password all’apertura. Dopo lo sblocco stampa, copia e modifica saranno consentite. Nessuna password viene memorizzata dall’app.")
        let password = NSSecureTextField(string: "")
        let confirmation = NSSecureTextField(string: "")
        alert.accessoryView = Self.formAccessory(labels: [L10n.tr("Password"), L10n.tr("Conferma")], fields: [password, confirmation])
        alert.addButton(withTitle: L10n.tr("Salva copia"))
        alert.addButton(withTitle: L10n.tr("Annulla"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard !password.stringValue.isEmpty, password.stringValue == confirmation.stringValue else {
            errorMessage = L10n.tr("Inserisci la stessa password, non vuota, in entrambi i campi.")
            return
        }
        do {
            let data = try protectedCopyData(password: password.stringValue)
            password.stringValue = ""; confirmation.stringValue = ""
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = L10n.tr("\((fileName as NSString).deletingPathExtension) protetto.pdf")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try ensureCopyDestination(url)
            try CartaFileIO.atomicWrite(data, to: url)
            statusMessage = L10n.tr("Copia protetta salvata: cifratura e password di apertura verificate.")
        } catch { errorMessage = error.localizedDescription }
    }

    private func ensureCopyDestination(_ url: URL) throws {
        if let source = documentOwner?.fileURL, source.resolvingSymlinksInPath().standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL {
            throw PDFAdvancedToolError(L10n.tr("Scegli un file diverso dall’originale per salvare la copia."))
        }
    }

    func protectedCopyData(password: String) throws -> Data {
        guard canEditDocument else { throw PDFWorkspaceError.editingNotAllowed }
        guard !password.isEmpty else { throw PDFAdvancedToolError(L10n.tr("La password non può essere vuota.")) }
        let data = try serializedData(options: [PDFDocumentWriteOption.ownerPasswordOption: password, PDFDocumentWriteOption.userPasswordOption: password])
        guard let verification = PDFDocument(data: data), verification.isEncrypted, verification.isLocked,
              verification.unlock(withPassword: password), verification.pageCount == pageCount else {
            throw PDFAdvancedToolError(L10n.tr("La copia non supera la verifica di cifratura e apertura. Nessun file è stato salvato."))
        }
        return data
    }

    @discardableResult
    func requireAdvancedPermission(_ permitted: Bool) -> Bool {
        if !permitted { errorMessage = PDFWorkspaceError.editingNotAllowed.localizedDescription }
        return permitted
    }

    static func formAccessory(labels: [String], fields: [NSTextField]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for (label, field) in zip(labels, fields) {
            field.setAccessibilityLabel(label)
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 12
            let title = NSTextField(labelWithString: label)
            title.setAccessibilityElement(false)
            title.widthAnchor.constraint(equalToConstant: 100).isActive = true
            field.widthAnchor.constraint(equalToConstant: 250).isActive = true
            row.addArrangedSubview(title)
            row.addArrangedSubview(field)
            stack.addArrangedSubview(row)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 370, height: fields.count * 36)
        return stack
    }
}

struct PDFAdvancedToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
