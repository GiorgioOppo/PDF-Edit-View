import AppKit
import PDFKit
import SwiftUI

enum PDFFormFieldKind: String, CaseIterable {
    case text, checkbox, choice, unsupported
    var title: String {
        switch self {
        case .text: return L10n.tr("Testo")
        case .checkbox: return L10n.tr("Casella di spunta")
        case .choice: return L10n.tr("Elenco")
        case .unsupported: return L10n.tr("Campo non supportato")
        }
    }
}

struct PDFFormField: Identifiable {
    let annotation: PDFAnnotation
    let pageIndex: Int
    let kind: PDFFormFieldKind
    let name: String
    let value: String
    let choices: [String]
    let editable: Bool
    var id: ObjectIdentifier { ObjectIdentifier(annotation) }
}

@MainActor
extension PDFEditorModel {
    var formFields: [PDFFormField] {
        var fields: [PDFFormField] = []
        for pageIndex in 0..<pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations where annotation.type == "Widget" {
                let kind: PDFFormFieldKind
                switch annotation.widgetFieldType {
                case .text: kind = .text
                case .choice: kind = .choice
                case .button where annotation.widgetControlType == .checkBoxControl: kind = .checkbox
                default: kind = .unsupported
                }
                var value = annotation.widgetStringValue ?? ""
                if kind == .checkbox { value = annotation.buttonWidgetState == .onState ? "true" : "false" }
                if kind == .choice, let index = annotation.values?.firstIndex(of: value), let choices = annotation.choices, choices.indices.contains(index) {
                    value = choices[index]
                }
                fields.append(PDFFormField(annotation: annotation, pageIndex: pageIndex, kind: kind,
                                           name: annotation.fieldName ?? L10n.tr("Campo senza nome"), value: value,
                                           choices: annotation.choices ?? [],
                                           editable: canFillForms && !formWasOriginallyReadOnly(annotation) && kind != .unsupported && !annotation.isPasswordField))
            }
        }
        return fields
    }

    func setFormValue(_ value: String, for field: PDFFormField) { setFormValue(value, for: field.annotation) }

    func setFormValue(_ value: String, for annotation: PDFAnnotation) {
        guard canFillForms, let entry = formFields.first(where: { $0.annotation === annotation }), entry.editable else {
            errorMessage = L10n.tr("Il campo è di sola lettura o non è supportato.")
            return
        }
        guard entry.value != value else { return }
        if entry.kind == .text, annotation.maximumLength > 0, value.count > annotation.maximumLength {
            errorMessage = L10n.tr("Questo campo accetta al massimo \(annotation.maximumLength) caratteri.")
            return
        }
        if entry.kind == .choice, !entry.choices.contains(value) {
            errorMessage = L10n.tr("Scegli un valore presente nell’elenco.")
            return
        }
        let related = formFields.filter {
            $0.annotation === annotation || (annotation.fieldName != nil && $0.annotation.fieldName == annotation.fieldName && $0.kind == entry.kind && $0.editable)
        }
        let changes = related.map { field -> FormValueState in
            if entry.kind == .checkbox {
                return FormValueState(annotation: field.annotation, value: field.annotation.widgetStringValue,
                                      state: value == "true" ? .onState : .offState)
            }
            var storedValue = value
            if entry.kind == .choice, let index = field.annotation.choices?.firstIndex(of: value),
               let values = field.annotation.values, values.indices.contains(index) { storedValue = values[index] }
            return FormValueState(annotation: field.annotation, value: storedValue, state: field.annotation.buttonWidgetState)
        }
        applyFormValues(changes)
    }

    private func applyFormValues(_ values: [FormValueState]) {
        let previous = values.map { FormValueState(annotation: $0.annotation, value: $0.annotation.widgetStringValue, state: $0.annotation.buttonWidgetState) }
        performChange(named: L10n.tr("Compila campo"), mutation: {
            for value in values {
                value.annotation.isReadOnly = false
                if value.annotation.widgetFieldType == .button {
                    value.annotation.buttonWidgetState = value.state
                } else { value.annotation.widgetStringValue = value.value }
                value.annotation.isReadOnly = true
            }
        }, inverse: { model in model.applyFormValues(previous) })
    }

    func prepareForm() {
        guard requireAdvancedPermission(canEditDocument), let page = currentPage else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("Prepara modulo")
        alert.informativeText = L10n.tr("Aggiunge un campo al centro della pagina corrente. I valori si compilano dal pannello Moduli.")
        let name = NSTextField(string: L10n.tr("Campo \(formFields.count + 1)"))
        name.setAccessibilityLabel(L10n.tr("Nome del nuovo campo modulo"))
        name.setAccessibilityHelp(L10n.tr("Nome univoco usato nel pannello Moduli e nelle intestazioni CSV."))
        let type = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 250, height: 26))
        type.setAccessibilityLabel(L10n.tr("Tipo del nuovo campo modulo"))
        type.addItems(withTitles: [L10n.tr("Testo"), L10n.tr("Casella di spunta"), L10n.tr("Elenco")])
        let choices = NSTextField(string: L10n.tr("Opzione 1, Opzione 2"))
        choices.setAccessibilityLabel(L10n.tr("Voci del nuovo elenco"))
        choices.setAccessibilityHelp(L10n.tr("Separa le opzioni con virgole; usato soltanto per campi elenco."))
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 10
        container.addArrangedSubview(Self.formAccessory(labels: [L10n.tr("Nome")], fields: [name]))
        container.addArrangedSubview(type)
        container.addArrangedSubview(Self.formAccessory(labels: [L10n.tr("Voci elenco")], fields: [choices]))
        container.frame = NSRect(x: 0, y: 0, width: 370, height: 110)
        alert.accessoryView = container
        alert.addButton(withTitle: L10n.tr("Aggiungi campo"))
        alert.addButton(withTitle: L10n.tr("Annulla"))
        name.nextKeyView = type; type.nextKeyView = choices; choices.nextKeyView = alert.buttons[0]
        alert.window.initialFirstResponder = name
        alert.buttons[0].keyEquivalent = "\r"; alert.buttons[0].keyEquivalentModifierMask = [.command]
        alert.buttons[1].keyEquivalent = "\u{1B}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let bounds = page.bounds(for: .cropBox)
        let kind: PDFFormFieldKind = [.text, .checkbox, .choice][type.indexOfSelectedItem]
        addFormField(name: name.stringValue, kind: kind, at: CGPoint(x: bounds.midX - 90, y: bounds.midY), on: page,
                     choices: choices.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    func addFormField(name: String, kind: PDFFormFieldKind, at point: CGPoint, on page: PDFPage, choices: [String] = []) {
        guard requireAdvancedPermission(canEditDocument), document.index(for: page) != NSNotFound else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !formFields.contains(where: { $0.name == name }) else {
            errorMessage = L10n.tr("Assegna al campo un nome non vuoto e diverso dagli altri.")
            return
        }
        guard kind != .unsupported else { return }
        let bounds = page.bounds(for: .cropBox)
        let width: CGFloat = kind == .checkbox ? 22 : min(180, bounds.width)
        let height: CGFloat = kind == .checkbox ? 22 : 28
        let rect = CGRect(x: min(max(point.x, bounds.minX), bounds.maxX - width),
                          y: min(max(point.y, bounds.minY), bounds.maxY - height), width: width, height: height)
        let annotation = PDFAnnotation(bounds: rect, forType: .widget, withProperties: nil)
        annotation.isReadOnly = false
        annotation.font = NSFont.systemFont(ofSize: 13)
        annotation.fontColor = .black
        annotation.backgroundColor = .white
        annotation.color = .gray
        let border = PDFBorder(); border.lineWidth = 1; annotation.border = border
        switch kind {
        case .text:
            annotation.widgetFieldType = .text
            annotation.widgetStringValue = ""
        case .checkbox:
            annotation.widgetFieldType = .button
            annotation.widgetControlType = .checkBoxControl
            annotation.buttonWidgetStateString = "Yes"
            annotation.buttonWidgetState = .offState
        case .choice:
            var options: [String] = []
            for option in choices where !option.isEmpty && !options.contains(option) { options.append(option) }
            guard !options.isEmpty else { errorMessage = L10n.tr("Inserisci almeno una voce per l’elenco."); return }
            annotation.widgetFieldType = .choice
            annotation.choices = options
            annotation.values = options
            annotation.widgetStringValue = options[0]
            annotation.isListChoice = false
        case .unsupported: return
        }
        // PDFKit initializes the underlying form object when its field type is assigned.
        annotation.fieldName = name
        addBatchAnnotations([(page, annotation)], actionName: L10n.tr("Aggiungi campo modulo"))
    }
}

private struct FormValueState {
    let annotation: PDFAnnotation
    let value: String?
    let state: PDFWidgetCellState
}

@MainActor
struct PDFFormsView: View {
    @ObservedObject var model: PDFEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    private var filteredFields: [PDFFormField] {
        model.formFields.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.tr("Moduli PDF")).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text(L10n.tr("Testo, caselle di spunta ed elenchi. Ogni modifica supporta Annulla.")).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.tr("Aggiungi campo")) { model.prepareForm() }.disabled(!model.canEditDocument)
                Button(L10n.tr("Fine")) { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(22)
            Divider()
            TextField(L10n.tr("Cerca un campo per nome"), text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 22).padding(.top, 12)
                .accessibilityLabel(L10n.tr("Cerca campi modulo per nome")).accessibilityHint(L10n.tr("Comando F sposta qui il focus.")).focused($searchFocused)
            if let error = model.errorMessage {
                HStack {
                    CartaPanelAccessibilityStatus(message: error, label: L10n.tr("Errore modulo"), announceOnAppear: true).foregroundStyle(.red)
                    Spacer()
                    Button(L10n.tr("Chiudi avviso")) { model.errorMessage = nil }.buttonStyle(.link)
                }.padding(.horizontal, 22).padding(.vertical, 10)
            }
            if model.formFields.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "list.bullet.rectangle").font(.system(size: 40)).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(L10n.tr("Il documento non contiene campi modulo."))
                    Button(L10n.tr("Crea un campo")) { model.prepareForm() }.disabled(!model.canEditDocument)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(Set(filteredFields.map(\.pageIndex))).sorted(), id: \.self) { index in
                            Section {
                                ForEach(filteredFields.filter { $0.pageIndex == index }.sorted { $0.annotation.bounds.maxY > $1.annotation.bounds.maxY }) { field in
                                    PDFFormFieldRow(model: model, field: field)
                                }
                            } header: {
                                Text(L10n.tr("Pagina \(index + 1)")).font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8).accessibilityAddTraits(.isHeader)
                            }
                        }
                    }.padding(22)
                }
            }
        }
        .frame(width: 700, height: 560).accessibilityIdentifier("panel.forms")
        .background { Button(L10n.tr("Cerca campo modulo")) { searchFocused = true }.keyboardShortcut("f", modifiers: .command).hidden() }
    }
}

@MainActor
private struct PDFFormFieldRow: View {
    @ObservedObject var model: PDFEditorModel
    let field: PDFFormField
    @State private var draft = ""
    @State private var edited = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(field.name).font(.headline).accessibilityAddTraits(.isHeader)
                if isRequired { Text(L10n.tr("Obbligatorio")).font(.caption).foregroundStyle(.orange) }
                Text(L10n.tr("Pagina \(field.pageIndex + 1) · \(field.kind.title)")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("Mostra")) {
                    model.goToPage(field.pageIndex)
                    model.selectAnnotation(field.annotation, on: model.document.page(at: field.pageIndex))
                }.buttonStyle(.link).accessibilityLabel(L10n.tr("Mostra il campo \(field.name) a pagina \(field.pageIndex + 1)"))
            }
            if !field.editable {
                Text(field.annotation.isPasswordField ? L10n.tr("Campo password non modificabile da questo pannello.") : L10n.tr("\(field.value) · Sola lettura"))
                    .foregroundStyle(.secondary)
                Text(readOnlyReason).font(.caption).foregroundStyle(.secondary)
            } else {
                switch field.kind {
                case .text:
                    HStack {
                        Group {
                            if field.annotation.isMultiline {
                                TextEditor(text: $draft).frame(minHeight: 70, maxHeight: 100).accessibilityLabel(L10n.tr("\(field.name), testo su più righe, pagina \(field.pageIndex + 1)")).accessibilityHint(editingHint)
                            } else {
                                TextField(L10n.tr("Valore"), text: $draft).textFieldStyle(.roundedBorder)
                                    .accessibilityLabel(L10n.tr("\(field.name), pagina \(field.pageIndex + 1)")).accessibilityHint(editingHint)
                                    .onSubmit { saveDraft() }
                            }
                        }
                            .onChange(of: draft) { _, _ in edited = draft != field.value }
                        Button(L10n.tr("Applica")) { saveDraft() }.disabled(!edited).accessibilityLabel(L10n.tr("Applica il valore di \(field.name)"))
                    }
                    HStack {
                        Text(edited ? L10n.tr("Modifica da applicare") : L10n.tr("Valore confermato")).foregroundStyle(edited ? .orange : .secondary)
                        Spacer()
                        if field.annotation.maximumLength > 0 { Text(L10n.tr("\(draft.count) / \(field.annotation.maximumLength) caratteri")) }
                    }.font(.caption)
                case .checkbox:
                    Toggle(L10n.tr("Selezionata"), isOn: Binding(get: { field.value == "true" }, set: { model.setFormValue($0 ? "true" : "false", for: field) }))
                        .accessibilityLabel(L10n.tr("\(field.name), casella di spunta, pagina \(field.pageIndex + 1)")).accessibilityHint(isRequired ? L10n.tr("Campo obbligatorio. La modifica viene applicata subito.") : L10n.tr("La modifica viene applicata subito."))
                case .choice:
                    Picker(L10n.tr("Valore"), selection: Binding(get: { field.value }, set: { model.setFormValue($0, for: field) })) {
                        ForEach(field.choices, id: \.self) { Text($0).tag($0) }
                    }.accessibilityLabel(L10n.tr("\(field.name), elenco, pagina \(field.pageIndex + 1)")).accessibilityHint(isRequired ? L10n.tr("Campo obbligatorio. La scelta viene applicata subito.") : L10n.tr("La scelta viene applicata subito."))
                case .unsupported: EmptyView()
                }
                if model.formFields.filter({ $0.name == field.name }).count > 1 {
                    Text(L10n.tr("Valore condiviso: la modifica aggiorna tutti i campi con questo nome.")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain).accessibilityLabel(L10n.tr("Campo \(field.name), \(field.kind.title), pagina \(field.pageIndex + 1)"))
        .onAppear { draft = field.value }
        .onChange(of: field.value) { _, value in draft = value; edited = false }
    }

    private func saveDraft() { model.setFormValue(draft, for: field); edited = false }
    private var editingHint: String {
        let limit = field.annotation.maximumLength > 0 ? L10n.tr("Massimo \(field.annotation.maximumLength) caratteri. ") : ""
        let required = isRequired ? L10n.tr("Campo obbligatorio. ") : ""
        let error = model.errorMessage.map { L10n.tr("Errore: \($0). ") } ?? ""
        return required + limit + error + L10n.tr("Premi Applica per confermare il valore.")
    }
    private var isRequired: Bool {
        let flags = (field.annotation.value(forAnnotationKey: .widgetFieldFlags) as? NSNumber)?.intValue ?? 0
        return flags & 2 != 0
    }
    private var readOnlyReason: String {
        if field.annotation.isPasswordField { return L10n.tr("Il campo contiene una password e non viene mostrato né modificato dal pannello.") }
        if !model.canFillForms { return L10n.tr("I permessi del documento non consentono la compilazione.") }
        if field.kind == .unsupported { return L10n.tr("Questo tipo di widget richiede un motore non disponibile nel pannello.") }
        return L10n.tr("Il PDF dichiara questo campo in sola lettura.")
    }
}
