import AppKit
import Combine
import CoreImage
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision
import WebKit

enum ScanToolError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var request: VNRequest?
    func cancel() { lock.lock(); cancelled = true; let active = request; lock.unlock(); active?.cancel() }
    func check() throws { lock.lock(); let stopped = cancelled; lock.unlock(); if stopped || Task.isCancelled { throw CancellationError() } }
    func register(_ value: VNRequest?) throws {
        lock.lock(); request = value; let stopped = cancelled; lock.unlock()
        if stopped { value?.cancel(); throw CancellationError() }
    }
}

struct ScanOptions: Sendable {
    var languages = ["it-IT", "en-US"]
    var automaticOrientation = true
    var deskew = true
    var cleanup = false
    var recognize = true
    var retryLowConfidence = true
    var columnOrder = true
    var dpi: Double = 220
    var manualAngle: Double = 0
    var prioritizedPage: Int?
}

struct ScanPageReport: Identifiable, Sendable {
    var id: Int { page }
    let page: Int
    let state: String
    let confidence: Float
    let lines: Int
    let angle: Double
}

enum AdvancedScanEngine {
    struct Line {
        let text: String
        let bounds: CGRect
        let confidence: Float
    }
    struct Output { let data: Data; let reports: [ScanPageReport]; let processingOrder: [Int] }
    typealias Progress = @Sendable (Double, String, [ScanPageReport]) -> Void

    static func readingOrder(_ lines: [Line], columns: Bool) -> [Line] {
        guard columns, lines.count > 3 else { return lines.sorted { abs($0.bounds.midY - $1.bounds.midY) > 0.015 ? $0.bounds.midY > $1.bounds.midY : $0.bounds.minX < $1.bounds.minX } }
        // A genuine vertical gutter must have no crossing line and text on both sides.
        let narrow = lines.filter { $0.bounds.width < 0.7 }
        let gutters = stride(from: 0.2, through: 0.8, by: 0.02).filter { x in
            narrow.filter { $0.bounds.maxX < x }.count >= 2 && narrow.filter { $0.bounds.minX > x }.count >= 2 &&
            !narrow.contains { $0.bounds.minX < x && $0.bounds.maxX > x }
        }
        guard let split = gutters.min(by: { abs($0 - 0.5) < abs($1 - 0.5) }) else { return readingOrder(lines, columns: false) }
        let spanning = lines.filter { $0.bounds.minX < split && $0.bounds.maxX > split }.sorted { $0.bounds.midY > $1.bounds.midY }
        if !spanning.isEmpty {
            var ordered: [Line] = [], top: CGFloat = 2
            for fullWidth in spanning {
                let band = narrow.filter { $0.bounds.midY < top && $0.bounds.midY > fullWidth.bounds.midY }
                ordered += readingOrder(band, columns: true); ordered.append(fullWidth); top = fullWidth.bounds.midY
            }
            ordered += readingOrder(narrow.filter { $0.bounds.midY < top }, columns: true)
            return ordered
        }
        let left = lines.filter { $0.bounds.midX < split }, right = lines.filter { $0.bounds.midX >= split }
        return readingOrder(left, columns: true) + readingOrder(right, columns: true)
    }

    static func processedImage(_ image: CGImage, angle: Double, cleanup: Bool, colorSpace: CGColorSpace? = nil) throws -> CGImage {
        let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        var result = CIImage(cgImage: image)
        let extent = result.extent
        if abs(angle) > 0.001 {
            let transform = CGAffineTransform(translationX: extent.midX, y: extent.midY)
                .rotated(by: CGFloat(angle * .pi / 180)).translatedBy(x: -extent.midX, y: -extent.midY)
            result = result.transformed(by: transform)
                .composited(over: CIImage(color: .white).cropped(to: extent)).cropped(to: extent)
        }
        if cleanup {
            result = result.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputBrightnessKey: 0.035, kCIInputContrastKey: 1.25])
                .applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.02, "inputSharpness": 0.4])
        }
        guard let output = context.createCGImage(result, from: extent, format: .RGBA8, colorSpace: space) else { throw PDFConversionError.cannotRender }
        return output
    }

    static func recognizedLines(_ image: CGImage, languages: [String], cancellation: ScanCancellation) throws -> [Line] {
        try cancellation.check()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        request.preferBackgroundProcessing = true
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = languages.filter { supported.contains($0) }
        try cancellation.register(request)
        defer { try? cancellation.register(nil) }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        try cancellation.check()
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            return Line(text: candidate.string, bounds: observation.boundingBox, confidence: candidate.confidence)
        }
    }

    static func estimatedSkew(_ image: CGImage, cancellation: ScanCancellation) throws -> Double {
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false
        try cancellation.register(request)
        defer { try? cancellation.register(nil) }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        try cancellation.check()
        let angles = (request.results ?? []).compactMap { observation -> Double? in
            let dx = Double(observation.bottomRight.x - observation.bottomLeft.x) * Double(image.width)
            let dy = Double(observation.bottomRight.y - observation.bottomLeft.y) * Double(image.height)
            guard dx > 30 else { return nil }
            let angle = atan2(dy, dx) * 180 / .pi
            return abs(angle) <= 12 ? angle : nil
        }.sorted()
        let measured = angles.isEmpty ? 0 : -angles[angles.count / 2]
        return abs(measured) > 0.1 ? measured : try projectionSkew(image, cancellation: cancellation)
    }

    private static func projectionSkew(_ image: CGImage, cancellation: ScanCancellation) throws -> Double {
        let scale = min(1, 900 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        var points: [(Double, Double)] = []
        for y in stride(from: 4, to: max(4, height - 4), by: 2) {
            for x in stride(from: 4, to: max(4, width - 4), by: 2) where pixels[y * width + x] < 150 {
                points.append((Double(x - width / 2), Double(y - height / 2)))
            }
        }
        guard points.count > 100 else { return 0 }
        let padding = width / 4 + 4
        func score(_ degrees: Double) -> Double {
            let angle = degrees * .pi / 180, sine = sin(angle), cosine = cos(angle)
            var rows = [Int](repeating: 0, count: height + 2 * padding)
            for (x, y) in points {
                let row = Int((x * sine + y * cosine).rounded()) + height / 2 + padding
                if rows.indices.contains(row) { rows[row] += 1 }
            }
            return rows.reduce(0.0) { $0 + Double($1 * $1) }
        }
        let baseline = score(0)
        var bestScore = baseline, bestAngle = 0.0
        for angle in stride(from: -8.0, through: 8.0, by: 0.5) {
            try cancellation.check()
            let value = score(angle)
            if value > bestScore { bestScore = value; bestAngle = angle }
        }
        return bestScore > baseline * 1.03 ? -bestAngle : 0
    }

    static func textCoverage(_ page: PDFPage) -> Double {
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return 0 }
        var area: CGFloat = 0
        for index in 0..<page.numberOfCharacters {
            let character = page.characterBounds(at: index).intersection(box)
            if !character.isNull { area += max(0, character.width) * max(0, character.height) }
        }
        return min(1, Double(area / (box.width * box.height)))
    }

    static func process(snapshot: Data, options: ScanOptions, cancellation: ScanCancellation = ScanCancellation(),
                        progress: Progress = { _, _, _ in }) throws -> Output {
        let source = try PDFConversionEngine.loadSnapshot(snapshot)
        let result = PDFDocument()
        var completedPages: [Int: PDFPage] = [:]
        var reports: [ScanPageReport] = []
        let indices = Array(0..<source.pageCount)
        let priority = options.prioritizedPage.flatMap { indices.contains($0) ? $0 : nil }
        let order = priority.map { page in [page] + indices.filter { $0 != page } } ?? indices
        progress(0, "Preparazione di Vision: il primo avvio può richiedere la compilazione locale dei modelli…", [])
        for (completed, index) in order.enumerated() {
            do { try autoreleasepool {
                try cancellation.check()
                guard let page = source.page(at: index) else { throw PDFConversionError.invalidPage }
                if options.recognize, textCoverage(page) > 0.025, !options.cleanup, abs(options.manualAngle) < 0.001 {
                    guard let copy = page.copy() as? PDFPage else { throw PDFConversionError.invalidPage }
                    completedPages[index] = copy
                    reports.append(.init(page: index + 1, state: "Testo già presente", confidence: 1, lines: 0, angle: 0))
                    return
                }
                let raster = try PDFConversionEngine.renderPage(page, dpi: options.dpi)
                var image = raster.image
                var orientationAngle = 0.0
                var lines: [Line] = []
                if options.recognize && options.automaticOrientation {
                    var bestScore = -1.0
                    for (orientation, angle) in [(CGImagePropertyOrientation.up, 0.0), (.right, -90), (.down, 180), (.left, 90)] {
                        try cancellation.check()
                        let rotated = CIImage(cgImage: raster.image).oriented(orientation)
                        let ci = CIContext(options: [.useSoftwareRenderer: false])
                        guard let candidate = ci.createCGImage(rotated, from: rotated.extent) else { continue }
                        let candidateLines = try recognizedLines(candidate, languages: options.languages, cancellation: cancellation)
                        let score = candidateLines.reduce(0.0) { $0 + Double($1.confidence) * Double($1.text.count) }
                        if score > bestScore { bestScore = score; image = candidate; lines = candidateLines; orientationAngle = angle }
                    }
                }
                let skew = options.deskew ? try estimatedSkew(image, cancellation: cancellation) : 0
                let correction = skew + options.manualAngle
                if options.cleanup || abs(correction) > 0.05 {
                    image = try processedImage(image, angle: correction, cleanup: options.cleanup)
                    lines = []
                }
                if options.recognize && lines.isEmpty { lines = try recognizedLines(image, languages: options.languages, cancellation: cancellation) }
                var confidence = lines.isEmpty ? 0 : lines.reduce(Float(0)) { $0 + $1.confidence } / Float(lines.count)
                if options.recognize, options.retryLowConfidence, confidence < 0.75, options.dpi < 300 {
                    progress(Double(completed) / Double(source.pageCount), "Pagina \(index + 1): nuovo tentativo a 300 dpi…", reports)
                    let high = try PDFConversionEngine.renderPage(page, dpi: 300)
                    let oriented = CIImage(cgImage: high.image).oriented(orientationAngle == -90 ? .right : orientationAngle == 90 ? .left : orientationAngle == 180 ? .down : .up)
                    let ci = CIContext()
                    if let raw = ci.createCGImage(oriented, from: oriented.extent) {
                        let retryImage = try processedImage(raw, angle: correction, cleanup: options.cleanup)
                        let retryLines = try recognizedLines(retryImage, languages: options.languages, cancellation: cancellation)
                        let retryConfidence = retryLines.isEmpty ? 0 : retryLines.reduce(Float(0)) { $0 + $1.confidence } / Float(retryLines.count)
                        if retryConfidence > confidence { image = retryImage; lines = retryLines; confidence = retryConfidence }
                    }
                }
                lines = readingOrder(lines, columns: options.columnOrder)
                let rotated = abs(orientationAngle) == 90
                let size = rotated ? CGSize(width: raster.pageSize.height, height: raster.pageSize.width) : raster.pageSize
                let data: Data
                if options.recognize, !options.cleanup, abs(correction) < 0.05, orientationAngle == 0 {
                    // Draw the original PDF to a PDF context instead of recompressing the scan image.
                    data = try searchableNativePage(page, size: size, lines: lines)
                } else {
                    data = try PDFConversionEngine.searchablePageData(image: image, pageSize: size,
                        lines: lines.map { .init(text: $0.text, normalizedBounds: $0.bounds) })
                }
                guard let converted = PDFDocument(data: data), let copy = converted.page(at: 0)?.copy() as? PDFPage else { throw PDFConversionError.cannotRender }
                completedPages[index] = copy
                reports.append(.init(page: index + 1, state: options.recognize ? (lines.isEmpty ? "Nessun testo rilevato" : "Riconosciuta") : "Scansione elaborata",
                                     confidence: confidence, lines: lines.count, angle: orientationAngle + correction))
            } } catch {
                try cancellation.check()
                guard let copy = source.page(at: index)?.copy() as? PDFPage else { throw error }
                completedPages[index] = copy
                reports.append(.init(page: index + 1, state: "Originale conservato: \(error.localizedDescription)", confidence: 0, lines: 0, angle: 0))
            }
            let recognizedCount = reports.filter { $0.state == "Riconosciuta" }.count
            let skipped = reports.filter { $0.state == "Testo già presente" }.count
            progress(Double(reports.count) / Double(source.pageCount), "Pagina \(index + 1) · \(reports.count)/\(source.pageCount) completate · \(recognizedCount) riconosciute · \(skipped) già testuali", reports)
        }
        for index in indices {
            guard let page = completedPages[index] else { throw PDFConversionError.invalidPage }
            result.insert(page, at: result.pageCount)
        }
        guard let data = result.dataRepresentation(), PDFDocument(data: data)?.pageCount == source.pageCount else { throw PDFConversionError.cannotRender }
        return Output(data: data, reports: reports.sorted { $0.page < $1.page }, processingOrder: order.map { $0 + 1 })
    }

    private static func searchableNativePage(_ page: PDFPage, size: CGSize, lines: [Line]) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw PDFConversionError.cannotRender }
        context.beginPDFPage(nil)
        page.draw(with: .cropBox, to: context)
        for line in lines {
            if page.rotation == 0 {
                let crop = page.bounds(for: .cropBox)
                let region = CGRect(x: crop.minX + line.bounds.minX * crop.width, y: crop.minY + line.bounds.minY * crop.height,
                                    width: line.bounds.width * crop.width, height: line.bounds.height * crop.height)
                if !(page.selection(for: region)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            }
            let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
            let string = NSAttributedString(string: line.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let ct = CTLineCreateWithAttributedString(string)
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(ct, &ascent, &descent, nil))
            guard width > 0, ascent + descent > 0 else { continue }
            context.saveGState()
            context.translateBy(x: line.bounds.minX * size.width, y: line.bounds.minY * size.height)
            context.scaleBy(x: line.bounds.width * size.width / width, y: line.bounds.height * size.height / (ascent + descent))
            context.textPosition = CGPoint(x: 0, y: descent)
            context.setTextDrawingMode(.invisible)
            CTLineDraw(ct, context)
            context.restoreGState()
        }
        context.endPDFPage(); context.closePDF()
        return data as Data
    }
}

enum ScanExportEngine {
    static func normalizedParagraphs(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var output = ""
        var previous = ""
        for line in lines {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { if !output.hasSuffix("\n\n") { output += "\n\n" }; previous = ""; continue }
            if !output.isEmpty && !output.hasSuffix("\n") {
                if previous.hasSuffix("-"), let first = value.first, first.isLowercase { output.removeLast() }
                else if previous.last.map({ ".!?:;".contains($0) }) == true || value.hasPrefix("•") || value.hasPrefix("- ") { output += "\n" }
                else { output += " " }
            }
            output += value; previous = value
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func tiff(snapshot: Data, dpi: Double = 200, profile: String = "sRGB", cancellation: ScanCancellation = ScanCancellation()) throws -> Data {
        let pdf = try PDFConversionEngine.loadSnapshot(snapshot)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, pdf.pageCount, nil) else { throw PDFConversionError.cannotRender }
        for index in 0..<pdf.pageCount {
            try autoreleasepool {
                try cancellation.check()
                guard let page = pdf.page(at: index) else { throw PDFConversionError.invalidPage }
                let raster = try PDFConversionEngine.renderPage(page, dpi: dpi)
                let actual = Double(raster.image.width) / Double(raster.pageSize.width) * 72
                let image = try AdvancedScanEngine.processedImage(raster.image, angle: 0, cleanup: false,
                    colorSpace: CGColorSpace(name: profile == "Display P3" ? CGColorSpace.displayP3 : CGColorSpace.sRGB))
                CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: actual, kCGImagePropertyDPIHeight: actual,
                    kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]] as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw PDFConversionError.cannotRender }
        return data as Data
    }

    static func jpegPDF(snapshot: Data, dpi: Double, quality: Double, profile: String,
                        cancellation: ScanCancellation = ScanCancellation(), progress: @Sendable (Double) -> Void = { _ in }) throws -> Data {
        let source = try PDFConversionEngine.loadSnapshot(snapshot)
        let data = NSMutableData(); var box = CGRect(origin: .zero, size: PDFConversionEngine.a4Size)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw PDFConversionError.cannotRender }
        do {
            for index in 0..<source.pageCount {
                try autoreleasepool {
                    try cancellation.check()
                    guard let page = source.page(at: index) else { throw PDFConversionError.invalidPage }
                    let raster = try PDFConversionEngine.renderPage(page, dpi: dpi)
                    let image = try AdvancedScanEngine.processedImage(raster.image, angle: 0, cleanup: false,
                        colorSpace: CGColorSpace(name: profile == "Display P3" ? CGColorSpace.displayP3 : CGColorSpace.sRGB))
                    let jpeg = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { throw PDFConversionError.cannotRender }
                    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: min(max(quality, 0), 1)] as CFDictionary)
                    guard CGImageDestinationFinalize(destination), let provider = CGDataProvider(data: jpeg),
                          let compressed = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw PDFConversionError.cannotRender }
                    var rect = CGRect(origin: .zero, size: raster.pageSize)
                    context.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &rect, count: MemoryLayout<CGRect>.size)] as CFDictionary)
                    context.draw(compressed, in: rect); context.endPDFPage()
                }
                progress(Double(index + 1) / Double(source.pageCount))
            }
        } catch { context.closePDF(); throw error }
        context.closePDF()
        guard PDFDocument(data: data as Data)?.pageCount == source.pageCount else { throw PDFConversionError.cannotRender }
        return data as Data
    }

    static func epub(pages: [String], title: String) throws -> Data {
        guard !pages.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PDFConversionError.noText }
        let identifier = "urn:uuid:\(UUID().uuidString)"
        let sections = pages.enumerated().map { index, text in
            "<section id=\"p\(index + 1)\"><h2>Pagina \(index + 1)</h2>" + normalizedParagraphs(text).components(separatedBy: "\n\n").map { "<p>\(xml($0).replacingOccurrences(of: "\n", with: "<br/>"))</p>" }.joined() + "</section>"
        }.joined()
        let content = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"it\"><head><title>\(xml(title))</title></head><body>\(sections)</body></html>"
        let navigation = "<?xml version=\"1.0\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>Indice</title></head><body><nav epub:type=\"toc\"><ol>" + pages.indices.map { "<li><a href=\"content.xhtml#p\($0 + 1)\">Pagina \($0 + 1)</a></li>" }.joined() + "</ol></nav></body></html>"
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
        let package = "<?xml version=\"1.0\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"id\">\(identifier)</dc:identifier><dc:title>\(xml(title))</dc:title><dc:language>it</dc:language><meta property=\"dcterms:modified\">\(formatter.string(from: Date()))</meta></metadata><manifest><item id=\"content\" href=\"content.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"nav\" href=\"nav.xhtml\" properties=\"nav\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"content\"/></spine></package>"
        let container = "<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"EPUB/package.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>"
        return try ScanStoredZIP.make([("mimetype", Data("application/epub+zip".utf8)), ("META-INF/container.xml", Data(container.utf8)), ("EPUB/package.opf", Data(package.utf8)), ("EPUB/content.xhtml", Data(content.utf8)), ("EPUB/nav.xhtml", Data(navigation.utf8))])
    }

    static func xml(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func imagePDF(urls: [URL], margin: CGFloat) throws -> Data {
        guard margin.isFinite, (0...200).contains(margin), !urls.isEmpty else { throw ScanToolError.message("Il margine deve essere compreso tra 0 e 200 punti.") }
        let data = NSMutableData(); var box = CGRect(origin: .zero, size: PDFConversionEngine.a4Size)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw PDFConversionError.cannotRender }
        for url in urls {
            try Task.checkCancellation()
            let image = try PDFConversionEngine.image(from: url)
            let size = image.width > image.height ? CGSize(width: box.height, height: box.width) : box.size
            var rect = CGRect(origin: .zero, size: size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &rect, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
            let available = rect.insetBy(dx: margin, dy: margin)
            let scale = min(available.width / CGFloat(image.width), available.height / CGFloat(image.height))
            let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
            context.draw(image, in: CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height))
            context.endPDFPage()
        }
        context.closePDF(); return data as Data
    }
}

enum ScanStoredZIP {
    static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) } }
        return ~crc
    }
    static func make(_ entries: [(String, Data)]) throws -> Data {
        guard entries.count <= Int(UInt16.max) else { throw ScanToolError.message("Troppi elementi ZIP.") }
        var output = Data(), directory = Data()
        func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        for (name, payload) in entries {
            let filename = Data(name.utf8)
            guard filename.count <= Int(UInt16.max), payload.count < Int(UInt32.max), output.count < Int(UInt32.max) else { throw ScanToolError.message("Il contenuto supera i limiti ZIP32.") }
            let offset = UInt32(output.count), size = UInt32(payload.count), crc = crc32(payload)
            append(UInt32(0x04034b50), to: &output); append(UInt16(20), to: &output); append(UInt16(0x800), to: &output)
            append(UInt16(0), to: &output); append(UInt16(0), to: &output); append(UInt16(0x21), to: &output)
            append(crc, to: &output); append(size, to: &output); append(size, to: &output)
            append(UInt16(filename.count), to: &output); append(UInt16(0), to: &output); output.append(filename); output.append(payload)
            append(UInt32(0x02014b50), to: &directory); append(UInt16(20), to: &directory); append(UInt16(20), to: &directory)
            append(UInt16(0x800), to: &directory); append(UInt16(0), to: &directory); append(UInt16(0), to: &directory); append(UInt16(0x21), to: &directory)
            append(crc, to: &directory); append(size, to: &directory); append(size, to: &directory)
            append(UInt16(filename.count), to: &directory); append(UInt16(0), to: &directory); append(UInt16(0), to: &directory)
            append(UInt16(0), to: &directory); append(UInt16(0), to: &directory); append(UInt32(0), to: &directory); append(offset, to: &directory); directory.append(filename)
        }
        let start = UInt32(output.count); output.append(directory)
        append(UInt32(0x06054b50), to: &output); append(UInt16(0), to: &output); append(UInt16(0), to: &output)
        append(UInt16(entries.count), to: &output); append(UInt16(entries.count), to: &output)
        append(UInt32(directory.count), to: &output); append(start, to: &output); append(UInt16(0), to: &output)
        return output
    }
}

enum ScanCSV {
    static func parse(_ text: String, delimiter: Character = ",") throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], value = "", quoted = false, recordStarted = false
        let characters = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                recordStarted = true
                if quoted, index + 1 < characters.count, characters[index + 1] == "\"" { value.append("\""); index += 1 }
                else if quoted || value.isEmpty { quoted.toggle() }
                else { throw ScanToolError.message("Virgolette CSV non valide.") }
            } else if character == delimiter && !quoted { recordStarted = true; row.append(value); value = "" }
            else if character == "\n" && !quoted {
                if recordStarted { row.append(value); rows.append(row) }
                row = []; value = ""; recordStarted = false
            }
            else { recordStarted = true; value.append(character) }
            index += 1
        }
        guard !quoted else { throw ScanToolError.message("Il CSV contiene un campo tra virgolette non chiuso.") }
        if recordStarted { row.append(value); rows.append(row) }
        return rows
    }

    static func encode(_ rows: [[String]], delimiter: Character = ",") -> String {
        rows.map { row in row.map { value in
            (value.isEmpty && row.count == 1) || value.contains(delimiter) || value.contains("\"") || value.contains("\n") || value.contains("\r")
                ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }.joined(separator: String(delimiter)) }.joined(separator: "\r\n")
    }

    static func table(page: PDFPage, normalizedRegion: CGRect, columns: [Double]?) throws -> [[String]] {
        let crop = page.bounds(for: .cropBox)
        let region = CGRect(x: crop.minX + normalizedRegion.minX * crop.width, y: crop.minY + normalizedRegion.minY * crop.height,
                            width: normalizedRegion.width * crop.width, height: normalizedRegion.height * crop.height).intersection(crop)
        guard !region.isNull, region.width > 0, region.height > 0 else { throw ScanToolError.message("L’area della tabella non è valida.") }
        struct CharacterBox { let bounds: CGRect }
        var characters: [CharacterBox] = []
        for index in 0..<page.numberOfCharacters {
            let box = page.characterBounds(at: index)
            guard box.width > 0, box.height > 0, box.width < box.height * 3,
                  region.contains(CGPoint(x: box.midX, y: box.midY)) else { continue }
            characters.append(.init(bounds: box))
        }
        guard !characters.isEmpty else { return [] }
        var rows: [[CharacterBox]] = []
        for character in characters.sorted(by: { $0.bounds.midY > $1.bounds.midY }) {
            if let last = rows.indices.last, let reference = rows[last].first,
               abs(reference.bounds.midY - character.bounds.midY) < max(2, reference.bounds.height * 0.45) { rows[last].append(character) }
            else { rows.append([character]) }
        }
        var cuts = columns ?? []
        if columns == nil {
            var gaps: [Double] = []
            for row in rows {
                let sorted = row.sorted { $0.bounds.minX < $1.bounds.minX }
                for index in 1..<sorted.count where sorted[index].bounds.minX - sorted[index - 1].bounds.maxX > sorted[index].bounds.height * 1.6 {
                    gaps.append(Double((sorted[index].bounds.minX + sorted[index - 1].bounds.maxX) / 2 - region.minX) / Double(region.width))
                }
            }
            for gap in gaps.sorted() where !cuts.contains(where: { abs($0 - gap) < 0.08 }) { cuts.append(gap) }
        }
        cuts = ([0] + cuts.filter { $0 > 0 && $0 < 1 } + [1]).sorted()
        cuts = cuts.reduce([]) { $0.last == $1 ? $0 : $0 + [$1] }
        return rows.map { row in
            (0..<(cuts.count - 1)).map { column in
                let left = region.minX + CGFloat(cuts[column]) * region.width, right = region.minX + CGFloat(cuts[column + 1]) * region.width
                let bottom = row.map { $0.bounds.minY }.min() ?? region.minY
                let top = row.map { $0.bounds.maxY }.max() ?? region.maxY
                let cell = CGRect(x: left, y: bottom - 0.1, width: right - left, height: top - bottom + 0.2)
                // PDFKit's generated spaces/line breaks do not share characterBounds indices.
                // Geometric selection lets PDFKit map glyphs to text without guessing offsets.
                return (page.selection(for: cell)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    static func filledDocuments(snapshot: Data, rows: [[String]]) throws -> [Data] {
        guard let headers = rows.first, rows.count > 1, Set(headers).count == headers.count, !headers.contains("") else { throw ScanToolError.message("Il CSV deve avere intestazioni univoche e almeno una riga di valori.") }
        return try rows.dropFirst().map { values in
            guard values.count == headers.count else { throw ScanToolError.message("Una riga CSV ha un numero di colonne diverso dalle intestazioni.") }
            let pdf = try PDFConversionEngine.loadSnapshot(snapshot)
            guard pdf.allowsFormFieldEntry else { throw PDFWorkspaceError.editingNotAllowed }
            var found = Set<String>()
            for index in 0..<pdf.pageCount {
                try Task.checkCancellation()
                for field in pdf.page(at: index)?.annotations ?? [] where field.type == "Widget" {
                    guard let name = field.fieldName, let column = headers.firstIndex(of: name) else { continue }
                    guard !field.isReadOnly else { throw ScanToolError.message("Il campo \(name) è in sola lettura.") }
                    guard !field.isPasswordField else { throw ScanToolError.message("Il campo password \(name) non viene compilato tramite CSV.") }
                    let value = values[column]
                    switch field.widgetFieldType {
                    case .text:
                        guard field.maximumLength <= 0 || value.count <= field.maximumLength else {
                            throw ScanToolError.message("Il campo \(name) accetta al massimo \(field.maximumLength) caratteri.")
                        }
                        field.widgetStringValue = value
                    case .choice:
                        let choices = field.choices ?? [], exports = field.values ?? []
                        if let index = choices.firstIndex(of: value) {
                            field.widgetStringValue = exports.indices.contains(index) ? exports[index] : value
                        } else if exports.contains(value) { field.widgetStringValue = value }
                        else { throw ScanToolError.message("Il valore di \(name) non è tra le opzioni consentite.") }
                    case .button:
                        guard field.widgetControlType == .checkBoxControl else { throw ScanToolError.message("Il campo \(name) non è una casella di spunta supportata.") }
                        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                        case "1", "true", "yes", "si", "sì": field.buttonWidgetState = .onState
                        case "0", "false", "no", "": field.buttonWidgetState = .offState
                        default: throw ScanToolError.message("La casella \(name) richiede sì/no, true/false oppure 1/0; un valore vuoto la deseleziona.")
                        }
                    default: throw ScanToolError.message("Tipo di campo non supportato: \(name).")
                    }
                    found.insert(name)
                }
            }
            guard found.count == headers.count else { throw ScanToolError.message("Campi non trovati: \(headers.filter { !found.contains($0) }.joined(separator: ", ")).") }
            guard let data = pdf.dataRepresentation() else { throw PDFWorkspaceError.cannotSave }
            return data
        }
    }
}

@MainActor
final class ScanHTMLRenderer: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var ready = false
    @Published var message = "Scegli un file HTML locale. Script e richieste di rete vengono bloccati."
    let webView: WKWebView
    private var generation = UUID()
    private var currentNavigation: WKNavigation?
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 794, height: 800), configuration: configuration)
        super.init(); webView.navigationDelegate = self
    }
    func load(_ url: URL) {
        ready = false; generation = UUID(); currentNavigation = nil
        webView.stopLoading()
        let id = generation
        do {
            let html = try String(contentsOf: url, encoding: .utf8)
            // WebKit's content blocker regex subset does not support alternation.
            let ruleObjects: [[String: Any]] = ["^https?://", "^wss?://", "^ftp://"].map {
                ["trigger": ["url-filter": $0], "action": ["type": "block"]]
            }
            let rules = String(decoding: try JSONSerialization.data(withJSONObject: ruleObjects), as: UTF8.self)
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "CartaPDF-OfflineHTML", encodedContentRuleList: rules) { [weak self] list, error in
                Task { @MainActor in
                    guard let self, self.generation == id else { return }
                    guard let list else {
                        self.message = error.map { "\($0.localizedDescription) \(($0 as NSError).userInfo)" } ?? "Blocco risorse non disponibile."
                        return
                    }
                    self.webView.configuration.userContentController.removeAllContentRuleLists()
                    self.webView.configuration.userContentController.add(list)
                    let csp = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; script-src 'none'; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'\">"
                    self.currentNavigation = self.webView.loadHTMLString(csp + html, baseURL: nil)
                    self.message = "Caricamento locale… Immagini e font esterni sono esclusi."
                }
            }
        } catch { message = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigation, navigation === currentNavigation else { return }
        ready = true; message = "HTML pronto. Il rendering WebKit viene suddiviso in pagine A4: controlla i salti di pagina di righe e tabelle."
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let navigation, navigation === currentNavigation else { return }
        ready = false; message = error.localizedDescription
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
    }
    func pdf() async throws -> PDFDocument {
        guard ready else { throw ScanToolError.message("Attendi il caricamento HTML.") }
        let id = generation
        ready = false
        defer { if generation == id { ready = true } }
        // This is our fixed DOM query, not document-provided JavaScript. Page scripts stay disabled.
        let metrics = try await webView.evaluateJavaScript("({width:Math.max(document.documentElement.scrollWidth,document.body.scrollWidth),height:Math.max(document.documentElement.scrollHeight,document.body.scrollHeight)})")
        try Task.checkCancellation()
        guard generation == id else { throw CancellationError() }
        guard let values = metrics as? [String: Any], let width = values["width"] as? Double, let height = values["height"] as? Double,
              width.isFinite, height.isFinite, width > 0, height > 0, height / width < 1500 else { throw ScanToolError.message("Dimensioni HTML non valide o documento troppo lungo.") }
        let a4 = PDFConversionEngine.a4Size
        let pageHeight = width * Double(a4.height / a4.width)
        let output = NSMutableData(); var box = CGRect(origin: .zero, size: a4)
        guard let consumer = CGDataConsumer(data: output), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw PDFConversionError.cannotRender }
        do {
            for offset in stride(from: 0.0, to: height, by: pageHeight) {
                try Task.checkCancellation()
                guard generation == id else { throw CancellationError() }
                let configuration = WKPDFConfiguration()
                configuration.rect = CGRect(x: 0, y: offset, width: width, height: pageHeight)
                let data = try await webView.pdf(configuration: configuration)
                try Task.checkCancellation()
                guard generation == id else { throw CancellationError() }
                guard let rendered = PDFDocument(data: data), let page = rendered.page(at: 0) else { throw PDFConversionError.cannotRender }
                context.beginPDFPage(nil); context.saveGState()
                context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
                let bounds = page.bounds(for: .mediaBox)
                context.scaleBy(x: box.width / bounds.width, y: box.height / bounds.height)
                page.draw(with: .mediaBox, to: context)
                context.restoreGState(); context.endPDFPage()
            }
        } catch { context.closePDF(); throw error }
        context.closePDF()
        guard let pdf = PDFDocument(data: output as Data), pdf.pageCount > 0 else { throw PDFConversionError.cannotRender }
        return pdf
    }
}

extension PDFEditorModel {
    func scanDetachedSnapshot(requirePrinting: Bool = true) throws -> Data {
        guard !document.isLocked else { throw PDFWorkspaceError.lockedPDF }
        guard document.allowsCopying else { throw PDFConversionError.copyingNotAllowed }
        if requirePrinting && !document.allowsPrinting { throw PDFConversionError.printingNotAllowed }
        let data = try serializedData()
        if let pdf = PDFDocument(data: data), !pdf.isLocked { return data }
        return try unprotectedWorkingSnapshot()
    }
}
