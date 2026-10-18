import AppKit
import AVFoundation
import Combine
import ImageCaptureCore
import ImageIO
import PDFKit
import Quartz
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import Vision
import WebKit

private final class ScanWeakReference<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// Keeps status text discoverable; announces completed changes without speaking every progress tick.
@MainActor
struct CartaPanelAccessibilityStatus: View {
    let message: String
    var label = "Stato"
    var announce = true
    var announceOnAppear = false
    var body: some View {
        Text(message).textSelection(.enabled).accessibilityLabel(label).accessibilityValue(message)
            .onChange(of: message) { _, value in announceValue(value) }
            .onAppear { if announceOnAppear { announceValue(message) } }
    }
    private func announceValue(_ value: String) {
        guard announce, !value.isEmpty, let application = NSApp else { return }
        NSAccessibility.post(element: application, notification: .announcementRequested,
                             userInfo: [.announcement: "\(label): \(value)", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

@MainActor
final class ScanPanelWindow: NSWindowController, NSWindowDelegate {
    static var retained: [ScanPanelWindow] = []
    var onClose: (() -> Void)?
    convenience init<V: View>(title: String, view: V, size: CGSize = CGSize(width: 1000, height: 760), onClose: (() -> Void)? = nil) {
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = title; window.setContentSize(size); window.minSize = CGSize(width: 760, height: 580)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false; window.center()
        self.init(window: window); self.onClose = onClose; window.delegate = self
        Self.retained.append(self)
    }
    func windowWillClose(_ notification: Notification) { onClose?(); Self.retained.removeAll { $0 === self } }
}

@MainActor
final class ScanWorkspaceController: ObservableObject {
    @Published var options = ScanOptions()
    @Published var progress: Double = 0
    @Published var message = "Le copie elaborate non modificano l’originale e non conservano firme o password."
    @Published var reports: [ScanPageReport] = []
    @Published var busy = false
    @Published var preview: NSImage?
    let languages: [String]
    let snapshot: Data
    private var cancellation = ScanCancellation()
    private var task: Task<Void, Never>?
    private var identifier = UUID()
    init(snapshot: Data, prioritizedPage: Int = 0) {
        self.snapshot = snapshot
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        languages = (try? request.supportedRecognitionLanguages()) ?? ["it-IT", "en-US"]
        options.languages = options.languages.filter { languages.contains($0) }
        options.prioritizedPage = prioritizedPage
    }
    func updatePreview() {
        let snapshot = self.snapshot, options = self.options
        Task { [weak self] in
            let image = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let pdf = PDFDocument(data: snapshot), let page = pdf.page(at: options.prioritizedPage ?? 0), let raster = try? PDFConversionEngine.renderPage(page, dpi: 80) else { return nil }
                return try? AdvancedScanEngine.processedImage(raster.image, angle: options.manualAngle, cleanup: options.cleanup)
            }.value
            if let image { self?.preview = NSImage(cgImage: image, size: .zero) }
        }
    }
    func run(completion: @escaping (PDFDocument) -> Void) {
        guard !busy else { return }
        cancellation = ScanCancellation(); let token = cancellation, snapshot = self.snapshot, options = self.options
        let limit = CartaPreferences.shared.concurrentJobs
        identifier = UUID(); let id = identifier
        let receiver = ScanWeakReference(self)
        busy = true; progress = 0; reports = []; message = "Preparazione del motore locale…"
        task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try await CartaJobLimiter.shared.withPermit(limit: limit) {
                    try AdvancedScanEngine.process(snapshot: snapshot, options: options, cancellation: token) { fraction, message, reports in
                        Task { @MainActor in
                            guard let self = receiver.value, self.identifier == id else { return }
                            self.progress = fraction; self.message = message; self.reports = reports
                        }
                    }
                }
            }
            do {
                let output = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel(); token.cancel() })
                guard let self, self.identifier == id, !Task.isCancelled else { return }
                guard let pdf = PDFDocument(data: output.data), pdf.pageCount > 0 else { throw PDFConversionError.cannotRender }
                self.reports = output.reports; self.progress = 1; self.busy = false; self.message = "Copia verificata. Controlla il rapporto e il testo riconosciuto."; completion(pdf)
            } catch {
                guard let self, self.identifier == id else { return }
                self.busy = false; self.message = error is CancellationError ? "Operazione annullata." : error.localizedDescription
            }
        }
    }
    func cancel() { identifier = UUID(); cancellation.cancel(); task?.cancel(); task = nil; busy = false; message = "Richiesta Vision annullata." }
}

@MainActor
struct ScanWorkspaceView: View {
    @ObservedObject var controller: ScanWorkspaceController
    var completion: (PDFDocument) -> Void
    var body: some View {
        HSplitView {
            ScrollView {
                Form {
                    Text("Scansioni e OCR locale").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Toggle("Riconosci il testo", isOn: $controller.options.recognize)
                    Toggle("Correggi orientamento 0°/90°/180°/270°", isOn: $controller.options.automaticOrientation).disabled(!controller.options.recognize)
                    Toggle("Raddrizza automaticamente le righe", isOn: $controller.options.deskew)
                    Toggle("Pulisci rumore e aumenta contrasto", isOn: $controller.options.cleanup)
                    Toggle("Riprova a 300 dpi con affidabilità bassa", isOn: $controller.options.retryLowConfidence)
                    Toggle("Ordine di lettura per colonne", isOn: $controller.options.columnOrder)
                    HStack { Text("Correzione manuale"); Slider(value: $controller.options.manualAngle, in: -12...12)
                            .accessibilityLabel("Correzione manuale dell’inclinazione")
                            .accessibilityValue("\(controller.options.manualAngle, specifier: "%.1f") gradi")
                            .accessibilityHint("Da meno 12 a più 12 gradi; usa i tasti freccia per regolare.")
                        Text("\(controller.options.manualAngle, specifier: "%.1f")°").accessibilityHidden(true) }
                    HStack { Text("DPI"); Slider(value: $controller.options.dpi, in: 100...300, step: 10)
                            .accessibilityLabel("Risoluzione OCR")
                            .accessibilityValue("\(Int(controller.options.dpi)) punti per pollice")
                            .accessibilityHint("Da 100 a 300 punti per pollice, incrementi di 10.")
                        Text("\(Int(controller.options.dpi))").accessibilityHidden(true) }
                    DisclosureGroup("Lingue disponibili sul Mac") {
                        ForEach(controller.languages, id: \.self) { language in
                            Toggle(Locale.current.localizedString(forIdentifier: language) ?? language, isOn: Binding(get: { controller.options.languages.contains(language) }, set: { enabled in
                                if enabled { controller.options.languages.append(language) } else { controller.options.languages.removeAll { $0 == language } }
                            })).accessibilityHint("Include o esclude \(language) dal riconoscimento locale.")
                        }
                    }
                    Text("Le pagine con poco testo, ad esempio una sola intestazione, vengono comunque riconosciute. Le modifiche di orientamento e pulizia producono pagine raster. Il raddrizzamento mantiene le dimensioni della pagina e può tagliare i bordi. Con controllo automatico dell’orientamento l’OCR può richiedere quattro passaggi.").font(.caption).foregroundStyle(.secondary)
                }.padding(20).disabled(controller.busy)
                HStack {
                    Button("Aggiorna anteprima") { controller.updatePreview() }
                    Button("Crea copia elaborata") { controller.run(completion: completion) }.buttonStyle(.borderedProminent).disabled(controller.busy)
                    if controller.busy { Button("Annulla") { controller.cancel() }.keyboardShortcut(.cancelAction).accessibilityLabel("Annulla elaborazione OCR") }
                }.padding()
            }.frame(minWidth: 370, idealWidth: 420)
            VStack(alignment: .leading) {
                if let image = controller.preview { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 320).background(.white).accessibilityLabel("Anteprima visiva della pagina corrente con le correzioni selezionate") }
                ProgressView(value: controller.progress).accessibilityLabel("Avanzamento elaborazione OCR").accessibilityValue("\(Int(controller.progress * 100)) percento")
                CartaPanelAccessibilityStatus(message: controller.message, label: "Stato OCR", announce: !controller.busy).font(.callout)
                Table(controller.reports) {
                    TableColumn("Pagina") { Text("\($0.page)") }.width(55)
                    TableColumn("Esito", value: \.state)
                    TableColumn("Affidabilità") { Text("\(Int($0.confidence * 100))%") }.width(80)
                    TableColumn("Righe") { Text("\($0.lines)") }.width(45)
                    TableColumn("Angolo") { Text("\($0.angle, specifier: "%.1f")°") }.width(60)
                }.accessibilityLabel("Rapporto OCR per pagina: esito, affidabilità, righe e angolo")
            }.padding(20)
        }.onAppear { controller.updatePreview() }.accessibilityIdentifier("panel.scan.ocr")
    }
}

@MainActor
final class ScanExportController: ObservableObject {
    enum Format: String, CaseIterable, Identifiable {
        case png = "Pagine PNG", tiff = "TIFF multipagina", epub = "EPUB testo", text = "TXT con paragrafi", rtf = "RTF con paragrafi", docx = "DOCX con paragrafi", jpeg = "PDF raster JPEG", csv = "CSV tabella"
        var id: String { rawValue }
        var ext: String { switch self { case .png: return "png"; case .tiff: return "tiff"; case .epub: return "epub"; case .text: return "txt"; case .rtf: return "rtf"; case .docx: return "docx"; case .jpeg: return "pdf"; case .csv: return "csv" } }
    }
    @Published var format: Format = .tiff
    @Published var dpi = 200.0
    @Published var quality = 0.75
    @Published var profile = "sRGB"
    @Published var prefix: String
    @Published var digits = 3
    @Published var margin = 24.0
    @Published var preview: NSImage?
    @Published var message = "Le esportazioni testuali ricostruiscono i paragrafi, senza riprodurre l’impaginazione originale."
    @Published var busy = false
    @Published var progress = 0.0
    @Published var conflicts: [String] = []
    @Published var csv = ""
    @Published var page = 1
    @Published var region = "0,0,1,1"
    @Published var cuts = "0.33,0.66"
    @Published var automaticTable = true
    let snapshot: Data
    let canRaster: Bool
    let pageCount: Int
    let originalURL: URL?
    private var task: Task<Void, Never>?
    private var cancellation = ScanCancellation()
    private var identifier = UUID()
    private var previewIdentifier = UUID()
    init(snapshot: Data, name: String, canRaster: Bool, originalURL: URL? = nil) {
        self.snapshot = snapshot; self.canRaster = canRaster
        self.originalURL = originalURL
        prefix = (name as NSString).deletingPathExtension
        pageCount = PDFDocument(data: snapshot)?.pageCount ?? 0
    }
    func cancel() { identifier = UUID(); cancellation.cancel(); task?.cancel(); busy = false; message = "Esportazione annullata." }
    func jpegPreview() {
        let snapshot = self.snapshot, dpi = self.dpi, quality = self.quality, profile = self.profile
        previewIdentifier = UUID(); let id = previewIdentifier
        Task { [weak self] in
            do {
                let result = try await Task.detached { () -> (CGImage, String) in
                    let pdf = try PDFConversionEngine.loadSnapshot(snapshot)
                    guard let page = pdf.page(at: 0) else { throw PDFConversionError.invalidPage }
                    let raster = try PDFConversionEngine.renderPage(page, dpi: dpi)
                    let space = CGColorSpace(name: profile == "Display P3" ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
                    let converted = try AdvancedScanEngine.processedImage(raster.image, angle: 0, cleanup: false, colorSpace: space)
                    let data = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw PDFConversionError.cannotRender }
                    CGImageDestinationAddImage(destination, converted, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                    guard CGImageDestinationFinalize(destination), let source = CGImageSourceCreateWithData(data, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw PDFConversionError.cannotRender }
                    let actual = Double(raster.image.width) / Double(raster.pageSize.width) * 72
                    return (image, "Anteprima JPEG pagina 1 · \(Int(actual.rounded())) dpi effettivi · \(profile) · \(ByteCountFormatter.string(fromByteCount: Int64(data.length), countStyle: .file))")
                }.value
                guard let self, self.previewIdentifier == id else { return }
                self.preview = NSImage(cgImage: result.0, size: .zero); self.message = result.1
            } catch { if self?.previewIdentifier == id { self?.message = error.localizedDescription } }
        }
    }
    func extractTable() {
        do {
            let values = region.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0,
                  let pdf = PDFDocument(data: snapshot), let source = pdf.page(at: page - 1) else { throw ScanToolError.message("Inserisci x,y,larghezza,altezza normalizzati e una pagina valida.") }
            let columns = automaticTable ? nil : cuts.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            csv = ScanCSV.encode(try ScanCSV.table(page: source, normalizedRegion: CGRect(x: values[0], y: values[1], width: values[2], height: values[3]), columns: columns))
            message = csv.isEmpty ? "Nessun testo nella regione. Esegui prima l’OCR su una scansione." : "Controlla e modifica il CSV prima di esportarlo. Il rilevamento delle colonne è euristico."
        } catch { message = error.localizedDescription }
    }
    func export() {
        guard !busy else { return }
        guard ![Format.png, .tiff, .jpeg].contains(format) || canRaster else { message = PDFConversionError.printingNotAllowed.localizedDescription; return }
        if format == .png { exportPNG(); return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: format.ext) ?? .data]
        panel.nameFieldStringValue = safePrefix + (format == .jpeg ? "-raster" : "") + "." + format.ext
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let originalURL, originalURL.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() {
            message = "Scegli un file diverso dall’originale."; return
        }
        let snapshot = self.snapshot, format = self.format, dpi = self.dpi, quality = self.quality, csv = self.csv, title = self.prefix, profile = self.profile
        let limit = CartaPreferences.shared.concurrentJobs
        let token = ScanCancellation(); cancellation = token; busy = true; progress = 0
        identifier = UUID(); let id = identifier
        task = Task { [weak self] in
            do {
                let data: Data
                if format == .docx || format == .rtf {
                    let pdf = try PDFConversionEngine.loadSnapshot(snapshot)
                    let text = (0..<pdf.pageCount).map { ScanExportEngine.normalizedParagraphs(pdf.page(at: $0)?.string ?? "") }.joined(separator: "\u{0C}\n")
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).isEmpty else { throw PDFConversionError.noText }
                    let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: Self.paragraphStyle()])
                    data = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: format == .docx ? NSAttributedString.DocumentType.officeOpenXML : .rtf])
                } else {
                    let worker = Task.detached(priority: .userInitiated) { () async throws -> Data in
                      try await CartaJobLimiter.shared.withPermit(limit: limit) {
                        try token.check()
                        let pdf = try PDFConversionEngine.loadSnapshot(snapshot)
                        switch format {
                        case .tiff: return try ScanExportEngine.tiff(snapshot: snapshot, dpi: dpi, profile: profile, cancellation: token)
                        case .epub: return try ScanExportEngine.epub(pages: (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }, title: title)
                        case .jpeg: return try ScanExportEngine.jpegPDF(snapshot: snapshot, dpi: dpi, quality: quality, profile: profile, cancellation: token)
                        case .text:
                            let text = (0..<pdf.pageCount).map { ScanExportEngine.normalizedParagraphs(pdf.page(at: $0)?.string ?? "") }.joined(separator: "\n\n")
                            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PDFConversionError.noText }
                            return Data(text.utf8)
                        case .csv: guard !csv.isEmpty else { throw ScanToolError.message("Estrai e controlla prima la tabella.") }; _ = try ScanCSV.parse(csv); return Data(csv.utf8)
                        default: throw PDFConversionError.cannotRender
                        }
                      }
                    }
                    data = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel(); token.cancel() })
                }
                try token.check()
                guard let self, self.identifier == id else { return }
                if format == .jpeg {
                    guard PDFDocument(data: data)?.pageCount == self.pageCount else { throw PDFConversionError.cannotRender }
                    let percent = (Double(data.count) / Double(max(1, snapshot.count)) - 1) * 100
                    self.message = "\(ByteCountFormatter.string(fromByteCount: Int64(snapshot.count), countStyle: .file)) → \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)) · \(String(format: "%+.1f%%", percent))"
                    if data.count > snapshot.count {
                        let alert = NSAlert(); alert.messageText = "La copia è più grande dell’originale"
                        alert.informativeText = self.message; alert.addButton(withTitle: "Conserva copia"); alert.addButton(withTitle: "Scarta")
                        guard alert.runModal() == .alertFirstButtonReturn else { self.busy = false; self.message = "Copia scartata; nessun file scritto."; return }
                    }
                }
                let writer = Task.detached { try token.check(); try Self.checkSpace(url: url, bytes: data.count); try CartaFileIO.atomicWrite(data, to: url) }
                try await withTaskCancellationHandler(operation: { try await writer.value }, onCancel: { writer.cancel(); token.cancel() })
                guard self.identifier == id else { return }
                self.busy = false; self.progress = 1; self.message += "\nSalvato \(url.lastPathComponent)."
            } catch { if self?.identifier == id { self?.busy = false; self?.message = error is CancellationError ? "Operazione annullata." : error.localizedDescription } }
        }
    }
    private var safePrefix: String { let value = prefix.components(separatedBy: CharacterSet(charactersIn: "/:\0")).joined(separator: "_"); return value.isEmpty ? "Documento" : value }
    private func exportPNG() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let names = (1...max(1, pageCount)).map { "\(safePrefix)-\(String(format: "%0*d", digits, $0)).png" }
        conflicts = names.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        if !conflicts.isEmpty {
            let alert = NSAlert(); alert.messageText = "Sostituire \(conflicts.count) file PNG?"
            let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 200)); field.string = conflicts.joined(separator: "\n"); field.isEditable = false
            field.setAccessibilityLabel("File PNG esistenti che verranno sostituiti")
            let scroll = NSScrollView(frame: field.frame); scroll.documentView = field; scroll.hasVerticalScroller = true; alert.accessoryView = scroll
            alert.addButton(withTitle: "Sostituisci"); alert.addButton(withTitle: "Annulla")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let snapshot = self.snapshot, dpi = self.dpi, profile = self.profile, token = ScanCancellation()
        let approvedConflicts = Set(conflicts), limit = CartaPreferences.shared.concurrentJobs
        identifier = UUID(); let id = identifier, receiver = ScanWeakReference(self)
        cancellation = token; busy = true
        task = Task { [weak self] in
            let worker = Task.detached { () async throws -> [Int] in
              try await CartaJobLimiter.shared.withPermit(limit: limit) {
                let pdf = try PDFConversionEngine.loadSnapshot(snapshot); var resolutions: [Int] = []
                for index in 0..<pdf.pageCount {
                    try autoreleasepool {
                        try token.check(); guard let page = pdf.page(at: index) else { throw PDFConversionError.invalidPage }
                        let raster = try PDFConversionEngine.renderPage(page, dpi: dpi)
                        let actual = Double(raster.image.width) / Double(raster.pageSize.width) * 72
                        let image = try AdvancedScanEngine.processedImage(raster.image, angle: 0, cleanup: false,
                            colorSpace: CGColorSpace(name: profile == "Display P3" ? CGColorSpace.displayP3 : CGColorSpace.sRGB))
                        let data = try PDFConversionEngine.pngData(for: image, dpi: actual)
                        let target = folder.appendingPathComponent(names[index]); try Self.checkSpace(url: target, bytes: data.count)
                        if FileManager.default.fileExists(atPath: target.path), !approvedConflicts.contains(names[index]) {
                            throw ScanToolError.message("È apparso un nuovo file in conflitto: \(names[index]). Nessuna sostituzione non confermata.")
                        }
                        try token.check(); try CartaFileIO.atomicWrite(data, to: target, replaceExisting: approvedConflicts.contains(names[index])); resolutions.append(Int(actual.rounded()))
                    }
                    Task { @MainActor in if receiver.value?.identifier == id { receiver.value?.progress = Double(index + 1) / Double(pdf.pageCount) } }
                }
                return resolutions
              }
            }
            do {
                let dpi = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel(); token.cancel() })
                if self?.identifier == id { self?.busy = false; self?.message = "PNG salvati · DPI per pagina: " + dpi.map(String.init).joined(separator: ", ") }
            } catch { if self?.identifier == id { self?.busy = false; self?.message = "Esportazione interrotta; i PNG già scritti restano nella cartella. \(error.localizedDescription)" } }
        }
    }
    private static func paragraphStyle() -> NSParagraphStyle { let style = NSMutableParagraphStyle(); style.paragraphSpacing = 10; return style }
    nonisolated static func checkSpace(url: URL, bytes: Int) throws {
        if let available = try? url.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           available < Int64(bytes) + 10_000_000 { throw ScanToolError.message("Spazio disponibile insufficiente per completare la scrittura atomica.") }
    }
}

@MainActor
struct ScanExportWorkspaceView: View {
    @ObservedObject var controller: ScanExportController
    @StateObject private var html = ScanHTMLRenderer()
    var generated: (PDFDocument, String) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Esportazione e creazione locale").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Picker("Formato", selection: $controller.format) { ForEach(ScanExportController.Format.allCases) { Text($0.rawValue).tag($0) } }
                HStack { TextField("Prefisso file", text: $controller.prefix).accessibilityLabel("Prefisso dei file esportati"); Stepper("Cifre: \(controller.digits)", value: $controller.digits, in: 1...8).accessibilityLabel("Cifre della numerazione file").accessibilityValue("\(controller.digits) cifre") }
                HStack { Slider(value: $controller.dpi, in: 72...300, step: 10).accessibilityLabel("Risoluzione esportazione immagini").accessibilityValue("\(Int(controller.dpi)) punti per pollice"); Text("\(Int(controller.dpi)) dpi").accessibilityHidden(true); Picker("Profilo", selection: $controller.profile) { Text("sRGB").tag("sRGB"); Text("Display P3").tag("Display P3") }.frame(width: 200).accessibilityLabel("Profilo colore esportazione") }
                if controller.format == .jpeg {
                    HStack { Slider(value: $controller.quality, in: 0.3...1).accessibilityLabel("Qualità JPEG").accessibilityValue("\(Int(controller.quality * 100)) percento"); Text("JPEG \(Int(controller.quality * 100))%").accessibilityHidden(true); Button("Anteprima JPEG") { controller.jpegPreview() } }
                    Text("La copia JPEG perde testo selezionabile, vettori, moduli, collegamenti, password e firme. Una copia più grande può essere scartata prima della scrittura.").font(.caption).foregroundStyle(.secondary)
                    if let image = controller.preview { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 320).accessibilityLabel("Anteprima visiva JPEG della prima pagina") }
                }
                if controller.format == .csv {
                    Stepper("Pagina \(controller.page)", value: $controller.page, in: 1...max(1, controller.pageCount)).accessibilityLabel("Pagina della tabella da esportare").accessibilityValue("\(controller.page) di \(controller.pageCount)")
                    TextField("Area x,y,larghezza,altezza (0–1, origine in basso a sinistra)", text: $controller.region).accessibilityLabel("Area della tabella").accessibilityHint("Quattro frazioni da zero a uno separate da virgole: x, y, larghezza e altezza; origine in basso a sinistra. \(controller.message)")
                    Toggle("Individua automaticamente le colonne", isOn: $controller.automaticTable)
                    if !controller.automaticTable { TextField("Separazioni colonne, frazioni da 0 a 1", text: $controller.cuts).accessibilityLabel("Separazioni manuali delle colonne").accessibilityHint("Frazioni da zero a uno separate da virgole.") }
                    Button("Estrai tabella") { controller.extractTable() }
                    TextEditor(text: $controller.csv).font(.system(.body, design: .monospaced)).frame(height: 180).border(.secondary.opacity(0.3)).accessibilityLabel("Anteprima CSV modificabile della tabella").accessibilityHint("Controlla e correggi le celle prima di esportare.")
                }
                HStack {
                    Button("Esporta") { controller.export() }.buttonStyle(.borderedProminent).disabled(controller.busy).keyboardShortcut("e", modifiers: .command).accessibilityHint("Esporta nel formato selezionato e chiede la destinazione.")
                    if controller.busy { Button("Annulla") { controller.cancel() }.keyboardShortcut(.cancelAction).accessibilityLabel("Annulla esportazione") }
                    ProgressView(value: controller.progress).frame(width: 200).accessibilityLabel("Avanzamento esportazione").accessibilityValue("\(Int(controller.progress * 100)) percento")
                }
                CartaPanelAccessibilityStatus(message: controller.message, label: "Stato esportazione", announce: !controller.busy)
                Divider()
                HStack {
                    Text("Immagini → PDF A4").font(.headline).accessibilityAddTraits(.isHeader)
                    Slider(value: $controller.margin, in: 0...100, step: 1).frame(width: 180).accessibilityLabel("Margine immagini nel PDF A4").accessibilityValue("\(Int(controller.margin)) punti")
                    Text("Margine \(Int(controller.margin)) pt").accessibilityHidden(true)
                    Button("Scegli immagini") {
                        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
                        guard panel.runModal() == .OK else { return }
                        do { let data = try ScanExportEngine.imagePDF(urls: panel.urls, margin: controller.margin); if let pdf = PDFDocument(data: data) { generated(pdf, "Immagini.pdf") } }
                        catch { controller.message = error.localizedDescription }
                    }
                }
                Divider()
                HStack {
                    Text("HTML locale → PDF").font(.headline).accessibilityAddTraits(.isHeader)
                    Button("Apri HTML") { let panel = NSOpenPanel(); panel.allowedContentTypes = [.html]; if panel.runModal() == .OK, let url = panel.url { html.load(url) } }
                    Button("Crea PDF A4") { Task { do { generated(try await html.pdf(), "HTML.pdf") } catch { controller.message = error.localizedDescription } } }.disabled(!html.ready)
                }
                CartaPanelAccessibilityStatus(message: html.message, label: "Stato HTML").font(.caption)
                ScanHTMLPreview(renderer: html).frame(height: 300).border(.secondary.opacity(0.3))
            }.padding(24)
        }.accessibilityIdentifier("panel.scan.export")
    }
}

struct ScanHTMLPreview: NSViewRepresentable {
    @ObservedObject var renderer: ScanHTMLRenderer
    func makeNSView(context: Context) -> WKWebView {
        renderer.webView.setAccessibilityLabel("Anteprima HTML locale")
        renderer.webView.setAccessibilityHelp("Contenuto del file selezionato, con script e risorse remote bloccati.")
        return renderer.webView
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

@MainActor
struct LibraryWorkspaceView: View {
    @ObservedObject var library: LocalPDFLibrary
    @State private var query = ""
    @State private var selection: UUID?
    @State private var tags = ""
    @State private var category = ""
    @State private var categoryFilter = ""
    @State private var tagFilter = ""
    @State private var pattern = "(?i)fattura\\s*(?:n[.°]?\\s*)?([A-Za-z0-9-]+)"
    @State private var template = "Fattura-$1"
    @State private var proposed = ""
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Biblioteca PDF locale").font(.title2.bold()).accessibilityAddTraits(.isHeader); Spacer()
                Button("Aggiungi PDF") { let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = true; if panel.runModal() == .OK { library.importFiles(panel.urls) } }
                Button("Reindicizza") { library.importFiles(library.entries.map { library.resolve($0) }) }.disabled(library.busy)
            }
            TextField("Cerca nel testo di tutti i PDF indicizzati", text: $query)
                .accessibilityLabel("Ricerca nel testo della biblioteca").accessibilityHint("I risultati si aggiornano dopo la digitazione. Comando F sposta qui il focus.").focused($searchFocused)
                .task(id: query) { try? await Task.sleep(nanoseconds: 250_000_000); guard !Task.isCancelled else { return }; await library.search(query) }
            HStack {
                Picker("Categoria", selection: $categoryFilter) { Text("Tutte").tag(""); ForEach(Array(Set(library.entries.map(\.category).filter { !$0.isEmpty })).sorted(), id: \.self) { Text($0).tag($0) } }
                TextField("Filtra per etichetta", text: $tagFilter).accessibilityLabel("Filtro etichetta della biblioteca")
            }
            HSplitView {
                List(selection: $selection) {
                    ForEach(library.entries.filter { (categoryFilter.isEmpty || $0.category == categoryFilter) && (tagFilter.isEmpty || $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(tagFilter) })) }) { entry in
                        VStack(alignment: .leading) { Text(entry.title); Text(([entry.category] + entry.tags).filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }.tag(entry.id).accessibilityElement(children: .combine).accessibilityLabel("\(entry.title), categoria \(entry.category.isEmpty ? "nessuna" : entry.category), etichette \(entry.tags.isEmpty ? "nessuna" : entry.tags.joined(separator: ", "))")
                    }
                }.frame(minWidth: 260).accessibilityLabel("Documenti della biblioteca")
                VStack(alignment: .leading, spacing: 12) {
                    if let selected = library.entries.first(where: { $0.id == selection }) {
                        Text(selected.path).font(.caption).textSelection(.enabled).accessibilityLabel("Percorso documento selezionato").accessibilityValue(selected.path)
                        TextField("Etichette separate da virgole", text: $tags).accessibilityLabel("Etichette di \(selected.title)").accessibilityHint("Separa le etichette con virgole e premi Salva etichette."); TextField("Categoria", text: $category).accessibilityLabel("Categoria di \(selected.title)")
                        HStack {
                            Button("Salva etichette") { library.update(id: selected.id, tags: tags, category: category) }
                            Button("Apri") { NSDocumentController.shared.openDocument(withContentsOf: library.resolve(selected), display: true) { _, _, error in if let error { library.message = error.localizedDescription } } }
                            Button("Rimuovi collegamento") { library.remove(id: selected.id) }.accessibilityHint("Rimuove dalla biblioteca e conserva il file PDF originale.")
                        }
                        Divider(); Text("Rinomina dal contenuto").font(.headline).accessibilityAddTraits(.isHeader)
                        TextField("Espressione regolare", text: $pattern).accessibilityLabel("Espressione regolare per il nuovo nome").accessibilityHint(library.message); TextField("Modello nome, ad esempio Fattura-$1", text: $template).accessibilityLabel("Modello del nuovo nome").accessibilityHint("Usa dollaro uno per il primo gruppo dell’espressione regolare.")
                        Button("Anteprima nome") {
                            do { proposed = try LibraryEngine.proposedName(text: selected.pageTexts.joined(separator: "\n"), pattern: pattern, template: template) ?? "Nessuna corrispondenza" }
                            catch { library.message = error.localizedDescription }
                        }
                        Text(proposed).textSelection(.enabled).accessibilityLabel("Anteprima nuovo nome").accessibilityValue(proposed)
                        Button("Rinomina file") { do { if proposed.hasSuffix(".pdf") { try library.rename(id: selected.id, filename: proposed) } } catch { library.message = error.localizedDescription } }.disabled(!proposed.hasSuffix(".pdf"))
                    }
                    List(library.hits) { hit in
                        Button {
                            guard let entry = library.entries.first(where: { $0.id == hit.entryID }) else { return }
                            NSDocumentController.shared.openDocument(withContentsOf: library.resolve(entry), display: true) { document, _, error in
                                if let document = document as? PDFWorkspaceDocument { document.model.goToPage(hit.page - 1) }
                                if let error { library.message = error.localizedDescription }
                            }
                        } label: { VStack(alignment: .leading) { Text("\(hit.title) · pagina \(hit.page)").bold(); Text(hit.excerpt).font(.caption).lineLimit(3) } }.buttonStyle(.plain).accessibilityLabel("\(hit.title), pagina \(hit.page): \(hit.excerpt)").accessibilityHint("Apre il PDF alla pagina del risultato.")
                    }.accessibilityLabel("Risultati della ricerca, \(library.hits.count) corrispondenze")
                }.padding()
            }
            CartaPanelAccessibilityStatus(message: library.message, label: "Stato biblioteca", announce: !library.busy).font(.caption)
        }.padding(20).onChange(of: selection) { _, value in
            if let entry = library.entries.first(where: { $0.id == value }) { tags = entry.tags.joined(separator: ", "); category = entry.category; proposed = "" }
        }.accessibilityIdentifier("panel.library").background {
            Button("Cerca nella biblioteca") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).hidden()
        }
    }
}

@MainActor
struct LibraryWatchFolderView: View {
    @ObservedObject var watcher: LibraryFolderWatcher
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Cartella monitorata locale").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text("Elabora PDF aggiunti o modificati nella cartella scelta. L’originale viene conservato; i conflitti di nome producono una nuova versione. Il monitoraggio termina alla chiusura di questa finestra.")
            HStack { Button("Cartella sorgente") { watcher.input = chooseFolder() }.disabled(watcher.active).accessibilityValue(watcher.input?.path ?? "Nessuna cartella"); Text(watcher.input?.path ?? "Nessuna cartella").accessibilityLabel("Percorso sorgente") }
            HStack { Button("Cartella risultati") { watcher.output = chooseFolder() }.disabled(watcher.active).accessibilityValue(watcher.output?.path ?? "Nessuna cartella"); Text(watcher.output?.path ?? "Nessuna cartella").accessibilityLabel("Percorso risultati") }
            Picker("Procedura", selection: $watcher.action) { ForEach(LibraryFolderWatcher.Action.allCases) { Text($0.rawValue).tag($0) } }.disabled(watcher.active)
            HStack { Button("Avvia monitoraggio") { watcher.start() }.disabled(watcher.active); Button("Ferma") { watcher.stop() }.disabled(!watcher.active).keyboardShortcut(.cancelAction).accessibilityLabel("Ferma monitoraggio cartella") }
            CartaPanelAccessibilityStatus(message: watcher.active ? "Monitoraggio attivo" : "Monitoraggio fermo", label: "Stato monitoraggio")
            List(Array(watcher.logs.enumerated()), id: \.offset) { Text($0.element).textSelection(.enabled) }.accessibilityLabel("Registro monitoraggio, \(watcher.logs.count) messaggi")
            CartaPanelAccessibilityStatus(message: watcher.logs.last ?? "Nessuna operazione registrata", label: "Ultimo evento monitoraggio").font(.caption)
        }.padding(24).accessibilityIdentifier("panel.library.watch")
    }
    private func chooseFolder() -> URL? { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; return panel.runModal() == .OK ? panel.url : nil }
}

@MainActor
struct LibrarySpeechView: View {
    @ObservedObject var controller: LibrarySpeechController
    @State var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Lettura ad alta voce").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Picker("Voce installata", selection: $controller.voiceIdentifier) { ForEach(controller.voices, id: \.identifier) { Text("\($0.name) · \($0.language)").tag($0.identifier) } }
            HStack { Text("Velocità"); Slider(value: $controller.rate, in: 0.2...0.65).accessibilityLabel("Velocità della sintesi vocale").accessibilityValue("\(Int((controller.rate / AVSpeechUtteranceDefaultSpeechRate) * 100)) percento della velocità predefinita") }
            TextEditor(text: $text).accessibilityLabel("Testo da leggere ad alta voce").accessibilityHint("Puoi modificare il testo prima di premere Leggi.")
            HStack { Button("Leggi") { controller.read(text) }; Button(controller.paused ? "Riprendi" : "Pausa") { controller.togglePause() }.disabled(!controller.speaking); Button("Ferma") { controller.stop() }.disabled(!controller.speaking).keyboardShortcut(.cancelAction).accessibilityLabel("Ferma lettura ad alta voce") }
            CartaPanelAccessibilityStatus(message: controller.message, label: "Stato lettura", announce: !controller.speaking)
        }.padding(24).accessibilityIdentifier("panel.library.speech")
    }
}

@MainActor
final class ScanCSVFormController: ObservableObject {
    let snapshot: Data
    @Published var csv = ""
    @Published var message = "La prima riga contiene i nomi esatti dei campi. Una riga di dati genera una copia del PDF; password e firme originali non vengono conservate."
    @Published var separator = ","
    @Published var preview = ""
    @Published var busy = false
    @Published var progress = 0.0
    private var task: Task<Void, Never>?
    private var identifier = UUID()
    private var cancellation = ScanCancellation()
    init(snapshot: Data) { self.snapshot = snapshot }
    func cancel() { identifier = UUID(); cancellation.cancel(); task?.cancel(); busy = false; message = "Operazione annullata; le copie già salvate sono conservate." }
    func run(folder: URL?) {
        guard !busy else { return }
        let csv = self.csv, delimiter = separator.first ?? ",", snapshot = self.snapshot, limit = CartaPreferences.shared.concurrentJobs
        let token = ScanCancellation(); cancellation = token; identifier = UUID(); let id = identifier, receiver = ScanWeakReference(self)
        busy = true; progress = 0
        task = Task { [weak self] in
            let worker = Task.detached { () async throws -> (Int, [String]) in
                try await CartaJobLimiter.shared.withPermit(limit: limit) {
                    let rows = try ScanCSV.parse(csv, delimiter: delimiter)
                    guard let headers = rows.first, rows.count > 1 else { throw ScanToolError.message("Inserisci intestazioni e almeno una riga CSV.") }
                    let filenames = (1..<rows.count).map { "modulo-\(String(format: "%03d", $0)).pdf" }
                    if let folder, filenames.contains(where: { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }) {
                        throw ScanToolError.message("Esistono già file modulo-NNN.pdf. Scegli una cartella nuova; nessun file viene sovrascritto.")
                    }
                    for (index, row) in rows.dropFirst().enumerated() {
                        try token.check()
                        try autoreleasepool {
                            guard let data = try ScanCSV.filledDocuments(snapshot: snapshot, rows: [headers, row]).first,
                                  let pdf = PDFDocument(data: data), pdf.pageCount > 0 else { throw PDFWorkspaceError.cannotSave }
                            if let folder { try CartaFileIO.atomicWrite(data, to: folder.appendingPathComponent(filenames[index]), replaceExisting: false) }
                        }
                        Task { @MainActor in if receiver.value?.identifier == id { receiver.value?.progress = Double(index + 1) / Double(rows.count - 1) } }
                    }
                    return (rows.count - 1, headers)
                }
            }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel(); token.cancel() })
                guard let self, self.identifier == id else { return }
                self.busy = false; self.preview = "\(result.0) copie valide. Campi: \(result.1.joined(separator: ", ")). File: modulo-001.pdf … modulo-\(String(format: "%03d", result.0)).pdf"
                self.message = folder == nil ? "Verifica completata; nessun file scritto." : "Salvate \(result.0) copie compilate e verificate."
            } catch { if self?.identifier == id { self?.busy = false; self?.message = "Operazione interrotta; eventuali copie già salvate restano nella cartella. \(error.localizedDescription)" } }
        }
    }
}

@MainActor
struct ScanCSVFormView: View {
    @ObservedObject var controller: ScanCSVFormController
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Compilazione moduli da CSV").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            CartaPanelAccessibilityStatus(message: controller.message, label: "Stato compilazione CSV", announce: !controller.busy)
            HStack {
                Picker("Separatore", selection: $controller.separator) { Text("Virgola").tag(","); Text("Punto e virgola").tag(";"); Text("Tab").tag("\t") }.disabled(controller.busy)
                Button("Apri CSV") { let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText, .plainText]; if panel.runModal() == .OK, let url = panel.url { do { controller.csv = try String(contentsOf: url, encoding: .utf8) } catch { controller.message = error.localizedDescription } } }.disabled(controller.busy)
            }
            TextEditor(text: $controller.csv).font(.system(.body, design: .monospaced)).disabled(controller.busy).accessibilityLabel("Dati CSV per compilare i moduli").accessibilityHint("Prima riga: nomi esatti dei campi. Una riga per ogni copia. \(controller.message)")
            Text(controller.preview).font(.caption).textSelection(.enabled).accessibilityLabel("Anteprima compilazione CSV").accessibilityValue(controller.preview)
            ProgressView(value: controller.progress).accessibilityLabel("Avanzamento compilazione moduli CSV").accessibilityValue("\(Int(controller.progress * 100)) percento")
            HStack {
                Button("Verifica e anteprima") { controller.run(folder: nil) }.disabled(controller.busy)
                Button("Crea copie compilate") {
                    let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
                    guard panel.runModal() == .OK, let folder = panel.url else { return }
                    controller.run(folder: folder)
                }.buttonStyle(.borderedProminent).disabled(controller.busy)
                if controller.busy { Button("Annulla") { controller.cancel() }.keyboardShortcut(.cancelAction).accessibilityLabel("Annulla compilazione CSV") }
            }
        }.padding(24).accessibilityIdentifier("panel.scan.csv.forms")
    }
}

@MainActor
final class ScanScannerController: NSObject, ObservableObject, ICDeviceBrowserDelegate, IKScannerDeviceViewDelegate {
    @Published var devices: [ICScannerDevice] = []
    @Published var selected = 0
    @Published var message = "Collega uno scanner locale compatibile con Acquisizione Immagine."
    var completion: ((PDFDocument) -> Void)?
    private let browser = ICDeviceBrowser()
    override init() {
        super.init(); browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: 0x00000102)!
        browser.start()
    }
    func stop() { browser.stop(); for device in devices { device.requestCloseSession() } }
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        Task { @MainActor [weak self] in if let scanner = device as? ICScannerDevice { self?.devices.append(scanner); self?.message = "Scanner disponibile: \(scanner.name ?? "Scanner")" } }
    }
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor [weak self] in guard let self else { return }; self.devices.removeAll { $0 === device }; self.selected = min(self.selected, max(0, self.devices.count - 1)) }
    }
    nonisolated func scannerDeviceView(_ scannerDeviceView: IKScannerDeviceView, didScanTo url: URL!, fileData data: Data!, error: Error!) {
        Task { @MainActor [weak self] in self?.receivedScan(url: url, data: data, error: error) }
    }
    private func receivedScan(url: URL?, data: Data?, error: Error?) {
        if let error { message = error.localizedDescription; return }
        do {
            if let url, let pdf = PDFDocument(url: url) { completion?(pdf); message = "PDF acquisito."; return }
            let bytes = try data ?? url.map { try Data(contentsOf: $0) }
            guard let bytes, let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { throw ScanToolError.message("Lo scanner non ha restituito un’immagine leggibile.") }
            var images: [CGImage] = []
            for index in 0..<CGImageSourceGetCount(source) { if let image = CGImageSourceCreateImageAtIndex(source, index, nil) { images.append(image) } }
            let output = try PDFConversionEngine.makeImagePDFData(images: images)
            if let pdf = PDFDocument(data: output) { completion?(pdf); message = "Acquisite \(images.count) pagine." }
        } catch { message = error.localizedDescription }
    }
    nonisolated func scannerDeviceView(_ scannerDeviceView: IKScannerDeviceView, didEncounterError error: Error!) {
        Task { @MainActor [weak self] in self?.message = error?.localizedDescription ?? "Errore dello scanner." }
    }
}

struct ScanNativeScanner: NSViewRepresentable {
    @ObservedObject var controller: ScanScannerController
    func makeNSView(context: Context) -> IKScannerDeviceView {
        let view = IKScannerDeviceView(frame: .zero)
        view.setAccessibilityLabel("Controlli nativi di acquisizione scanner")
        view.setAccessibilityHelp("Controlli forniti da macOS per lo scanner selezionato.")
        view.delegate = controller; view.mode = .advanced; view.hasDisplayModeSimple = true; view.hasDisplayModeAdvanced = true
        view.transferMode = .memoryBased; view.displaysPostProcessApplicationControl = false
        return view
    }
    func updateNSView(_ nsView: IKScannerDeviceView, context: Context) {
        if controller.devices.indices.contains(controller.selected), nsView.scannerDevice !== controller.devices[controller.selected] { nsView.scannerDevice = controller.devices[controller.selected] }
    }
}

@MainActor
struct ScanScannerView: View {
    @ObservedObject var controller: ScanScannerController
    var body: some View {
        VStack(alignment: .leading) {
            Text("Acquisizione da scanner locale").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Picker("Scanner", selection: $controller.selected) { ForEach(controller.devices.indices, id: \.self) { Text(controller.devices[$0].name ?? "Scanner").tag($0) } }
            if controller.devices.isEmpty { ContentUnavailableView("Nessuno scanner locale", systemImage: "scanner", description: Text("Collega un dispositivo USB e installa il supporto di macOS del produttore. Non vengono cercati dispositivi di rete.")) }
            else { ScanNativeScanner(controller: controller) }
            CartaPanelAccessibilityStatus(message: controller.message, label: "Stato scanner").font(.caption)
        }.padding(20).accessibilityIdentifier("panel.scan.scanner")
    }
}

@MainActor
final class ScanCaptureController: ObservableObject {
    @Published var windows: [SCWindow] = []
    @Published var displays: [SCDisplay] = []
    @Published var selectedWindow: UInt32 = 0
    @Published var selectedDisplay: UInt32 = 0
    @Published var windowMode = true
    @Published var message = "Autorizza la cattura nelle impostazioni di macOS; nessuna registrazione continua."
    @Published var busy = false
    func refresh() {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { message = "Permesso negato. Abilita CartaPDF in Privacy e sicurezza → Registrazione schermo, quindi riprova."; return }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                displays = content.displays
                windows = content.windows.filter { $0.frame.width > 10 && $0.frame.height > 10 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier }
                selectedWindow = windows.first?.windowID ?? 0; selectedDisplay = displays.first?.displayID ?? 0
                message = "Scegli una finestra o uno schermo. La cattura genera una nuova pagina PDF."
            } catch { message = error.localizedDescription }
        }
    }
    func capture(completion: @escaping (PDFDocument) -> Void) {
        let filter: SCContentFilter
        if windowMode, let window = windows.first(where: { $0.windowID == selectedWindow }) { filter = SCContentFilter(desktopIndependentWindow: window) }
        else if !windowMode, let display = displays.first(where: { $0.displayID == selectedDisplay }) { filter = SCContentFilter(display: display, excludingWindows: []) }
        else { message = "Seleziona prima una sorgente disponibile."; return }
        busy = true
        Task {
            do {
                let configuration = SCStreamConfiguration(); configuration.showsCursor = false
                configuration.width = max(1, Int(filter.contentRect.width * CGFloat(filter.pointPixelScale)))
                configuration.height = max(1, Int(filter.contentRect.height * CGFloat(filter.pointPixelScale)))
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                let data = try PDFConversionEngine.makeImagePDFData(images: [image])
                if let pdf = PDFDocument(data: data) { completion(pdf); message = "Cattura completata e mantenuta sul Mac." }
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
}

@MainActor
struct ScanCaptureView: View {
    @ObservedObject var controller: ScanCaptureController
    var completion: (PDFDocument) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Cattura schermo o finestra").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Button("Autorizza e aggiorna sorgenti") { controller.refresh() }.accessibilityHint("Può mostrare la richiesta macOS di registrazione schermo. Non esegue ancora una cattura.")
            Toggle("Cattura una finestra", isOn: $controller.windowMode)
            if controller.windowMode { Picker("Finestra", selection: $controller.selectedWindow) { ForEach(controller.windows, id: \.windowID) { Text(($0.owningApplication?.applicationName ?? "App") + " · " + ($0.title ?? "Senza titolo")).tag($0.windowID) } } }
            else { Picker("Schermo", selection: $controller.selectedDisplay) { ForEach(controller.displays, id: \.displayID) { Text("Schermo \($0.displayID) · \($0.width)×\($0.height)").tag($0.displayID) } } }
            Button("Cattura e crea PDF") { controller.capture(completion: completion) }.buttonStyle(.borderedProminent).disabled(controller.busy)
            if controller.busy { ProgressView().accessibilityLabel("Cattura in corso") }
            CartaPanelAccessibilityStatus(message: controller.message, label: "Stato cattura", announce: !controller.busy)
            Spacer()
        }.padding(24).accessibilityIdentifier("panel.scan.capture")
    }
}

extension PDFEditorModel {
    func showScanWorkspace() {
        do {
            let controller = ScanWorkspaceController(snapshot: try scanDetachedSnapshot(), prioritizedPage: currentPageIndex)
            let panel = ScanPanelWindow(title: "Scansioni e OCR", view: ScanWorkspaceView(controller: controller) { [weak self] pdf in self?.openGeneratedDocument(pdf, name: "Copia elaborata-OCR.pdf") }, onClose: controller.cancel)
            panel.showWindow(nil)
        } catch { errorMessage = error.localizedDescription }
    }
    func showExportWorkspace() {
        do {
            let controller = ScanExportController(snapshot: try scanDetachedSnapshot(requirePrinting: false), name: fileName, canRaster: canPrint, originalURL: documentOwner?.fileURL)
            ScanPanelWindow(title: "Esportazioni", view: ScanExportWorkspaceView(controller: controller) { [weak self] pdf, name in self?.openGeneratedDocument(pdf, name: name) }, onClose: controller.cancel).showWindow(nil)
        } catch { errorMessage = error.localizedDescription }
    }
    func showLibraryWorkspace() { ScanPanelWindow(title: "Biblioteca locale", view: LibraryWorkspaceView(library: .shared)).showWindow(nil) }
    func showScannerWorkspace() {
        let controller = ScanScannerController(); controller.completion = { [weak self] pdf in self?.openGeneratedDocument(pdf, name: "Scansione.pdf") }
        ScanPanelWindow(title: "Scanner", view: ScanScannerView(controller: controller), onClose: controller.stop).showWindow(nil)
    }
    func showCaptureWorkspace() {
        let controller = ScanCaptureController()
        ScanPanelWindow(title: "Cattura locale", view: ScanCaptureView(controller: controller) { [weak self] pdf in self?.openGeneratedDocument(pdf, name: "Cattura.pdf") }).showWindow(nil)
    }
    func showSpeechWorkspace() {
        guard document.allowsCopying else { errorMessage = PDFConversionError.copyingNotAllowed.localizedDescription; return }
        let controller = LibrarySpeechController()
        let text = selectedText.isEmpty ? PDFConversionEngine.extractedText(from: document) : selectedText
        ScanPanelWindow(title: "Lettura ad alta voce", view: LibrarySpeechView(controller: controller, text: text), onClose: controller.stop).showWindow(nil)
    }
    func showCSVFormWorkspace() {
        guard canFillForms else { errorMessage = PDFWorkspaceError.editingNotAllowed.localizedDescription; return }
        do {
            let controller = ScanCSVFormController(snapshot: try scanDetachedSnapshot(requirePrinting: false))
            ScanPanelWindow(title: "Moduli da CSV", view: ScanCSVFormView(controller: controller), onClose: controller.cancel).showWindow(nil)
        }
        catch { errorMessage = error.localizedDescription }
    }
    func showWatchFolderWorkspace() {
        let watcher = LibraryFolderWatcher()
        ScanPanelWindow(title: "Cartella monitorata", view: LibraryWatchFolderView(watcher: watcher), onClose: watcher.stop).showWindow(nil)
    }
}
