import AppKit
import PDFKit
import SwiftUI

private struct OutlineEntry: Identifiable {
    let outline: PDFOutline
    let depth: Int
    var id: ObjectIdentifier { ObjectIdentifier(outline) }
}

private struct CommentEntry: Identifiable {
    let annotation: PDFAnnotation
    let page: PDFPage
    let pageIndex: Int
    var id: ObjectIdentifier { ObjectIdentifier(annotation) }
}

struct DocumentNavigationView: View {
    @ObservedObject var model: PDFEditorModel
    let showOutline: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showOutline {
                HStack {
                    Text(L10n.tr("INDICE")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button(action: model.addBookmark) { Image(systemName: "bookmark.badge.plus") }
                        .buttonStyle(.borderless).help(L10n.tr("Aggiungi segnalibro")).accessibilityLabel(L10n.tr("Aggiungi segnalibro alla pagina corrente")).disabled(!model.canEditDocument)
                }.padding(.horizontal, 14).padding(.vertical, 8)
                if outlineEntries.isEmpty {
                    Text(L10n.tr("Nessun segnalibro. Aggiungi la pagina corrente con il pulsante +."))
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(20)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(outlineEntries) { entry in
                                Button {
                                    if let destination = entry.outline.destination { model.pdfView?.go(to: destination) }
                                    else if let action = entry.outline.action { model.pdfView?.perform(action) }
                                } label: {
                                    Label(entry.outline.label ?? L10n.tr("Segnalibro"), systemImage: "bookmark")
                                        .font(.callout).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 8).padding(.leading, CGFloat(min(entry.depth, 8)) * 12 + 10)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel(entry.outline.label ?? L10n.tr("Segnalibro"))
                                    .accessibilityValue(bookmarkDestination(entry))
                                    .accessibilityHint(L10n.tr("Vai alla destinazione del segnalibro. Livello \(entry.depth + 1) dell’indice."))
                            }
                        }.padding(.horizontal, 8)
                    }
                }
            } else {
                HStack {
                    Text(L10n.tr("\(comments.count) ANNOTAZIONI")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                    Spacer()
                }.padding(.horizontal, 14).padding(.vertical, 8)
                if comments.isEmpty {
                    Text(L10n.tr("Note, evidenziazioni e altre annotazioni appariranno qui."))
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(20)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 7) {
                            ForEach(comments) { entry in
                                Button {
                                    model.goToPage(entry.pageIndex)
                                    model.selectAnnotation(entry.annotation, on: entry.page)
                                    model.pdfView?.go(to: entry.annotation.bounds, on: entry.page)
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(L10n.tr("Pagina \(entry.pageIndex + 1) · \(typeName(entry.annotation.type))"))
                                            .font(.caption).foregroundStyle(.secondary)
                                        Text(entry.annotation.contents ?? "\(typeName(entry.annotation.type))")
                                            .font(.callout).lineLimit(4).foregroundStyle(.primary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                        .background(model.selectedAnnotation === entry.annotation ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(L10n.tr("\(typeName(entry.annotation.type)), pagina \(entry.pageIndex + 1): \(entry.annotation.contents ?? L10n.tr("Senza testo"))"))
                                .accessibilityAddTraits(model.selectedAnnotation === entry.annotation ? .isSelected : [])
                                .accessibilityHint(L10n.tr("Mostra e seleziona l’annotazione. Le azioni disponibili includono modifica ed eliminazione quando consentite."))
                                .accessibilityActions {
                                    if model.canEditAnnotations {
                                        if entry.annotation.type == "Text" || entry.annotation.type == "FreeText" {
                                            Button(L10n.tr("Modifica contenuto")) { model.editComment(entry.annotation, on: entry.page) }
                                        }
                                        Button(L10n.tr("Elimina annotazione"), role: .destructive) { model.removeAnnotation(entry.annotation, from: entry.page) }
                                    }
                                }
                                .contextMenu {
                                    if entry.annotation.type == "Text" || entry.annotation.type == "FreeText" {
                                        Button(L10n.tr("Modifica contenuto…")) { model.editComment(entry.annotation, on: entry.page) }
                                            .disabled(!model.canEditAnnotations)
                                    }
                                    Button(L10n.tr("Elimina annotazione"), role: .destructive) { model.removeAnnotation(entry.annotation, from: entry.page) }
                                        .disabled(!model.canEditAnnotations)
                                }
                            }
                        }.padding(10)
                    }
                }
            }
        }.accessibilityIdentifier(showOutline ? "sidebar.bookmarks" : "sidebar.comments")
    }

    private func bookmarkDestination(_ entry: OutlineEntry) -> String {
        guard let page = entry.outline.destination?.page else { return L10n.tr("Destinazione del segnalibro") }
        let index = model.document.index(for: page)
        return index == NSNotFound ? L10n.tr("Destinazione del segnalibro") : L10n.tr("Pagina \(index + 1)")
    }

    private var outlineEntries: [OutlineEntry] {
        guard let root = model.document.outlineRoot else { return [] }
        var entries: [OutlineEntry] = []
        func visit(_ parent: PDFOutline, depth: Int) {
            guard depth < 16, entries.count < 5000 else { return }
            for index in 0..<parent.numberOfChildren {
                guard let child = parent.child(at: index) else { continue }
                entries.append(OutlineEntry(outline: child, depth: depth))
                visit(child, depth: depth + 1)
            }
        }
        visit(root, depth: 0)
        return entries
    }

    private var comments: [CommentEntry] {
        var entries: [CommentEntry] = []
        for index in 0..<model.pageCount {
            guard let page = model.document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.type != "Widget" && annotation.type != "Link" && annotation.type != "Popup" {
                entries.append(CommentEntry(annotation: annotation, page: page, pageIndex: index))
            }
        }
        return entries
    }

    private func typeName(_ type: String?) -> String {
        switch type {
        case "Text": return L10n.tr("Nota")
        case "FreeText": return L10n.tr("Testo")
        case "Highlight": return L10n.tr("Evidenziazione")
        case "Ink": return L10n.tr("Disegno")
        case "Square": return L10n.tr("Rettangolo")
        case "Circle": return L10n.tr("Ellisse")
        default: return L10n.tr("Annotazione")
        }
    }
}

@MainActor
extension PDFEditorModel {
    func addBookmark() {
        guard canEditDocument, currentPage != nil else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("Aggiungi segnalibro")
        alert.addButton(withTitle: L10n.tr("Aggiungi"))
        alert.addButton(withTitle: L10n.tr("Annulla"))
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[0].keyEquivalentModifierMask = [.command]
        alert.buttons[1].keyEquivalent = "\u{1B}"
        let field = NSTextField(string: L10n.tr("Pagina \(currentPageIndex + 1)"))
        field.setAccessibilityLabel(L10n.tr("Titolo del segnalibro"))
        field.setAccessibilityHelp(L10n.tr("Il segnalibro punta alla pagina corrente. Comando Invio conferma."))
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 25)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        addBookmark(title: field.stringValue)
    }

    func addBookmark(title: String) {
        guard canEditDocument, let page = currentPage else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let bookmark = PDFOutline()
        let bounds = page.bounds(for: .cropBox)
        let destination = PDFDestination(page: page, at: CGPoint(x: bounds.minX, y: bounds.maxY))
        let root = document.outlineRoot ?? PDFOutline()
        insertBookmark(bookmark, title: title, destination: destination, in: root, at: root.numberOfChildren)
    }

    private func insertBookmark(_ bookmark: PDFOutline, title: String, destination: PDFDestination, in root: PDFOutline, at index: Int) {
        performChange(named: L10n.tr("Aggiungi segnalibro"), mutation: {
            root.insertChild(bookmark, at: index)
            // PDFKit treats a parentless node as an outline root and ignores its
            // destination. Assign leaf data only after the node has a parent.
            bookmark.label = title
            bookmark.destination = destination
            document.outlineRoot = root
            refreshBookmarkSerialization()
        }, inverse: { model in model.removeBookmark(bookmark, title: title, destination: destination, from: root, at: index) })
    }

    private func removeBookmark(_ bookmark: PDFOutline, title: String, destination: PDFDestination, from root: PDFOutline, at index: Int) {
        performChange(named: L10n.tr("Aggiungi segnalibro"), mutation: {
            bookmark.removeFromParent()
            refreshBookmarkSerialization()
        }, inverse: { model in
            model.insertBookmark(bookmark, title: title, destination: destination, in: root, at: index)
        })
    }

    private func refreshBookmarkSerialization() {
        // PDFKit's original-document writer can omit a changed outline. Reinsert the
        // identical page at the identical index to select its page-tree writer, which
        // includes the outline while retaining page objects, annotations and encryption.
        guard let firstPage = document.page(at: 0) else { return }
        let selectedIndex = currentPageIndex
        document.removePage(at: 0)
        document.insert(firstPage, at: 0)
        currentPageIndex = selectedIndex
    }

    func editComment(_ annotation: PDFAnnotation, on page: PDFPage) {
        guard canEditAnnotations else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("Modifica annotazione")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 130))
        let text = NSTextView(frame: scroll.bounds)
        text.setAccessibilityLabel(L10n.tr("Contenuto dell’annotazione"))
        text.setAccessibilityHelp(L10n.tr("Modifica il testo; Comando Invio conferma, Esc annulla."))
        text.isRichText = false
        text.string = annotation.contents ?? ""
        text.font = .systemFont(ofSize: 14)
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = text
        alert.addButton(withTitle: L10n.tr("Conferma"))
        alert.addButton(withTitle: L10n.tr("Annulla"))
        alert.buttons[0].keyEquivalent = "\r"; alert.buttons[0].keyEquivalentModifierMask = [.command]
        alert.buttons[1].keyEquivalent = "\u{1B}"
        if alert.runModal() == .alertFirstButtonReturn { updateAnnotation(annotation, text: text.string, on: page) }
    }
}
