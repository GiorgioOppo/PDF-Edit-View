import AppKit
import CryptoKit
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum CartaVisualEngine {
    struct Difference { let image: CGImage; let changedFraction: Double }
    static func pixels(_ image: CGImage, width: Int = 256, height: Int = 256) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        let success = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let scale = min(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            context.draw(image, in: CGRect(x: (CGFloat(width) - size.width) / 2, y: (CGFloat(height) - size.height) / 2, width: size.width, height: size.height))
            return true
        }
        guard success else { throw PDFWorkspaceError.cannotSave }
        return bytes
    }
    static func difference(left: CGImage, right: CGImage, threshold: Int = 24) throws -> Difference {
        let width = 700, height = 900
        let a = try pixels(left, width: width, height: height), b = try pixels(right, width: width, height: height)
        var out = a, changed = 0
        for offset in stride(from: 0, to: a.count, by: 4) {
            if offset % (width * 4) == 0 { try Task.checkCancellation() }
            let delta = max(abs(Int(a[offset]) - Int(b[offset])), abs(Int(a[offset + 1]) - Int(b[offset + 1])), abs(Int(a[offset + 2]) - Int(b[offset + 2])))
            if delta > threshold { out[offset] = 255; out[offset + 1] = 30; out[offset + 2] = 30; changed += 1 }
            else { let gray = UInt8((Int(a[offset]) + Int(a[offset + 1]) + Int(a[offset + 2])) / 3); out[offset] = gray; out[offset + 1] = gray; out[offset + 2] = gray }
            out[offset + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw PDFWorkspaceError.cannotSave }
        return Difference(image: image, changedFraction: Double(changed) / Double(width * height))
    }
    static func duplicatePairs(snapshot: Data, tolerance: Double = 0.012) throws -> [(Int, Int, Double)] {
        guard let pdf = PDFDocument(data: snapshot), !pdf.isLocked else { throw PDFWorkspaceError.invalidPDF }
        var fingerprints: [[UInt8]] = [], sizes: [CGSize] = [], pairs: [(Int, Int, Double)] = []
        for index in 0..<pdf.pageCount {
            try Task.checkCancellation()
            guard let page = pdf.page(at: index) else { continue }
            let raster = try PDFConversionEngine.renderPage(page, dpi: 40)
            let pixels = try self.pixels(raster.image, width: 96, height: 128)
            for prior in 0..<fingerprints.count where sizes[prior] == raster.pageSize {
                try Task.checkCancellation()
                let distance = zip(pixels, fingerprints[prior]).enumerated().reduce(0.0) { result, value in
                    value.offset % 4 == 3 ? result : result + Double(abs(Int(value.element.0) - Int(value.element.1)))
                } / Double(96 * 128 * 3 * 255)
                if distance <= tolerance { pairs.append((prior, index, 1 - distance)) }
            }
            fingerprints.append(pixels); sizes.append(raster.pageSize)
        }
        return pairs
    }
}

@MainActor
final class CartaVisualState: ObservableObject {
    @Published var image: NSImage?
    @Published var message = ""
    @Published var busy = false
    @Published var page = 0
    @Published var threshold = 24
    @Published var pairs: [(Int, Int, Double)] = []
    var task: Task<Void, Never>?
    private var operationID = UUID()
    let left: Data
    let right: Data?
    var pageCount: Int { max(PDFDocument(data: left)?.pageCount ?? 0, right.flatMap(PDFDocument.init(data:))?.pageCount ?? 0) }
    init(left: Data, right: Data? = nil) { self.left = left; self.right = right }
    func compare() {
        task?.cancel(); busy = true
        operationID = UUID()
        let id = operationID, limit = CartaPreferences.shared.concurrentJobs
        let left = left, right = right, index = page, threshold = threshold
        task = Task {
            defer { if operationID == id { busy = false } }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try await CartaJobLimiter.shared.withPermit(limit: limit) {
                        guard let leftDocument = PDFDocument(data: left), let right,
                              let rightDocument = PDFDocument(data: right), let a = leftDocument.page(at: index),
                              let b = rightDocument.page(at: index) else { throw PDFWorkspaceError.invalidPDF }
                        return try withExtendedLifetime((leftDocument, rightDocument)) {
                            try CartaVisualEngine.difference(left: PDFConversionEngine.renderPage(a, dpi: 90).image,
                                                            right: PDFConversionEngine.renderPage(b, dpi: 90).image, threshold: threshold)
                        }
                    }
                }
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard operationID == id else { return }
                image = NSImage(cgImage: result.image, size: .zero)
                message = L10n.tr("Pixel diversi: \(result.changedFraction * 100, specifier: "%.2f")%. Rosso = differenza oltre soglia; la resa può variare tra font e antialias.")
            } catch {
                guard operationID == id else { return }
                message = error is CancellationError ? L10n.tr("Confronto annullato.") : L10n.tr("Pagina mancante o non confrontabile: \(error.localizedDescription)"); image = nil
            }
            guard operationID == id else { return }
            busy = false
        }
    }
    func duplicates() {
        task?.cancel()
        busy = true
        operationID = UUID()
        let source = left, id = operationID, limit = CartaPreferences.shared.concurrentJobs
        task = Task {
            defer { if operationID == id { busy = false } }
            do {
                let worker = Task.detached {
                    try await CartaJobLimiter.shared.withPermit(limit: limit) { try CartaVisualEngine.duplicatePairs(snapshot: source) }
                }
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard operationID == id else { return }
                pairs = result
                message = L10n.tr("\(pairs.count) coppie candidate. Verifica visivamente prima di eliminare pagine.")
            } catch {
                guard operationID == id else { return }
                message = error is CancellationError ? L10n.tr("Ricerca annullata.") : error.localizedDescription
            }
            guard operationID == id else { return }
            busy = false
        }
    }
}

@MainActor
private struct CartaVisualWorkspace: View {
    @StateObject var state: CartaVisualState
    let model: PDFEditorModel
    let revision: Int
    let duplicates: Bool
    var body: some View {
        VStack(spacing: 15) {
            Text(duplicates ? L10n.tr("Pagine duplicate visive") : L10n.tr("Confronto visivo")).font(.title2.bold())
            if state.busy { HStack { ProgressView(); Button(L10n.tr("Annulla")) { state.task?.cancel() } } }
            if duplicates {
                List(Array(state.pairs.enumerated()), id: \.offset) { _, pair in
                    HStack {
                        Text(L10n.tr("Pagine \(pair.0 + 1) e \(pair.1 + 1) · \(Int(pair.2 * 100))% simili"))
                        Spacer()
                        Button(L10n.tr("Mostra prima")) { model.goToPage(pair.0) }.accessibilityLabel(L10n.tr("Mostra pagina \(pair.0 + 1), prima della coppia"))
                        Button(L10n.tr("Mostra seconda")) { model.goToPage(pair.1) }.accessibilityLabel(L10n.tr("Mostra pagina \(pair.1 + 1), seconda della coppia"))
                    }
                }
                if model.contentRevision != revision { Text(L10n.tr("Il documento è cambiato: riapri lo strumento per aggiornare i risultati.")).foregroundStyle(.orange) }
            } else {
                HStack {
                    Stepper(L10n.tr("Pagina \(state.page + 1)"), value: $state.page, in: 0...max(0, state.pageCount - 1))
                    Stepper(L10n.tr("Soglia \(state.threshold)"), value: $state.threshold, in: 1...100)
                    Button(L10n.tr("Confronta"), action: state.compare)
                }
                if let image = state.image {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel(L10n.tr("Confronto visivo della pagina \(state.page + 1)"))
                        .accessibilityHint(L10n.tr("Le differenze grafiche sono visuali. Il riepilogo indica la percentuale di pixel diversi; usa Confronta documenti per le differenze testuali."))
                }
            }
            CartaPanelAccessibilityStatus(message: state.message, label: duplicates ? L10n.tr("Ricerca duplicati") : L10n.tr("Confronto visivo")).font(.callout).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 760, minHeight: 650)
            .onAppear { if duplicates { state.duplicates() } else { state.compare() } }
            .onDisappear { state.task?.cancel() }
            .accessibilityIdentifier(duplicates ? "panel.visual.duplicates" : "panel.visual.comparison")
    }
}

struct CartaStamp: Codable, Identifiable {
    var id: UUID
    var title: String
    var text: String
    var imageName: String?
}

@MainActor
final class CartaStampStore: ObservableObject {
    static let shared = CartaStampStore()
    @Published var items: [CartaStamp] = []
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? CartaSnapshotStore.shared.baseURL.appendingPathComponent("Stamps")
        if let data = try? Data(contentsOf: self.directory.appendingPathComponent("index.json")), let list = try? JSONDecoder().decode([CartaStamp].self, from: data) { items = list }
        else { items = [L10n.tr("APPROVATO"), L10n.tr("RISERVATO"), L10n.tr("BOZZA")].map { CartaStamp(id: UUID(), title: $0, text: $0) } }
    }
    func addText(_ text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        items.append(CartaStamp(id: UUID(), title: text, text: text)); try save()
    }
    func addImage(_ url: URL) throws {
        let image = try PDFConversionEngine.image(from: url)
        let id = UUID(), name = UUID().uuidString + ".png"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try PDFConversionEngine.pngData(for: image).write(to: directory.appendingPathComponent(name), options: .atomic)
        items.append(CartaStamp(id: id, title: url.deletingPathExtension().lastPathComponent, text: "", imageName: name)); try save()
    }
    private func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(items).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }
}

final class CartaImageStampAnnotation: PDFAnnotation {
    let stampImage: CGImage
    init(bounds: CGRect, image: CGImage) {
        stampImage = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }
    required init?(coder: NSCoder) { return nil }
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState(); context.draw(stampImage, in: bounds); context.restoreGState()
    }
}

@MainActor
private struct CartaStampWorkspace: View {
    @ObservedObject var store = CartaStampStore.shared
    @ObservedObject var model: PDFEditorModel
    @State private var newText = ""
    @State private var width = 180.0
    @State private var message = ""
    var body: some View {
        VStack(spacing: 16) {
            Text(L10n.tr("Timbri riutilizzabili")).font(.title2.bold())
            HStack {
                TextField(L10n.tr("Nuovo timbro testuale"), text: $newText)
                Button(L10n.tr("Aggiungi")) { do { try store.addText(newText); newText = "" } catch { message = error.localizedDescription } }
                Button(L10n.tr("Importa immagine…")) {
                    let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
                    if panel.runModal() == .OK, let url = panel.url { do { try store.addImage(url) } catch { message = error.localizedDescription } }
                }
            }
            Slider(value: $width, in: 60...360) { Text(L10n.tr("Larghezza: \(Int(width)) pt")) }
                .accessibilityLabel(L10n.tr("Larghezza timbro")).accessibilityValue(L10n.tr("\(Int(width)) punti"))
            List(store.items) { item in
                HStack {
                    Text(item.title).font(.headline)
                    Spacer()
                    Button(L10n.tr("Inserisci nella pagina")) { model.insertStamp(item, width: width) }.disabled(!model.canEditAnnotations)
                        .accessibilityLabel(L10n.tr("Inserisci timbro \(item.title) nella pagina \(model.currentPageIndex + 1)"))
                }.padding(.vertical, 8)
            }
            CartaPanelAccessibilityStatus(message: message.isEmpty ? L10n.tr("Il timbro viene inserito al centro. Usa Annotazioni da tastiera per posizionarlo con campi numerici.") : message, label: L10n.tr("Timbri")).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 700, minHeight: 500)
            .accessibilityIdentifier("panel.stamps")
    }
}

@MainActor
extension PDFEditorModel {
    func showDuplicateWorkspace() {
        do {
            guard canPrint else { throw PDFWorkspaceError.printingNotAllowed }
            let snapshot = try unprotectedWorkingSnapshot()
            let state = CartaVisualState(left: snapshot)
            CartaPanelController.present(CartaVisualWorkspace(state: state, model: self, revision: contentRevision, duplicates: true), title: L10n.tr("Pagine duplicate"))
        } catch { errorMessage = error.localizedDescription }
    }
    func showVisualComparisonWorkspace() {
        guard canPrint, document.allowsCopying else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let other = PDFDocument(url: url) else { throw PDFWorkspaceError.invalidPDF }
            try PDFWorkspaceDocument.unlockIfNeeded(other, name: url.lastPathComponent)
            guard other.allowsCopying, other.allowsPrinting else { throw PDFWorkspaceError.copyingNotAllowed }
            let wrapper = PDFEditorModel(); wrapper.replaceDocument(other, fileName: url.lastPathComponent)
            let state = CartaVisualState(left: try unprotectedWorkingSnapshot(), right: try wrapper.unprotectedWorkingSnapshot())
            CartaPanelController.present(CartaVisualWorkspace(state: state, model: self, revision: contentRevision, duplicates: false), title: L10n.tr("Confronto visivo"))
        } catch { errorMessage = error.localizedDescription }
    }
    func showStampWorkspace() { CartaPanelController.present(CartaStampWorkspace(model: self), title: L10n.tr("Timbri")) }
    func insertStamp(_ stamp: CartaStamp, width: Double) {
        guard canEditAnnotations, let page = currentPage else { return }
        let crop = page.bounds(for: .cropBox)
        let width = min(CGFloat(width), crop.width - 16)
        if let name = stamp.imageName {
            do {
                let image = try PDFConversionEngine.image(from: CartaStampStore.shared.directory.appendingPathComponent(name))
                let height = min(width * CGFloat(image.height) / CGFloat(image.width), crop.height / 2)
                let annotation = CartaImageStampAnnotation(bounds: CGRect(x: crop.midX - width / 2, y: crop.midY - height / 2, width: width, height: height), image: image)
                annotation.contents = stamp.title
                addBatchAnnotations([(page, annotation)], actionName: L10n.tr("Inserisci timbro"))
            } catch { errorMessage = error.localizedDescription }
        } else {
            let bounds = CGRect(x: crop.midX - width / 2, y: crop.midY - 25, width: width, height: 50)
            let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            annotation.contents = stamp.text
            annotation.font = .boldSystemFont(ofSize: min(24, width / max(4, CGFloat(stamp.text.count)) * 1.5))
            annotation.fontColor = .systemRed; annotation.color = .white; annotation.alignment = .center
            let border = PDFBorder(); border.lineWidth = 2; annotation.border = border
            addBatchAnnotations([(page, annotation)], actionName: L10n.tr("Inserisci timbro"))
        }
    }
}
