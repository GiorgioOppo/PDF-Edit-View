import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

extension PDFArchiveVerdict {
    var cartaLabel: String {
        switch self {
        case .conforming: return L10n.tr("Conforme")
        case .nonconforming: return L10n.tr("Non conforme")
        case .indeterminate: return L10n.tr("Indeterminato")
        }
    }
}

extension PDFArchiveRuleStatus {
    var cartaLabel: String {
        switch self {
        case .passed: return L10n.tr("Verificata")
        case .failed: return L10n.tr("Violazione")
        case .notVerified: return L10n.tr("Non verificata")
        case .notApplicable: return L10n.tr("Non applicabile")
        }
    }
}

@MainActor
final class CartaArchiveValidationState: ObservableObject {
    let data: Data
    let sourceURL: URL?
    let name: String
    let analysisOrigin: String
    let declaredProfile: PDFArchiveProfile?
    @Published var profile: PDFArchiveProfile = .pdfa2u {
        didSet { if profile != oldValue { cancel(); report = nil; status = L10n.tr("Profilo selezionato: \(profile.title). Avvia la verifica.") } }
    }
    @Published private(set) var report: PDFArchiveValidationReport?
    @Published private(set) var busy = false
    @Published private(set) var status = L10n.tr("Scegli il profilo da verificare. Il file viene analizzato sul Mac senza modificarlo.")
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(data: Data, sourceURL: URL?, name: String, analysisOrigin: String = L10n.tr("Analisi dei byte del documento nel pannello.")) {
        self.data = data; self.sourceURL = sourceURL; self.name = name; self.analysisOrigin = analysisOrigin
        declaredProfile = PDFArchiveValidator.declaredProfile(data: data)
        if let declaredProfile { profile = declaredProfile }
    }

    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; busy = false
        status = L10n.tr("Verifica annullata.")
    }

    func validate() {
        cancel()
        generation = UUID()
        let id = generation, data = data, profile = profile, limit = CartaPreferences.shared.concurrentJobs
        busy = true; report = nil; status = L10n.tr("Verifica locale di \(profile.title) in corso…")
        task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try await CartaJobLimiter.shared.withPermit(limit: limit) {
                    try Task.checkCancellation()
                    let result = PDFArchiveValidator.validate(data: data, profile: profile)
                    try Task.checkCancellation()
                    return result
                }
            }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, self.generation == id, !Task.isCancelled else { return }
                self.report = result; self.busy = false
                self.status = L10n.tr("\(profile.title): \(result.verdict.cartaLabel). \(result.failedCount) violazioni, \(result.unverifiedCount) regole non verificate.")
            } catch {
                guard let self, self.generation == id else { return }
                self.busy = false; self.status = error is CancellationError ? L10n.tr("Verifica annullata.") : error.localizedDescription
            }
        }
    }

    func export(json: Bool) {
        guard !busy, let report else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = json ? [.json] : [.plainText]
        panel.nameFieldStringValue = (name as NSString).deletingPathExtension + "-PDF-A-" + profile.rawValue + (json ? ".json" : ".txt")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        if let sourceURL, sourceURL.resolvingSymlinksInPath().standardizedFileURL == destination.resolvingSymlinksInPath().standardizedFileURL {
            status = L10n.tr("Scegli un percorso diverso dal PDF originale."); return
        }
        do {
            let bytes: Data
            if json { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; bytes = try encoder.encode(report) }
            else { bytes = Data(report.textReport.utf8) }
            try CartaFileIO.atomicWrite(bytes, to: destination)
            status = L10n.tr("Rapporto salvato: \(destination.lastPathComponent).")
        } catch { status = error.localizedDescription }
    }
}

@MainActor
struct CartaArchiveValidationView: View {
    @StateObject var state: CartaArchiveValidationState
    @State private var query = ""
    @State private var filter = "all"
    @FocusState private var queryFocused: Bool

    private var rules: [PDFArchiveRuleResult] {
        ((state.report?.modelChecks ?? []) + (state.report?.rules ?? [])).filter {
            (filter == "all" || $0.status.rawValue == filter) && (query.isEmpty || ($0.id + " " + $0.clause + " " + $0.objectType + " " + $0.requirement + " " + $0.detail).localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("Validazione PDF/A")).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text(state.name).foregroundStyle(.secondary)
            Text(state.analysisOrigin).font(.caption)
            Text(L10n.tr("Profilo dichiarato nei metadati: \(state.declaredProfile?.title ?? L10n.tr("assente o non riconosciuto"))")).font(.callout)
            HStack {
                Picker(L10n.tr("Profilo ISO PDF/A"), selection: $state.profile) {
                    ForEach(PDFArchiveProfile.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(maxWidth: 320)
                Button(L10n.tr("Verifica il PDF"), action: state.validate).disabled(state.busy).keyboardShortcut(.defaultAction)
                if state.busy { ProgressView().accessibilityLabel(L10n.tr("Validazione in corso")); Button(L10n.tr("Annulla"), action: state.cancel).keyboardShortcut(.cancelAction) }
                Spacer()
            }
            Text(L10n.tr("Le regole non valutate rimangono esplicitamente non verificate. Un risultato indeterminato non attesta la conformità ISO del documento."))
                .font(.callout)
            CartaPanelAccessibilityStatus(message: state.status, label: L10n.tr("Esito validazione"))
            if let report = state.report {
                HStack {
                    Text(report.verdict.cartaLabel).font(.headline)
                    Text(L10n.tr("\(report.passedCount) verificate · \(report.failedCount) violazioni · \(report.unverifiedCount) non verificate"))
                        .fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine)
                Text(L10n.tr("SHA-256: \(report.sha256)")).font(.caption.monospaced()).textSelection(.enabled)
                    .accessibilityLabel(L10n.tr("Impronta SHA 256 del file analizzato")).accessibilityValue(report.sha256)
                HStack {
                    TextField(L10n.tr("Cerca clausola, oggetto o requisito"), text: $query).focused($queryFocused)
                    Picker(L10n.tr("Regole visualizzate"), selection: $filter) {
                        Text(L10n.tr("Tutte")).tag("all")
                        Text(L10n.tr("Violazioni")).tag(PDFArchiveRuleStatus.failed.rawValue)
                        Text(L10n.tr("Non verificate")).tag(PDFArchiveRuleStatus.notVerified.rawValue)
                        Text(L10n.tr("Verificate")).tag(PDFArchiveRuleStatus.passed.rawValue)
                        Text(L10n.tr("Non applicabili")).tag(PDFArchiveRuleStatus.notApplicable.rawValue)
                    }.labelsHidden().accessibilityLabel(L10n.tr("Regole visualizzate"))
                        .frame(minWidth: 200, idealWidth: 230, maxWidth: 260)
                }
                List(rules) { rule in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.tr("\(rule.status.cartaLabel) · \(rule.specification) · § \(rule.clause) · test \(rule.testNumber)")).font(.headline)
                        Text(rule.requirement).textSelection(.enabled)
                        Text(rule.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        if !rule.locations.isEmpty { Text(rule.locations.joined(separator: ", ")).font(.caption).textSelection(.enabled) }
                    }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 6).accessibilityElement(children: .combine)
                }.accessibilityLabel(L10n.tr("\(rules.count) regole del rapporto"))
                if !report.diagnostics.isEmpty { Text(report.diagnostics.joined(separator: "\n")).font(.caption).textSelection(.enabled) }
                DisclosureGroup(L10n.tr("Ambiti ancora da verificare (\(report.scopeGaps.count))")) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(report.scopeGaps, id: \.self) {
                                Text($0).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 180)
                }
                HStack {
                    Button(L10n.tr("Esporta JSON…")) { state.export(json: true) }
                    Button(L10n.tr("Esporta testo…")) { state.export(json: false) }
                    Spacer()
                    Text(L10n.tr("Copertura completa: \(report.coverageComplete ? L10n.tr("sì") : L10n.tr("no"))")).font(.caption)
                }
            } else { Spacer() }
        }.padding(24).frame(minWidth: 880, minHeight: 680)
            .accessibilityIdentifier("panel.pdfa.validation")
            .onDisappear(perform: state.cancel)
            .background(Button("") { queryFocused = true }.keyboardShortcut("f", modifiers: .command).hidden().accessibilityHidden(true))
    }
}

@MainActor
extension PDFEditorModel {
    func showArchiveValidationWorkspace() {
        guard !isProcessing else { return }
        do {
            let source = documentOwner?.fileURL
            let bytes: Data
            if let owner = documentOwner, !owner.isDocumentEdited, let source { bytes = try Data(contentsOf: source) }
            else { bytes = try serializedData() }
            let original = documentOwner?.isDocumentEdited == false && source != nil
            let state = CartaArchiveValidationState(data: bytes, sourceURL: source, name: fileName,
                analysisOrigin: original ? L10n.tr("Analisi dei byte originali del file salvato.") : L10n.tr("Analisi dello snapshot in memoria: comprende le modifiche non salvate."))
            CartaPanelController.present(CartaArchiveValidationView(state: state), title: L10n.tr("Validazione PDF/A"), width: 1050, height: 800)
        } catch { errorMessage = error.localizedDescription }
    }
}

@MainActor
extension PDFStructureWorkspaceState {
    func showArchiveValidationWorkspace() {
        let state = CartaArchiveValidationState(data: data, sourceURL: sourceURL, name: sourceName)
        CartaPanelController.present(CartaArchiveValidationView(state: state), title: L10n.tr("Validazione PDF/A"), width: 1050, height: 800)
    }
}
