import AppKit
import Combine
import CoreText
import PDFKit
import UniformTypeIdentifiers
import Vision

struct WorkflowError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct WorkflowRangeResult {
    let indices: [Int]
    let repeatedPages: [Int]
}

struct WorkflowSource: Identifiable {
    let id: UUID
    let url: URL?
    let title: String
    let document: PDFDocument
    let byteCount: Int
    let formats: [String]
    var range: String
    init(document: PDFDocument, title: String, url: URL? = nil, range: String = "all") {
        id = UUID(); self.document = document; self.title = title; self.url = url; self.range = range
        byteCount = url.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? document.dataRepresentation()?.count ?? 0
        formats = Set((0..<document.pageCount).compactMap(document.page(at:)).map { page -> String in
            let box = page.bounds(for: .cropBox)
            let size = abs(page.rotation % 180) == 90 ? CGSize(width: box.height, height: box.width) : box.size
            guard size.width.isFinite, size.height.isFinite, abs(size.width) < 1_000_000, abs(size.height) < 1_000_000 else { return L10n.tr("Formato non valido") }
            return "\(Int(size.width.rounded())) × \(Int(size.height.rounded())) pt"
        }).sorted()
    }
}

enum WorkflowMergeMode: String, CaseIterable, Identifiable {
    case append = "In sequenza", alternate = "Fronte/retro alternato", groups = "Gruppi per nome"
    var id: String { rawValue }
}

enum WorkflowSplitMode: String, CaseIterable, Identifiable {
    case intervals = "Intervalli", everyN = "Ogni N pagine", bookmarks = "Segnalibri", blank = "Pagine bianche"
    case text = "Testo separatore", barcode = "QR / codice a barre", maxBytes = "Dimensione massima"
    var id: String { rawValue }
}

enum WorkflowConflictPolicy: String, CaseIterable, Identifiable {
    case fail = "Interrompi sui conflitti", rename = "Rinomina le copie", replace = "Sostituisci dopo conferma"
    var id: String { rawValue }
}

struct WorkflowPart: Identifiable {
    let id = UUID()
    var indices: [Int]
    var label: String
    var estimatedBytes: Int = 0
}

struct WorkflowOutput {
    var name: String
    let document: PDFDocument
    var password: String? = nil
}

struct WorkflowPageToken: Identifiable {
    let id = UUID()
    let index: Int
}

enum WorkflowLayoutMode: String, CaseIterable, Identifiable {
    case organize = "Organizza pagine", replace = "Sostituisci pagine", nUp = "N pagine per foglio"
    case booklet = "Libretto fronte/retro", poster = "Poster a tasselli", facing = "Separa scansione libro"
    case overlay = "Sovrapponi PDF", contents = "Sommario cliccabile"
    var id: String { rawValue }
}

enum WorkflowPosition: String, CaseIterable, Identifiable {
    case topLeft = "Alto sinistra", top = "Alto centro", topRight = "Alto destra"
    case left = "Centro sinistra", center = "Centro", right = "Centro destra"
    case bottomLeft = "Basso sinistra", bottom = "Basso centro", bottomRight = "Basso destra"
    var id: String { rawValue }
}

struct WorkflowTextSettings {
    var text = L10n.tr("BOZZA")
    var fontName = "Helvetica-Bold"
    var fontSize: CGFloat = 48
    var opacity: CGFloat = 0.25
    var color = NSColor.gray
    var position: WorkflowPosition = .center
    var margin: CGFloat = 24
}

struct WorkflowNumberingSettings {
    var header = ""
    var footer = "{page} / {pages}"
    var batesPrefix = "DOC-"
    var start = 1
    var padding = 6
    var fontSize: CGFloat = 10
    var margin: CGFloat = 18
    var usesBates = false
}

/// PDFKit rejects numeric /CA for FreeText (it interprets it as a widget caption),
/// so opacity is rendered into the native annotation appearance stream instead.
final class WorkflowWatermarkAnnotation: PDFAnnotation {
    static let opacityKey = PDFAnnotationKey(rawValue: "/CartaPDFOpacity")
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.setAlpha(CGFloat((value(forAnnotationKey: Self.opacityKey) as? NSNumber)?.doubleValue ?? 1))
        super.draw(with: box, in: context)
        context.restoreGState()
    }
}

enum WorkflowBatchKind: String, CaseIterable, Codable, Identifiable {
    case rotate = "Ruota", reverse = "Inverti pagine", crop = "Ritaglia margini", watermark = "Filigrana"
    case numbers = "Numeri pagina", bates = "Numeri Bates", extract = "Estrai intervallo", nUp = "N-up"
    case booklet = "Libretto", split = "Dividi ogni N", flatten = "Appiattisci", jpeg = "Ottimizza JPEG", ocr = "OCR", protect = "Proteggi copia"
    var id: String { rawValue }
}

struct WorkflowBatchStep: Identifiable, Codable {
    var id = UUID()
    var kind: WorkflowBatchKind
    var text: String = ""
    var value: Double = 18
    var secondary: Double = 2
    init(kind: WorkflowBatchKind) {
        self.kind = kind
        switch kind {
        case .rotate: value = 90
        case .watermark: text = L10n.tr("BOZZA"); value = 48
        case .numbers: text = "{page} / {pages}"; value = 10
        case .bates: text = "DOC-"; value = 1; secondary = 6
        case .extract: text = "all"
        case .nUp: value = 2; secondary = 2
        case .split: value = 10
        case .flatten, .jpeg: value = 144; secondary = 0.7
        default: break
        }
    }
}

@MainActor
enum WorkflowEngine {
    typealias Progress = (Double, String) -> Void

    static func parseRange(_ text: String, pageCount: Int) throws -> WorkflowRangeResult {
        guard pageCount > 0 else { throw WorkflowError(L10n.tr("Il documento non contiene pagine.")) }
        let normalized = text.lowercased().replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: ";", with: ",").replacingOccurrences(of: "\n", with: ",")
        var indices: [Int] = [], repeated: [Int] = []
        let tokens = normalized.split(separator: ",", omittingEmptySubsequences: false)
        for raw in tokens {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw WorkflowError(L10n.tr("Intervallo vuoto vicino a “\(raw)”. Usa 1-3, 5, ultima.")) }
            var selected: [Int]
            switch token {
            case "all", "tutte", "tutti", "*": selected = Array(0..<pageCount)
            case "odd", "dispari": selected = Array(stride(from: 0, to: pageCount, by: 2))
            case "even", "pari": selected = Array(stride(from: 1, to: pageCount, by: 2))
            case "last", "ultima": selected = [pageCount - 1]
            default:
                let parts = token.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                func number(_ value: String) -> Int? { value == "ultima" || value == "last" ? pageCount : Int(value) }
                guard (1...2).contains(parts.count), let first = number(parts[0]), first > 0, first <= pageCount else {
                    throw WorkflowError(L10n.tr("“\(token)” non è valido: le pagine vanno da 1 a \(pageCount)."))
                }
                let last = parts.count == 2 ? number(parts[1]) : first
                guard let last, last >= first, last <= pageCount else { throw WorkflowError(L10n.tr("Intervallo “\(token)” invertito o fuori dal documento.")) }
                selected = Array((first - 1)..<last)
            }
            for index in selected {
                if indices.contains(index) { if !repeated.contains(index) { repeated.append(index) } }
                else { indices.append(index) }
            }
        }
        guard !indices.isEmpty else { throw WorkflowError(L10n.tr("La selezione non contiene pagine.")) }
        return WorkflowRangeResult(indices: indices, repeatedPages: repeated)
    }

    static func validateSource(_ document: PDFDocument, rendering: Bool = false) throws {
        guard !document.isLocked else { throw WorkflowError(L10n.tr("Sblocca il PDF con la sua password prima di elaborarlo.")) }
        guard document.pageCount > 0, document.allowsCopying else { throw PDFWorkspaceError.copyingNotAllowed }
        if rendering && !document.allowsPrinting { throw PDFWorkspaceError.printingNotAllowed }
    }

    static func extract(_ document: PDFDocument, indices: [Int], keepOutline: Bool = true) throws -> PDFDocument {
        try validateSource(document)
        guard !indices.isEmpty, indices.allSatisfy({ (0..<document.pageCount).contains($0) }) else { throw WorkflowError(L10n.tr("Selezione di pagine non valida.")) }
        let result = PDFDocument()
        result.documentAttributes = document.documentAttributes
        var mapping: [Int: PDFPage] = [:]
        for index in indices {
            guard let page = document.page(at: index), let copy = page.copy() as? PDFPage else { throw PDFWorkspaceError.invalidPDF }
            result.insert(copy, at: result.pageCount)
            if mapping[index] == nil { mapping[index] = copy }
        }
        if keepOutline, let sourceRoot = document.outlineRoot {
            let root = PDFOutline()
            appendOutlineChildren(sourceRoot, to: root, source: document, mapping: mapping)
            if root.numberOfChildren > 0 { result.outlineRoot = root }
        }
        return result
    }

    static func appendOutlineChildren(_ sourceNode: PDFOutline, to target: PDFOutline, source: PDFDocument, mapping: [Int: PDFPage], depth: Int = 0) {
        guard depth < 24 else { return }
        for index in 0..<min(sourceNode.numberOfChildren, 10_000) {
            guard let child = sourceNode.child(at: index) else { continue }
            let copied = PDFOutline()
            target.insertChild(copied, at: target.numberOfChildren)
            copied.label = child.label ?? L10n.tr("Segnalibro")
            if let destination = child.destination, let page = destination.page, let mapped = mapping[source.index(for: page)] {
                copied.destination = PDFDestination(page: mapped, at: destination.point)
            }
            appendOutlineChildren(child, to: copied, source: source, mapping: mapping, depth: depth + 1)
            if copied.destination == nil && copied.numberOfChildren == 0 { copied.removeFromParent() }
        }
    }

    static func merge(_ sources: [WorkflowSource], alternate: Bool = false, reverseBacks: Bool = true,
                      keepOutline: Bool = true, progress: Progress = { _, _ in }) async throws -> PDFDocument {
        guard !sources.isEmpty else { throw WorkflowError(L10n.tr("Aggiungi almeno un documento.")) }
        if alternate && sources.count != 2 { throw WorkflowError(L10n.tr("L’unione fronte/retro richiede esattamente due PDF: fronti e retri.")) }
        var selections: [[Int]] = []
        for source in sources {
            try validateSource(source.document)
            selections.append(try parseRange(source.range, pageCount: source.document.pageCount).indices)
        }
        if alternate && reverseBacks { selections[1].reverse() }
        var sequence: [(Int, Int)] = []
        if alternate {
            for index in 0..<max(selections[0].count, selections[1].count) {
                for side in 0..<2 where selections[side].indices.contains(index) { sequence.append((side, selections[side][index])) }
            }
        } else {
            for source in sources.indices { sequence += selections[source].map { (source, $0) } }
        }
        let result = PDFDocument()
        result.documentAttributes = [PDFDocumentAttribute.creatorAttribute: "CartaPDF"]
        var mappings = Array(repeating: [Int: PDFPage](), count: sources.count)
        for (position, entry) in sequence.enumerated() {
            try Task.checkCancellation()
            guard let copy = sources[entry.0].document.page(at: entry.1)?.copy() as? PDFPage else { throw PDFWorkspaceError.invalidPDF }
            result.insert(copy, at: result.pageCount)
            mappings[entry.0][entry.1] = copy
            progress(Double(position + 1) / Double(sequence.count), L10n.tr("\(sources[entry.0].title) · pagina \(entry.1 + 1) · \(position + 1)/\(sequence.count)"))
            await Task.yield()
        }
        if keepOutline {
            let root = PDFOutline()
            for index in sources.indices {
                guard let firstIndex = selections[index].first, let firstPage = mappings[index][firstIndex] else { continue }
                let parent = PDFOutline()
                root.insertChild(parent, at: root.numberOfChildren)
                parent.label = sources[index].title
                parent.destination = PDFDestination(page: firstPage, at: CGPoint(x: 0, y: firstPage.bounds(for: .cropBox).maxY))
                if let existing = sources[index].document.outlineRoot { appendOutlineChildren(existing, to: parent, source: sources[index].document, mapping: mappings[index]) }
            }
            result.outlineRoot = root
        }
        return result
    }

    static func filenameGroup(_ title: String) -> String {
        let base = (title as NSString).deletingPathExtension
        let regex = try! NSRegularExpression(pattern: "[ _-]+[0-9]+$")
        let grouped = regex.stringByReplacingMatches(in: base, range: NSRange(base.startIndex..., in: base), withTemplate: "")
        return grouped.isEmpty ? base : grouped
    }

    static func groupedSources(_ sources: [WorkflowSource]) -> [(String, [WorkflowSource])] {
        var names: [String] = [], groups: [String: [WorkflowSource]] = [:]
        for source in sources {
            let key = filenameGroup(source.title)
            if groups[key] == nil { names.append(key) }
            groups[key, default: []].append(source)
        }
        return names.map { ($0, groups[$0] ?? []) }
    }

    static func planSplit(_ source: PDFDocument, mode: WorkflowSplitMode, count: Int = 10, intervals: String = "all",
                          marker: String = "", maxBytes: Int = 5_000_000, skipMarkers: Bool = false,
                          blankThreshold: Double = 0.002, progress: Progress = { _, _ in }) async throws -> [WorkflowPart] {
        try validateSource(source, rendering: mode == .blank || mode == .barcode)
        let total = source.pageCount
        if mode == .intervals {
            return try intervals.split(separator: ";", omittingEmptySubsequences: false).map {
                WorkflowPart(indices: try parseRange(String($0), pageCount: total).indices, label: L10n.tr("Intervallo"))
            }
        }
        if mode == .everyN {
            guard count > 0 else { throw WorkflowError(L10n.tr("N deve essere maggiore di zero.")) }
            return stride(from: 0, to: total, by: count).map { WorkflowPart(indices: Array($0..<min($0 + count, total)), label: L10n.tr("Parte")) }
        }
        if mode == .maxBytes {
            guard maxBytes >= 1024 else { throw WorkflowError(L10n.tr("La dimensione massima deve essere almeno 1 KB.")) }
            var parts: [WorkflowPart] = [], current: [Int] = []
            for index in 0..<total {
                try Task.checkCancellation()
                let candidate = current + [index]
                let bytes = try serialized(extract(source, indices: candidate)).count
                if bytes > maxBytes {
                    guard !current.isEmpty else { throw WorkflowError(L10n.tr("La pagina \(index + 1) supera da sola il limite. Aumentalo: i PDF non vengono ricompressi durante questa divisione.")) }
                    parts.append(WorkflowPart(indices: current, label: L10n.tr("Parte"), estimatedBytes: try serialized(extract(source, indices: current)).count))
                    current = [index]
                    guard try serialized(extract(source, indices: current)).count <= maxBytes else { throw WorkflowError(L10n.tr("La pagina \(index + 1) supera da sola il limite scelto.")) }
                } else { current = candidate }
                progress(Double(index + 1) / Double(total), L10n.tr("Misurazione pagina \(index + 1)/\(total)"))
                await Task.yield()
            }
            if !current.isEmpty { parts.append(WorkflowPart(indices: current, label: L10n.tr("Parte"), estimatedBytes: try serialized(extract(source, indices: current)).count)) }
            return parts
        }
        var boundaries: [Int: String] = [0: L10n.tr("Parte")]
        var excluded: Set<Int> = []
        if mode == .bookmarks {
            guard let root = source.outlineRoot, root.numberOfChildren > 0 else { throw WorkflowError(L10n.tr("Il documento non contiene segnalibri utilizzabili.")) }
            for index in 0..<root.numberOfChildren {
                guard let child = root.child(at: index), let page = child.destination?.page else { continue }
                let pageIndex = source.index(for: page)
                if pageIndex != NSNotFound { boundaries[pageIndex] = child.label ?? L10n.tr("Parte") }
            }
            guard boundaries.count > 1 || root.child(at: 0)?.destination?.page != nil else { throw WorkflowError(L10n.tr("I segnalibri non hanno destinazioni di pagina utilizzabili.")) }
        } else {
            if mode == .text && marker.trimmingCharacters(in: .whitespaces).isEmpty { throw WorkflowError(L10n.tr("Inserisci il testo separatore da cercare.")) }
            for index in 0..<total {
                try Task.checkCancellation()
                guard let page = source.page(at: index) else { throw PDFWorkspaceError.invalidPDF }
                var isMarker = false, label = L10n.tr("Parte")
                if mode == .text { isMarker = (page.string ?? L10n.tr("")).localizedCaseInsensitiveContains(marker); label = marker }
                else if mode == .blank {
                    let raster = try PDFConversionEngine.renderPage(page, dpi: 36)
                    isMarker = try blankFraction(raster.image) <= min(max(blankThreshold, 0), 0.1)
                    label = L10n.tr("Dopo pagina bianca")
                } else if mode == .barcode {
                    let raster = try PDFConversionEngine.renderPage(page, dpi: 100)
                    let request = VNDetectBarcodesRequest()
                    try VNImageRequestHandler(cgImage: raster.image, options: [:]).perform([request])
                    let found = (request.results ?? []).compactMap(\.payloadStringValue).first { marker.isEmpty || $0.localizedCaseInsensitiveContains(marker) }
                    isMarker = found != nil; label = found ?? L10n.tr("Codice")
                }
                if isMarker {
                    if skipMarkers { excluded.insert(index); if index + 1 < total { boundaries[index + 1] = label } }
                    else { boundaries[index] = label }
                }
                progress(Double(index + 1) / Double(total), L10n.tr("Analisi pagina \(index + 1)/\(total)"))
                await Task.yield()
            }
        }
        let starts = boundaries.keys.sorted()
        let parts = starts.enumerated().compactMap { offset, start -> WorkflowPart? in
            let end = offset + 1 < starts.count ? starts[offset + 1] : total
            let indices = (start..<end).filter { !excluded.contains($0) }
            return indices.isEmpty ? nil : WorkflowPart(indices: indices, label: boundaries[start] ?? L10n.tr("Parte"))
        }
        guard !parts.isEmpty else { throw WorkflowError(L10n.tr("La divisione non produce pagine. Disattiva l’esclusione dei separatori.")) }
        return parts
    }

    static func blankFraction(_ image: CGImage) throws -> Double {
        let size = 128
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw PDFConversionError.cannotRender }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = context.data else { throw PDFConversionError.cannotRender }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let dark = (0..<(size * size)).filter { bytes[$0] < 220 }.count
        return Double(dark) / Double(size * size)
    }

    static func outputName(pattern: String, source: String, part: WorkflowPart, index: Int) -> String {
        var result = pattern
        let values = ["name": (source as NSString).deletingPathExtension, "index": String(index + 1),
                      "start": String((part.indices.first ?? 0) + 1), "end": String((part.indices.last ?? 0) + 1),
                      "pages": String(part.indices.count), "label": part.label]
        for (key, value) in values {
            let regex = try! NSRegularExpression(pattern: "\\{" + key + "(?::([0-9]{1,2}))?\\}")
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                guard let range = Range(match.range, in: result) else { continue }
                var formatted = value
                if match.range(at: 1).location != NSNotFound, let digits = Range(match.range(at: 1), in: result), let width = Int(result[digits]) {
                    formatted = String(repeating: "0", count: max(0, min(width, 20) - value.count)) + value
                }
                result.replaceSubrange(range, with: formatted)
            }
        }
        result = result.components(separatedBy: CharacterSet(charactersIn: "/:\0\n\r")).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty { result = L10n.tr("Parte-\(index + 1)") }
        if result.lowercased().hasSuffix(".pdf") { result = String(result.dropLast(4)) }
        while result.utf8.count > 235 { result.removeLast() }
        return result + ".pdf"
    }

    static func serialized(_ document: PDFDocument, password: String? = nil) throws -> Data {
        let data: Data?
        if let password {
            guard !password.isEmpty else { throw WorkflowError(L10n.tr("Inserisci una password per le copie protette.")) }
            data = document.dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: password, PDFDocumentWriteOption.userPasswordOption: password])
        } else { data = document.dataRepresentation() }
        guard let data else { throw PDFWorkspaceError.cannotSave }
        return data
    }

    static func displayedSize(_ page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox)
        return abs(page.rotation % 180) == 90 ? CGSize(width: box.height, height: box.width) : box.size
    }

    private static func draw(_ page: PDFPage, into rect: CGRect, context: CGContext, opacity: CGFloat = 1) throws {
        let size = displayedSize(page)
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else { throw WorkflowError(L10n.tr("Dimensioni di pagina non valide.")) }
        let scale = min(rect.width / size.width, rect.height / size.height)
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to: rect)
        context.setAlpha(min(max(opacity, 0), 1))
        context.translateBy(x: rect.midX - size.width * scale / 2, y: rect.midY - size.height * scale / 2)
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
    }

    private final class Writer {
        let data = NSMutableData()
        let context: CGContext
        init() throws {
            guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: nil, [kCGPDFContextCreator as String: "CartaPDF"] as CFDictionary) else { throw PDFWorkspaceError.cannotSave }
            self.context = context
        }
        func begin(_ size: CGSize) throws {
            guard size.width.isFinite, size.height.isFinite, size.width >= 18, size.height >= 18, size.width <= 20_000, size.height <= 20_000 else { throw WorkflowError(L10n.tr("Il foglio deve misurare da 18 a 20.000 punti per lato.")) }
            var rect = CGRect(origin: .zero, size: size)
            let box = NSData(bytes: &rect, length: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
        }
        func finish() throws -> PDFDocument {
            context.closePDF()
            guard let doc = PDFDocument(data: data as Data), doc.pageCount > 0 else { throw PDFWorkspaceError.cannotSave }
            return doc
        }
    }

    static func nUp(_ source: PDFDocument, columns: Int, rows: Int, sheet: CGSize, gutter: CGFloat = 12,
                    booklet: Bool = false, progress: Progress = { _, _ in }) async throws -> PDFDocument {
        try validateSource(source, rendering: true)
        guard (1...8).contains(columns), (1...8).contains(rows), gutter >= 0 else { throw WorkflowError(L10n.tr("Usa da 1 a 8 righe/colonne e una spaziatura positiva.")) }
        let cols = booklet ? 2 : columns, lineCount = booklet ? 1 : rows
        let capacity = cols * lineCount
        let cell = CGSize(width: (sheet.width - gutter * CGFloat(cols + 1)) / CGFloat(cols), height: (sheet.height - gutter * CGFloat(lineCount + 1)) / CGFloat(lineCount))
        guard cell.width >= 10, cell.height >= 10 else { throw WorkflowError(L10n.tr("Spaziatura troppo grande per il foglio.")) }
        var order: [Int?]
        if booklet {
            let padded = ((source.pageCount + 3) / 4) * 4
            order = []
            for sheetIndex in 0..<(padded / 4) {
                let values = [padded - 1 - sheetIndex * 2, sheetIndex * 2, sheetIndex * 2 + 1, padded - 2 - sheetIndex * 2]
                order += values.map { $0 < source.pageCount ? $0 : nil }
            }
        } else { order = (0..<source.pageCount).map(Optional.some) }
        let writer = try Writer()
        for offset in stride(from: 0, to: order.count, by: capacity) {
            try Task.checkCancellation(); try writer.begin(sheet)
            for slot in 0..<capacity where offset + slot < order.count {
                guard let index = order[offset + slot], let page = source.page(at: index) else { continue }
                let column = slot % cols, row = slot / cols
                let rect = CGRect(x: gutter + CGFloat(column) * (cell.width + gutter),
                                  y: sheet.height - gutter - CGFloat(row + 1) * cell.height - CGFloat(row) * gutter, width: cell.width, height: cell.height)
                try draw(page, into: rect, context: writer.context)
            }
            writer.context.endPDFPage()
            progress(Double(min(offset + capacity, order.count)) / Double(order.count), L10n.tr("Impaginazione foglio \(offset / capacity + 1)"))
            await Task.yield()
        }
        return try writer.finish()
    }

    static func poster(_ source: PDFDocument, columns: Int, rows: Int, sheet: CGSize, overlap: CGFloat,
                       progress: Progress = { _, _ in }) async throws -> PDFDocument {
        try validateSource(source, rendering: true)
        guard (1...12).contains(columns), (1...12).contains(rows), overlap >= 0, overlap < min(sheet.width, sheet.height) / 2 else { throw WorkflowError(L10n.tr("Griglia o sovrapposizione del poster non valida.")) }
        let canvas = CGSize(width: sheet.width * CGFloat(columns) - overlap * CGFloat(columns - 1), height: sheet.height * CGFloat(rows) - overlap * CGFloat(rows - 1))
        let writer = try Writer(); var completed = 0
        for index in 0..<source.pageCount {
            guard let page = source.page(at: index) else { throw PDFWorkspaceError.invalidPDF }
            for row in 0..<rows { for column in 0..<columns {
                try Task.checkCancellation(); try writer.begin(sheet)
                writer.context.saveGState()
                writer.context.clip(to: CGRect(origin: .zero, size: sheet))
                writer.context.translateBy(x: -CGFloat(column) * (sheet.width - overlap), y: -CGFloat(rows - 1 - row) * (sheet.height - overlap))
                try draw(page, into: CGRect(origin: .zero, size: canvas), context: writer.context)
                writer.context.restoreGState(); writer.context.endPDFPage()
                completed += 1; progress(Double(completed) / Double(source.pageCount * rows * columns), L10n.tr("Tassello \(completed)/\(source.pageCount * rows * columns)"))
                await Task.yield()
            } }
        }
        return try writer.finish()
    }

    static func facing(_ source: PDFDocument, rightFirst: Bool = false, progress: Progress = { _, _ in }) async throws -> PDFDocument {
        try validateSource(source, rendering: true)
        let writer = try Writer()
        for index in 0..<source.pageCount {
            guard let page = source.page(at: index) else { throw PDFWorkspaceError.invalidPDF }
            let size = displayedSize(page), half = CGSize(width: size.width / 2, height: size.height)
            for side in (rightFirst ? [1, 0] : [0, 1]) {
                try Task.checkCancellation(); try writer.begin(half)
                writer.context.saveGState(); writer.context.clip(to: CGRect(origin: .zero, size: half))
                writer.context.translateBy(x: -CGFloat(side) * half.width, y: 0)
                try draw(page, into: CGRect(origin: .zero, size: size), context: writer.context)
                writer.context.restoreGState(); writer.context.endPDFPage(); await Task.yield()
            }
            progress(Double(index + 1) / Double(source.pageCount), L10n.tr("Separazione scansione \(index + 1)"))
        }
        return try writer.finish()
    }

    static func overlay(_ base: PDFDocument, overlay: PDFDocument, opacity: CGFloat, progress: Progress = { _, _ in }) async throws -> PDFDocument {
        try validateSource(base, rendering: true); try validateSource(overlay, rendering: true)
        guard opacity.isFinite, opacity > 0, opacity <= 1 else { throw WorkflowError(L10n.tr("L’opacità deve essere maggiore di zero e non superiore a uno.")) }
        let writer = try Writer()
        for index in 0..<base.pageCount {
            try Task.checkCancellation()
            guard let page = base.page(at: index), let top = overlay.page(at: index % overlay.pageCount) else { throw PDFWorkspaceError.invalidPDF }
            let size = displayedSize(page); try writer.begin(size)
            try draw(page, into: CGRect(origin: .zero, size: size), context: writer.context)
            try draw(top, into: CGRect(origin: .zero, size: size), context: writer.context, opacity: opacity)
            writer.context.endPDFPage(); progress(Double(index + 1) / Double(base.pageCount), L10n.tr("Sovrapposizione pagina \(index + 1)")); await Task.yield()
        }
        return try writer.finish()
    }

    static func replace(_ source: PDFDocument, indices: [Int], replacements: PDFDocument) throws -> PDFDocument {
        try validateSource(source); try validateSource(replacements)
        guard !indices.isEmpty, indices.count == replacements.pageCount, Set(indices).count == indices.count else { throw WorkflowError(L10n.tr("Seleziona tante pagine quante quelle del PDF sostitutivo, senza duplicati.")) }
        let result = try extract(source, indices: Array(0..<source.pageCount), keepOutline: false)
        for (position, index) in indices.enumerated() {
            guard (0..<result.pageCount).contains(index), let copy = replacements.page(at: position)?.copy() as? PDFPage else { throw WorkflowError(L10n.tr("Pagina sostitutiva non valida.")) }
            result.removePage(at: index); result.insert(copy, at: index)
        }
        if let root = source.outlineRoot {
            let copy = PDFOutline(), mapping = Dictionary(uniqueKeysWithValues: (0..<source.pageCount).compactMap { i in result.page(at: i).map { (i, $0) } })
            appendOutlineChildren(root, to: copy, source: source, mapping: mapping); result.outlineRoot = copy
        }
        return result
    }

    static func template(_ text: String, page: Int, pages: Int, name: String, bates: String = "", date: Date = Date()) -> String {
        let formatter = DateFormatter(); formatter.locale = L10n.currentLocale; formatter.dateStyle = .short
        return text.replacingOccurrences(of: "{page}", with: String(page)).replacingOccurrences(of: "{pages}", with: String(pages))
            .replacingOccurrences(of: "{name}", with: (name as NSString).deletingPathExtension)
            .replacingOccurrences(of: "{date}", with: formatter.string(from: date)).replacingOccurrences(of: "{bates}", with: bates)
    }

    static func watermarkAnnotations(_ source: PDFDocument, indices: [Int], settings: WorkflowTextSettings) throws -> [(PDFPage, PDFAnnotation)] {
        guard settings.fontSize >= 6, settings.fontSize <= 144, settings.opacity > 0, settings.opacity <= 1,
              settings.margin.isFinite, settings.margin >= 0, !settings.text.isEmpty else { throw WorkflowError(L10n.tr("Testo, dimensione, margini o opacità della filigrana non validi.")) }
        let font = NSFont(name: settings.fontName, size: settings.fontSize) ?? NSFont.systemFont(ofSize: settings.fontSize)
        return try indices.map { index in
            guard let page = source.page(at: index) else { throw PDFWorkspaceError.invalidPDF }
            let crop = page.bounds(for: .cropBox), available = max(10, crop.width - 2 * settings.margin)
            let height = ceil((settings.text as NSString).boundingRect(with: CGSize(width: available, height: 100_000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height) + 12
            guard crop.width - 2 * settings.margin >= 18, height + 2 * settings.margin <= crop.height else { throw WorkflowError(L10n.tr("La filigrana non entra nella pagina \(index + 1). Riduci font, testo o margini.")) }
            let y: CGFloat
            switch settings.position { case .top, .topLeft, .topRight: y = crop.maxY - settings.margin - height
            case .bottom, .bottomLeft, .bottomRight: y = crop.minY + settings.margin
            default: y = crop.midY - height / 2 }
            let annotation = WorkflowWatermarkAnnotation(bounds: CGRect(x: crop.minX + settings.margin, y: max(crop.minY, y), width: available, height: height), forType: .freeText, withProperties: nil)
            annotation.contents = settings.text; annotation.font = font; annotation.fontColor = settings.color.withAlphaComponent(1); annotation.color = .clear
            annotation.setValue(NSNumber(value: Double(settings.opacity)), forAnnotationKey: WorkflowWatermarkAnnotation.opacityKey)
            switch settings.position { case .left, .topLeft, .bottomLeft: annotation.alignment = .left
            case .right, .topRight, .bottomRight: annotation.alignment = .right
            default: annotation.alignment = .center }
            let border = PDFBorder(); border.lineWidth = 0; annotation.border = border; annotation.userName = "CartaPDF:workflow-watermark"
            return (page, annotation)
        }
    }

    static func numberingAnnotations(_ source: PDFDocument, indices: [Int], name: String, settings: WorkflowNumberingSettings) throws -> [(PDFPage, PDFAnnotation)] {
        guard (1...20).contains(settings.padding), settings.start >= 0, settings.start <= Int.max - indices.count,
              settings.fontSize >= 6, settings.fontSize <= 72, settings.margin.isFinite, settings.margin >= 0 else { throw WorkflowError(L10n.tr("Impostazioni della numerazione non valide.")) }
        var result: [(PDFPage, PDFAnnotation)] = []
        let font = NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
        for (offset, index) in indices.enumerated() {
            guard let page = source.page(at: index) else { throw PDFWorkspaceError.invalidPDF }
            let value = String(settings.start + offset), bates = settings.batesPrefix + String(repeating: "0", count: max(0, settings.padding - value.count)) + value
            let crop = page.bounds(for: .cropBox), width = crop.width - settings.margin * 2
            guard settings.margin * 2 + settings.fontSize * 1.8 < crop.height else { throw WorkflowError(L10n.tr("Margini o font troppo grandi per la pagina \(index + 1).")) }
            for (header, raw) in [(true, settings.header), (false, settings.usesBates ? "{bates}" : settings.footer)] where !raw.isEmpty {
                let text = template(raw, page: index + 1, pages: source.pageCount, name: name, bates: bates)
                guard (text as NSString).size(withAttributes: [.font: font]).width + 8 <= width else { throw WorkflowError(L10n.tr("Il testo “\(text)” non entra nel piè pagina. Riduci font/prefisso o margini.")) }
                let annotation = PDFAnnotation(bounds: CGRect(x: crop.minX + settings.margin, y: header ? crop.maxY - settings.margin - settings.fontSize * 1.8 : crop.minY + settings.margin, width: width, height: settings.fontSize * 1.8), forType: .freeText, withProperties: nil)
                annotation.contents = text; annotation.font = font; annotation.fontColor = .black; annotation.color = .clear; annotation.alignment = .center
                let border = PDFBorder(); border.lineWidth = 0; annotation.border = border; annotation.userName = "CartaPDF:workflow-numbering"
                result.append((page, annotation))
            }
        }
        return result
    }

    static func existingNumberingCount(_ document: PDFDocument) -> Int {
        let regex = try! NSRegularExpression(pattern: "^\\s*[0-9]+\\s*/\\s*[0-9]+\\s*$")
        return (0..<document.pageCount).compactMap(document.page(at:)).flatMap(\.annotations).filter {
            $0.userName == "CartaPDF:workflow-numbering" || ($0.contents.map { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil } ?? false)
        }.count
    }

    static func tableOfContents(_ source: PDFDocument, title: String = L10n.tr("Indice")) throws -> PDFDocument {
        try validateSource(source)
        var entries: [(String, Int)] = []
        if let root = source.outlineRoot {
            for index in 0..<root.numberOfChildren {
                guard let child = root.child(at: index), let page = child.destination?.page else { continue }
                let pageIndex = source.index(for: page)
                if pageIndex != NSNotFound { entries.append((child.label ?? L10n.tr("Pagina \(pageIndex + 1)"), pageIndex)) }
            }
        }
        if entries.isEmpty { entries = (0..<source.pageCount).map { (L10n.tr("Pagina \($0 + 1)"), $0) } }
        let rows = 35, tocCount = (entries.count + rows - 1) / rows, writer = try Writer()
        let size = CGSize(width: 595.276, height: 841.89)
        for toc in 0..<tocCount {
            try writer.begin(size)
            @MainActor func drawLine(_ text: String, x: CGFloat, y: CGFloat, fontSize: CGFloat) {
                let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
                writer.context.textPosition = CGPoint(x: x, y: y); CTLineDraw(line, writer.context)
            }
            drawLine(title, x: 42, y: 786, fontSize: 24)
            for offset in 0..<rows where toc * rows + offset < entries.count {
                let entry = entries[toc * rows + offset]
                drawLine("\(entry.0.prefix(65))  ·  \(entry.1 + tocCount + 1)", x: 42, y: 744 - CGFloat(offset) * 19, fontSize: 11)
            }
            writer.context.endPDFPage()
        }
        let result = try writer.finish()
        var mapping: [Int: PDFPage] = [:]
        for index in 0..<source.pageCount {
            guard let page = source.page(at: index)?.copy() as? PDFPage else { throw PDFWorkspaceError.invalidPDF }
            result.insert(page, at: result.pageCount); mapping[index] = page
        }
        for (index, entry) in entries.enumerated() {
            guard let page = result.page(at: index / rows), let destination = mapping[entry.1] else { continue }
            let link = PDFAnnotation(bounds: CGRect(x: 38, y: 740 - CGFloat(index % rows) * 19, width: 515, height: 18), forType: .link, withProperties: nil)
            link.destination = PDFDestination(page: destination, at: CGPoint(x: 0, y: destination.bounds(for: .cropBox).maxY)); page.addAnnotation(link)
        }
        let root = PDFOutline()
        if let original = source.outlineRoot { appendOutlineChildren(original, to: root, source: source, mapping: mapping) }
        result.outlineRoot = root
        return result
    }
}

@MainActor
enum WorkflowStagedWriter {
    static func destinations(names: [String], directory: URL, policy: WorkflowConflictPolicy) throws -> [URL] {
        let fm = FileManager.default
        var reserved = Set<String>(), urls: [URL] = []
        for name in names {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw WorkflowError(L10n.tr("Il nome di output deve essere un nome file, senza cartelle o caratteri nulli.")) }
            var url = directory.appendingPathComponent(name), suffix = 2
            if policy == .rename {
                while fm.fileExists(atPath: url.path) || reserved.contains(url.path) {
                    url = directory.appendingPathComponent("\((name as NSString).deletingPathExtension)-\(suffix).pdf"); suffix += 1
                }
            } else if reserved.contains(url.path) { throw WorkflowError(L10n.tr("Il modello produce due file chiamati “\(name)”. Aggiungi {index} al nome.")) }
            else if policy == .fail && fm.fileExists(atPath: url.path) { throw WorkflowError(L10n.tr("Esiste già “\(name)”. Scegli Rinomina o una cartella diversa.")) }
            reserved.insert(url.path); urls.append(url)
        }
        return urls
    }

    static func write(_ outputs: [WorkflowOutput], directory: URL, policy: WorkflowConflictPolicy,
                      protectedURLs: [URL] = [], progress: WorkflowEngine.Progress = { _, _ in }) async throws -> [URL] {
        guard !outputs.isEmpty else { throw WorkflowError(L10n.tr("Nessun documento da salvare.")) }
        let fm = FileManager.default
        let targets = try destinations(names: outputs.map(\.name), directory: directory, policy: policy)
        let protectedPaths = Set(protectedURLs.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        guard targets.allSatisfy({ !protectedPaths.contains($0.resolvingSymlinksInPath().standardizedFileURL.path) }) else { throw WorkflowError(L10n.tr("Le copie non possono sostituire i documenti sorgente.")) }
        let staging = directory.appendingPathComponent(".CartaPDF-stage-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        for (index, output) in outputs.enumerated() {
            try Task.checkCancellation()
            let data = try WorkflowEngine.serialized(output.document, password: output.password)
            guard let check = PDFDocument(data: data) else { throw PDFWorkspaceError.cannotSave }
            if let password = output.password { guard check.unlock(withPassword: password) else { throw WorkflowError(L10n.tr("La verifica della password della copia non è riuscita.")) } }
            guard check.pageCount == output.document.pageCount else { throw WorkflowError(L10n.tr("La verifica del numero di pagine della copia non è riuscita.")) }
            try data.write(to: staging.appendingPathComponent("part-\(index).pdf"), options: .atomic)
            progress(Double(index + 1) / Double(outputs.count) * 0.8, L10n.tr("Preparazione \(output.name) · \(index + 1)/\(outputs.count)"))
            await Task.yield()
        }
        var written: [URL] = [], backups: [(URL, URL)] = []
        do {
            for (index, destination) in targets.enumerated() {
                try Task.checkCancellation()
                if fm.fileExists(atPath: destination.path) {
                    guard policy == .replace else { throw WorkflowError(L10n.tr("È comparso un file in conflitto: \(destination.lastPathComponent). Nessuna copia verrà sovrascritta.")) }
                    let backup = staging.appendingPathComponent("backup-\(index)")
                    try fm.moveItem(at: destination, to: backup); backups.append((destination, backup))
                }
                try fm.moveItem(at: staging.appendingPathComponent("part-\(index).pdf"), to: destination)
                written.append(destination)
                progress(0.8 + Double(index + 1) / Double(outputs.count) * 0.2, L10n.tr("Conferma \(index + 1)/\(outputs.count)"))
                await Task.yield()
            }
            try Task.checkCancellation()
            return written
        } catch {
            for url in written { try? fm.removeItem(at: url) }
            for (original, backup) in backups { try? fm.moveItem(at: backup, to: original) }
            throw error
        }
    }
}

@MainActor
extension WorkflowEngine {
    static func runBatch(sources: [WorkflowSource], steps: [WorkflowBatchStep], password: String = "",
                         progress: Progress = { _, _ in }) async throws -> [WorkflowOutput] {
        guard !sources.isEmpty, !steps.isEmpty else { throw WorkflowError(L10n.tr("Scegli documenti e almeno un passaggio.")) }
        var outputs: [WorkflowOutput] = []
        let rendering = steps.contains { [.nUp, .booklet, .flatten, .jpeg, .ocr].contains($0.kind) }
        for (fileIndex, source) in sources.enumerated() {
            try validateSource(source.document, rendering: rendering)
            var documents = [try extract(source.document, indices: parseRange(source.range, pageCount: source.document.pageCount).indices)]
            var protected = false
            for (stepIndex, step) in steps.enumerated() {
                try Task.checkCancellation()
                progress((Double(fileIndex) + Double(stepIndex) / Double(steps.count)) / Double(sources.count), L10n.tr("\(source.title) · \(L10n.string(step.kind.rawValue)) · passaggio \(stepIndex + 1)/\(steps.count)"))
                if step.kind == .protect {
                    guard !password.isEmpty else { throw WorkflowError(L10n.tr("Inserisci la password delle copie protette prima di avviare la procedura.")) }
                    protected = true; continue
                }
                var changed: [PDFDocument] = []
                for document in documents {
                    switch step.kind {
                    case .rotate:
                        let angle = try integer(step.value, range: -3600...3600)
                        guard angle % 90 == 0 else { throw WorkflowError(L10n.tr("La rotazione deve essere multipla di 90°.")) }
                        for index in 0..<document.pageCount { document.page(at: index)?.rotation += angle }
                        changed.append(document)
                    case .reverse: changed.append(try extract(document, indices: Array((0..<document.pageCount).reversed())))
                    case .crop:
                        guard step.value.isFinite, step.value >= 0 else { throw WorkflowError(L10n.tr("Margine non valido nella procedura.")) }
                        for index in 0..<document.pageCount {
                            guard let page = document.page(at: index) else { throw PDFWorkspaceError.invalidPDF }
                            let box = page.bounds(for: .cropBox), margin = CGFloat(step.value)
                            guard box.width - margin * 2 >= 18, box.height - margin * 2 >= 18 else { throw WorkflowError(L10n.tr("Il margine elimina tutta la pagina \(index + 1) di \(source.title).")) }
                            page.setBounds(box.insetBy(dx: margin, dy: margin), for: .cropBox)
                        }
                        changed.append(document)
                    case .watermark:
                        var settings = WorkflowTextSettings(); settings.text = step.text; settings.fontSize = CGFloat(step.value)
                        for (page, annotation) in try watermarkAnnotations(document, indices: Array(0..<document.pageCount), settings: settings) { page.addAnnotation(annotation) }
                        changed.append(document)
                    case .numbers, .bates:
                        var settings = WorkflowNumberingSettings()
                        if step.kind == .bates { settings.usesBates = true; settings.batesPrefix = step.text; settings.start = try integer(step.value, range: 0...1_000_000_000); settings.padding = try integer(step.secondary, range: 1...20) }
                        else { settings.footer = step.text; settings.fontSize = CGFloat(step.value) }
                        for (page, annotation) in try numberingAnnotations(document, indices: Array(0..<document.pageCount), name: source.title, settings: settings) { page.addAnnotation(annotation) }
                        changed.append(document)
                    case .extract: changed.append(try extract(document, indices: parseRange(step.text, pageCount: document.pageCount).indices))
                    case .nUp: changed.append(try await nUp(document, columns: integer(step.value, range: 1...8), rows: integer(step.secondary, range: 1...8), sheet: CGSize(width: 841.89, height: 595.276)))
                    case .booklet: changed.append(try await nUp(document, columns: 2, rows: 1, sheet: CGSize(width: 841.89, height: 595.276), booklet: true))
                    case .split:
                        let count = try integer(step.value, range: 1...1_000_000)
                        for start in stride(from: 0, to: document.pageCount, by: count) { changed.append(try extract(document, indices: Array(start..<min(start + count, document.pageCount)))) }
                    case .flatten, .jpeg, .ocr:
                        let snapshot = try serialized(document)
                        let kind = step.kind, dpi = step.value, quality = step.secondary
                        let worker = Task.detached(priority: .userInitiated) { () throws -> Data in
                            if kind == .ocr { return try PDFConversionEngine.ocrPDFData(snapshot: snapshot).data }
                            return try PDFConversionEngine.rasterPDFData(snapshot: snapshot, dpi: dpi, jpegQuality: kind == .jpeg ? quality : nil)
                        }
                        let data = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                        guard let converted = PDFDocument(data: data) else { throw PDFWorkspaceError.cannotSave }
                        changed.append(converted)
                    case .protect: break
                    }
                    await Task.yield()
                }
                documents = changed
                await Task.yield()
            }
            for (part, document) in documents.enumerated() {
                let label = documents.count == 1 ? L10n.tr("elaborato") : L10n.tr("parte-\(part + 1)")
                let name = outputName(pattern: "{name}-\(label)", source: source.title, part: WorkflowPart(indices: Array(0..<document.pageCount), label: label), index: part)
                outputs.append(WorkflowOutput(name: name, document: document, password: protected ? password : nil))
            }
            progress(Double(fileIndex + 1) / Double(sources.count), L10n.tr("Completato \(source.title)"))
            await Task.yield()
        }
        return outputs
    }

    private static func integer(_ value: Double, range: ClosedRange<Int>) throws -> Int {
        guard value.isFinite, value.rounded() == value, value >= Double(range.lowerBound), value <= Double(range.upperBound) else { throw WorkflowError(L10n.tr("Parametro intero non valido: usa un valore tra \(range.lowerBound) e \(range.upperBound).")) }
        return Int(value)
    }
}

@MainActor
extension PDFEditorModel {
    func workflowSource() throws -> WorkflowSource {
        try WorkflowEngine.validateSource(document)
        let copy = PDFDocument()
        copy.documentAttributes = document.documentAttributes
        var mapping: [Int: PDFPage] = [:]
        for index in 0..<pageCount {
            guard let page = document.page(at: index), let copied = copyPagePreservingFormFlags(page) else { throw PDFWorkspaceError.invalidPDF }
            copy.insert(copied, at: copy.pageCount); mapping[index] = copied
        }
        if let root = document.outlineRoot {
            let copied = PDFOutline(); WorkflowEngine.appendOutlineChildren(root, to: copied, source: document, mapping: mapping); copy.outlineRoot = copied
        }
        return WorkflowSource(document: copy, title: fileName, url: documentOwner?.fileURL)
    }
}
