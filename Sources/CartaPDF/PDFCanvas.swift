import AppKit
import PDFKit
import SwiftUI

/// Keeps PDFKit's navigation and text selection while routing every annotation
/// change through the document model and its undo manager.
@MainActor
struct PDFCanvas: NSViewRepresentable {
    @ObservedObject var model: PDFEditorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> EditablePDFView {
        let view = EditablePDFView()
        view.backgroundColor = .underPageBackgroundColor
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        view.displayDirection = .vertical
        view.displayBox = .cropBox
        view.minScaleFactor = 0.1
        view.maxScaleFactor = 8
        view.acceptsDraggedFiles = false
        view.setAccessibilityLabel("Documento PDF")
        context.coordinator.observe(view)
        context.coordinator.update(view, model: model)
        return view
    }

    func updateNSView(_ view: EditablePDFView, context: Context) {
        context.coordinator.update(view, model: model)
    }

    static func dismantleNSView(_ view: EditablePDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
        view.cancelDrawing()
        view.editorModel = nil
        if coordinator.model.pdfView === view { coordinator.model.pdfView = nil }
    }

    @MainActor
    final class Coordinator: NSObject {
        var model: PDFEditorModel
        private weak var view: EditablePDFView?
        private var updatingView = false
        private var updateQueued = false

        init(model: PDFEditorModel) { self.model = model }

        func observe(_ view: EditablePDFView) {
            self.view = view
            let names: [Notification.Name] = [
                .PDFViewPageChanged,
                .PDFViewScaleChanged,
                .PDFViewSelectionChanged,
                .PDFViewDisplayModeChanged
            ]
            for name in names {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(viewStateChanged), name: name, object: view
                )
            }
        }

        func stopObserving() {
            NotificationCenter.default.removeObserver(self)
            view = nil
        }

        func update(_ view: EditablePDFView, model: PDFEditorModel) {
            self.model = model
            updatingView = true
            defer { updatingView = false }
            view.editorModel = model
            view.configureAccessibleActions()
            var needsModelUpdate = false

            if view.document !== model.document || model.pdfView !== view {
                view.cancelDrawing()
                model.attachPDFView(view)
                needsModelUpdate = true
            }
            if view.displayMode != model.displayMode {
                view.displayMode = model.displayMode
                needsModelUpdate = true
            }
            if view.autoScales != model.autoScales {
                view.autoScales = model.autoScales
                needsModelUpdate = true
            }
            if !model.autoScales, abs(view.scaleFactor - model.scale) > 0.001 {
                view.scaleFactor = model.scale
                needsModelUpdate = true
            }
            if view.activeTool != model.activeTool {
                view.cancelDrawing()
                view.activeTool = model.activeTool
                view.window?.invalidateCursorRects(for: view)
            }
            view.strokePreview.color = model.annotationColor
            if let annotation = model.selectedAnnotation, let page = model.selectedAnnotationPage {
                view.strokePreview.selectionPage = page
                if view.movingAnnotation == nil { view.strokePreview.selectionBounds = annotation.bounds }
            } else {
                view.strokePreview.selectionBounds = nil
                view.strokePreview.selectionPage = nil
            }
            view.strokePreview.needsDisplay = true
            // An initial layout can change the fit scale. Publish it after SwiftUI's
            // update pass, as with notifications produced by scrolling or pinch zoom.
            if needsModelUpdate { scheduleModelUpdate() }
        }

        @objc private func viewStateChanged(_ notification: Notification) {
            guard !updatingView else { return }
            scheduleModelUpdate()
        }

        private func scheduleModelUpdate() {
            guard !updateQueued else { return }
            updateQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateQueued = false
                guard self.view != nil else { return }
                self.model.notifyViewStateChanged()
            }
        }
    }
}

@MainActor
final class EditablePDFView: PDFView {
    weak var editorModel: PDFEditorModel?
    var activeTool: EditorTool = .select
    fileprivate let strokePreview = InkPreviewView()
    private var drawingPage: PDFPage?
    private var drawingPoints: [CGPoint] = []
    private var drawingTool: EditorTool?
    private var suppressNativeDrag = false
    fileprivate var movingAnnotation: PDFAnnotation?
    private var movingPage: PDFPage?
    private var movingStart = CGPoint.zero
    private var movingOriginal = CGRect.zero
    private var movingPreview = CGRect.zero
    private var resizingAnnotation = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        strokePreview.pdfView = self
        strokePreview.frame = bounds
        strokePreview.autoresizingMask = [.width, .height]
        addSubview(strokePreview)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        strokePreview.pdfView = self
        strokePreview.frame = bounds
        strokePreview.autoresizingMask = [.width, .height]
        addSubview(strokePreview)
    }

    override var acceptsFirstResponder: Bool { true }

    func configureAccessibleActions() {
        setAccessibilityHelp("Documento PDF. Tab e Maiuscole Tab scorrono le annotazioni e poi escono dal documento. Comando Maiuscole K apre le annotazioni da tastiera.")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Annotazioni da tastiera", handler: { [weak self] in
                guard let model = self?.editorModel, !model.isProcessing else { return false }
                model.showKeyboardEditingWorkspace(); return true
            }),
            NSAccessibilityCustomAction(name: "Pagina successiva", handler: { [weak self] in
                guard let model = self?.editorModel, model.currentPageIndex + 1 < model.pageCount else { return false }
                model.nextPage(); return true
            }),
            NSAccessibilityCustomAction(name: "Pagina precedente", handler: { [weak self] in
                guard let model = self?.editorModel, model.currentPageIndex > 0 else { return false }
                model.previousPage(); return true
            })
        ])
    }

    override func layout() {
        super.layout()
        // PDFKit may insert its internal scroll view after initialization.
        addSubview(strokePreview, positioned: .above, relativeTo: nil)
        strokePreview.frame = bounds
        strokePreview.needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit != nil else { return nil }
        var ancestor = hit
        while let candidate = ancestor, candidate !== self {
            if candidate is NSScroller { return hit }
            ancestor = candidate.superview
        }
        let localPoint = convert(point, from: superview)
        if activeTool != .select { return self }
        // PDFKit creates private editors for free text, notes and form widgets.
        // Our own alerts provide undo-aware note/text editing. Form widgets are
        // locked by the model while displayed and restored during serialization.
        if let (annotation, _) = annotation(at: localPoint), annotation.type != "Link" {
            return self
        }
        return hit
    }

    override func mouseDown(with event: NSEvent) {
        suppressNativeDrag = false
        let location = convert(event.locationInWindow, from: nil)

        if activeTool == .select {
            if let (annotation, page) = annotation(at: location), annotation.type != "Link" {
                suppressNativeDrag = true
                window?.makeFirstResponder(self)
                editorModel?.selectAnnotation(annotation, on: page)
                if event.clickCount == 2,
                   annotation.type == "Text" || annotation.type == "FreeText" {
                    edit(annotation, on: page)
                } else if isRemovable(annotation), editorModel?.canEditAnnotations == true, editorModel?.isProcessing == false {
                    movingAnnotation = annotation
                    movingPage = page
                    movingStart = convert(location, to: page)
                    movingOriginal = annotation.bounds
                    movingPreview = annotation.bounds
                    resizingAnnotation = event.modifierFlags.contains(.option) && ["FreeText", "Square", "Circle"].contains(annotation.type ?? "")
                }
                return
            }
            editorModel?.selectAnnotation(nil, on: nil)
            super.mouseDown(with: event)
            return
        }

        suppressNativeDrag = true
        window?.makeFirstResponder(self)
        guard let model = editorModel, !model.isProcessing else { return }
        guard activeTool == .redact ? model.canEditDocument : model.canEditAnnotations else {
            editorModel?.errorMessage = "Il PDF non consente la modifica delle annotazioni."
            return
        }
        guard let page = page(for: location, nearest: false) else { return }
        let pagePoint = convert(location, to: page)
        switch activeTool {
        case .select:
            break
        case .note:
            if let text = requestText(title: "Aggiungi una nota", initialValue: "") {
                model.addNote(text: text, at: pagePoint, on: page)
            }
        case .text:
            if let text = requestText(title: "Aggiungi testo", initialValue: "", preview: { [weak self, weak page] text in
                guard let self, let page else { return }
                self.strokePreview.textPreview = text
                self.strokePreview.textPreviewPoint = pagePoint
                self.strokePreview.textPreviewPage = page
                self.strokePreview.needsDisplay = true
            }) {
                model.addTextAnnotation(text: text, at: pagePoint, on: page)
            }
            strokePreview.textPreview = nil
            strokePreview.needsDisplay = true
        case .draw, .rectangle, .ellipse, .redact, .link:
            drawingPage = page
            drawingPoints = [clamped(pagePoint, to: page)]
            drawingTool = activeTool
            updateStrokePreview()
        case .signature:
            model.addGraphicalSignature(at: pagePoint, on: page)
        case .erase:
            if let (annotation, hitPage) = annotation(at: location), isRemovable(annotation) {
                if annotation.type == "Link" { model.removeWebLink(annotation, from: hitPage) }
                else { model.removeAnnotation(annotation, from: hitPage) }
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if movingAnnotation != nil, let page = movingPage {
            let point = convert(convert(event.locationInWindow, from: nil), to: page)
            let delta = CGPoint(x: point.x - movingStart.x, y: point.y - movingStart.y)
            let crop = page.bounds(for: .cropBox)
            if resizingAnnotation {
                movingPreview = CGRect(x: movingOriginal.minX, y: movingOriginal.minY,
                    width: max(8, min(crop.maxX - movingOriginal.minX, movingOriginal.width + delta.x)),
                    height: max(8, min(crop.maxY - movingOriginal.minY, movingOriginal.height + delta.y)))
            } else {
                movingPreview = movingOriginal.offsetBy(dx: delta.x, dy: delta.y)
                movingPreview.origin.x = min(max(movingPreview.minX, crop.minX), crop.maxX - movingPreview.width)
                movingPreview.origin.y = min(max(movingPreview.minY, crop.minY), crop.maxY - movingPreview.height)
            }
            strokePreview.selectionBounds = movingPreview
            strokePreview.selectionPage = page
            strokePreview.needsDisplay = true
            return
        }
        if let page = drawingPage {
            let point = convert(convert(event.locationInWindow, from: nil), to: page)
            let nextPoint = clamped(point, to: page)
            if let lastPoint = drawingPoints.last,
               hypot(nextPoint.x - lastPoint.x, nextPoint.y - lastPoint.y) < 0.75 { return }
            if drawingTool == .draw { drawingPoints.append(nextPoint) }
            else { drawingPoints = [drawingPoints[0], nextPoint] }
            updateStrokePreview()
        } else if !suppressNativeDrag {
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let annotation = movingAnnotation, let page = movingPage {
            editorModel?.moveAnnotation(annotation, to: movingPreview, on: page)
            movingAnnotation = nil
            movingPage = nil
            suppressNativeDrag = false
            return
        }
        if let page = drawingPage {
            let point = convert(convert(event.locationInWindow, from: nil), to: page)
            drawingPoints.append(clamped(point, to: page))
            let points = drawingPoints
            let tool = drawingTool
            cancelDrawing()
            if tool == .draw {
                editorModel?.addInkAnnotation(points: points, on: page)
            } else if let first = points.first, let last = points.last {
                let rectangle = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                                       width: abs(first.x - last.x), height: abs(first.y - last.y))
                guard rectangle.width >= 3, rectangle.height >= 3 else { return }
                switch tool {
                case .rectangle: editorModel?.addShapeAnnotation(in: rectangle, on: page, ellipse: false)
                case .ellipse: editorModel?.addShapeAnnotation(in: rectangle, on: page, ellipse: true)
                case .redact: editorModel?.redactRegion(rectangle, on: page)
                case .link: editorModel?.addLinkAnnotation(in: rectangle, on: page)
                default: break
                }
            }
        } else if !suppressNativeDrag {
            super.mouseUp(with: event)
        }
        suppressNativeDrag = false
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            movingAnnotation = nil
            movingPage = nil
            editorModel?.selectAnnotation(nil, on: nil)
            strokePreview.selectionBounds = nil
            strokePreview.needsDisplay = true
        }
        if event.keyCode == 53, drawingPage != nil {
            cancelDrawing()
            return
        }
        // Do not let PDFKit start a native form/free-text editor through its tab
        // traversal. Normal app focus traversal remains available.
        if event.keyCode == 48 {
            if !event.modifierFlags.contains(.control), activeTool == .select, let model = editorModel, let page = model.currentPage {
                let annotations = page.annotations.filter { $0.shouldDisplay && !["Widget", "Link", "Popup"].contains($0.type ?? "") }
                let selected = annotations.firstIndex { $0 === model.selectedAnnotation }
                switch CartaAnnotationFocusRoute.tab(selected: selected, count: annotations.count, backwards: event.modifierFlags.contains(.shift)) {
                case .select(let index):
                    model.selectAnnotation(annotations[index], on: page)
                    CartaAccessibility.announce(annotations[index].contents ?? "Annotazione \(index + 1) di \(annotations.count)", in: window)
                    return
                case .leaveDocument:
                    model.selectAnnotation(nil, on: nil)
                }
            }
            if event.modifierFlags.contains(.shift) {
                window?.selectPreviousKeyView(self)
            } else {
                window?.selectNextKeyView(self)
            }
            return
        }
        if event.keyCode == 36, let annotation = editorModel?.selectedAnnotation,
           let page = editorModel?.selectedAnnotationPage, ["Text", "FreeText"].contains(annotation.type ?? "") {
            edit(annotation, on: page)
            return
        }
        super.keyDown(with: event)
    }

    override func setCursorFor(_ area: PDFAreaOfInterest) {
        if activeTool == .select { super.setCursorFor(area) }
        else { NSCursor.crosshair.set() }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if activeTool != .select { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func magnify(with event: NSEvent) {
        keepingZoomAnchor(event) { super.magnify(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.option) else { super.scrollWheel(with: event); return }
        keepingZoomAnchor(event) {
            autoScales = false
            scaleFactor = min(maxScaleFactor, max(minScaleFactor, scaleFactor * pow(1.012, event.scrollingDeltaY)))
        }
    }

    private func keepingZoomAnchor(_ event: NSEvent, change: () -> Void) {
        let location = convert(event.locationInWindow, from: nil)
        guard let page = page(for: location, nearest: false), let clip = documentView?.enclosingScrollView?.contentView else { change(); return }
        let anchor = convert(location, to: page)
        let before = clip.convert(convert(anchor, from: page), from: self)
        change()
        layoutDocumentView()
        let after = clip.convert(convert(anchor, from: page), from: self)
        clip.scroll(to: CGPoint(x: clip.bounds.minX + after.x - before.x, y: clip.bounds.minY + after.y - before.y))
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
        editorModel?.notifyViewStateChanged()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Keep native annotation mutation actions out of the responder chain.
        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copia", action: #selector(copy(_:)), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = document?.allowsCopying == true && currentSelection != nil
        menu.addItem(copy)
        let selectAll = NSMenuItem(title: "Seleziona tutto", action: #selector(selectAll(_:)), keyEquivalent: "")
        selectAll.target = self
        menu.addItem(selectAll)
        menu.autoenablesItems = false
        return menu
    }

    func cancelDrawing() {
        movingAnnotation = nil
        movingPage = nil
        resizingAnnotation = false
        suppressNativeDrag = false
        drawingPage = nil
        drawingTool = nil
        drawingPoints.removeAll(keepingCapacity: true)
        strokePreview.page = nil
        strokePreview.points = []
        strokePreview.shapeTool = nil
        strokePreview.needsDisplay = true
    }

    private func updateStrokePreview() {
        strokePreview.page = drawingPage
        strokePreview.points = drawingPoints
        strokePreview.shapeTool = drawingTool == .draw ? nil : drawingTool
        strokePreview.needsDisplay = true
    }

    private func annotation(at point: NSPoint) -> (PDFAnnotation, PDFPage)? {
        guard let page = page(for: point, nearest: false) else { return nil }
        let pagePoint = convert(point, to: page)
        guard let annotation = page.annotations.reversed().first(where: {
            $0.shouldDisplay && $0.bounds.contains(pagePoint)
        }) else { return nil }
        return (annotation, page)
    }

    private func isRemovable(_ annotation: PDFAnnotation) -> Bool {
        // Links, popups and widgets can carry document behavior or signatures.
        // Erase only supported visible annotation types, never those structures.
        let supported: Set<String> = [
            "Text", "FreeText", "Ink", "Highlight", "Underline", "StrikeOut",
            "Square", "Circle", "Line", "Stamp"
        ]
        let flags = (annotation.value(forAnnotationKey: .flags) as? NSNumber)?.intValue ?? 0
        let readOnlyOrLocked = flags & ((1 << 6) | (1 << 7)) != 0
        let ownLink = annotation.type == "Link"
            && CartaOwnedLink.identity(of: annotation) != nil
        return (supported.contains(annotation.type ?? "") || ownLink) && !readOnlyOrLocked
    }

    private func edit(_ annotation: PDFAnnotation, on page: PDFPage) {
        guard let model = editorModel, !model.isProcessing else { return }
        if model.canEditAnnotations, isRemovable(annotation) {
            if let text = requestText(title: annotation.type == "Text" ? "Modifica nota" : "Modifica testo",
                                      initialValue: annotation.contents ?? "") {
                model.updateAnnotation(annotation, text: text, on: page)
            }
        } else {
            let alert = NSAlert()
            alert.messageText = "Annotazione in sola lettura"
            alert.informativeText = annotation.contents ?? ""
            alert.addButton(withTitle: "Chiudi")
            alert.runModal()
        }
    }

    private func requestText(title: String, initialValue: String, preview: ((String) -> Void)? = nil) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Scrivi il contenuto dell’annotazione."
        alert.addButton(withTitle: "Conferma")
        alert.addButton(withTitle: "Annulla")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[0].keyEquivalentModifierMask = [.command]
        alert.buttons[1].keyEquivalent = "\u{1B}"
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 120))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        let textView = NSTextView(frame: scrollView.bounds)
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 14)
        textView.string = initialValue
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Contenuto dell’annotazione")
        scrollView.documentView = textView
        alert.accessoryView = scrollView
        alert.window.initialFirstResponder = textView
        let observer = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: textView, queue: .main) { _ in
            MainActor.assumeIsolated { preview?(textView.string) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func clamped(_ point: CGPoint, to page: PDFPage) -> CGPoint {
        let bounds = page.bounds(for: displayBox)
        return CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                       y: min(max(point.y, bounds.minY), bounds.maxY))
    }
}

/// An ephemeral drawing preview: it never enters the PDF or its undo history.
@MainActor
private final class InkPreviewView: NSView {
    weak var pdfView: PDFView?
    weak var page: PDFPage?
    var points: [CGPoint] = []
    var shapeTool: EditorTool?
    var color: NSColor = .systemRed
    weak var selectionPage: PDFPage?
    var selectionBounds: CGRect?
    weak var textPreviewPage: PDFPage?
    var textPreviewPoint = CGPoint.zero
    var textPreview: String?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let pdfView else { return }
        if let bounds = selectionBounds, let selectionPage {
            let rectangle = convert(pdfView.convert(bounds, from: selectionPage), from: pdfView).insetBy(dx: -3, dy: -3)
            let path = NSBezierPath(rect: rectangle)
            path.lineWidth = 2
            path.setLineDash([5, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
        if let textPreview, let textPreviewPage {
            let fontSize = (pdfView as? EditablePDFView)?.editorModel?.textFontSize ?? 18
            let point = pdfView.convert(textPreviewPoint, from: textPreviewPage)
            let rect = CGRect(x: point.x, y: point.y - 200 * pdfView.scaleFactor, width: 320 * pdfView.scaleFactor, height: 200 * pdfView.scaleFactor)
            (textPreview as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: fontSize * pdfView.scaleFactor), .foregroundColor: NSColor.black])
        }
        guard let page, let first = points.first else { return }
        if let shapeTool, let last = points.last {
            let pageRect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                                  width: abs(first.x - last.x), height: abs(first.y - last.y))
            let rectangle = convert(pdfView.convert(pageRect, from: page), from: pdfView)
            let shape = shapeTool == .ellipse ? NSBezierPath(ovalIn: rectangle) : NSBezierPath(rect: rectangle)
            shape.lineWidth = 2
            shape.setLineDash([5, 3], count: 2, phase: 0)
            if shapeTool == .redact {
                NSColor.black.withAlphaComponent(0.65).setFill()
                shape.fill()
            }
            (shapeTool == .redact ? NSColor.black : color).setStroke()
            shape.stroke()
            return
        }
        let path = NSBezierPath()
        path.lineWidth = max(1, CartaPreferences.shared.strokeWidth * pdfView.scaleFactor)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: convert(pdfView.convert(first, from: page), from: pdfView))
        if points.count == 1 {
            let point = convert(pdfView.convert(first, from: page), from: pdfView)
            path.line(to: CGPoint(x: point.x + 0.1, y: point.y + 0.1))
        } else {
            for point in points.dropFirst() {
                path.line(to: convert(pdfView.convert(point, from: page), from: pdfView))
            }
        }
        color.setStroke()
        path.stroke()
    }
}

@MainActor
struct PDFThumbnailSidebar: NSViewRepresentable {
    @ObservedObject var model: PDFEditorModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = ReadOnlyThumbnailView()
        view.thumbnailSize = NSSize(width: 120, height: 152)
        view.maximumNumberOfColumns = 1
        view.labelFont = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        view.backgroundColor = .windowBackgroundColor
        view.allowsDragging = false
        view.allowsMultipleSelection = false
        view.setAccessibilityLabel("Miniature delle pagine")
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: PDFThumbnailView, context: Context) {
        let documentChanged = context.coordinator.document !== model.document
        let pageCountChanged = context.coordinator.pageCount != model.document.pageCount
        if view.pdfView !== model.pdfView || documentChanged || pageCountChanged {
            view.pdfView = nil
            view.pdfView = model.pdfView
            context.coordinator.document = model.document
            context.coordinator.pageCount = model.document.pageCount
        }
    }

    @MainActor
    final class Coordinator {
        weak var document: PDFDocument?
        var pageCount = -1
    }
}

@MainActor
private final class ReadOnlyThumbnailView: PDFThumbnailView {
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { return }
        super.keyDown(with: event)
    }
}
