import AppKit
import PDFKit
import Darwin

enum EditorTool: String, CaseIterable, Identifiable {
    case select, note, text, draw, erase, rectangle, ellipse, redact, link, signature

    var id: String { rawValue }
    var title: String {
        switch self {
        case .select: return L10n.tr("Seleziona")
        case .note: return L10n.tr("Nota")
        case .text: return L10n.tr("Testo")
        case .draw: return L10n.tr("Disegna")
        case .erase: return L10n.tr("Gomma")
        case .rectangle: return L10n.tr("Rettangolo")
        case .ellipse: return L10n.tr("Ellisse")
        case .redact: return L10n.tr("Oscura area")
        case .link: return L10n.tr("Collegamento")
        case .signature: return L10n.tr("Firma grafica")
        }
    }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .note: return "note.text"
        case .text: return "textformat"
        case .draw: return "pencil.tip"
        case .erase: return "eraser"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .redact: return "rectangle.fill"
        case .link: return "link"
        case .signature: return "signature"
        }
    }
    var hint: String {
        switch self {
        case .select: return L10n.tr("Seleziona il testo per copiarlo o evidenziarlo. Doppio clic su una nota o un testo aggiunto per modificarlo.")
        case .note: return L10n.tr("Fai clic sulla pagina per aggiungere una nota.")
        case .text: return L10n.tr("Fai clic sulla pagina per aggiungere un riquadro di testo.")
        case .draw: return L10n.tr("Trascina sulla pagina per disegnare a mano libera.")
        case .erase: return L10n.tr("Fai clic su un’annotazione per eliminarla.")
        case .rectangle, .ellipse: return L10n.tr("Trascina sulla pagina per aggiungere una forma.")
        case .redact: return L10n.tr("Trascina sull’area da oscurare per creare una copia rasterizzata senza contenuto originale recuperabile.")
        case .link: return L10n.tr("Trascina sulla pagina per creare un collegamento web.")
        case .signature: return L10n.tr("Fai clic sulla pagina, disegna la firma e inseriscila. È una firma grafica, senza certificato digitale.")
        }
    }
}

@main
struct CartaPDFApp {
    @MainActor static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--cli") {
            Darwin.exit(CartaAutomation.cli(Array(CommandLine.arguments.dropFirst(index + 1))))
        }
        let application = NSApplication.shared
        let delegate = CartaAppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class CartaDocumentController: NSDocumentController {
    override var defaultType: String? { "com.adobe.pdf" }
    override func documentClass(forType typeName: String) -> AnyClass? {
        typeName == "com.adobe.pdf" ? PDFWorkspaceDocument.self : nil
    }
}

@MainActor
final class CartaAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private let documents = CartaDocumentController()
    private var recentDocumentsMenu: NSMenu?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMenu()
        NSWindow.allowsAutomaticWindowTabbing = false
        NotificationCenter.default.addObserver(self, selector: #selector(applyShortcutPreferences), name: .cartaShortcutsChanged, object: nil)
        applyShortcutPreferences()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        let fileArguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") && $0.lowercased().hasSuffix(".pdf") }
        for path in fileArguments { open(URL(fileURLWithPath: path)) }
        // Finder may deliver its open-file event in this run loop.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.documents.documents.isEmpty, fileArguments.isEmpty else { return }
            self.documents.newDocument(nil)
            if !CartaSnapshotStore.shared.entries(kind: "Recovery").isEmpty {
                CartaPanelController.present(CartaHistoryView(model: nil, recovery: true), title: L10n.tr("Recupero documenti"))
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if documents.documents.isEmpty { documents.newDocument(nil) }
            else { documents.documents.first?.showWindows() }
        }
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for filename in filenames { open(URL(fileURLWithPath: filename)) }
        sender.reply(toOpenOrPrint: .success)
    }

    private func open(_ url: URL) {
        documents.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }

    private var model: PDFEditorModel? {
        (NSApp.keyWindow?.windowController?.document as? PDFWorkspaceDocument)?.model
            ?? (documents.currentDocument as? PDFWorkspaceDocument)?.model
    }
    private var originalShortcuts: [String: (String, NSEvent.ModifierFlags)] = [:]
    @objc private func applyShortcutPreferences() {
        func visit(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { visit(submenu) }
                guard item.target as AnyObject? === self, let action = item.action else { continue }
                let key = NSStringFromSelector(action)
                if originalShortcuts[key] == nil { originalShortcuts[key] = (item.keyEquivalent, item.keyEquivalentModifierMask) }
                if let custom = CartaPreferences.shared.shortcuts[key] { item.keyEquivalent = custom; item.keyEquivalentModifierMask = [.command] }
                else if let original = originalShortcuts[key] { item.keyEquivalent = original.0; item.keyEquivalentModifierMask = original.1 }
            }
        }
        if let menu = NSApp.mainMenu { visit(menu) }
    }
    @objc private func preferences(_ sender: Any?) { CartaPanelController.present(CartaPreferencesView(), title: L10n.tr("Preferenze")) }

    @objc private func rotatePage(_ sender: Any?) { model?.rotateCurrentPage() }
    @objc private func deletePage(_ sender: Any?) { model?.deleteCurrentPage() }
    @objc private func insertPages(_ sender: Any?) { model?.insertPDF() }
    @objc private func highlight(_ sender: Any?) { model?.highlightSelection() }
    @objc private func keyboardAnnotations(_ sender: Any?) { model?.showKeyboardEditingWorkspace() }
    @objc private func nextPage(_ sender: Any?) { model?.nextPage() }
    @objc private func previousPage(_ sender: Any?) { model?.previousPage() }
    @objc private func zoomIn(_ sender: Any?) { model?.zoomIn() }
    @objc private func zoomOut(_ sender: Any?) { model?.zoomOut() }
    @objc private func fit(_ sender: Any?) { model?.fitToWindow() }
    @objc private func actualSize(_ sender: Any?) { model?.actualSize() }
    @objc private func toggleSidebar(_ sender: Any?) { model?.showSidebar.toggle() }
    @objc private func focusSearch(_ sender: Any?) {
        guard let model else { return }
        model.showSidebar = true
        NotificationCenter.default.post(name: .cartaFocusSearch, object: model)
    }
    @objc private func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { open(url) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentDocumentsMenu else { return }
        menu.removeAllItems()
        for url in documents.recentDocumentURLs {
            let entry = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = url
            entry.toolTip = url.path
            menu.addItem(entry)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: L10n.tr("Cancella elenco"), action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        clear.target = documents
        menu.addItem(clear)
    }
    @objc private func showHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("Usare CartaPDF")
        alert.informativeText = L10n.tr("Apri un PDF con ⌘O o trascinalo nella finestra. Usa Nota, Testo e Disegna per annotare; fai doppio clic per modificare il contenuto. Seleziona un’annotazione e trascinala per spostarla, oppure usa ⌥ per ridimensionare testo e forme. Tab passa tra le annotazioni ed esce dal documento agli estremi. ⇧⌘K apre Annotazioni da tastiera: creazione, testo, coordinate, dimensioni ed eliminazione con undo. Esc annulla il gesto.\n\nApri Strumenti (⇧⌘T) per unione, divisione avanzata, libretti, scansioni, esportazioni, biblioteca, procedure batch, allegati, livelli, preflight e firme con certificato locale. Le operazioni sui contenuti originali salvano copie separate e segnalano i formati non supportati.\n\n⌘Z annulla, ⌘S salva, ⌘F cerca; ⌥ e rotella ingrandiscono intorno al puntatore. Preferenze configura autore, tratto, cache e scorciatoie. Versioni e recupero conservano copie locali.\n\nL’app elabora tutto sul Mac. Validazione PDF/A offre 11 profili, incluso PDF/A-4, rapporti JSON/testo e regole non verificate esplicite. La copertura ISO completa resta incompleta: un esito indeterminato non attesta conformità. PDF/X e tag accessibili descrivono il proprio ambito senza certificazione ISO.")
        alert.addButton(withTitle: L10n.tr("Ho capito"))
        alert.runModal()
    }
    @objc private func showTools(_ sender: Any?) {
        guard let model else { return }
        NotificationCenter.default.post(name: .cartaShowTools, object: model)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(showHelp(_:)) || menuItem.action == #selector(openRecent(_:)) { return true }
        guard let model else { return false }
        switch menuItem.action {
        case #selector(rotatePage(_:)), #selector(insertPages(_:)): return model.canEditPages
        case #selector(deletePage(_:)): return model.canEditPages && model.pageCount > 1
        case #selector(highlight(_:)): return model.canEditAnnotations && !(model.pdfView?.currentSelection?.string ?? "").isEmpty
        case #selector(previousPage(_:)): return model.currentPageIndex > 0
        case #selector(nextPage(_:)): return model.currentPageIndex + 1 < model.pageCount
        default: return true
        }
    }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        func item(_ title: String, _ action: Selector, _ key: String = "", target: AnyObject? = nil, modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let result = NSMenuItem(title: title, action: action, keyEquivalent: key)
            result.target = target
            result.keyEquivalentModifierMask = modifiers
            return result
        }
        let app = submenu("CartaPDF")
        app.addItem(item(L10n.tr("Informazioni su CartaPDF"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        app.addItem(item(L10n.tr("Preferenze…"), #selector(preferences(_:)), ",", target: self))
        app.addItem(.separator())
        let services = NSMenuItem(title: L10n.tr("Servizi"), action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: L10n.tr("Servizi"))
        app.addItem(services)
        NSApp.servicesMenu = services.submenu
        app.addItem(.separator())
        app.addItem(item(L10n.tr("Nascondi CartaPDF"), #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item(L10n.tr("Nascondi altre"), #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option]))
        app.addItem(item(L10n.tr("Mostra tutte"), #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item(L10n.tr("Esci da CartaPDF"), #selector(NSApplication.terminate(_:)), "q"))

        let file = submenu(L10n.tr("File"))
        file.addItem(item(L10n.tr("Nuovo PDF"), #selector(NSDocumentController.newDocument(_:)), "n", target: documents))
        file.addItem(item(L10n.tr("Apri…"), #selector(NSDocumentController.openDocument(_:)), "o", target: documents))
        let recent = NSMenuItem(title: L10n.tr("Apri recenti"), action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: L10n.tr("Apri recenti"))
        recentMenu.addItem(item(L10n.tr("Cancella elenco"), #selector(NSDocumentController.clearRecentDocuments(_:)), target: documents))
        recent.submenu = recentMenu
        recentMenu.delegate = self
        recentDocumentsMenu = recentMenu
        file.addItem(recent)
        file.addItem(.separator())
        file.addItem(item(L10n.tr("Chiudi"), #selector(NSWindow.performClose(_:)), "w"))
        file.addItem(item(L10n.tr("Salva"), #selector(NSDocument.save(_:)), "s"))
        file.addItem(item(L10n.tr("Salva con nome…"), #selector(NSDocument.saveAs(_:)), "s", modifiers: [.command, .shift]))
        file.addItem(.separator())
        file.addItem(item(L10n.tr("Stampa…"), #selector(NSDocument.printDocument(_:)), "p"))

        let edit = submenu(L10n.tr("Modifica"))
        edit.addItem(item(L10n.tr("Annulla"), Selector(("undo:")), "z"))
        edit.addItem(item(L10n.tr("Ripristina"), Selector(("redo:")), "z", modifiers: [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item(L10n.tr("Taglia"), #selector(NSText.cut(_:)), "x"))
        edit.addItem(item(L10n.tr("Copia"), #selector(NSText.copy(_:)), "c"))
        edit.addItem(item(L10n.tr("Incolla"), #selector(NSText.paste(_:)), "v"))
        edit.addItem(item(L10n.tr("Seleziona tutto"), #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        edit.addItem(item(L10n.tr("Cerca nel PDF…"), #selector(focusSearch(_:)), "f", target: self))

        let view = submenu(L10n.tr("Vista"))
        view.addItem(item(L10n.tr("Mostra / nascondi pagine"), #selector(toggleSidebar(_:)), "1", target: self, modifiers: [.command, .option]))
        view.addItem(.separator())
        view.addItem(item(L10n.tr("Ingrandisci"), #selector(zoomIn(_:)), "+", target: self))
        view.addItem(item(L10n.tr("Riduci"), #selector(zoomOut(_:)), "-", target: self))
        view.addItem(item(L10n.tr("Adatta alla finestra"), #selector(fit(_:)), "0", target: self))
        view.addItem(item(L10n.tr("Dimensioni reali"), #selector(actualSize(_:)), "0", target: self, modifiers: [.command, .option]))
        view.addItem(.separator())
        view.addItem(item(L10n.tr("Pagina precedente"), #selector(previousPage(_:)), "[", target: self))
        view.addItem(item(L10n.tr("Pagina successiva"), #selector(nextPage(_:)), "]", target: self))

        let document = submenu(L10n.tr("Documento"))
        document.addItem(item(L10n.tr("Annotazioni da tastiera…"), #selector(keyboardAnnotations(_:)), "k", target: self, modifiers: [.command, .shift]))
        document.addItem(item(L10n.tr("Evidenzia selezione"), #selector(highlight(_:)), "h", target: self, modifiers: [.command, .shift]))
        document.addItem(item(L10n.tr("Ruota pagina a destra"), #selector(rotatePage(_:)), "r", target: self))
        document.addItem(item(L10n.tr("Inserisci pagine da PDF…"), #selector(insertPages(_:)), target: self))
        document.addItem(item(L10n.tr("Elimina pagina"), #selector(deletePage(_:)), target: self))
        document.addItem(.separator())
        document.addItem(item(L10n.tr("Tutti gli strumenti…"), #selector(showTools(_:)), "t", target: self, modifiers: [.command, .shift]))

        let window = submenu(L10n.tr("Finestra"))
        window.addItem(item(L10n.tr("Riduci a icona"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item(L10n.tr("Ingrandisci"), #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item(L10n.tr("Porta tutto in primo piano"), #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = window
        let help = submenu(L10n.tr("Aiuto"))
        help.addItem(item(L10n.tr("Guida di CartaPDF"), #selector(showHelp(_:)), target: self))
        NSApp.helpMenu = help
        return main
    }
}

extension Notification.Name {
    static let cartaFocusSearch = Notification.Name("CartaPDFFocusSearch")
    static let cartaShowTools = Notification.Name("CartaPDFShowTools")
}
