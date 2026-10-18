import AppKit
import SwiftUI
import PDFKit
import UniformTypeIdentifiers

private enum SidebarTab: String, CaseIterable {
    case pages = "Pagine", search = "Ricerca", outline = "Indice", annotations = "Note"
}

struct ContentView: View {
    @ObservedObject var model: PDFEditorModel
    @State private var sidebarTab: SidebarTab = .pages
    @State private var pageEntry = "1"
    @State private var showTools = false
    @State private var searchTask: Task<Void, Never>?
    @ObservedObject private var preferences = CartaPreferences.shared
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color {
        colorScheme == .dark ? Color(red: 0.38, green: 0.78, blue: 0.72) : Color(red: 0.13, green: 0.45, blue: 0.43)
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            Divider()
            editingBar
            Divider()
            if model.activeTool == .text || model.selectedAnnotation?.type == "FreeText" {
                textFormattingBar
                Divider()
            }
            HSplitView {
                if model.showSidebar {
                    sidebar
                        .frame(minWidth: 180, idealWidth: preferences.sidebarWidth, maxWidth: 340)
                        .background(GeometryReader { geometry in
                            Color.clear.onChange(of: geometry.size.width) { _, width in
                                let value = min(max(width.rounded(), 180), 340)
                                if abs(preferences.sidebarWidth - value) > 1 { preferences.sidebarWidth = value }
                            }
                        })
                }
                PDFCanvas(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("workspace.document")
                    .overlay(alignment: .top) {
                        if !model.canEditAnnotations {
                            Label(L10n.tr("Documento protetto: annotazioni non consentite"), systemImage: "lock")
                                .font(.caption)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                                .padding(16)
                        }
                    }
            }
            Divider()
            statusBar
        }
        .environment(\.locale, L10n.currentLocale)
        .disabled(model.isProcessing)
        .overlay {
            if model.isProcessing {
                VStack(spacing: 14) {
                    ProgressView(value: model.processingProgress).frame(width: 260)
                        .accessibilityLabel(L10n.tr("Avanzamento elaborazione"))
                        .accessibilityValue(L10n.tr("\(Int(model.processingProgress * 100)) percento"))
                    Text(model.processingMessage ?? L10n.tr("Elaborazione…")).font(.headline)
                    Button(L10n.tr("Annulla elaborazione"), action: model.cancelProcessing)
                        .keyboardShortcut(.cancelAction)
                }
                .padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .tint(accent)
        .frame(minWidth: 880, minHeight: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.currentPageIndex) { _, index in pageEntry = String(index + 1) }
        .onAppear { pageEntry = String(model.currentPageIndex + 1) }
        .onChange(of: model.statusMessage) { _, message in
            if let message { CartaAccessibility.announce(message, in: model.pdfView?.window) }
        }
        .onChange(of: model.isSearching) { old, searching in
            if old && !searching { CartaAccessibility.announce(L10n.tr("Ricerca completata: \(model.searchResults.count) risultati."), in: model.pdfView?.window) }
        }
        .onChange(of: model.isProcessing) { _, busy in
            CartaAccessibility.announce(busy ? model.processingMessage ?? L10n.tr("Elaborazione avviata.") : L10n.tr("Elaborazione terminata."), in: model.pdfView?.window)
        }
        .sheet(isPresented: $showTools) {
            ToolBrowserView(model: model)
        }
        .onReceive(NotificationCenter.default.publisher(for: .cartaShowTools)) { notification in
            if notification.object as? PDFEditorModel === model { showTools = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cartaFocusSearch)) { notification in
            guard notification.object as? PDFEditorModel === model else { return }
            model.showSidebar = true
            sidebarTab = .search
            searchFocused = false
            DispatchQueue.main.async {
                searchFocused = true
                DispatchQueue.main.async {
                    if let editor = model.pdfView?.window?.firstResponder as? NSTextView, editor.isFieldEditor,
                       editor.string == model.searchQuery { editor.selectAll(nil) }
                }
            }
        }
        .alert(L10n.tr("Impossibile completare l’operazione"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button(L10n.tr("OK"), role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .onDrop(of: [UTType.fileURL], isTargeted: nil, perform: openDroppedPDFs)
    }

    private var navigationBar: some View {
        ViewThatFits(in: .horizontal) {
            fullNavigationBar
            compactNavigationBar
        }
    }

    private var compactNavigationBar: some View {
        HStack(spacing: 14) {
            Button { NSDocumentController.shared.openDocument(nil) } label: { Label(L10n.tr("Apri"), systemImage: "folder") }
            iconButton(L10n.tr("Pagine"), "sidebar.left") { model.showSidebar.toggle() }
            iconButton(L10n.tr("Pagina precedente (⌘[)"), "chevron.left", action: model.previousPage)
                .disabled(model.currentPageIndex == 0)
            Text(L10n.tr("\(model.currentPageIndex + 1) / \(model.pageCount)")).monospacedDigit()
                .accessibilityLabel(L10n.tr("Pagina \(model.currentPageIndex + 1) di \(model.pageCount)"))
            iconButton(L10n.tr("Pagina successiva (⌘])"), "chevron.right", action: model.nextPage)
                .disabled(model.currentPageIndex + 1 >= model.pageCount)
            Spacer()
            Label(model.activeTool.title, systemImage: model.activeTool.symbol).font(.caption)
                .accessibilityLabel(L10n.tr("Strumento attivo: \(model.activeTool.title)"))
            Menu(L10n.tr("\(Int(model.scale * 100))%")) {
                Button(L10n.tr("Ingrandisci (⌘+)"), action: model.zoomIn)
                Button(L10n.tr("Riduci (⌘−)"), action: model.zoomOut)
                Button(L10n.tr("Adatta (⌘0)"), action: model.fitToWindow)
            }.fixedSize().accessibilityLabel(L10n.tr("Zoom documento")).accessibilityValue(L10n.tr("\(Int(model.scale * 100)) percento"))
            Button { showTools = true } label: { Label(L10n.tr("Strumenti"), systemImage: "square.grid.2x2") }
            Button(action: model.save) { Image(systemName: "square.and.arrow.down") }.accessibilityLabel(L10n.tr("Salva (⌘S)"))
        }.buttonStyle(.borderless).padding(14)
    }

    private var fullNavigationBar: some View {
        HStack(spacing: 14) {
            Button {
                NSDocumentController.shared.openDocument(nil)
            } label: { Label(L10n.tr("Apri"), systemImage: "folder") }
                .help(L10n.tr("Apri un PDF (⌘O)"))
            Button {
                model.showSidebar.toggle()
            } label: { Image(systemName: "sidebar.left") }
                .help(L10n.tr("Mostra o nascondi la barra laterale"))
                .accessibilityLabel(L10n.tr("Mostra o nascondi pagine"))
            Divider().frame(height: 24)
            HStack(spacing: 5) {
                iconButton(L10n.tr("Pagina precedente"), "chevron.left", action: model.previousPage)
                    .disabled(model.currentPageIndex == 0)
                TextField(L10n.tr("Pagina"), text: $pageEntry)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 42)
                    .onSubmit {
                        if let value = Int(pageEntry), (1...max(1, model.pageCount)).contains(value) {
                            model.goToPage(value - 1)
                        } else {
                            model.statusMessage = L10n.tr("Inserisci un numero di pagina da 1 a \(model.pageCount).")
                        }
                        pageEntry = String(model.currentPageIndex + 1)
                    }
                    .accessibilityLabel(L10n.tr("Numero di pagina"))
                    .accessibilityHint(L10n.tr("Scrivi un numero da 1 a \(model.pageCount) e premi Invio."))
                Text(L10n.tr("/ \(model.pageCount)")).foregroundStyle(.secondary).monospacedDigit()
                iconButton(L10n.tr("Pagina successiva"), "chevron.right", action: model.nextPage)
                    .disabled(model.currentPageIndex + 1 >= model.pageCount)
            }
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                iconButton(L10n.tr("Riduci (⌘−)"), "minus", action: model.zoomOut)
                Menu {
                    Button(L10n.tr("Adatta alla finestra"), action: model.fitToWindow)
                    Button(L10n.tr("Dimensioni reali (100%)"), action: model.actualSize)
                } label: {
                    Text(L10n.tr("\(Int(model.scale * 100))%"))
                        .monospacedDigit().frame(width: 52)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(L10n.tr("Zoom documento"))
                .accessibilityValue(L10n.tr("\(Int(model.scale * 100)) percento"))
                iconButton(L10n.tr("Ingrandisci (⌘+)"), "plus", action: model.zoomIn)
            }
            Menu {
                Button(L10n.tr("Scorrimento verticale")) { model.displayMode = .singlePageContinuous }
                Button(L10n.tr("Una pagina alla volta")) { model.displayMode = .singlePage }
                Button(L10n.tr("Due pagine affiancate")) { model.displayMode = .twoUpContinuous }
            } label: { Image(systemName: "rectangle.split.2x1") }
                .menuStyle(.borderlessButton).frame(width: 24)
                .help(L10n.tr("Disposizione pagine"))
                .accessibilityLabel(L10n.tr("Disposizione pagine"))
            Button(action: model.fitToWindow) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }.help(L10n.tr("Adatta alla finestra (⌘0)")).accessibilityLabel(L10n.tr("Adatta alla finestra"))
            Divider().frame(height: 24)
            Button { showTools = true } label: { Label(L10n.tr("Strumenti"), systemImage: "square.grid.2x2") }
                .help(L10n.tr("Tutti gli strumenti (⇧⌘T)"))
            Button(action: model.save) { Label(L10n.tr("Salva"), systemImage: "square.and.arrow.down") }
                .buttonStyle(.borderedProminent)
                .help(L10n.tr("Salva il documento (⌘S)"))
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var editingBar: some View {
        ViewThatFits(in: .horizontal) {
            editingBarContent(compact: false)
            editingBarContent(compact: true)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private func editingBarContent(compact: Bool) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach([EditorTool.select, .note, .text, .draw, .erase]) { tool in
                    Button { model.activeTool = tool } label: {
                        Group {
                            if compact { Image(systemName: tool.symbol) }
                            else { Label(tool.title, systemImage: tool.symbol).fixedSize() }
                        }
                            .font(.system(size: 12, weight: model.activeTool == tool ? .semibold : .regular))
                            .padding(.horizontal, 9).padding(.vertical, 7)
                            .background(model.activeTool == tool ? accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(model.activeTool == tool ? accent : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .disabled(tool != .select && !model.canEditAnnotations)
                    .help(tool.hint)
                    .accessibilityLabel(tool.title)
                    .accessibilityAddTraits(model.activeTool == tool ? .isSelected : [])
                    .accessibilityValue(model.activeTool == tool ? L10n.tr("Attivo") : "")
                }
            }
            Divider().frame(height: 22)
            Button(action: model.highlightSelection) {
                if compact { Image(systemName: "highlighter") }
                else { Label(L10n.tr("Evidenzia"), systemImage: "highlighter").fixedSize() }
            }
            .disabled(!model.canEditAnnotations || (model.pdfView?.currentSelection?.string ?? "").isEmpty)
            .accessibilityLabel(L10n.tr("Evidenzia"))
            .help(L10n.tr("Evidenzia il testo selezionato (⇧⌘H)"))
            if model.activeTool != .text { colorPalette }
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                iconButton(L10n.tr("Annulla (⌘Z)"), "arrow.uturn.backward", action: model.undo).disabled(!model.canUndo)
                iconButton(L10n.tr("Ripristina (⇧⌘Z)"), "arrow.uturn.forward", action: model.redo).disabled(!model.canRedo)
            }
            Divider().frame(height: 22)
            Menu {
                Button(L10n.tr("Ruota pagina a destra"), action: model.rotateCurrentPage)
                    .disabled(!model.canEditPages)
                Button(L10n.tr("Inserisci pagine da PDF…"), action: model.insertPDF)
                    .disabled(!model.canEditPages)
                Divider()
                Button(L10n.tr("Elimina pagina"), role: .destructive, action: model.deleteCurrentPage)
                    .disabled(!model.canEditPages || model.pageCount <= 1)
            } label: {
                if compact { Image(systemName: "doc.on.doc") }
                else { Label(L10n.tr("Pagine"), systemImage: "doc.on.doc") }
            }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel(L10n.tr("Pagine"))
        }
    }

    private var colorPalette: some View {
        HStack(spacing: 6) {
            ForEach(Array(annotationColors.enumerated()), id: \.offset) { index, item in
                Button { model.annotationColor = item.color } label: {
                    Circle().fill(Color(nsColor: item.color))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.black.opacity(0.14), lineWidth: 1))
                        .padding(3)
                        .overlay(Circle().stroke(model.annotationColor.isEqual(item.color) ? accent : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .help(item.name)
                .accessibilityLabel(L10n.tr("Colore \(item.name)"))
                .accessibilityAddTraits(model.annotationColor.isEqual(item.color) ? .isSelected : [])
                .accessibilityHint(L10n.tr("Seleziona il colore. Scorciatoia Comando Maiuscole \(index + 1)."))
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .shift])
                .focusable()
            }
        }
    }

    private var textFormattingBar: some View {
        HStack(spacing: 14) {
            Text(model.selectedAnnotation?.type == "FreeText" ? L10n.tr("Testo selezionato") : L10n.tr("Nuovo testo")).font(.caption).foregroundStyle(.secondary)
            Picker(L10n.tr("Carattere"), selection: $model.textFontName) {
                Text("Helvetica").tag("Helvetica")
                Text("Times").tag("Times-Roman")
                Text("Courier").tag("Courier")
            }.labelsHidden().frame(width: 125).accessibilityLabel(L10n.tr("Carattere del testo"))
            Menu {
                ForEach([10, 12, 14, 18, 24, 32, 48, 72], id: \.self) { size in
                    Button(L10n.tr("\(size) pt")) { model.textFontSize = CGFloat(size) }
                }
            } label: { Text(L10n.tr("\(Int(model.textFontSize)) pt")).monospacedDigit() }
                .frame(width: 70)
                .accessibilityLabel(L10n.tr("Dimensione del testo"))
                .accessibilityValue(L10n.tr("\(Int(model.textFontSize)) punti"))
            ColorPicker(L10n.tr("Colore"), selection: Binding(
                get: { Color(nsColor: model.textColor) },
                set: { model.textColor = NSColor($0).usingColorSpace(.deviceRGB) ?? .black }
            ), supportsOpacity: false)
                .fixedSize()
            if model.selectedAnnotation?.type == "FreeText" {
                Button(L10n.tr("Applica stile"), action: model.applySelectedTextStyle)
            }
            Spacer()
        }.padding(.horizontal, 20).padding(.vertical, 6)
    }

    private var annotationColors: [(name: String, color: NSColor)] {
        [(L10n.tr("Giallo"), .systemYellow), (L10n.tr("Corallo"), .systemRed), (L10n.tr("Verde"), .systemGreen), (L10n.tr("Blu"), .systemBlue), (L10n.tr("Grafite"), .black)]
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                Picker(L10n.tr("Barra laterale"), selection: $sidebarTab) {
                    ForEach(SidebarTab.allCases, id: \.self) { Text(L10n.string($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
                Picker(L10n.tr("Barra laterale"), selection: $sidebarTab) {
                    ForEach(SidebarTab.allCases, id: \.self) { Text(L10n.string($0.rawValue)).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityLabel(L10n.tr("Contenuto della barra laterale"))
            .padding(12)
            if sidebarTab == .pages {
                HStack {
                    Text(L10n.tr("\(model.pageCount) \(model.pageCount == 1 ? L10n.tr("PAGINA") : L10n.tr("PAGINE"))"))
                        .font(.system(size: 10, weight: .semibold)).tracking(1.2)
                    Spacer()
                    Image(systemName: "square.grid.1x2").accessibilityHidden(true)
                }.foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 10)
                CartaThumbnailSidebar(model: model)
            } else if sidebarTab == .search {
                searchPanel
            } else {
                DocumentNavigationView(model: model, showOutline: sidebarTab == .outline)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.35))
    }

    private var searchPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(L10n.tr("Cerca nel documento"), text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { searchTask?.cancel(); model.search() }
                    .onChange(of: model.searchQuery) { _, query in
                        searchTask?.cancel()
                        guard preferences.searchAsYouType else { return }
                        searchTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(320))
                            guard !Task.isCancelled, query == model.searchQuery else { return }
                            model.search()
                        }
                    }
                if !model.searchQuery.isEmpty {
                    Button {
                        model.searchQuery = ""
                        model.search()
                    } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel(L10n.tr("Cancella ricerca"))
                }
            }
            .padding(9)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 12)
            HStack {
                if model.isSearching {
                    ProgressView().controlSize(.small)
                    Text(L10n.tr("Ricerca…"))
                } else {
                    Text(L10n.tr("\(model.searchResults.count) risultati"))
                }
                Spacer()
                iconButton(L10n.tr("Risultato precedente"), "chevron.up", action: model.previousSearchResult)
                    .disabled(model.searchResults.isEmpty)
                iconButton(L10n.tr("Risultato successivo"), "chevron.down", action: model.nextSearchResult)
                    .disabled(model.searchResults.isEmpty)
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
            if model.searchResults.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.magnifyingglass").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(L10n.tr("Inserisci una parola e premi Invio.")).font(.callout)
                    Text(L10n.tr("La ricerca funziona nei PDF con testo selezionabile.")).font(.caption).foregroundStyle(.secondary)
                    if (model.currentPage?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button(L10n.tr("Riconosci il testo con OCR"), action: model.runOCR)
                    }
                }
                .multilineTextAlignment(.center).padding(18)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(Array(model.searchResults.enumerated()), id: \.offset) { index, selection in
                            Button {
                                model.chooseSearchResult(index)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(pageLabel(for: selection)).font(.caption).foregroundStyle(accent)
                                    Text(model.searchSnippet(for: selection)).font(.callout).lineLimit(3).foregroundStyle(.primary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(index == model.searchResultIndex ? accent.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel(L10n.tr("Risultato \(index + 1) di \(model.searchResults.count), \(pageLabel(for: selection)): \(model.searchSnippet(for: selection))"))
                                .accessibilityAddTraits(index == model.searchResultIndex ? .isSelected : [])
                                .accessibilityHint(L10n.tr("Mostra il testo nel documento conservando lo zoom."))
                        }
                    }.padding(.horizontal, 10)
                }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Image(systemName: model.activeTool.symbol).foregroundStyle(accent).accessibilityHidden(true)
            Text(model.statusMessage ?? model.activeTool.hint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if model.document.isEncrypted {
                Image(systemName: "lock.open").help(L10n.tr("PDF cifrato sbloccato"))
                    .accessibilityLabel(L10n.tr("PDF cifrato, attualmente sbloccato"))
            }
            Text(L10n.tr("Pagina \(model.currentPageIndex + 1) di \(model.pageCount)")).monospacedDigit().fixedSize()
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 18).padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workspace.status")
    }

    private func iconButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 19, height: 20).contentShape(Rectangle())
        }.buttonStyle(.borderless).help(title).accessibilityLabel(title).focusable()
    }

    private func pageLabel(for selection: PDFSelection) -> String {
        guard let page = selection.pages.first else { return L10n.tr("Risultato") }
        let index = model.document.index(for: page)
        return index == NSNotFound ? L10n.tr("Risultato") : L10n.tr("Pagina \(index + 1)")
    }

    private func openDroppedPDFs(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    guard url.pathExtension.lowercased() == "pdf" else {
                        model.errorMessage = L10n.tr("Trascina un file con estensione .pdf.")
                        return
                    }
                    NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                        if let error { NSApp.presentError(error) }
                    }
                }
            }
        }
        return true
    }
}
