import SwiftUI
import AppKit

private enum ToolCategory: String, CaseIterable, Identifiable {
    case all = "Tutti", create = "Crea e converti", pages = "Organizza pagine", markup = "Annota e firma", protect = "Proteggi", forms = "Moduli", analyze = "Analizza"
    var id: String { rawValue }
}

private struct WorkspaceTool: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let category: ToolCategory
    var enabled = true
    let action: () -> Void
}

struct ToolBrowserView: View {
    @ObservedObject var model: PDFEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var category: ToolCategory = .all
    @State private var query = ""
    @State private var showForms = false
    @FocusState private var queryFocused: Bool
    @AccessibilityFocusState private var queryAccessibilityFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("Tutti gli strumenti")).font(.title2.weight(.semibold))
                    Text(L10n.tr("Il tuo spazio di lavoro PDF, sul Mac.")).foregroundStyle(.secondary)
                }.fixedSize(horizontal: false, vertical: true)
                Spacer()
                TextField(L10n.tr("Trova uno strumento"), text: $query)
                    .textFieldStyle(.roundedBorder).frame(width: 230)
                    .focused($queryFocused)
                    .accessibilityFocused($queryAccessibilityFocused)
                    .accessibilityIdentifier("tools.search")
                Button(L10n.tr("Fine")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(22)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(ToolCategory.allCases) { item in
                        Button { category = item } label: {
                            Text(L10n.string(item.rawValue)).fontWeight(category == item ? .semibold : .regular)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(category == item ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(category == item ? .isSelected : [])
                            .accessibilityValue(category == item ? L10n.tr("Categoria selezionata") : "")
                    }
                    Spacer()
                    Label(L10n.tr("Elaborazione locale"), systemImage: "desktopcomputer")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(8)
                }.padding(12).frame(width: 172)
                Divider()
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                        ForEach(filteredTools) { tool in
                            Button {
                                if tool.id == "forms" { showForms = true }
                                else {
                                    dismiss()
                                    DispatchQueue.main.async { tool.action() }
                                }
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: tool.symbol)
                                        .font(.system(size: 22)).foregroundStyle(color(for: tool.category))
                                        .frame(width: 35, height: 38)
                                        .background(color(for: tool.category).opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(tool.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(tool.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
                                .padding(13)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.13)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!tool.enabled || model.isProcessing)
                            .opacity(tool.enabled ? 1 : 0.45)
                            .help(tool.enabled ? tool.detail : L10n.tr("Il documento non consente questa operazione."))
                            .accessibilityLabel(tool.title)
                            .accessibilityHint(tool.enabled ? tool.detail : L10n.tr("Il documento non consente questa operazione."))
                            .accessibilityIdentifier("tool.\(tool.id)")
                        }
                    }.padding(20)
                    if filteredTools.isEmpty { Text(L10n.tr("Nessuno strumento corrisponde alla ricerca.")).foregroundStyle(.secondary).padding(30) }
                }
            }
        }
        .frame(width: 940, height: 650)
        .sheet(isPresented: $showForms) { PDFFormsView(model: model) }
        .accessibilityIdentifier("panel.tools")
        .onAppear { queryFocused = true; queryAccessibilityFocused = true }
        .background(Button("") { queryFocused = true; queryAccessibilityFocused = true }
            .keyboardShortcut("f", modifiers: .command).hidden().accessibilityHidden(true))
    }

    private var filteredTools: [WorkspaceTool] {
        tools.filter { (category == .all || $0.category == category) && (query.isEmpty || ($0.title + " " + $0.detail).localizedCaseInsensitiveContains(query)) }
    }

    private func color(for category: ToolCategory) -> Color {
        switch category {
        case .all, .create: return .blue
        case .pages: return .purple
        case .markup: return .orange
        case .protect: return .red
        case .forms: return .green
        case .analyze: return .teal
        }
    }

    private var tools: [WorkspaceTool] {
        [
            WorkspaceTool(id: "pdfa-validator", title: L10n.tr("Validazione PDF/A"), detail: L10n.tr("Seleziona uno degli 11 profili, controlla le clausole e le verifiche non eseguite, esporta il rapporto locale."), symbol: "checkmark.shield", category: .analyze, action: model.showArchiveValidationWorkspace),
            WorkspaceTool(id: "keyboard-editing", title: L10n.tr("Annotazioni da tastiera"), detail: L10n.tr("Crea, seleziona, modifica e posiziona annotazioni con campi numerici e VoiceOver."), symbol: "keyboard", category: .markup, action: model.showKeyboardEditingWorkspace),
            WorkspaceTool(id: "merge-workspace", title: L10n.tr("Unione avanzata"), detail: L10n.tr("Ordina i file, scegli intervalli e unisci scansioni fronte/retro."), symbol: "rectangle.3.group", category: .pages, action: model.showMergeWorkspace),
            WorkspaceTool(id: "split-workspace", title: L10n.tr("Divisione avanzata"), detail: L10n.tr("Dividi per capitoli, testo, codici, pagine bianche, quantità o dimensioni."), symbol: "scissors", category: .pages, action: model.showSplitWorkspace),
            WorkspaceTool(id: "layout-workspace", title: L10n.tr("Impaginazione e stampa"), detail: L10n.tr("Libretti, poster, più pagine per foglio, scansioni libro e sovrapposizioni."), symbol: "rectangle.grid.2x2", category: .pages, action: model.showPageLayoutWorkspace),
            WorkspaceTool(id: "crop-workspace", title: L10n.tr("Ritaglio con anteprima"), detail: L10n.tr("Margini in punti o millimetri e dimensioni risultanti."), symbol: "crop", category: .pages, enabled: model.canEditPages, action: model.showCropWorkspace),
            WorkspaceTool(id: "watermark-workspace", title: L10n.tr("Filigrane configurabili"), detail: L10n.tr("Posizione, dimensione, colore e trasparenza con anteprima."), symbol: "drop", category: .markup, enabled: model.canEditAnnotations, action: model.showWatermarkWorkspace),
            WorkspaceTool(id: "number-workspace", title: L10n.tr("Numerazione e intestazioni"), detail: L10n.tr("Bates, numeri, data, nome file e sommario cliccabile."), symbol: "number.square", category: .markup, enabled: model.canEditAnnotations, action: model.showNumberingWorkspace),
            WorkspaceTool(id: "batch-workspace", title: L10n.tr("Procedure batch"), detail: L10n.tr("Combina operazioni locali su una coda di documenti."), symbol: "list.bullet.rectangle.portrait", category: .create, action: model.showBatchWorkspace),
            WorkspaceTool(id: "scan-workspace", title: L10n.tr("Scansioni e OCR avanzato"), detail: L10n.tr("Lingue, orientamento, raddrizzamento, pulizia e rapporto per pagina."), symbol: "text.viewfinder", category: .create, action: model.showScanWorkspace),
            WorkspaceTool(id: "export-workspace", title: L10n.tr("Esportazioni avanzate"), detail: L10n.tr("TIFF, EPUB, CSV tabelle, HTML locale e anteprime JPEG."), symbol: "square.and.arrow.up", category: .create, action: model.showExportWorkspace),
            WorkspaceTool(id: "scanner-workspace", title: L10n.tr("Acquisisci da scanner"), detail: L10n.tr("Scanner locali tramite il pannello nativo macOS."), symbol: "scanner", category: .create, action: model.showScannerWorkspace),
            WorkspaceTool(id: "capture-workspace", title: L10n.tr("Acquisisci schermata"), detail: L10n.tr("Crea PDF da schermi o finestre con autorizzazione macOS."), symbol: "camera.viewfinder", category: .create, action: model.showCaptureWorkspace),
            WorkspaceTool(id: "csv-forms-workspace", title: L10n.tr("Compila moduli da CSV"), detail: L10n.tr("Genera una serie di PDF da dati locali."), symbol: "tablecells", category: .forms, action: model.showCSVFormWorkspace),
            WorkspaceTool(id: "library-workspace", title: L10n.tr("Biblioteca locale"), detail: L10n.tr("Categorie, etichette, ricerca in più PDF e rinomina da contenuti."), symbol: "books.vertical", category: .analyze, action: model.showLibraryWorkspace),
            WorkspaceTool(id: "watch-workspace", title: L10n.tr("Cartelle monitorate"), detail: L10n.tr("Applica un’operazione locale ai nuovi PDF di una cartella."), symbol: "folder.badge.gearshape", category: .create, action: model.showWatchFolderWorkspace),
            WorkspaceTool(id: "speech-workspace", title: L10n.tr("Leggi ad alta voce"), detail: L10n.tr("Usa le voci installate sul Mac, senza servizi esterni."), symbol: "speaker.wave.2", category: .analyze, action: model.showSpeechWorkspace),
            WorkspaceTool(id: "visual-workspace", title: L10n.tr("Confronto visivo"), detail: L10n.tr("Evidenzia in rosso le differenze nelle immagini delle pagine."), symbol: "rectangle.on.rectangle", category: .analyze, action: model.showVisualComparisonWorkspace),
            WorkspaceTool(id: "duplicates-workspace", title: L10n.tr("Trova pagine duplicate"), detail: L10n.tr("Individua coppie visivamente simili da verificare."), symbol: "doc.on.doc", category: .pages, action: model.showDuplicateWorkspace),
            WorkspaceTool(id: "stamp-workspace", title: L10n.tr("Libreria timbri"), detail: L10n.tr("Conserva timbri grafici e testuali riutilizzabili."), symbol: "seal", category: .markup, action: model.showStampWorkspace),
            WorkspaceTool(id: "recovery-workspace", title: L10n.tr("Recupero documenti"), detail: L10n.tr("Apri le copie automatiche dopo un arresto imprevisto."), symbol: "arrow.counterclockwise", category: .protect, action: model.showRecoveryWorkspace),
            WorkspaceTool(id: "versions-workspace", title: L10n.tr("Versioni locali"), detail: L10n.tr("Conserva e ripristina versioni senza sovrascrivere l’originale."), symbol: "clock.arrow.circlepath", category: .protect, action: model.showVersionWorkspace),
            WorkspaceTool(id: "preferences-workspace", title: L10n.tr("Preferenze"), detail: L10n.tr("Autore, tratto, memoria, recupero e scorciatoie."), symbol: "gearshape", category: .all, action: model.showPreferencesWorkspace),
            WorkspaceTool(id: "structure-workspace", title: L10n.tr("Struttura PDF"), detail: L10n.tr("Etichette pagina, immagini originali, allegati, portfolio e livelli."), symbol: "square.3.layers.3d", category: .analyze, action: model.showStructureWorkspace),
            WorkspaceTool(id: "preflight-workspace", title: L10n.tr("Preflight e archiviazione"), detail: L10n.tr("Controlli strutturali, conversione nativa PDF/A e preparazione ICC."), symbol: "checkmark.shield", category: .analyze, action: model.showPreflightWorkspace),
            WorkspaceTool(id: "certificate-workspace", title: L10n.tr("Firme con certificato"), detail: L10n.tr("Firma locale e verifica offline dell’integrità, con limiti espliciti."), symbol: "signature", category: .protect, action: model.showCertificateWorkspace),
            WorkspaceTool(id: "original-workspace", title: L10n.tr("Contenuti originali"), detail: L10n.tr("Modifica le risorse supportate del PDF e salva una copia verificata."), symbol: "doc.text.magnifyingglass", category: .markup, action: model.showOriginalContentWorkspace),
            WorkspaceTool(id: "images", title: L10n.tr("Crea PDF da immagini"), detail: L10n.tr("Combina foto e scansioni in un nuovo documento."), symbol: "photo.on.rectangle", category: .create, action: model.createPDFFromImages),
            WorkspaceTool(id: "textpdf", title: L10n.tr("Crea PDF da testo o Word"), detail: L10n.tr("Impagina il testo di file TXT, RTF e DOCX in un nuovo PDF."), symbol: "doc.badge.gearshape", category: .create, action: model.createPDFFromText),
            WorkspaceTool(id: "ocr", title: L10n.tr("Riconosci testo · OCR · copia"), detail: L10n.tr("Crea una copia ricercabile delle scansioni con Apple Vision."), symbol: "text.viewfinder", category: .create, enabled: model.canPrint && model.document.allowsCopying, action: model.runOCR),
            WorkspaceTool(id: "txt", title: L10n.tr("Esporta testo"), detail: L10n.tr("Estrai il testo selezionabile in un file TXT."), symbol: "doc.text", category: .create, enabled: model.document.allowsCopying, action: model.exportText),
            WorkspaceTool(id: "docx", title: L10n.tr("Esporta testo in Word"), detail: L10n.tr("Crea un DOCX modificabile dal testo. Il layout viene semplificato."), symbol: "doc.text.fill", category: .create, enabled: model.document.allowsCopying, action: model.exportDOCX),
            WorkspaceTool(id: "rtf", title: L10n.tr("Esporta RTF"), detail: L10n.tr("Esporta il testo per un elaboratore di testi. Il layout viene semplificato."), symbol: "doc.richtext", category: .create, enabled: model.document.allowsCopying, action: model.exportRTF),
            WorkspaceTool(id: "png", title: L10n.tr("Esporta pagine in PNG"), detail: L10n.tr("Salva un’immagine per ogni pagina in una cartella."), symbol: "photo.stack", category: .create, enabled: model.canPrint, action: model.exportPageImages),
            WorkspaceTool(id: "compress", title: L10n.tr("Riduci dimensioni · copia"), detail: L10n.tr("Rasterizza e comprime le pagine. Rimuove interattività e testo selezionabile."), symbol: "arrow.down.right.and.arrow.up.left", category: .create, enabled: model.canPrint, action: model.compressCopy),
            WorkspaceTool(id: "flatten", title: L10n.tr("Appiattisci · copia"), detail: L10n.tr("Incorpora la resa visiva di contenuti e annotazioni in immagini."), symbol: "square.3.layers.3d.down.right", category: .create, enabled: model.canPrint, action: model.flattenCopy),
            WorkspaceTool(id: "merge", title: L10n.tr("Combina PDF"), detail: L10n.tr("Inserisci le pagine di uno o più PDF dopo quella corrente."), symbol: "doc.on.doc", category: .pages, enabled: model.canEditPages, action: model.insertPDF),
            WorkspaceTool(id: "blank", title: L10n.tr("Inserisci pagina vuota"), detail: L10n.tr("Aggiungi una pagina per nuovi contenuti."), symbol: "doc.badge.plus", category: .pages, enabled: model.canEditPages, action: model.insertBlankPage),
            WorkspaceTool(id: "duplicate", title: L10n.tr("Duplica pagina"), detail: L10n.tr("Crea una copia indipendente della pagina corrente."), symbol: "plus.square.on.square", category: .pages, enabled: model.canEditPages, action: model.duplicateCurrentPage),
            WorkspaceTool(id: "moveup", title: L10n.tr("Sposta pagina prima"), detail: L10n.tr("Riordina la pagina corrente di una posizione."), symbol: "arrow.up.doc", category: .pages, enabled: model.canEditPages && model.currentPageIndex > 0, action: { model.moveCurrentPage(by: -1) }),
            WorkspaceTool(id: "movedown", title: L10n.tr("Sposta pagina dopo"), detail: L10n.tr("Riordina la pagina corrente di una posizione."), symbol: "arrow.down.doc", category: .pages, enabled: model.canEditPages && model.currentPageIndex + 1 < model.pageCount, action: { model.moveCurrentPage(by: 1) }),
            WorkspaceTool(id: "reverse", title: L10n.tr("Inverti ordine pagine"), detail: L10n.tr("Riordina tutte le pagine dall’ultima alla prima."), symbol: "arrow.up.arrow.down", category: .pages, enabled: model.canEditPages && model.pageCount > 1, action: model.reversePages),
            WorkspaceTool(id: "extract", title: L10n.tr("Estrai pagine"), detail: L10n.tr("Salva un intervallo di pagine in un nuovo PDF."), symbol: "square.and.arrow.up.on.square", category: .pages, enabled: model.document.allowsCopying, action: model.extractPages),
            WorkspaceTool(id: "split", title: L10n.tr("Dividi PDF"), detail: L10n.tr("Salva ogni pagina come documento PDF indipendente."), symbol: "square.split.2x1", category: .pages, enabled: model.document.allowsCopying, action: model.splitPDF),
            WorkspaceTool(id: "crop", title: L10n.tr("Ritaglia pagina"), detail: L10n.tr("Modifica i margini visibili; i contenuti esterni restano nel file."), symbol: "crop", category: .pages, enabled: model.canEditPages, action: model.cropCurrentPage),
            WorkspaceTool(id: "rotate", title: L10n.tr("Ruota pagina"), detail: L10n.tr("Ruota la pagina corrente di 90° verso destra."), symbol: "rotate.right", category: .pages, enabled: model.canEditPages, action: model.rotateCurrentPage),
            WorkspaceTool(id: "delete", title: L10n.tr("Elimina pagina"), detail: L10n.tr("Rimuovi la pagina corrente. Puoi annullare con ⌘Z."), symbol: "trash", category: .pages, enabled: model.canEditPages && model.pageCount > 1, action: model.deleteCurrentPage),
            WorkspaceTool(id: "watermark", title: L10n.tr("Filigrana"), detail: L10n.tr("Aggiungi una filigrana testuale a tutte le pagine."), symbol: "drop", category: .markup, enabled: model.canEditAnnotations, action: model.addWatermark),
            WorkspaceTool(id: "numbers", title: L10n.tr("Numera pagine"), detail: L10n.tr("Inserisci numeri di pagina nel piè di pagina."), symbol: "number.square", category: .markup, enabled: model.canEditAnnotations, action: model.addPageNumbers),
            WorkspaceTool(id: "bates", title: L10n.tr("Numerazione Bates"), detail: L10n.tr("Aggiungi identificativi progressivi con prefisso e zeri iniziali."), symbol: "number", category: .markup, enabled: model.canEditAnnotations, action: model.addBatesNumbers),
            WorkspaceTool(id: "bookmark", title: L10n.tr("Aggiungi segnalibro"), detail: L10n.tr("Inserisci la pagina corrente nell’indice del documento."), symbol: "bookmark", category: .analyze, enabled: model.canEditDocument, action: model.addBookmark),
            WorkspaceTool(id: "rectangle", title: L10n.tr("Rettangolo"), detail: L10n.tr("Traccia una forma rettangolare sulla pagina."), symbol: "rectangle", category: .markup, enabled: model.canEditAnnotations, action: { model.activeTool = .rectangle }),
            WorkspaceTool(id: "ellipse", title: L10n.tr("Ellisse"), detail: L10n.tr("Traccia una forma ovale sulla pagina."), symbol: "circle", category: .markup, enabled: model.canEditAnnotations, action: { model.activeTool = .ellipse }),
            WorkspaceTool(id: "link", title: L10n.tr("Aggiungi collegamento"), detail: L10n.tr("Crea un’area cliccabile con un indirizzo web."), symbol: "link", category: .markup, enabled: model.canEditAnnotations, action: { model.activeTool = .link }),
            WorkspaceTool(id: "signature", title: L10n.tr("Firma grafica"), detail: L10n.tr("Disegna e inserisci una firma. Senza certificato digitale."), symbol: "signature", category: .markup, enabled: model.canEditAnnotations, action: { model.activeTool = .signature }),
            WorkspaceTool(id: "redact", title: L10n.tr("Oscura area · copia"), detail: L10n.tr("Rimuovi l’area selezionata da una copia interamente rasterizzata."), symbol: "rectangle.fill", category: .protect, enabled: model.canEditDocument && model.canPrint && model.document.allowsCopying, action: { model.activeTool = .redact }),
            WorkspaceTool(id: "password", title: L10n.tr("Proteggi con password"), detail: L10n.tr("Salva una copia cifrata con password di apertura."), symbol: "lock.doc", category: .protect, enabled: model.canEditDocument, action: model.protectPDFCopy),
            WorkspaceTool(id: "metadata", title: L10n.tr("Proprietà documento"), detail: L10n.tr("Modifica titolo, autore, oggetto e parole chiave."), symbol: "info.circle", category: .analyze, enabled: model.canEditDocument, action: model.editMetadata),
            WorkspaceTool(id: "forms", title: L10n.tr("Compila moduli"), detail: L10n.tr("Modifica i campi supportati con salvataggio e annullamento."), symbol: "list.bullet.rectangle", category: .forms, action: {}),
            WorkspaceTool(id: "prepareform", title: L10n.tr("Prepara modulo"), detail: L10n.tr("Aggiungi campi di testo, caselle di controllo ed elenchi."), symbol: "checkmark.square", category: .forms, enabled: model.canEditDocument, action: model.prepareForm),
            WorkspaceTool(id: "compare", title: L10n.tr("Confronta documenti"), detail: L10n.tr("Affianca due PDF e individua le differenze nel testo."), symbol: "doc.on.doc.fill", category: .analyze, action: model.comparePDF)
        ]
    }
}
