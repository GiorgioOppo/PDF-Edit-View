import AppKit
import SwiftUI

enum PDFStructureSection: String, CaseIterable {
    case structure = "Struttura", originalContent = "Contenuto originale", preflight = "Preflight e standard", certificates = "Certificati e firme"
    var symbol: String {
        switch self { case .structure: return "square.stack.3d.up"; case .originalContent: return "doc.text.magnifyingglass"
        case .preflight: return "checklist"; case .certificates: return "checkmark.seal" }
    }
}

@MainActor
struct PDFStructureWorkspaceView: View {
    @ObservedObject var state: PDFStructureWorkspaceState
    @State private var section: PDFStructureSection
    init(state: PDFStructureWorkspaceState, initialSection: PDFStructureSection) {
        self.state = state; _section = State(initialValue: initialSection)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(state.sourceName, systemImage: "doc.richtext").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Text(L10n.tr("\(state.pageCount) pagine")).foregroundStyle(.secondary)
            }
            Text(L10n.tr("Lavora su uno snapshot e salva copie separate. Le revisioni incrementali conservano i dati precedenti: la modifica del testo e la rimozione di allegati non sono strumenti di oscuramento."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if state.encrypted {
                Label(L10n.tr("PDF cifrato: modifiche strutturali e lettura dei contenuti disabilitate per preservare la protezione."), systemImage: "lock")
                    .font(.callout).foregroundStyle(.orange)
            }
            TabView(selection: $section) {
                PDFStructurePanel(state: state).tabItem { Label(L10n.string(PDFStructureSection.structure.rawValue), systemImage: PDFStructureSection.structure.symbol) }.tag(PDFStructureSection.structure)
                PDFOriginalContentPanel(state: state).tabItem { Label(L10n.string(PDFStructureSection.originalContent.rawValue), systemImage: PDFStructureSection.originalContent.symbol) }.tag(PDFStructureSection.originalContent)
                PDFPreflightPanel(state: state).tabItem { Label(L10n.string(PDFStructureSection.preflight.rawValue), systemImage: PDFStructureSection.preflight.symbol) }.tag(PDFStructureSection.preflight)
                PDFCertificatePanel(state: state).tabItem { Label(L10n.string(PDFStructureSection.certificates.rawValue), systemImage: PDFStructureSection.certificates.symbol) }.tag(PDFStructureSection.certificates)
            }
            .disabled(state.isWriting).accessibilityLabel(L10n.tr("Strumenti struttura PDF"))
            if state.isWriting {
                HStack { ProgressView().controlSize(.small).accessibilityLabel(L10n.tr("Elaborazione struttura PDF in corso")); Text(state.jobMessage).font(.caption); Spacer(); Button(L10n.tr("Annulla"), action: state.cancelWrite).keyboardShortcut(.cancelAction).accessibilityLabel(L10n.tr("Annulla elaborazione struttura PDF")) }
            }
            if let status = state.status { CartaPanelAccessibilityStatus(message: status, label: L10n.tr("Stato struttura PDF"), announce: !state.isWriting, announceOnAppear: true).font(.caption).foregroundStyle(.secondary) }
        }.padding(18).frame(minWidth: 820, minHeight: 600).accessibilityIdentifier("panel.structure")
            .alert(L10n.tr("Operazione non completata"), isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) {
                Button(L10n.tr("OK"), role: .cancel) { state.error = nil }
            } message: { Text(state.error ?? "") }
    }
}

@MainActor
private struct PDFStructurePanel: View {
    @ObservedObject var state: PDFStructureWorkspaceState
    @State private var startPage = 1
    @State private var firstNumber = 1
    @State private var prefix = ""
    @State private var style = PDFStructureDocument.PageLabelStyle.decimal
    @State private var attachmentID: PDFObjectID?
    @State private var imageID: PDFObjectID?
    private var attachment: PDFEmbeddedFile? { state.attachments.first { $0.id == attachmentID } }
    private var image: PDFEmbeddedImage? { state.images.first { $0.id == imageID } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox(L10n.tr("Numerazione logica delle sezioni")) {
                    HStack {
                        Stepper(L10n.tr("Dalla pagina \(startPage)"), value: $startPage, in: 1...max(1, state.pageCount)).frame(width: 190).accessibilityLabel(L10n.tr("Pagina iniziale della sezione logica")).accessibilityValue(L10n.tr("\(startPage) di \(state.pageCount)"))
                        Stepper(L10n.tr("Primo numero \(firstNumber)"), value: $firstNumber, in: 1...100_000).frame(width: 210).accessibilityLabel(L10n.tr("Primo numero logico della sezione")).accessibilityValue(L10n.tr("\(firstNumber)"))
                        TextField(L10n.tr("Prefisso"), text: $prefix).frame(width: 110).accessibilityLabel(L10n.tr("Prefisso della numerazione logica"))
                        Picker(L10n.tr("Stile"), selection: $style) { ForEach(PDFStructureDocument.PageLabelStyle.allCases) { Text($0.title).tag($0) } }.frame(width: 180)
                        Spacer(minLength: 0)
                    }.padding(8)
                    HStack {
                        Text(L10n.tr("Modifica PageLabels; non stampa numeri sulla pagina. Le altre sezioni vengono conservate.")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.tr("Salva copia numerata")) { state.setLabels(startPage: startPage - 1, number: firstNumber, prefix: prefix, style: style) }.disabled(state.encrypted)
                    }.padding(8)
                }
                GroupBox(L10n.tr("Allegati incorporati e portfolio PDF")) {
                    VStack(alignment: .leading, spacing: 10) {
                        List(state.attachments, selection: $attachmentID) { file in
                            HStack { Image(systemName: "paperclip").accessibilityHidden(true); Text(file.name); Spacer(); Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)).foregroundStyle(.secondary) }.tag(file.id).accessibilityElement(children: .combine)
                        }.frame(height: 125).accessibilityLabel(L10n.tr("Allegati incorporati, \(state.attachments.count) file"))
                        HStack {
                            Button(L10n.tr("Aggiungi file…")) { state.chooseAttachments(portfolio: false) }.disabled(state.encrypted)
                            Button(L10n.tr("Estrai selezionato…")) { if let attachment { state.exportAttachment(attachment) } }.disabled(attachment == nil).accessibilityValue(attachment?.name ?? L10n.tr("Nessun allegato selezionato"))
                            Button(L10n.tr("Rimuovi nella copia…")) { if let attachment { state.deleteAttachment(attachment) } }.disabled(attachment == nil || state.encrypted).accessibilityValue(attachment?.name ?? L10n.tr("Nessun allegato selezionato")).accessibilityHint(L10n.tr("Rimuove il riferimento nella nuova copia; le revisioni precedenti conservano i dati."))
                            Spacer()
                            Button(L10n.tr("Nuovo portfolio da file…")) { state.chooseAttachments(portfolio: true) }
                        }
                        Text(L10n.tr("Il portfolio contiene una pagina indice, una Collection e i file originali incorporati. La rimozione incrementale elimina il riferimento, ma conserva le vecchie revisioni: non è una cancellazione sicura."))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox(L10n.tr("Immagini incorporate alla risoluzione originale")) {
                    VStack(alignment: .leading, spacing: 10) {
                        List(state.images, selection: $imageID) { item in Text(item.description).tag(item.id) }.frame(height: 110).accessibilityLabel(L10n.tr("Immagini incorporate, \(state.images.count) oggetti"))
                        HStack {
                            Button(L10n.tr("Estrai immagine…")) { if let image { state.exportImage(image) } }.disabled(image == nil).accessibilityValue(image?.description ?? L10n.tr("Nessuna immagine selezionata"))
                            Text(L10n.tr("JPEG/JPX: byte originali. Bitmap RGB/grigie compatibili: PNG lossless. Maschere e altri formati non vengono simulati."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(8)
                }
                GroupBox(L10n.tr("Visibilità dei livelli PDF")) {
                    VStack(alignment: .leading, spacing: 8) {
                        if state.layers.isEmpty { Text(L10n.tr("Il catalogo non contiene gruppi opzionali OCG.")).foregroundStyle(.secondary) }
                        ForEach(state.layers) { layer in
                            HStack {
                                Image(systemName: layer.visible ? "eye" : "eye.slash").accessibilityHidden(true)
                                Text(layer.name).accessibilityLabel(L10n.tr("Livello \(layer.name)")).accessibilityValue(layer.visible ? L10n.tr("Visibile") : L10n.tr("Nascosto")); Spacer()
                                Button(layer.visible ? L10n.tr("Salva copia con livello nascosto") : L10n.tr("Salva copia con livello visibile")) { state.changeLayer(layer, visible: !layer.visible) }
                                    .disabled(state.encrypted).accessibilityLabel(L10n.tr("Salva copia con livello \(layer.name) \(layer.visible ? L10n.tr("nascosto") : L10n.tr("visibile"))"))
                            }
                        }
                        Text(L10n.tr("Modifica lo stato ON/OFF della configurazione predefinita. Il contenuto nascosto resta nel PDF e può essere riattivato da un lettore compatibile."))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
            }.padding(12)
        }.accessibilityIdentifier("panel.structure.objects")
    }
}

@MainActor
private struct PDFOriginalContentPanel: View {
    @ObservedObject var state: PDFStructureWorkspaceState
    @State private var runID: String?
    @State private var replacement = ""
    @State private var imageID: PDFObjectID?
    private var run: PDFOriginalTextRun? { state.runs.first { $0.id == runID } }
    private var image: PDFEmbeddedImage? { state.images.first { $0.id == imageID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox(L10n.tr("Modifica effettiva del testo nel content stream")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.tr("Supporta stringhe Tj, ' e \" con font Type1 standard e codifica WinAnsi esplicita. Font incorporati/CID/subset, ToUnicode personalizzato, kerning TJ e immagini inline non vengono riscritti. Si modifica l’operando originale senza annotazioni; niente reflow. Gli stream condivisi vengono modificati in tutti i loro utilizzi."))
                        .font(.caption).foregroundStyle(.secondary)
                    if let limit = state.originalTextLimit { Text(limit).font(.caption).foregroundStyle(.orange) }
                    List(state.runs, selection: $runID) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.tr("Pagina \(item.pageIndex + 1) · \(item.font)")).font(.caption).foregroundStyle(.secondary)
                            Text(item.text).lineLimit(2)
                        }.tag(item.id).accessibilityElement(children: .combine)
                    }.frame(minHeight: 140).accessibilityLabel(L10n.tr("Stringhe di testo originale compatibili, \(state.runs.count) elementi"))
                    if state.runs.isEmpty { Text(L10n.tr("Nessuna stringa originale compatibile trovata in questo PDF.")).foregroundStyle(.secondary) }
                    HStack {
                        TextField(L10n.tr("Testo sostitutivo"), text: $replacement).accessibilityLabel(L10n.tr("Testo sostitutivo della stringa originale selezionata")).accessibilityHint(L10n.tr("Modifica l’operando originale, senza reimpaginazione; gli utilizzi condivisi cambiano insieme."))
                        Button(L10n.tr("Salva copia modificata")) { if let run { state.replaceText(run, text: replacement) } }.disabled(run == nil || state.encrypted).accessibilityHint(run == nil ? L10n.tr("Seleziona prima una stringa compatibile.") : L10n.tr("Salva una nuova copia con la stringa selezionata modificata."))
                    }
                }.padding(8)
            }
            GroupBox(L10n.tr("Sostituzione effettiva di un oggetto immagine")) {
                VStack(alignment: .leading, spacing: 10) {
                    List(state.images, selection: $imageID) { item in Text(item.description).tag(item.id) }.frame(height: 150).accessibilityLabel(L10n.tr("Immagini originali sostituibili, \(state.images.count) oggetti"))
                    HStack {
                        Button(L10n.tr("Scegli immagine sostitutiva…")) { if let image { state.chooseReplacementImage(image) } }.disabled(image == nil || state.encrypted).accessibilityValue(image?.description ?? L10n.tr("Nessuna immagine selezionata"))
                        Text(L10n.tr("Sostituisce l’XObject in tutti i suoi utilizzi. Le posizioni sulla pagina restano uguali; la nuova immagine viene composta su bianco.")).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(8)
            }
            Spacer(minLength: 0)
        }.padding(12).onChange(of: runID) { replacement = run?.text ?? "" }.accessibilityIdentifier("panel.structure.original")
    }
}

@MainActor
private struct PDFPreflightPanel: View {
    @ObservedObject var state: PDFStructureWorkspaceState
    @State private var language = "it-IT"
    @State private var role = "Figure"
    @State private var descriptions = ""
    private var lines: [String] { descriptions.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) } }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L10n.tr("Controlli effettivi della struttura")).font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button(L10n.tr("Esporta rapporto…"), action: state.exportReport)
                }
                List(state.report) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Label(item.title, systemImage: item.severity == "errore" ? "xmark.circle" : item.severity == "avviso" ? "exclamationmark.triangle" : "info.circle")
                            .font(.headline).foregroundStyle(item.severity == "errore" ? Color.red : item.severity == "avviso" ? Color.orange : Color.primary)
                        Text(item.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(.vertical, 4).accessibilityElement(children: .combine).accessibilityLabel(L10n.tr("\(L10n.string(item.severity)): \(item.title)")).accessibilityValue(item.detail)
                }.accessibilityLabel(L10n.tr("Rapporto preflight, \(state.report.count) risultati"))
            }.frame(minWidth: 360)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox(L10n.tr("Archiviazione PDF/A")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L10n.tr("CoreGraphics genera una copia archivistica; il profilo effettivo viene letto dai metadati del risultato. Le pagine vengono ridisegnate: moduli/annotazioni vengono appiattiti; allegati, livelli e firme digitali non sono trasferiti. Apri Validazione PDF/A per scegliere il profilo e leggere le clausole non verificate."))
                            Button(L10n.tr("Apri validazione PDF/A…"), action: state.showArchiveValidationWorkspace)
                                .accessibilityHint(L10n.tr("Apre il rapporto locale per uno degli undici profili ISO PDF/A."))
                                .font(.caption).foregroundStyle(.secondary)
                            Button(L10n.tr("Genera copia archivistica PDF/A…"), action: state.makeArchivalCopy).disabled(state.encrypted)
                        }.padding(8)
                    }
                    GroupBox(L10n.tr("Preparazione colore per PDF/X")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L10n.tr("Inserisce un intento di output con un profilo ICC CMYK locale e ridisegna il documento. Non sostituisce tutte le separazioni colore e non dichiara conformità ISO 15930."))
                                .font(.caption).foregroundStyle(.secondary)
                            Button(L10n.tr("Scegli profilo ICC e prepara copia…"), action: state.preparePrintProfile).disabled(state.encrypted)
                        }.padding(8)
                    }
                    GroupBox(L10n.tr("Tag di accessibilità per pagina")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L10n.tr("Autore una struttura reale con un elemento per pagina, nell’ordine del documento. Per grafici/scansioni scegli Figura e scrivi un’alternativa significativa. Non crea automaticamente un ordine di lettura tra i blocchi e non certifica PDF/UA. Le strutture già presenti vengono preservate, senza sovrascriverle."))
                                .font(.caption).foregroundStyle(.secondary)
                            TextField(L10n.tr("Lingua BCP-47"), text: $language).accessibilityLabel(L10n.tr("Lingua del documento per i tag di accessibilità")).accessibilityHint(L10n.tr("Codice BCP 47, ad esempio it trattino IT."))
                            Picker(L10n.tr("Ruolo"), selection: $role) {
                                Text(L10n.tr("Figura, pagina intera")).tag("Figure")
                                Text(L10n.tr("Paragrafo, pagina intera")).tag("P")
                                Text(L10n.tr("Titolo H1, pagina intera")).tag("H1")
                                Text(L10n.tr("Titolo H2, pagina intera")).tag("H2")
                            }
                            Text(L10n.tr("Una descrizione per riga, per tutte le \(state.pageCount) pagine.")).font(.caption)
                            TextEditor(text: $descriptions).frame(height: 130).border(Color.secondary.opacity(0.25)).accessibilityLabel(L10n.tr("Descrizioni alternative delle pagine"))
                                .accessibilityHint(L10n.tr("Una descrizione non vuota per ogni pagina, nell’ordine del PDF. \(lines.count) righe inserite per \(state.pageCount) pagine."))
                            Button(L10n.tr("Salva copia con tag accessibili…")) { state.authorTags(language: language, role: role, descriptions: lines) }
                                .disabled(state.encrypted || language.isEmpty || lines.count != state.pageCount || lines.contains(where: \.isEmpty))
                                .accessibilityHint(L10n.tr("Richiede lingua e \(state.pageCount) descrizioni non vuote, una per riga; il PDF cifrato non è modificabile qui."))
                        }.padding(8)
                    }
                }.padding(.leading, 12)
            }.frame(minWidth: 360, idealWidth: 420)
        }.padding(12).accessibilityIdentifier("panel.structure.preflight")
    }
}

@MainActor
private struct PDFCertificatePanel: View {
    @ObservedObject var state: PDFStructureWorkspaceState
    @State private var identityID = ""
    @State private var reason = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(L10n.tr("Firma con certificato e chiave privata locali")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.tr("Crea una firma PDF CMS SHA-256 con ByteRange e controlla subito l’integrità. Usa il Portachiavi locale; il sistema può chiedere accesso alla chiave privata. Nessun server, timestamp remoto o firma qualificata. Il certificato incorporato è quello del firmatario; non vengono recuperate catene online."))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(L10n.tr("Leggi identità dal Portachiavi"), action: state.loadIdentities)
                        Picker(L10n.tr("Identità"), selection: $identityID) {
                            Text(L10n.tr("Seleziona un certificato")).tag("")
                            ForEach(state.identities) { identity in Text(identity.name + " · " + identity.id.prefix(10)).tag(identity.id) }
                        }
                    }
                    TextField(L10n.tr("Motivo della firma"), text: $reason).accessibilityLabel(L10n.tr("Motivo della firma digitale della copia"))
                    Button(L10n.tr("Firma e salva una copia…")) { state.sign(identityID: identityID, reason: reason) }.disabled(identityID.isEmpty || state.encrypted)
                    if state.identities.isEmpty { Text(L10n.tr("Sono necessarie un’identità esistente e la relativa chiave privata. L’app non crea certificati o identità nel Portachiavi.")).font(.caption).foregroundStyle(.secondary) }
                }.padding(8)
            }
            HStack {
                Text(L10n.tr("Verifica offline delle firme")).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(L10n.tr("Verifica snapshot"), action: state.verifySignatures).disabled(state.encrypted)
                Button(L10n.tr("Scegli un PDF da verificare…"), action: state.chooseFileToVerify)
            }
            Text(L10n.tr("I file puliti vengono verificati sui byte originali su disco. Uno snapshot con modifiche può invalidare le firme precedenti. La verifica locale distingue integrità, fiducia del Portachiavi e modifiche successive; OCSP/CRL e validità qualificata non vengono attestate."))
                .font(.caption).foregroundStyle(.secondary)
            List(state.signatures) { signature in
                VStack(alignment: .leading, spacing: 5) {
                    Label(signature.signer, systemImage: signature.integrityValid ? "checkmark.seal" : "xmark.seal")
                        .font(.headline).foregroundStyle(signature.integrityValid ? .green : .red)
                        .accessibilityLabel(L10n.tr("Firmatario \(signature.signer)")).accessibilityValue(signature.integrityValid ? L10n.tr("Integrità della firma valida") : L10n.tr("Integrità della firma non valida"))
                    Text(signature.detail).font(.caption)
                    Text(L10n.tr("Revisione firmata: \(signature.signedRevisionBytes) byte · byte successivi non firmati: \(signature.bytesAfterSignature)"))
                        .font(.caption).foregroundStyle(signature.bytesAfterSignature > 0 ? .orange : .secondary)
                    if !signature.digest.isEmpty { Text(L10n.tr("SHA-256 dei byte firmati: ") + signature.digest).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }
                }.padding(.vertical, 5).accessibilityElement(children: .contain)
            }.accessibilityLabel(L10n.tr("Firme verificate, \(state.signatures.count) risultati"))
        }.padding(12).accessibilityIdentifier("panel.structure.certificates")
    }
}
