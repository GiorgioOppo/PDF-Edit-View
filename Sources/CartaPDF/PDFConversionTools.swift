import AppKit
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Local conversion routines operate on detached document snapshots, never on the live PDFView document.
enum PDFConversionEngine {
    struct RasterPage {
        let image: CGImage
        let pageSize: CGSize
    }

    struct OCRLine {
        let text: String
        /// Vision coordinates: normalized, with the origin in the lower-left corner.
        let normalizedBounds: CGRect
    }

    struct OCRResult {
        let data: Data
        let recognizedPages: Int
        let skippedTextPages: Int
        let pagesWithoutRecognition: Int
    }

    typealias Progress = @Sendable (Double, String) -> Void

    static let a4Size = CGSize(width: 595.276, height: 841.89)
    static let maximumPixels = 24_000_000.0

    static func renderPage(_ page: PDFPage, dpi: Double = 200) throws -> RasterPage {
        try Task.checkCancellation()
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { throw PDFConversionError.invalidPage }
        let rotated = ((page.rotation % 360) + 360) % 180 != 0
        let pageSize = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let requestedScale = min(max(dpi.isFinite ? dpi : 200, 36), 600) / 72
        // Bound allocation for unusually large engineering drawings or malicious page dimensions.
        let pixelScale = sqrt(maximumPixels / Double(pageSize.width * pageSize.height))
        let sideScale = 16_000 / Double(max(pageSize.width, pageSize.height))
        let scale = min(requestedScale, pixelScale, sideScale)
        guard scale.isFinite, scale > 0 else { throw PDFConversionError.invalidPage }
        let width = max(1, Int(ceil(Double(pageSize.width) * scale)))
        let height = max(1, Int(ceil(Double(pageSize.height) * scale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PDFConversionError.cannotRender
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / pageSize.width, y: CGFloat(height) / pageSize.height)
        page.displaysAnnotations = true
        // PDFPage handles page rotation and crop-box offsets, including annotation appearances.
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { throw PDFConversionError.cannotRender }
        return RasterPage(image: image, pageSize: pageSize)
    }

    static func pngData(for image: CGImage, dpi: Double = 200) throws -> Data {
        try encodedImageData(image, type: UTType.png, quality: nil, dpi: dpi)
    }

    private static func encodedImageData(_ image: CGImage, type: UTType, quality: Double?, dpi: Double? = nil) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw PDFConversionError.cannotRender
        }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0), 1) }
        if let dpi, dpi.isFinite, dpi > 0 {
            options[kCGImagePropertyDPIWidth] = dpi
            options[kCGImagePropertyDPIHeight] = dpi
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PDFConversionError.cannotRender }
        return data as Data
    }

    static func image(from url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw PDFConversionError.invalidImage(url.lastPathComponent)
        }
        // ImageIO applies EXIF orientation and downsamples before decoding very large photos.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 6000,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PDFConversionError.invalidImage(url.lastPathComponent)
        }
        return image
    }

    static func makeImagePDFData(images: [CGImage], pageSize: CGSize = a4Size) throws -> Data {
        guard !images.isEmpty, pageSize.width > 0, pageSize.height > 0 else { throw PDFConversionError.invalidPage }
        return try makePDF { context in
            for image in images {
                try Task.checkCancellation()
                let landscape = image.width > image.height
                let size = landscape && pageSize.height > pageSize.width
                    ? CGSize(width: pageSize.height, height: pageSize.width) : pageSize
                let bounds = CGRect(origin: .zero, size: size)
                context.beginPDFPage([kCGPDFContextMediaBox as String: rectData(bounds)] as CFDictionary)
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(bounds)
                let available = bounds.insetBy(dx: 24, dy: 24)
                let scale = min(available.width / CGFloat(image.width), available.height / CGFloat(image.height))
                let imageSize = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                let destination = CGRect(x: bounds.midX - imageSize.width / 2, y: bounds.midY - imageSize.height / 2,
                                         width: imageSize.width, height: imageSize.height)
                context.draw(image, in: destination)
                context.endPDFPage()
            }
        }
    }

    static func makeImagePDFData(urls: [URL], progress: Progress = { _, _ in }) throws -> Data {
        guard !urls.isEmpty else { throw PDFConversionError.invalidPage }
        let result = PDFDocument()
        // One decoded image at a time keeps photo imports bounded in memory.
        for (index, url) in urls.enumerated() {
            try autoreleasepool {
                try Task.checkCancellation()
                let image = try image(from: url)
                let data = try makeImagePDFData(images: [image])
                guard let imported = PDFDocument(data: data), let page = imported.page(at: 0)?.copy() as? PDFPage else {
                    throw PDFConversionError.cannotRender
                }
                result.insert(page, at: result.pageCount)
            }
            progress(Double(index + 1) / Double(urls.count), "Importazione immagine \(index + 1) di \(urls.count)…")
        }
        result.documentAttributes = [PDFDocumentAttribute.creatorAttribute: "CartaPDF"]
        guard let data = result.dataRepresentation() else { throw PDFConversionError.cannotRender }
        return data
    }

    static func extractedText(from document: PDFDocument) -> String {
        (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }.joined(separator: "\n\n")
    }

    static func rtfData(from document: PDFDocument) throws -> Data {
        let result = NSMutableAttributedString(string: "")
        for index in 0..<document.pageCount {
            let heading = "Pagina \(index + 1)\n"
            result.append(NSAttributedString(string: heading, attributes: [.font: NSFont.boldSystemFont(ofSize: 14)]))
            result.append(NSAttributedString(string: (document.page(at: index)?.string ?? "") + "\n\n",
                                             attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        }
        return try result.data(from: NSRange(location: 0, length: result.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    static func rasterPDFData(snapshot: Data, dpi: Double, jpegQuality: Double? = nil,
                              progress: Progress = { _, _ in }) throws -> Data {
        let document = try loadSnapshot(snapshot)
        return try makePDF { context in
            for index in 0..<document.pageCount {
                try autoreleasepool {
                    try Task.checkCancellation()
                    guard let page = document.page(at: index) else { throw PDFConversionError.invalidPage }
                    let raster = try renderPage(page, dpi: dpi)
                    let bounds = CGRect(origin: .zero, size: raster.pageSize)
                    context.beginPDFPage([kCGPDFContextMediaBox as String: rectData(bounds)] as CFDictionary)
                    let image: CGImage
                    if let jpegQuality {
                        let jpeg = try encodedImageData(raster.image, type: .jpeg, quality: jpegQuality)
                        // Decoding a JPEG via a data provider lets Quartz retain its DCT representation in the PDF.
                        guard let provider = CGDataProvider(data: jpeg as CFData),
                              let compressed = CGImage(jpegDataProviderSource: provider, decode: nil,
                                                       shouldInterpolate: true, intent: .defaultIntent) else {
                            throw PDFConversionError.cannotRender
                        }
                        image = compressed
                    } else { image = raster.image }
                    context.draw(image, in: bounds)
                    context.endPDFPage()
                }
                progress(Double(index + 1) / Double(document.pageCount), "Conversione pagina \(index + 1) di \(document.pageCount)…")
            }
        }
    }

    static func searchablePageData(image: CGImage, pageSize: CGSize, lines: [OCRLine]) throws -> Data {
        guard pageSize.width > 0, pageSize.height > 0 else { throw PDFConversionError.invalidPage }
        return try makePDF { context in
            let bounds = CGRect(origin: .zero, size: pageSize)
            context.beginPDFPage([kCGPDFContextMediaBox as String: rectData(bounds)] as CFDictionary)
            context.draw(image, in: bounds)
            for line in lines where !line.text.isEmpty {
                let normalized = line.normalizedBounds.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                guard !normalized.isNull, normalized.width > 0, normalized.height > 0 else { continue }
                let target = CGRect(x: normalized.minX * pageSize.width, y: normalized.minY * pageSize.height,
                                    width: normalized.width * pageSize.width, height: normalized.height * pageSize.height)
                let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
                let attributed = NSAttributedString(string: line.text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font
                ])
                let ctLine = CTLineCreateWithAttributedString(attributed)
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil))
                guard width > 0, ascent + descent > 0 else { continue }
                context.saveGState()
                context.translateBy(x: target.minX, y: target.minY)
                context.scaleBy(x: target.width / width, y: target.height / (ascent + descent))
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: 0, y: descent)
                context.setTextDrawingMode(.invisible)
                CTLineDraw(ctLine, context)
                context.restoreGState()
            }
            context.endPDFPage()
        }
    }

    static func ocrPDFData(snapshot: Data, progress: Progress = { _, _ in }) throws -> OCRResult {
        let source = try loadSnapshot(snapshot)
        let result = PDFDocument()
        var recognizedPages = 0
        var skippedPages = 0
        var emptyPages = 0
        for index in 0..<source.pageCount {
            try autoreleasepool {
                try Task.checkCancellation()
                guard let page = source.page(at: index) else { throw PDFConversionError.invalidPage }
                if !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard let copy = page.copy() as? PDFPage else { throw PDFConversionError.invalidPage }
                    result.insert(copy, at: result.pageCount)
                    skippedPages += 1
                    return
                }
                let raster = try renderPage(page, dpi: 220)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                request.preferBackgroundProcessing = true
                let supported = try request.supportedRecognitionLanguages()
                let preferred = ["it-IT", "en-US"].filter { supported.contains($0) }
                if !preferred.isEmpty { request.recognitionLanguages = preferred }
                let handler = VNImageRequestHandler(cgImage: raster.image, options: [:])
                try handler.perform([request])
                try Task.checkCancellation()
                let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
                    guard let candidate = observation.topCandidates(1).first,
                          !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return OCRLine(text: candidate.string, normalizedBounds: observation.boundingBox)
                }
                if lines.isEmpty {
                    // Preserve the original page and annotations when Vision found nothing useful.
                    guard let copy = page.copy() as? PDFPage else { throw PDFConversionError.invalidPage }
                    result.insert(copy, at: result.pageCount)
                    emptyPages += 1
                } else {
                    let data = try searchablePageData(image: raster.image, pageSize: raster.pageSize, lines: lines)
                    guard let recognized = PDFDocument(data: data), let copy = recognized.page(at: 0)?.copy() as? PDFPage else {
                        throw PDFConversionError.cannotRender
                    }
                    result.insert(copy, at: result.pageCount)
                    recognizedPages += 1
                }
            }
            progress(Double(index + 1) / Double(source.pageCount), "OCR pagina \(index + 1) di \(source.pageCount)…")
        }
        result.documentAttributes = source.documentAttributes
        guard let data = result.dataRepresentation() else { throw PDFConversionError.cannotRender }
        return OCRResult(data: data, recognizedPages: recognizedPages,
                         skippedTextPages: skippedPages, pagesWithoutRecognition: emptyPages)
    }

    static func loadSnapshot(_ data: Data) throws -> PDFDocument {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { throw PDFConversionError.invalidPage }
        guard !document.isLocked else { throw PDFWorkspaceError.lockedPDF }
        return document
    }

    private static func makePDF(_ draw: (CGContext) throws -> Void) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: a4Size)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box,
                                      [kCGPDFContextCreator as String: "CartaPDF"] as CFDictionary) else {
            throw PDFConversionError.cannotRender
        }
        do { try draw(context) } catch { context.closePDF(); throw error }
        context.closePDF()
        return data as Data
    }

    private static func rectData(_ rect: CGRect) -> CFData {
        var value = rect
        return Data(bytes: &value, count: MemoryLayout<CGRect>.size) as CFData
    }
}

enum PDFConversionError: LocalizedError {
    case invalidPage, cannotRender, invalidImage(String), noText, copyingNotAllowed, printingNotAllowed, outputIsOriginal

    var errorDescription: String? {
        switch self {
        case .invalidPage: return "Una pagina non ha dimensioni valide o il documento non contiene pagine."
        case .cannotRender: return "Non è stato possibile convertire la pagina o generare il file."
        case .invalidImage(let name): return "Non è stato possibile leggere l’immagine “\(name)”."
        case .noText: return "Il PDF non contiene testo estraibile. Prova prima OCR su una copia."
        case .copyingNotAllowed: return "Questo PDF non consente di copiare o esportare il contenuto."
        case .printingNotAllowed: return "Questo PDF non consente la stampa necessaria alla conversione delle pagine."
        case .outputIsOriginal: return "Scegli un file diverso dall’originale per salvare la copia convertita."
        }
    }
}

private enum PDFConversionProduct {
    case document(Data, String)
    case saved(URL, String)
    case pageImages(directory: URL, names: [String])

    func cleanUp() {
        if case .pageImages(let directory, _) = self { try? FileManager.default.removeItem(at: directory) }
    }
}

extension PDFEditorModel {
    func createPDFFromImages() {
        guard canStartConversion() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Crea PDF"
        panel.message = "Una pagina A4 per ogni immagine, con orientamento e proporzioni conservati."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        performConversion(message: "Creazione PDF dalle immagini…", snapshot: Data(), operation: { _, progress in
            .document(try PDFConversionEngine.makeImagePDFData(urls: urls, progress: progress), "PDF creato dalle immagini.")
        }, completion: { [weak self] product in
            guard case .document(let data, _) = product, let pdf = PDFDocument(data: data) else { return }
            self?.openGeneratedDocument(pdf, name: "Immagini.pdf")
        })
    }

    func exportText() {
        exportExtractedText(asRTF: false)
    }

    func exportRTF() {
        exportExtractedText(asRTF: true)
    }

    private func exportExtractedText(asRTF: Bool) {
        guard canStartConversion() else { return }
        do {
            let snapshot = try conversionSnapshot(requirePrinting: false)
            let type: UTType = asRTF ? .rtf : .plainText
            guard let output = conversionSaveURL(type: type, suffix: "", message: "Il testo segue l’ordine di estrazione del PDF; l’impaginazione originale non viene ricostruita.") else { return }
            performConversion(message: "Estrazione testo…", snapshot: snapshot, operation: { data, _ in
                let pdf = try PDFConversionEngine.loadSnapshot(data)
                let text = PDFConversionEngine.extractedText(from: pdf)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PDFConversionError.noText }
                let result = asRTF ? try PDFConversionEngine.rtfData(from: pdf) : Data(text.utf8)
                try Task.checkCancellation()
                try CartaFileIO.atomicWrite(result, to: output)
                return .saved(output, "Testo esportato in \(output.lastPathComponent).")
            })
        } catch { errorMessage = error.localizedDescription }
    }

    func exportPageImages() {
        guard canStartConversion() else { return }
        do {
            let snapshot = try conversionSnapshot(requirePrinting: true)
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Esporta PNG"
            panel.message = "Esporta tutte le pagine a 200 dpi. Le pagine molto grandi vengono limitate a 24 milioni di pixel."
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            let names = (0..<pageCount).map { "\(conversionBaseName)-pagina-\(String(format: "%03d", $0 + 1)).png" }
            let existing = Set(names.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) })
            guard existing.isEmpty || confirmImageReplacement(existing.count) else { return }
            performConversion(message: "Esportazione pagine PNG…", snapshot: snapshot, operation: { data, progress in
                let pdf = try PDFConversionEngine.loadSnapshot(data)
                let staging = FileManager.default.temporaryDirectory.appendingPathComponent("CartaPDF-PNG-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                var success = false
                defer { if !success { try? FileManager.default.removeItem(at: staging) } }
                for index in 0..<pdf.pageCount {
                    try autoreleasepool {
                        try Task.checkCancellation()
                        guard let page = pdf.page(at: index) else { throw PDFConversionError.invalidPage }
                        let raster = try PDFConversionEngine.renderPage(page, dpi: 200)
                        let actualDPI = Double(raster.image.width) / Double(raster.pageSize.width) * 72
                        let imageData = try PDFConversionEngine.pngData(for: raster.image, dpi: actualDPI)
                        try CartaFileIO.atomicWrite(imageData, to: staging.appendingPathComponent(names[index]), replaceExisting: false)
                    }
                    progress(Double(index + 1) / Double(pdf.pageCount), "Esportazione pagina \(index + 1) di \(pdf.pageCount)…")
                }
                success = true
                return .pageImages(directory: staging, names: names)
            }, completion: { [weak self] product in
                guard let self, case .pageImages(let staging, let names) = product else { return }
                // Recheck conflicts because files may have appeared while the background conversion ran.
                let newConflicts = names.filter { !existing.contains($0) && FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
                guard newConflicts.isEmpty || self.confirmImageReplacement(newConflicts.count) else {
                    self.statusMessage = "Esportazione annullata; nessuna immagine sostituita."
                    return
                }
                let identifier = self.processingIdentifier
                let writer = Task.detached(priority: .userInitiated) {
                    for name in names {
                        try Task.checkCancellation()
                        try autoreleasepool {
                            let data = try Data(contentsOf: staging.appendingPathComponent(name))
                            try CartaFileIO.atomicWrite(data, to: folder.appendingPathComponent(name), replaceExisting: existing.contains(name) || newConflicts.contains(name))
                        }
                    }
                }
                do {
                    try await withTaskCancellationHandler(operation: { try await writer.value }, onCancel: { writer.cancel() })
                    guard self.processingIdentifier == identifier else { return }
                    self.statusMessage = "\(names.count) pagine PNG esportate in \(folder.lastPathComponent)."
                } catch {
                    guard self.processingIdentifier == identifier else { return }
                    if error is CancellationError { self.statusMessage = "Esportazione annullata; alcune immagini potrebbero essere già state salvate." }
                    else { self.errorMessage = "Esportazione interrotta: alcune immagini potrebbero essere già state salvate. \(error.localizedDescription)" }
                }
            })
        } catch { errorMessage = error.localizedDescription }
    }

    func runOCR() {
        guard canStartConversion() else { return }
        do {
            let snapshot = try conversionSnapshot(requirePrinting: true)
            let hasScannedPage = (0..<pageCount).contains { (document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard hasScannedPage else { statusMessage = "Tutte le pagine contengono già testo selezionabile. Nessuna pagina da riconoscere."; return }
            let alert = NSAlert()
            alert.messageText = "Crea una copia PDF ricercabile"
            alert.informativeText = "Vision riconosce il testo localmente, senza inviare il documento. Le sole pagine senza testo vengono convertite in immagini a 220 dpi con testo invisibile ricercabile; le loro annotazioni e i moduli vengono appiattiti. Le altre pagine vengono conservate. Il risultato OCR può contenere errori. La nuova copia non conserva password o firme digitali; l’originale rimane invariato."
            alert.addButton(withTitle: "Crea copia OCR")
            alert.addButton(withTitle: "Annulla")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let name = conversionBaseName + "-OCR.pdf"
            performConversion(message: "Riconoscimento testo sul dispositivo…", snapshot: snapshot, operation: { data, progress in
                let result = try PDFConversionEngine.ocrPDFData(snapshot: data, progress: progress)
                let message = "OCR: \(result.recognizedPages) pagine riconosciute, \(result.skippedTextPages) già con testo, \(result.pagesWithoutRecognition) senza testo rilevato."
                return .document(result.data, message)
            }, completion: { [weak self] product in
                guard let self, case .document(let data, let message) = product, let pdf = PDFDocument(data: data) else { return }
                self.openGeneratedDocument(pdf, name: name)
                self.statusMessage = message
            })
        } catch { errorMessage = error.localizedDescription }
    }

    func flattenCopy() {
        makeRasterCopy(compressed: false)
    }

    func compressCopy() {
        makeRasterCopy(compressed: true)
    }

    private func makeRasterCopy(compressed: Bool) {
        guard canStartConversion() else { return }
        do {
            let snapshot = try conversionSnapshot(requirePrinting: true)
            let alert = NSAlert()
            alert.messageText = compressed ? "Crea una copia raster ottimizzata" : "Appiattisci una copia del PDF"
            alert.informativeText = "Ogni pagina diventa un’immagine: si perdono testo selezionabile, vettori, collegamenti, moduli interattivi, livelli, password e firme digitali. L’originale rimane invariato. " + (compressed ? "Il JPEG può degradare testo e dettagli; il file risultante potrebbe essere più grande." : "La copia usa immagini a 200 dpi e conserva l’aspetto visibile delle annotazioni.")
            let quality = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
            quality.addItems(withTitles: ["Compatta · 100 dpi · JPEG 65%", "Bilanciata · 150 dpi · JPEG 75%", "Dettagliata · 200 dpi · JPEG 85%"])
            quality.selectItem(at: 1)
            if compressed { alert.accessoryView = quality }
            alert.addButton(withTitle: "Crea copia")
            alert.addButton(withTitle: "Annulla")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let selected = min(max(quality.indexOfSelectedItem, 0), 2)
            let dpi = compressed ? [100.0, 150.0, 200.0][selected] : 200
            let jpegQuality: Double? = compressed ? [0.65, 0.75, 0.85][selected] : nil
            guard let output = conversionSaveURL(type: .pdf, suffix: compressed ? "-ottimizzato" : "-appiattito", message: "Salva la copia raster in un file diverso dall’originale.") else { return }
            performConversion(message: "Creazione copia raster…", snapshot: snapshot, operation: { data, progress in
                let result = try PDFConversionEngine.rasterPDFData(snapshot: data, dpi: dpi, jpegQuality: jpegQuality, progress: progress)
                try Task.checkCancellation()
                guard let verified = PDFDocument(data: result), verified.pageCount == PDFDocument(data: data)?.pageCount else {
                    throw PDFConversionError.cannotRender
                }
                try CartaFileIO.atomicWrite(result, to: output)
                let originalSize = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
                let resultSize = ByteCountFormatter.string(fromByteCount: Int64(result.count), countStyle: .file)
                let comparison = result.count < data.count ? "più piccola" : "di dimensioni uguali o maggiori"
                return .saved(output, "Copia salvata: \(resultSize), \(comparison) rispetto alla copia sorgente di \(originalSize).")
            })
        } catch { errorMessage = error.localizedDescription }
    }

    func cancelProcessing() {
        guard isProcessing else { return }
        processingIdentifier = nil
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
        processingProgress = 0
        processingMessage = nil
        statusMessage = "Operazione annullata."
    }

    func openGeneratedDocument(_ pdf: PDFDocument, name: String) {
        let generated = PDFWorkspaceDocument()
        generated.model.replaceDocument(pdf, fileName: name)
        generated.displayName = name
        NSDocumentController.shared.addDocument(generated)
        generated.updateChangeCount(.changeDone)
        generated.makeWindowControllers()
        generated.showWindows()
    }

    private var conversionBaseName: String {
        let base = (fileName as NSString).deletingPathExtension
        let sanitized = base.components(separatedBy: CharacterSet(charactersIn: "/:\0")).joined(separator: "_")
        return sanitized.isEmpty ? "Documento" : sanitized
    }

    private func canStartConversion() -> Bool {
        guard !isProcessing else { statusMessage = "Attendi la fine dell’operazione corrente o annullala."; return false }
        return true
    }

    private func conversionSnapshot(requirePrinting: Bool) throws -> Data {
        guard !document.isLocked else { throw PDFWorkspaceError.lockedPDF }
        guard document.allowsCopying else { throw PDFConversionError.copyingNotAllowed }
        if requirePrinting && !document.allowsPrinting { throw PDFConversionError.printingNotAllowed }
        let data = try serializedData()
        if let reopened = PDFDocument(data: data), !reopened.isLocked { return data }
        // PDFKit keeps encryption when serializing an unlocked document. Copying permitted pages
        // into a fresh document provides an unlocked worker snapshot without retaining passwords.
        let snapshot = PDFDocument()
        for index in 0..<pageCount {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { throw PDFConversionError.invalidPage }
            snapshot.insert(page, at: snapshot.pageCount)
        }
        snapshot.documentAttributes = document.documentAttributes
        guard let unprotected = snapshot.dataRepresentation() else { throw PDFConversionError.cannotRender }
        return unprotected
    }

    private func conversionSaveURL(type: UTType, suffix: String, message: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.message = message
        panel.nameFieldStringValue = conversionBaseName + suffix + "." + (type.preferredFilenameExtension ?? "pdf")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if let original = documentOwner?.fileURL,
           original.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() {
            errorMessage = PDFConversionError.outputIsOriginal.localizedDescription
            return nil
        }
        return url
    }

    private func confirmImageReplacement(_ count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Sostituire \(count) immagini esistenti?"
        alert.informativeText = "La cartella contiene file PNG con gli stessi nomi delle pagine da esportare."
        alert.addButton(withTitle: "Sostituisci")
        alert.addButton(withTitle: "Annulla")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func performConversion(message: String, snapshot: Data,
                                   operation: @escaping @Sendable (Data, @escaping PDFConversionEngine.Progress) throws -> PDFConversionProduct,
                                   completion: (@MainActor (PDFConversionProduct) async -> Void)? = nil) {
        let identifier = UUID()
        let limit = CartaPreferences.shared.concurrentJobs
        processingIdentifier = identifier
        isProcessing = true
        processingProgress = 0
        processingMessage = message
        errorMessage = nil
        let progress: PDFConversionEngine.Progress = { [weak self] fraction, message in
            Task { @MainActor [weak self] in
                guard let self, self.processingIdentifier == identifier else { return }
                self.processingProgress = min(max(fraction, 0), 1)
                self.processingMessage = message
            }
        }
        processingTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                try await CartaJobLimiter.shared.withPermit(limit: limit) { try operation(snapshot, progress) }
            }
            do {
                let product = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                defer { product.cleanUp() }
                try Task.checkCancellation()
                guard let self, self.processingIdentifier == identifier else { return }
                if case .saved(_, let message) = product { self.statusMessage = message }
                if case .document(_, let message) = product { self.statusMessage = message }
                await completion?(product)
                self.endConversion(identifier: identifier)
            } catch {
                guard let self, self.processingIdentifier == identifier else { return }
                if error is CancellationError { self.statusMessage = "Operazione annullata." }
                else { self.errorMessage = error.localizedDescription }
                self.endConversion(identifier: identifier)
            }
        }
    }

    private func endConversion(identifier: UUID) {
        guard processingIdentifier == identifier else { return }
        processingIdentifier = nil
        processingTask = nil
        isProcessing = false
        processingProgress = 0
        processingMessage = nil
    }
}
