import AppKit
import PDFKit
import SwiftUI

struct PDFRedactionRegion {
    let pageIndex: Int
    /// Unrotated PDF page coordinates, matching PDFView.convert(_:to:).
    let bounds: CGRect
}

enum PDFRasterSanitizerError: LocalizedError {
    case invalidRegion, invalidPage, oversizedPage, renderingFailed
    var errorDescription: String? {
        switch self {
        case .invalidRegion: return "L’area da oscurare non è valida o non interseca la pagina."
        case .invalidPage: return "Il documento contiene una pagina non valida."
        case .oversizedPage: return "Una pagina è troppo grande per essere rasterizzata in sicurezza a questa risoluzione."
        case .renderingFailed: return "Non è stato possibile generare il PDF rasterizzato."
        }
    }
}

/// Creates a new PDF exclusively from opaque RGB pixels. Source PDF objects,
/// text, annotations, attachments and metadata never enter the output context.
/// The black masks are baked into those pixels before any image is encoded.
@MainActor
enum PDFRasterSanitizer {
    static func sanitizedDocument(_ source: PDFDocument, regions: [PDFRedactionRegion], dpi: CGFloat = 200) throws -> PDFDocument {
        let writer = try RasterWriter(source: source, regions: regions, dpi: dpi)
        for index in 0..<source.pageCount { try writer.appendPage(at: index) }
        return try writer.finish()
    }

    static func sanitizedDocumentAsync(_ source: PDFDocument, regions: [PDFRedactionRegion], dpi: CGFloat = 200,
                                       progress: (Double) -> Void) async throws -> PDFDocument {
        let writer = try RasterWriter(source: source, regions: regions, dpi: dpi)
        for index in 0..<source.pageCount {
            try Task.checkCancellation()
            try autoreleasepool { try writer.appendPage(at: index) }
            progress(Double(index + 1) / Double(source.pageCount))
            await Task.yield()
        }
        try Task.checkCancellation()
        return try writer.finish()
    }

    static func renderedImage(_ page: PDFPage, masks: [CGRect], dpi: CGFloat) throws -> (image: CGImage, size: CGSize) {
        guard dpi.isFinite, dpi >= 36, dpi <= 600 else { throw PDFRasterSanitizerError.oversizedPage }
        let crop = page.bounds(for: .cropBox)
        let transform = page.transform(for: .cropBox)
        let displayBounds = crop.applying(transform).standardized
        guard displayBounds.width.isFinite, displayBounds.height.isFinite,
              displayBounds.width > 0, displayBounds.height > 0 else { throw PDFRasterSanitizerError.invalidPage }
        let pixelWidthValue = ceil(displayBounds.width * dpi / 72)
        let pixelHeightValue = ceil(displayBounds.height * dpi / 72)
        guard pixelWidthValue > 0, pixelHeightValue > 0,
              pixelWidthValue * pixelHeightValue <= 40_000_000 else { throw PDFRasterSanitizerError.oversizedPage }
        let width = Int(pixelWidthValue), height = Int(pixelHeightValue)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw PDFRasterSanitizerError.renderingFailed
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.scaleBy(x: CGFloat(width) / displayBounds.width, y: CGFloat(height) / displayBounds.height)
        context.translateBy(x: -displayBounds.minX, y: -displayBounds.minY)
        // PDFPage.draw applies exactly this page's rotation/crop transform itself.
        page.draw(with: .cropBox, to: context)
        // Apply the same transform to the masks. They replace the original image
        // samples, rather than becoming removable PDF annotations or vector covers.
        context.restoreGState()
        context.setShouldAntialias(false)
        context.setBlendMode(.copy)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for mask in masks {
            let displayed = mask.applying(transform).offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)
            let scaleX = CGFloat(width) / displayBounds.width, scaleY = CGFloat(height) / displayBounds.height
            let left = floor(displayed.minX * scaleX), bottom = floor(displayed.minY * scaleY)
            // Round outwards in device space so no source samples survive along
            // a fractional mask edge, even on cropped or rotated pages.
            let pixels = CGRect(x: left, y: bottom, width: ceil(displayed.maxX * scaleX) - left,
                                height: ceil(displayed.maxY * scaleY) - bottom)
            context.fill(pixels)
        }
        guard let image = context.makeImage() else { throw PDFRasterSanitizerError.renderingFailed }
        return (image, displayBounds.size)
    }

    @MainActor
    private final class RasterWriter {
        let source: PDFDocument
        let regions: [PDFRedactionRegion]
        let dpi: CGFloat
        let data = NSMutableData()
        let context: CGContext
        var finished = false

        init(source: PDFDocument, regions: [PDFRedactionRegion], dpi: CGFloat) throws {
            guard source.pageCount > 0, !source.isLocked, !regions.isEmpty else { throw PDFRasterSanitizerError.invalidRegion }
            var checked: [PDFRedactionRegion] = []
            for region in regions {
                guard region.bounds.origin.x.isFinite, region.bounds.origin.y.isFinite,
                      region.bounds.width.isFinite, region.bounds.height.isFinite,
                      let page = source.page(at: region.pageIndex) else { throw PDFRasterSanitizerError.invalidRegion }
                let clipped = region.bounds.standardized.intersection(page.bounds(for: .cropBox))
                guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { throw PDFRasterSanitizerError.invalidRegion }
                checked.append(PDFRedactionRegion(pageIndex: region.pageIndex, bounds: clipped))
            }
            self.source = source
            self.regions = checked
            self.dpi = dpi
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
                throw PDFRasterSanitizerError.renderingFailed
            }
            self.context = context
        }

        func appendPage(at index: Int) throws {
            guard let page = source.page(at: index) else { throw PDFRasterSanitizerError.invalidPage }
            let raster = try PDFRasterSanitizer.renderedImage(page, masks: regions.filter { $0.pageIndex == index }.map(\.bounds), dpi: dpi)
            var box = CGRect(origin: .zero, size: raster.size)
            let boxData = NSData(bytes: &box, length: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
            context.draw(raster.image, in: box)
            context.endPDFPage()
        }

        func finish() throws -> PDFDocument {
            context.closePDF()
            finished = true
            guard let result = PDFDocument(data: data as Data), result.pageCount == source.pageCount else {
                throw PDFRasterSanitizerError.renderingFailed
            }
            result.documentAttributes = [:]
            return result
        }

        deinit { if !finished { context.closePDF() } }
    }
}

@MainActor
extension PDFEditorModel {
    func addShapeAnnotation(in rectangle: CGRect, on page: PDFPage, ellipse: Bool) {
        guard !isProcessing, canEditAnnotations, page.document === document else { return }
        let bounds = rectangle.standardized.intersection(page.bounds(for: .cropBox))
        guard !bounds.isNull, bounds.width >= 3, bounds.height >= 3 else { return }
        let annotation = PDFAnnotation(bounds: bounds, forType: ellipse ? .circle : .square, withProperties: nil)
        annotation.color = annotationColor
        annotation.interiorColor = .clear
        annotation.modificationDate = Date()
        let border = PDFBorder()
        border.lineWidth = CartaPreferences.shared.strokeWidth
        annotation.border = border
        addMarkup(annotation, on: page, actionName: ellipse ? "Aggiungi ellisse" : "Aggiungi rettangolo")
    }

    func addLinkAnnotation(in rectangle: CGRect, on page: PDFPage) {
        guard !isProcessing, canEditAnnotations, page.document === document else { return }
        let bounds = rectangle.standardized.intersection(page.bounds(for: .cropBox))
        guard !bounds.isNull, bounds.width >= 3, bounds.height >= 3 else { return }
        let alert = NSAlert()
        alert.messageText = "Aggiungi collegamento web"
        alert.informativeText = "Inserisci un indirizzo HTTPS o HTTP completo per l’area selezionata."
        alert.addButton(withTitle: "Aggiungi")
        alert.addButton(withTitle: "Annulla")
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = "https://"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty else {
            errorMessage = "Inserisci un URL valido che inizi con https:// oppure http://."
            return
        }
        addWebLink(url, in: bounds, on: page)
    }

    func addWebLink(_ url: URL, in rectangle: CGRect, on page: PDFPage) {
        guard !isProcessing, canEditAnnotations, page.document === document,
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return }
        let bounds = rectangle.standardized.intersection(page.bounds(for: .cropBox))
        guard !bounds.isNull, bounds.width >= 3, bounds.height >= 3 else { return }
        let annotation = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
        annotation.action = PDFActionURL(url: url)
        annotation.color = .systemBlue
        let border = PDFBorder()
        border.lineWidth = 1
        annotation.border = border
        annotation.contents = url.absoluteString
        annotation.setValue("CartaPDF-Link-" + UUID().uuidString, forAnnotationKey: .name)
        addMarkup(annotation, on: page, actionName: "Aggiungi collegamento")
    }

    func removeWebLink(_ annotation: PDFAnnotation, from page: PDFPage) {
        guard !isProcessing, canEditAnnotations, page.document === document,
              page.annotations.contains(where: { $0 === annotation }), annotation.type == "Link",
              (annotation.value(forAnnotationKey: .name) as? String)?.hasPrefix("CartaPDF-Link-") == true else { return }
        removeMarkup(annotation, on: page, actionName: "Elimina collegamento")
    }

    private func addMarkup(_ annotation: PDFAnnotation, on page: PDFPage, actionName: String) {
        performChange(named: actionName, mutation: {
            page.addAnnotation(annotation)
            pdfView?.annotationsChanged(on: page)
        }, inverse: { model in model.removeMarkup(annotation, on: page, actionName: actionName) })
    }

    private func removeMarkup(_ annotation: PDFAnnotation, on page: PDFPage, actionName: String) {
        performChange(named: actionName, mutation: {
            page.removeAnnotation(annotation)
            pdfView?.annotationsChanged(on: page)
        }, inverse: { model in model.addMarkup(annotation, on: page, actionName: actionName) })
    }

    func redactRegion(_ rectangle: CGRect, on page: PDFPage) {
        guard !isProcessing else { return }
        guard canEditDocument, document.allowsPrinting, document.allowsCopying, page.document === document else {
            errorMessage = "Per creare una copia oscurata servono i permessi di modifica, copia e stampa del PDF."
            return
        }
        let index = document.index(for: page)
        guard index != NSNotFound else { return }
        let alert = NSAlert()
        alert.messageText = "Crea una copia oscurata?"
        alert.informativeText = "Tutte le pagine saranno convertite in immagini a 200 dpi. L’area selezionata verrà sostituita da pixel neri prima di creare il nuovo PDF. La copia perderà testo selezionabile, moduli, collegamenti, annotazioni modificabili, metadati originali ed eventuale protezione con password. Il documento originale rimarrà aperto e invariato."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Crea copia oscurata")
        alert.addButton(withTitle: "Annulla")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Detach every page before yielding: Undo or another window must never
        // mutate pages while the operation is rendering them.
        let source = PDFDocument()
        for pageIndex in 0..<document.pageCount {
            guard let copy = document.page(at: pageIndex)?.copy() as? PDFPage else {
                errorMessage = PDFRasterSanitizerError.invalidPage.localizedDescription
                return
            }
            source.insert(copy, at: source.pageCount)
        }
        let identifier = UUID()
        processingIdentifier = identifier
        isProcessing = true
        processingProgress = 0
        processingMessage = "Creazione della copia oscurata…"
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.processingIdentifier == identifier {
                    self.isProcessing = false
                    self.processingMessage = nil
                    self.processingTask = nil
                    self.processingIdentifier = nil
                }
            }
            do {
                let result = try await PDFRasterSanitizer.sanitizedDocumentAsync(source, regions: [PDFRedactionRegion(pageIndex: index, bounds: rectangle)]) {
                    if self.processingIdentifier == identifier { self.processingProgress = $0 }
                }
                guard self.processingIdentifier == identifier else { return }
                self.openGeneratedDocument(result, name: "Copia oscurata.pdf")
                self.statusMessage = "Copia oscurata aperta in una nuova finestra. Salvala con ⌘S."
            } catch is CancellationError {
                if self.processingIdentifier == identifier { self.statusMessage = "Oscuramento annullato." }
            } catch {
                if self.processingIdentifier == identifier { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func addGraphicalSignature(at point: CGPoint, on page: PDFPage) {
        guard !isProcessing, canEditAnnotations, page.document === document else { return }
        let alert = NSAlert()
        alert.messageText = "Firma grafica"
        alert.informativeText = "Disegna la tua firma nel riquadro. Sarà aggiunta come tratto modificabile: non è una firma digitale crittografica e non certifica l’identità."
        alert.addButton(withTitle: "Inserisci firma")
        alert.addButton(withTitle: "Annulla")
        let pad = SignaturePadView(frame: CGRect(x: 0, y: 0, width: 460, height: 160))
        alert.accessoryView = pad
        guard alert.runModal() == .alertFirstButtonReturn, !pad.strokes.isEmpty else { return }
        let allPoints = pad.strokes.flatMap { $0 }
        guard let minX = allPoints.map(\.x).min(), let maxX = allPoints.map(\.x).max(),
              let minY = allPoints.map(\.y).min(), let maxY = allPoints.map(\.y).max(),
              maxX - minX > 2, maxY - minY > 2 else { return }
        let transform = page.transform(for: .cropBox)
        let crop = page.bounds(for: .cropBox).applying(transform)
        guard crop.width > 8, crop.height > 8 else { return }
        let scale = min(220 / (maxX - minX), 80 / (maxY - minY), (crop.width - 6) / (maxX - minX), (crop.height - 6) / (maxY - minY))
        let size = CGSize(width: (maxX - minX) * scale + 6, height: (maxY - minY) * scale + 6)
        let displayPoint = point.applying(transform)
        let origin = CGPoint(x: min(max(displayPoint.x, crop.minX), crop.maxX - size.width),
                             y: min(max(displayPoint.y - size.height, crop.minY), crop.maxY - size.height))
        let bounds = CGRect(origin: origin, size: size).applying(transform.inverted())
        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        for stroke in pad.strokes where stroke.count > 1 {
            let path = NSBezierPath()
            for (index, point) in stroke.enumerated() {
                let displayed = CGPoint(x: origin.x + (point.x - minX) * scale + 3,
                                        y: origin.y + (point.y - minY) * scale + 3)
                let pagePoint = displayed.applying(transform.inverted())
                let local = CGPoint(x: pagePoint.x - bounds.minX, y: pagePoint.y - bounds.minY)
                if index == 0 { path.move(to: local) } else { path.line(to: local) }
            }
            annotation.add(path)
        }
        let border = PDFBorder()
        border.lineWidth = 1.5
        annotation.border = border
        annotation.color = .black
        annotation.contents = "Firma grafica"
        addMarkup(annotation, on: page, actionName: "Aggiungi firma grafica")
    }
}

@MainActor
private final class SignaturePadView: NSView {
    var strokes: [[CGPoint]] = []
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        strokes.append([convert(event.locationInWindow, from: nil)])
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard !strokes.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        strokes[strokes.count - 1].append(CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height)))
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { strokes = []; needsDisplay = true }
        else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        NSColor.black.setStroke()
        for stroke in strokes {
            let path = NSBezierPath()
            path.lineWidth = 2
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            for (index, point) in stroke.enumerated() {
                if index == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            path.stroke()
        }
    }
}
