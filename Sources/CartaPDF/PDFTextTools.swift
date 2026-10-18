import AppKit
import CoreText
import PDFKit
import UniformTypeIdentifiers

@MainActor
enum PDFTextEngine {
    static func makePDF(from text: NSAttributedString) throws -> Data {
        guard text.length > 0 else { throw PDFTextError.emptyText }
        // Imported documents supply the text. CoreText lays it out independently
        // of any original Office page geometry or attachments.
        let printable = NSMutableAttributedString(string: text.string.replacingOccurrences(of: "\u{0C}", with: "\n"), attributes: [
            .font: NSFont(name: "Helvetica", size: 12)!, .foregroundColor: NSColor.black
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(printable)
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 595.276, height: 841.89)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw PDFTextError.cannotConvert }
        let path = CGPath(rect: media.insetBy(dx: 48, dy: 48), transform: nil)
        var position = 0
        while position < printable.length {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(media)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: position, length: 0), path, nil)
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()
            guard visible.length > 0 else { throw PDFTextError.cannotConvert }
            position += visible.length
        }
        context.closePDF()
        return data as Data
    }

    static func wordData(text: String) throws -> Data {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PDFTextError.emptyText }
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
        return try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    }
}

@MainActor
extension PDFEditorModel {
    func createPDFFromText() {
        guard !isProcessing else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .rtf, UTType(filenameExtension: "docx")!]
        panel.canChooseDirectories = false
        panel.message = L10n.tr("Il testo verrà impaginato in un nuovo PDF A4. Immagini, tabelle e layout di Word non vengono riprodotti.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let source = try Data(contentsOf: url)
            let text: NSAttributedString
            if url.pathExtension.lowercased() == "txt" {
                guard let string = String(data: source, encoding: .utf8) ?? String(data: source, encoding: .utf16) else { throw PDFTextError.invalidEncoding }
                text = NSAttributedString(string: string)
            } else {
                let type: NSAttributedString.DocumentType = url.pathExtension.lowercased() == "docx" ? .officeOpenXML : .rtf
                text = try NSAttributedString(data: source, options: [.documentType: type], documentAttributes: nil)
            }
            let data = try PDFTextEngine.makePDF(from: text)
            guard let pdf = PDFDocument(data: data) else { throw PDFTextError.cannotConvert }
            openGeneratedDocument(pdf, name: url.deletingPathExtension().lastPathComponent + ".pdf")
        } catch { errorMessage = error.localizedDescription }
    }

    func exportDOCX() {
        guard !isProcessing, document.allowsCopying else { return }
        do {
            let text = (0..<pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n\n")
            let data = try PDFTextEngine.wordData(text: text)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "docx")!]
            panel.nameFieldStringValue = (fileName as NSString).deletingPathExtension + ".docx"
            panel.message = L10n.tr("Esporta il testo in Word. Colonne, tabelle, immagini e impaginazione non vengono conservate.")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            statusMessage = L10n.tr("Testo esportato in Word.")
        } catch { errorMessage = error.localizedDescription }
    }
}

enum PDFTextError: LocalizedError {
    case emptyText, cannotConvert, invalidEncoding
    var errorDescription: String? {
        switch self {
        case .emptyText: return L10n.tr("Il documento non contiene testo esportabile. Esegui prima OCR se è una scansione.")
        case .cannotConvert: return L10n.tr("Non è stato possibile convertire il testo in PDF.")
        case .invalidEncoding: return L10n.tr("Il file di testo deve essere codificato in UTF-8 o UTF-16.")
        }
    }
}
