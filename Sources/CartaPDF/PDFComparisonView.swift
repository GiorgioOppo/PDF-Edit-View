import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct PDFTextComparison {
    let changedPages: [Int]
    let pagesWithoutExtractableText: Int
    let leftPageCount: Int
    let rightPageCount: Int

    init(left: PDFDocument, right: PDFDocument) {
        leftPageCount = left.pageCount
        rightPageCount = right.pageCount
        var changed: [Int] = []
        var unextractable = 0
        for index in 0..<max(left.pageCount, right.pageCount) {
            let leftPage = left.page(at: index), rightPage = right.page(at: index)
            let lhs = Self.normalized(leftPage?.string ?? "")
            let rhs = Self.normalized(rightPage?.string ?? "")
            if leftPage == nil || rightPage == nil || lhs != rhs { changed.append(index) }
            if lhs.isEmpty || rhs.isEmpty { unextractable += 1 }
        }
        changedPages = changed
        pagesWithoutExtractableText = unextractable
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

@MainActor
private final class PDFComparisonState: ObservableObject {
    let left: PDFDocument
    let right: PDFDocument
    let leftName: String
    let rightName: String
    let comparison: PDFTextComparison
    @Published var pageIndex = 0
    var pageCount: Int { max(left.pageCount, right.pageCount) }

    init(left: PDFDocument, right: PDFDocument, leftName: String, rightName: String) {
        self.left = left
        self.right = right
        self.leftName = leftName
        self.rightName = rightName
        comparison = PDFTextComparison(left: left, right: right)
    }

    func go(to index: Int) { pageIndex = min(max(index, 0), max(0, pageCount - 1)) }
}

@MainActor
private struct PDFComparisonView: View {
    @ObservedObject var state: PDFComparisonState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("Confronto del testo", systemImage: "doc.on.doc")
                    .font(.headline)
                Spacer()
                Button { state.go(to: state.pageIndex - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(state.pageIndex == 0).help("Pagina precedente")
                    .accessibilityLabel("Pagina precedente nel confronto")
                Text("Pagina \(state.pageIndex + 1) di \(state.pageCount)").monospacedDigit()
                Button { state.go(to: state.pageIndex + 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(state.pageIndex + 1 >= state.pageCount).help("Pagina successiva")
                    .accessibilityLabel("Pagina successiva nel confronto")
            }.padding(16)
            HStack {
                Text("\(state.comparison.changedPages.count) pagine con testo diverso o mancanti. Immagini e impaginazione non analizzate.")
                Spacer()
                if !state.comparison.changedPages.isEmpty {
                    Menu("Pagine diverse") {
                        ForEach(state.comparison.changedPages, id: \.self) { index in
                            Button("Pagina \(index + 1)") { state.go(to: index) }
                        }
                    }
                }
            }.font(.callout).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 12)
            if state.comparison.pagesWithoutExtractableText > 0 {
                Text("\(state.comparison.pagesWithoutExtractableText) posizioni contengono pagine mancanti o senza testo estraibile. Esegui OCR sui PDF scansionati prima del confronto.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
            Divider()
            HSplitView {
                column(document: state.left, name: state.leftName)
                column(document: state.right, name: state.rightName)
            }
        }.frame(minWidth: 900, minHeight: 650)
            .accessibilityIdentifier("panel.comparison.text")
    }

    private func column(document: PDFDocument, name: String) -> some View {
        VStack(spacing: 0) {
            Text(name).font(.headline).lineLimit(1).padding(12)
            Divider()
            if state.pageIndex < document.pageCount {
                ComparisonPDFCanvas(document: document, name: name, state: state)
            } else {
                ContentUnavailableView("Pagina assente", systemImage: "doc", description: Text("Questo PDF non contiene la pagina \(state.pageIndex + 1)."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(minWidth: 350)
    }
}

@MainActor
private struct ComparisonPDFCanvas: NSViewRepresentable {
    let document: PDFDocument
    let name: String
    @ObservedObject var state: PDFComparisonState

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }
    func makeNSView(context: Context) -> EditablePDFView {
        let view = EditablePDFView()
        view.document = document
        view.displayMode = .singlePage
        view.autoScales = true
        view.backgroundColor = .underPageBackgroundColor
        context.coordinator.observe(view)
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: EditablePDFView, context: Context) {
        view.setAccessibilityLabel("Confronto, \(name), pagina \(state.pageIndex + 1)")
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        if view.document !== document { view.document = document }
        if let page = document.page(at: state.pageIndex), view.currentPage !== page { view.go(to: page) }
    }
    static func dismantleNSView(_ view: EditablePDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject {
        let state: PDFComparisonState
        weak var view: PDFView?
        var updating = false
        init(state: PDFComparisonState) { self.state = state }
        func observe(_ view: PDFView) {
            self.view = view
            NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
        }
        @objc private func pageChanged() {
            guard !updating, let view, let page = view.currentPage, let document = view.document else { return }
            let index = document.index(for: page)
            guard index != NSNotFound, index != state.pageIndex else { return }
            DispatchQueue.main.async { [weak self] in self?.state.go(to: index) }
        }
    }
}

@MainActor
private final class PDFComparisonController: NSWindowController, NSWindowDelegate {
    private static var sessions: [PDFComparisonController] = []
    init(state: PDFComparisonState) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: PDFComparisonView(state: state)))
        window.setContentSize(NSSize(width: 1180, height: 820))
        window.title = "Confronto PDF"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        Self.sessions.append(self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowWillClose(_ notification: Notification) { Self.sessions.removeAll { $0 === self } }
}

@MainActor
extension PDFEditorModel {
    func comparePDF() {
        guard !isProcessing else { return }
        guard document.allowsCopying else {
            errorMessage = "Il PDF non consente l’estrazione del testo necessaria per il confronto."
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.message = "Scegli il secondo PDF da confrontare con il documento corrente."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let other = PDFDocument(url: url) else { throw PDFWorkspaceError.invalidPDF }
            try PDFWorkspaceDocument.unlockIfNeeded(other, name: url.lastPathComponent)
            guard other.pageCount > 0 else { throw PDFWorkspaceError.invalidPDF }
            guard other.allowsCopying else {
                errorMessage = "Il secondo PDF non consente l’estrazione del testo."
                return
            }
            let left = try comparisonSnapshot(document)
            let right = try comparisonSnapshot(other)
            let state = PDFComparisonState(left: left, right: right, leftName: fileName, rightName: url.lastPathComponent)
            PDFComparisonController(state: state).showWindow(nil)
        } catch {
            if (error as NSError).code != NSUserCancelledError { errorMessage = error.localizedDescription }
        }
    }

    private func comparisonSnapshot(_ document: PDFDocument) throws -> PDFDocument {
        let snapshot = PDFDocument()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { throw PDFWorkspaceError.invalidPDF }
            for annotation in page.annotations where annotation.type == "Widget" { annotation.isReadOnly = true }
            snapshot.insert(page, at: snapshot.pageCount)
        }
        return snapshot
    }
}
