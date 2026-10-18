import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

actor CartaJobLimiter {
    static let shared = CartaJobLimiter()
    private var active = 0
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
    func acquire(limit: Int) async throws {
        try Task.checkCancellation()
        if active < max(1, limit) { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in waiting.append((id, continuation)) }
        }, onCancel: { Task { await self.cancel(id) } })
    }
    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }
    func release() {
        if !waiting.isEmpty { waiting.removeFirst().1.resume() }
        else { active = max(0, active - 1) }
    }
    func withPermit<T>(limit: Int, operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire(limit: limit)
        do {
            try Task.checkCancellation()
            let result = try await operation()
            release()
            return result
        } catch { release(); throw error }
    }
}

@MainActor
final class CartaThumbnailCache {
    static let shared = CartaThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private var pressure: DispatchSourceMemoryPressure?
    init() {
        pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure?.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.cache.removeAllObjects() } }
        pressure?.resume()
    }
    func image(page: PDFPage, documentID: String, revision: Int, index: Int) -> NSImage {
        cache.totalCostLimit = max(32, CartaPreferences.shared.cacheMegabytes) * 1024 * 1024
        let key = "\(documentID)-\(revision)-\(index)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = page.thumbnail(of: NSSize(width: 144, height: 182), for: .cropBox)
        let cost = image.representations.reduce(0) { $0 + max(1, $1.pixelsWide) * max(1, $1.pixelsHigh) * 4 }
        cache.setObject(image, forKey: key, cost: max(cost, 144 * 182 * 4))
        return image
    }
    func removeAll() { cache.removeAllObjects() }
}

@MainActor
struct CartaThumbnailSidebar: View {
    @ObservedObject var model: PDFEditorModel
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(0..<model.pageCount, id: \.self) { index in
                        if let page = model.document.page(at: index) {
                            CartaThumbnailCell(model: model, page: page, index: index)
                                .id(index)
                                .onDrag { NSItemProvider(object: "CartaPDF-page:\(index)" as NSString) }
                                .onDrop(of: [.plainText], isTargeted: nil) { providers in
                                    guard model.canEditPages, let provider = providers.first else { return false }
                                    _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                                        guard let text = text as? String, text.hasPrefix("CartaPDF-page:"),
                                              let from = Int(text.dropFirst("CartaPDF-page:".count)) else { return }
                                        Task { @MainActor in
                                            guard (0..<model.pageCount).contains(from) else { return }
                                            model.goToPage(from)
                                            model.moveCurrentPage(by: index - from)
                                        }
                                    }
                                    return true
                                }
                        }
                    }
                }.padding(18)
            }
            .onChange(of: model.currentPageIndex) { _, index in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(index, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(model.currentPageIndex, anchor: .center) }
        }
        .accessibilityLabel(L10n.tr("Pagine. Trascina una miniatura per riordinare."))
    }
}

@MainActor
private struct CartaThumbnailCell: View {
    @ObservedObject var model: PDFEditorModel
    let page: PDFPage
    let index: Int
    @State private var image: NSImage?
    var body: some View {
        Button { model.goToPage(index) } label: {
            VStack(spacing: 7) {
                Group {
                    if let image { Image(nsImage: image).resizable().scaledToFit() }
                    else { Rectangle().fill(.white).overlay(ProgressView().controlSize(.small)) }
                }
                .frame(width: 120, height: 152)
                .padding(5)
                .background(model.currentPageIndex == index ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(model.currentPageIndex == index ? Color.accentColor : Color.clear, lineWidth: 2))
                Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityLabel(L10n.tr("Pagina \(index + 1)"))
        .accessibilityAddTraits(model.currentPageIndex == index ? .isSelected : [])
        .task(id: model.contentRevision) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            image = CartaThumbnailCache.shared.image(page: page, documentID: String(describing: ObjectIdentifier(model.document)), revision: model.contentRevision, index: index)
        }
        .onDisappear { image = nil }
    }
}

enum CartaInkGeometry {
    static func smoothed(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 3 else { return points }
        var output = points
        for index in 1..<(points.count - 1) {
            let a = points[index - 1], b = points[index], c = points[index + 1]
            let u = CGPoint(x: b.x - a.x, y: b.y - a.y), v = CGPoint(x: c.x - b.x, y: c.y - b.y)
            let length = hypot(u.x, u.y) * hypot(v.x, v.y)
            guard length > 0.01, (u.x * v.x + u.y * v.y) / length > 0.6 else { continue }
            output[index] = CGPoint(x: a.x * 0.2 + b.x * 0.6 + c.x * 0.2, y: a.y * 0.2 + b.y * 0.6 + c.y * 0.2)
        }
        return output
    }
}

@MainActor
extension PDFEditorModel {
    func selectAnnotation(_ annotation: PDFAnnotation?, on page: PDFPage?) {
        selectedAnnotation = annotation
        selectedAnnotationPage = page
        if let annotation {
            if let font = annotation.font { textFontName = font.fontName; textFontSize = font.pointSize }
            if let color = annotation.fontColor { textColor = color }
            statusMessage = L10n.tr("Annotazione selezionata. Trascina per spostare; ⌥ trascina per ridimensionare testo e forme.")
        }
        pdfView?.needsDisplay = true
    }

    func cycleAnnotation(backward: Bool) {
        guard let page = currentPage else { return }
        let list = page.annotations.filter { $0.shouldDisplay && !["Widget", "Link", "Popup"].contains($0.type ?? "") }
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0 === selectedAnnotation } ?? (backward ? 0 : -1)
        let index = (current + (backward ? -1 : 1) + list.count) % list.count
        selectAnnotation(list[index], on: page)
        pdfView?.go(to: list[index].bounds, on: page)
    }

    func moveAnnotation(_ annotation: PDFAnnotation, to bounds: CGRect, on page: PDFPage) {
        guard canEditAnnotations, page.document === document, page.annotations.contains(where: { $0 === annotation }),
              annotation.type != "Widget", annotation.type != "Link", bounds != annotation.bounds else { return }
        let flags = (annotation.value(forAnnotationKey: .flags) as? NSNumber)?.intValue ?? 0
        guard flags & ((1 << 6) | (1 << 7)) == 0 else { return }
        let old = annotation.bounds
        performChange(named: L10n.tr("Sposta annotazione"), relayout: false, mutation: {
            annotation.bounds = bounds
            pdfView?.annotationsChanged(on: page)
        }, inverse: { model in model.moveAnnotation(annotation, to: old, on: page) })
        warnIfTextOverflows(annotation)
    }

    func applySelectedTextStyle() {
        guard canEditAnnotations, let annotation = selectedAnnotation, let page = selectedAnnotationPage,
              annotation.type == "FreeText" else { return }
        setAnnotationStyle(annotation, on: page, font: NSFont(name: textFontName, size: textFontSize) ?? .systemFont(ofSize: textFontSize), color: textColor)
    }
    private func setAnnotationStyle(_ annotation: PDFAnnotation, on page: PDFPage, font: NSFont, color: NSColor) {
        let flags = (annotation.value(forAnnotationKey: .flags) as? NSNumber)?.intValue ?? 0
        guard flags & ((1 << 6) | (1 << 7) | (1 << 9)) == 0 else {
            errorMessage = L10n.tr("L’annotazione è protetta e non consente modifiche allo stile.")
            return
        }
        let oldFont = annotation.font ?? .systemFont(ofSize: 18), oldColor = annotation.fontColor ?? .black
        performChange(named: L10n.tr("Stile annotazione"), relayout: false, mutation: {
            annotation.font = font
            annotation.fontColor = color
            pdfView?.annotationsChanged(on: page)
        }, inverse: { model in model.setAnnotationStyle(annotation, on: page, font: oldFont, color: oldColor) })
        warnIfTextOverflows(annotation)
    }

    func warnIfTextOverflows(_ annotation: PDFAnnotation) {
        guard annotation.type == "FreeText", let contents = annotation.contents else { return }
        let font = annotation.font ?? .systemFont(ofSize: 18)
        let measured = (contents as NSString).boundingRect(with: NSSize(width: max(1, annotation.bounds.width - 12), height: 1_000_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        if measured.height + 12 > annotation.bounds.height + 1 {
            statusMessage = L10n.tr("Il testo supera il riquadro: ridimensiona l’annotazione o riduci il carattere.")
        }
    }

    func searchSnippet(for selection: PDFSelection) -> String {
        guard let page = selection.pages.first, let text = page.string else { return selection.string ?? L10n.tr("Risultato") }
        let range = selection.numberOfTextRanges(on: page) > 0 ? selection.range(at: 0, on: page) : (text as NSString).range(of: selection.string ?? searchQuery, options: .caseInsensitive)
        guard range.location != NSNotFound else { return selection.string ?? L10n.tr("Risultato") }
        let ns = text as NSString
        let start = max(0, range.location - 45), end = min(ns.length, NSMaxRange(range) + 75)
        return (start > 0 ? "…" : "") + ns.substring(with: NSRange(location: start, length: end - start)).replacingOccurrences(of: "\n", with: " ") + (end < ns.length ? "…" : "")
    }
}
