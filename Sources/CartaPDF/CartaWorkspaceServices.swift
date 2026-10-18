import AppKit
import Combine
import CryptoKit
import PDFKit
import SwiftUI

@MainActor
final class CartaPreferences: ObservableObject {
    static let shared = CartaPreferences()
    private let defaults: UserDefaults
    @Published var annotationAuthor: String { didSet { defaults.set(annotationAuthor, forKey: "Carta.annotationAuthor") } }
    @Published var strokeWidth: Double { didSet { defaults.set(strokeWidth, forKey: "Carta.strokeWidth") } }
    @Published var smoothInk: Bool { didSet { defaults.set(smoothInk, forKey: "Carta.smoothInk") } }
    @Published var cacheMegabytes: Int { didSet { defaults.set(cacheMegabytes, forKey: "Carta.cacheMB") } }
    @Published var concurrentJobs: Int { didSet { defaults.set(concurrentJobs, forKey: "Carta.jobs") } }
    @Published var recoveryEnabled: Bool { didSet { defaults.set(recoveryEnabled, forKey: "Carta.recovery") } }
    @Published var searchAsYouType: Bool { didSet { defaults.set(searchAsYouType, forKey: "Carta.liveSearch") } }
    @Published var sidebarWidth: Double { didSet { defaults.set(sidebarWidth, forKey: "Carta.sidebarWidth") } }
    @Published var shortcuts: [String: String] { didSet { defaults.set(shortcuts, forKey: "Carta.shortcuts") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        annotationAuthor = defaults.string(forKey: "Carta.annotationAuthor") ?? NSFullUserName()
        strokeWidth = defaults.object(forKey: "Carta.strokeWidth") as? Double ?? 2.5
        smoothInk = defaults.object(forKey: "Carta.smoothInk") as? Bool ?? true
        cacheMegabytes = defaults.object(forKey: "Carta.cacheMB") as? Int ?? 128
        concurrentJobs = defaults.object(forKey: "Carta.jobs") as? Int ?? 2
        recoveryEnabled = defaults.object(forKey: "Carta.recovery") as? Bool ?? true
        searchAsYouType = defaults.object(forKey: "Carta.liveSearch") as? Bool ?? true
        sidebarWidth = defaults.object(forKey: "Carta.sidebarWidth") as? Double ?? 214
        shortcuts = defaults.dictionary(forKey: "Carta.shortcuts") as? [String: String] ?? [:]
    }
}

struct CartaReadingState: Codable, Equatable {
    var page: Int
    var scale: Double
    var autoScales: Bool
    var displayMode: Int
    var showSidebar: Bool
}

struct CartaSnapshot: Codable, Identifiable {
    var id: UUID
    var sourcePath: String?
    var name: String
    var date: Date
    var encrypted: Bool
    var pageCount: Int
    var kind: String
    var documentID: String?
}

@MainActor
final class CartaSnapshotStore {
    static let shared = CartaSnapshotStore()
    let baseURL: URL
    init(baseURL: URL? = nil) {
        self.baseURL = baseURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CartaPDF", isDirectory: true)
    }

    func entries(kind: String) -> [CartaSnapshot] {
        let directory = baseURL.appendingPathComponent(kind, isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(CartaSnapshot.self, from: $0) } }
            .sorted { $0.date > $1.date }
    }

    func write(data: Data, name: String, source: URL?, kind: String, id: UUID = UUID(), documentID: String? = nil) throws -> CartaSnapshot {
        guard let pdf = PDFDocument(data: data), pdf.isLocked || pdf.pageCount > 0 else { throw PDFWorkspaceError.invalidPDF }
        let directory = baseURL.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let entry = CartaSnapshot(id: id, sourcePath: source?.path, name: name, date: Date(), encrypted: pdf.isEncrypted,
                                  pageCount: pdf.pageCount, kind: kind, documentID: documentID)
        let pdfURL = directory.appendingPathComponent(id.uuidString + ".pdf")
        try data.write(to: pdfURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pdfURL.path)
        try JSONEncoder().encode(entry).write(to: directory.appendingPathComponent(id.uuidString + ".json"), options: .atomic)
        if kind == "Versions", source != nil || documentID != nil {
            let old = entries(kind: kind).filter {
                if let source { return $0.sourcePath == source.path }
                return $0.sourcePath == nil && $0.documentID == documentID
            }.dropFirst(20)
            for item in old { try remove(item) }
        }
        return entry
    }

    func data(for entry: CartaSnapshot) throws -> Data {
        try Data(contentsOf: baseURL.appendingPathComponent(entry.kind).appendingPathComponent(entry.id.uuidString + ".pdf"))
    }
    func remove(_ entry: CartaSnapshot) throws {
        for ext in ["json", "pdf"] {
            let url = baseURL.appendingPathComponent(entry.kind).appendingPathComponent(entry.id.uuidString + "." + ext)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
    func removeRecovery(id: UUID) {
        guard let entry = entries(kind: "Recovery").first(where: { $0.id == id }) else { return }
        try? remove(entry)
    }

    static func identity(for url: URL) -> String {
        SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func readingState(for url: URL) -> CartaReadingState? {
        let location = baseURL.appendingPathComponent("Reading").appendingPathComponent(Self.identity(for: url) + ".json")
        return (try? Data(contentsOf: location)).flatMap { try? JSONDecoder().decode(CartaReadingState.self, from: $0) }
    }
    func storeReading(_ state: CartaReadingState, for url: URL) throws {
        let directory = baseURL.appendingPathComponent("Reading", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: directory.appendingPathComponent(Self.identity(for: url) + ".json"), options: .atomic)
    }
}

@MainActor
final class CartaPanelController: NSWindowController, NSWindowDelegate {
    private static var panels: [CartaPanelController] = []
    static func present<V: View>(_ root: V, title: String, width: CGFloat = 880, height: CGFloat = 650) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.setContentSize(NSSize(width: width, height: height))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = title
        window.center()
        window.isReleasedWhenClosed = false
        let controller = CartaPanelController(window: window)
        window.delegate = controller
        panels.append(controller)
        controller.showWindow(nil)
    }
    func windowWillClose(_ notification: Notification) { Self.panels.removeAll { $0 === self } }
}

@MainActor
struct CartaPreferencesView: View {
    @ObservedObject var preferences = CartaPreferences.shared
    @State private var shortcut = ""
    @State private var command = "focusSearch:"
    @State private var shortcutMessage = ""
    var body: some View {
        Form {
            Text("Preferenze locali").font(.title2.bold())
            TextField("Autore annotazioni", text: $preferences.annotationAuthor)
            Slider(value: $preferences.strokeWidth, in: 0.5...12, step: 0.5) {
                Text("Tratto: \(preferences.strokeWidth, specifier: "%.1f") pt")
            }
            .accessibilityLabel("Spessore del tratto")
            .accessibilityValue("\(preferences.strokeWidth, specifier: "%.1f") punti")
            Toggle("Regolarizza i tratti a mano libera", isOn: $preferences.smoothInk)
            Toggle("Ricerca durante la digitazione", isOn: $preferences.searchAsYouType)
            Toggle("Copie automatiche di recupero, senza sovrascrivere l’originale", isOn: $preferences.recoveryEnabled)
            Stepper("Elaborazioni simultanee: \(preferences.concurrentJobs)", value: $preferences.concurrentJobs, in: 1...4)
            Stepper("Cache miniature: \(preferences.cacheMegabytes) MB", value: $preferences.cacheMegabytes, in: 32...512, step: 32)
            Slider(value: $preferences.sidebarWidth, in: 180...340) { Text("Larghezza barra laterale") }
                .accessibilityValue("\(Int(preferences.sidebarWidth)) punti")
            Divider()
            Text("Scorciatoie personalizzate").font(.headline)
            Picker("Comando", selection: $command) {
                Text("Ricerca").tag("focusSearch:")
                Text("Strumenti").tag("showTools:")
                Text("Ruota pagina").tag("rotatePage:")
                Text("Adatta finestra").tag("fit:")
                Text("Pagina successiva").tag("nextPage:")
                Text("Pagina precedente").tag("previousPage:")
            }
            HStack {
                TextField("Un carattere, con ⌘", text: $shortcut)
                Button("Assegna") {
                    guard shortcut.count == 1, !"qwnoscvxazphm,+-".contains(shortcut.lowercased()) else {
                        shortcutMessage = "Questo tasto è riservato a un comando standard."
                        return
                    }
                    guard !preferences.shortcuts.contains(where: { $0.key != command && $0.value == shortcut.lowercased() }) else {
                        shortcutMessage = "Questo tasto è già assegnato. Ripristina prima l’altro comando."
                        return
                    }
                    let builtIn = ["focusSearch:": "f", "rotatePage:": "r", "fit:": "0", "nextPage:": "]", "previousPage:": "["]
                    guard !builtIn.contains(where: { $0.key != command && $0.value == shortcut.lowercased() && preferences.shortcuts[$0.key] == nil }) else {
                        shortcutMessage = "Questo tasto appartiene già a un altro comando. Personalizza prima quel comando."
                        return
                    }
                    preferences.shortcuts[command] = shortcut.lowercased()
                    shortcutMessage = "Scorciatoia ⌘\(shortcut.uppercased()) assegnata."
                    NotificationCenter.default.post(name: .cartaShortcutsChanged, object: nil)
                }.disabled(shortcut.count != 1)
                Button("Ripristina") {
                    preferences.shortcuts.removeValue(forKey: command)
                    shortcutMessage = "Scorciatoia predefinita ripristinata."
                    NotificationCenter.default.post(name: .cartaShortcutsChanged, object: nil)
                }
            }
            if !shortcutMessage.isEmpty { CartaPanelAccessibilityStatus(message: shortcutMessage, label: "Assegnazione scorciatoia").font(.caption) }
            Text("I comandi standard di apertura, salvataggio, copia e chiusura restano riservati. La nuova assegnazione viene applicata al menu.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped).padding(16).frame(minWidth: 560, minHeight: 600)
            .accessibilityIdentifier("panel.preferences")
    }
}

@MainActor
struct CartaHistoryView: View {
    let model: PDFEditorModel?
    let recovery: Bool
    @State private var entries: [CartaSnapshot] = []
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(recovery ? "Recupero documenti" : "Versioni locali").font(.title2.bold())
                Spacer()
                if !recovery, let model {
                    Button("Salva versione adesso") { model.saveLocalVersion(); reload() }
                }
                Button("Aggiorna", action: reload)
            }
            Text("Le copie restano sul Mac. Il ripristino apre una nuova finestra e conserva il file originale.")
                .foregroundStyle(.secondary)
            if entries.isEmpty { ContentUnavailableView("Nessuna copia", systemImage: "clock.arrow.circlepath") }
            List(entries) { entry in
                HStack {
                    VStack(alignment: .leading) {
                        Text(entry.name).font(.headline)
                        Text(entry.date, style: .date) + Text(" · ") + Text(entry.date, style: .time)
                        if entry.encrypted { Label("Copia cifrata", systemImage: "lock").font(.caption) }
                    }
                    Spacer()
                    Button("Apri copia") { restore(entry) }
                        .accessibilityLabel("Apri copia di \(entry.name), \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                    Button("Mostra file") {
                        let url = CartaSnapshotStore.shared.baseURL.appendingPathComponent(entry.kind).appendingPathComponent(entry.id.uuidString + ".pdf")
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .accessibilityLabel("Mostra file della copia \(entry.name) nel Finder")
                }.padding(.vertical, 5)
            }
            if !message.isEmpty { CartaPanelAccessibilityStatus(message: message, label: "Ripristino").foregroundStyle(.secondary) }
        }.padding(24).frame(minWidth: 700, minHeight: 520).onAppear(perform: reload)
            .accessibilityIdentifier(recovery ? "panel.recovery" : "panel.versions")
    }
    private func reload() {
        entries = CartaSnapshotStore.shared.entries(kind: recovery ? "Recovery" : "Versions")
        if !recovery, let url = model?.documentOwner?.fileURL { entries = entries.filter { $0.sourcePath == url.path } }
    }
    private func restore(_ entry: CartaSnapshot) {
        do {
            let copy = PDFWorkspaceDocument()
            try copy.read(from: CartaSnapshotStore.shared.data(for: entry), ofType: "com.adobe.pdf")
            copy.displayName = entry.name + " · recuperato"
            copy.updateChangeCount(.changeDone)
            NSDocumentController.shared.addDocument(copy)
            copy.makeWindowControllers()
            copy.showWindows()
            message = "Copia aperta. Salvala in un percorso a tua scelta."
        } catch { message = error.localizedDescription }
    }
}

extension Notification.Name {
    static let cartaShortcutsChanged = Notification.Name("CartaShortcutsChanged")
}

@MainActor
extension PDFEditorModel {
    func showPreferencesWorkspace() { CartaPanelController.present(CartaPreferencesView(), title: "Preferenze", width: 600, height: 680) }
    func showRecoveryWorkspace() { CartaPanelController.present(CartaHistoryView(model: self, recovery: true), title: "Recupero") }
    func showVersionWorkspace() { CartaPanelController.present(CartaHistoryView(model: self, recovery: false), title: "Versioni") }
    func saveLocalVersion() {
        do {
            _ = try CartaSnapshotStore.shared.write(data: serializedData(), name: fileName, source: documentOwner?.fileURL, kind: "Versions", documentID: localHistoryID)
            statusMessage = "Versione locale conservata."
        } catch { errorMessage = error.localizedDescription }
    }
    func persistReadingState() {
        guard let url = documentOwner?.fileURL else { return }
        try? CartaSnapshotStore.shared.storeReading(CartaReadingState(page: currentPageIndex, scale: Double(scale), autoScales: autoScales,
                                                                     displayMode: displayMode.rawValue, showSidebar: showSidebar), for: url)
    }
    func restoreReadingState() {
        guard let url = documentOwner?.fileURL, let state = CartaSnapshotStore.shared.readingState(for: url) else { return }
        currentPageIndex = min(max(0, state.page), max(0, pageCount - 1))
        scale = CGFloat(min(max(state.scale, 0.1), 8))
        autoScales = state.autoScales
        displayMode = PDFDisplayMode(rawValue: state.displayMode) ?? .singlePageContinuous
        showSidebar = state.showSidebar
    }
}
