import AppKit
import AppIntents
import Darwin
import PDFKit
import UniformTypeIdentifiers

enum CartaAutomationError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

@MainActor
enum CartaAutomation {
    static func load(_ path: String, password: String? = nil) throws -> PDFDocument {
        guard let pdf = PDFDocument(url: URL(fileURLWithPath: path)) else { throw PDFWorkspaceError.invalidPDF }
        if pdf.isLocked, let password { _ = pdf.unlock(withPassword: password) }
        guard !pdf.isLocked else { throw CartaAutomationError.message(L10n.tr("PDF protetto: specifica --password-file, senza mettere password nella riga di comando.")) }
        guard pdf.pageCount > 0 else { throw PDFWorkspaceError.invalidPDF }
        return pdf
    }
    static func merge(_ paths: [String], password: String? = nil) throws -> Data {
        guard !paths.isEmpty else { throw CartaAutomationError.message(L10n.tr("Seleziona almeno un PDF.")) }
        let result = PDFDocument()
        for path in paths {
            try Task.checkCancellation()
            let source = try load(path, password: password)
            guard source.allowsCopying else { throw PDFWorkspaceError.copyingNotAllowed }
            for index in 0..<source.pageCount {
                try Task.checkCancellation()
                guard let page = source.page(at: index)?.copy() as? PDFPage else { throw PDFWorkspaceError.invalidPDF }
                result.insert(page, at: result.pageCount)
            }
        }
        guard let data = result.dataRepresentation() else { throw PDFWorkspaceError.cannotSave }
        return data
    }
    static func write(_ data: Data, to path: String, sources: [String], overwrite: Bool = false) throws {
        let output = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard !sources.contains(where: { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() == output }) else {
            throw CartaAutomationError.message(L10n.tr("L’output deve essere diverso dai file sorgente."))
        }
        guard overwrite || !FileManager.default.fileExists(atPath: output.path) else { throw CartaAutomationError.message(L10n.tr("L’output esiste già. Usa --overwrite per sostituirlo esplicitamente.")) }
        try CartaFileIO.atomicWrite(data, to: output, replaceExisting: overwrite)
    }
    static func cli(_ arguments: [String]) -> Int32 {
        var args = arguments
        var password: String?
        if let index = args.firstIndex(of: "--password-file"), args.indices.contains(index + 1) {
            password = try? String(contentsOfFile: args[index + 1], encoding: .utf8).trimmingCharacters(in: .newlines)
            args.removeSubrange(index...(index + 1))
        }
        let overwrite = args.contains("--overwrite")
        args.removeAll { $0 == "--overwrite" }
        guard let command = args.first, command != "help" else {
            print("""
            CartaPDF --cli info input.pdf
            CartaPDF --cli merge output.pdf input1.pdf input2.pdf ...
            CartaPDF --cli extract input.pdf output.pdf '1-3,5'
            CartaPDF --cli split input.pdf folder
            CartaPDF --cli text input.pdf output.txt
            CartaPDF --cli ocr input.pdf output.pdf
            CartaPDF --cli flatten input.pdf output.pdf
            CartaPDF --cli compress input.pdf output.pdf
            CartaPDF --cli validate-pdfa input.pdf 2u [report.json]
            CartaPDF --cli language
            """)
            print(L10n.tr("Profili:1a,1b,2a,2b,2u,3a,3b,3u,4,4e,4f. Esiti CLI:conforme0,nonconforme2,indeterminato3."))
            print(L10n.tr("Opzioni: --password-file percorso, --overwrite. Nessuna rete, nessuna sovrascrittura dei sorgenti."))
            return 0
        }
        do {
            if command == "language" {
                // Read-only diagnostics for language selection and resources
                // in the assembled app. No system preference is modified.
                let info: [String: Any] = [
                    "selectedLanguage": L10n.language,
                    "preferredLanguages": Locale.preferredLanguages,
                    "supportedLanguages": L10n.supportedLanguages,
                    "catalogueCounts": Dictionary(uniqueKeysWithValues: L10n.supportedLanguages.map {
                        ($0, L10n.localizedStrings(for: $0).count)
                    }),
                    "labels": ["open": L10n.tr("Apri…"), "save": L10n.tr("Salva"), "cancel": L10n.tr("Annulla")]
                ]
                let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                return 0
            }
            if command == "validate-pdfa" {
                guard (3...4).contains(args.count), let profile = PDFArchiveProfile(rawValue: args[2].lowercased()) else {
                    throw CartaAutomationError.message(L10n.tr("Uso: validate-pdfa input.pdf profilo [rapporto.json]. Profili:1a,1b,2a,2b,2u,3a,3b,3u,4,4e,4f."))
                }
                let report = PDFArchiveValidator.validate(data: try Data(contentsOf: URL(fileURLWithPath: args[1]), options: .mappedIfSafe), profile: profile)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let json = try encoder.encode(report)
                if args.count > 3 { try write(json, to: args[3], sources: [args[1]], overwrite: overwrite) }
                else { print(String(decoding: json, as: UTF8.self)) }
                switch report.verdict {
                case .conforming: return 0
                case .nonconforming: return 2
                case .indeterminate: return 3
                }
            }
            if command == "merge" {
                guard args.count >= 4 else { throw CartaAutomationError.message(L10n.tr("Uso: merge output.pdf input1.pdf input2.pdf")) }
                let sources = Array(args.dropFirst(2))
                try write(merge(sources, password: password), to: args[1], sources: sources, overwrite: overwrite)
            } else {
                guard args.count >= 2 else { throw CartaAutomationError.message(L10n.tr("Manca il PDF sorgente.")) }
                let input = args[1], pdf = try load(input, password: password)
                if command == "info" {
                    let info: [String: Any] = ["pages": pdf.pageCount, "encrypted": pdf.isEncrypted, "copying": pdf.allowsCopying,
                                               "printing": pdf.allowsPrinting, "textCharacters": pdf.string?.count ?? 0]
                    let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
                    print(String(decoding: data, as: UTF8.self)); return 0
                }
                guard args.count >= 3 else { throw CartaAutomationError.message(L10n.tr("Manca il percorso di output.")) }
                let model = PDFEditorModel(); model.replaceDocument(pdf, fileName: URL(fileURLWithPath: input).lastPathComponent)
                switch command {
                case "split":
                    let folder = URL(fileURLWithPath: args[2], isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let urls = try model.splitPDF(to: folder)
                    print(urls.map(\.path).joined(separator: "\n"))
                case "extract":
                    guard args.count >= 4 else { throw CartaAutomationError.message(L10n.tr("Manca l’intervallo, per esempio 1-3,5.")) }
                    let indices = try PDFEditorModel.parsePageRange(args[3], pageCount: pdf.pageCount)
                    let extracted = try model.extractedDocument(pageIndexes: indices)
                    guard let data = extracted.dataRepresentation() else { throw PDFWorkspaceError.cannotSave }
                    try write(data, to: args[2], sources: [input], overwrite: overwrite)
                case "text":
                    guard pdf.allowsCopying else { throw PDFWorkspaceError.copyingNotAllowed }
                    try write(Data(PDFConversionEngine.extractedText(from: pdf).utf8), to: args[2], sources: [input], overwrite: overwrite)
                case "ocr", "flatten", "compress":
                    guard pdf.allowsPrinting, pdf.allowsCopying else { throw PDFWorkspaceError.copyingNotAllowed }
                    let snapshot = try model.unprotectedWorkingSnapshot()
                    let data: Data
                    if command == "ocr" { data = try PDFConversionEngine.ocrPDFData(snapshot: snapshot).data }
                    else { data = try PDFConversionEngine.rasterPDFData(snapshot: snapshot, dpi: command == "compress" ? 150 : 200, jpegQuality: command == "compress" ? 0.75 : nil) }
                    try write(data, to: args[2], sources: [input], overwrite: overwrite)
                default: throw CartaAutomationError.message(L10n.tr("Comando sconosciuto. Usa --cli help."))
                }
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            return 1
        }
    }
}

struct CartaMergeIntent: AppIntent {
    static var title: LocalizedStringResource = "Unisci PDF"
    static var description = IntentDescription("Unisce documenti localmente sul Mac. I sorgenti vengono conservati.")
    @Parameter(title: "Documenti") var documents: [IntentFile]
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let limit = await MainActor.run { CartaPreferences.shared.concurrentJobs }
        let data = try await CartaJobLimiter.shared.withPermit(limit: limit) {
            try await MainActor.run {
                let result = PDFDocument()
                for file in documents {
                    try Task.checkCancellation()
                    guard let source = PDFDocument(data: file.data), !source.isLocked, source.allowsCopying else { throw PDFWorkspaceError.copyingNotAllowed }
                    for index in 0..<source.pageCount {
                        try Task.checkCancellation()
                        guard let page = source.page(at: index)?.copy() as? PDFPage else { throw PDFWorkspaceError.invalidPDF }
                        result.insert(page, at: result.pageCount)
                    }
                }
                guard result.pageCount > 0, let data = result.dataRepresentation() else { throw PDFWorkspaceError.invalidPDF }
                return data
            }
        }
        return .result(value: IntentFile(data: data, filename: L10n.tr("Unione.pdf"), type: .pdf))
    }
}

struct CartaShortcutProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CartaMergeIntent(), phrases: ["Unisci documenti con \(.applicationName)"], shortTitle: "Unisci PDF", systemImageName: "doc.on.doc")
    }
}

@objc(CartaMergeScriptCommand)
final class CartaMergeScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            do {
                guard let paths = evaluatedArguments?["files"] as? [String], let destination = evaluatedArguments?["destination"] as? String else {
                    throw CartaAutomationError.message(L10n.tr("Servono files e destination."))
                }
                try CartaAutomation.write(CartaAutomation.merge(paths), to: destination, sources: paths)
                return destination
            } catch { scriptErrorNumber = -2700; scriptErrorString = error.localizedDescription; return nil }
        }
    }
}
