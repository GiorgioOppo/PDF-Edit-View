import Foundation
import CryptoKit
import Security

/// Original Swift checks over standard PDF relationships, never key-name guesses
/// inside private application data. Atomic profile predicates are kept distinct
/// from complete ISO conformance and from cryptographic trust.
final class PDFArchiveStructureChecks {
    private struct Record {
        let value: [String: PDFSyntaxValue]
        let id: PDFObjectID?
        let location: String
        var key: String { id?.syntax ?? location }
    }
    private struct Model {
        var annotations: [Record] = [], fields: [Record] = [], forms: [Record] = []
        var files: [Record] = [], signatures: [Record] = [], threeD: [Record] = [], engineeringAssets: [Record] = []
        var elements: [Record] = [], languages: [(PDFSyntaxValue, String)] = []
        var associated = Set<String>(), fileKeys = Set<String>(), annotationKeys = Set<String>()
        var resourceKeys = Set<String>(), contentObjectKeys = Set<String>()
        var contentStreams: [(PDFObjectID, [String: PDFSyntaxValue])] = []
        var structureIssues: [String] = [], structureGaps: [String] = []
        var associationGaps: [String] = [], associationIssues: [String] = []
        var associationCount = 0
        var structureRoot: Record?
    }
    private final class AttachmentBudget: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0, bytes = 0
        func reserve(_ size: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard calls < 256, size <= 64 * 1024 * 1024, bytes <= 128 * 1024 * 1024 - size else { return false }
            calls += 1; bytes += size; return true
        }
    }
    private struct Recursion: Sendable { var hashes = Set<String>(); var depth = 0; var budget: AttachmentBudget? }
    @TaskLocal private static var recursion = Recursion()
    private let reader: PDFStructureDocument
    private let profile: PDFArchiveProfile
    private var cached: Result<Model, Error>?
    private lazy var logicalChecks = PDFArchiveLogicalStructureChecks(reader: reader, profile: profile)
    private var standardTags: Set<String> {
        let tags = Set("Document Part Art Sect Div BlockQuote Caption TOC TOCI Index NonStruct Private P H H1 H2 H3 H4 H5 H6 L LI Lbl LBody Table TR TH TD THead TBody TFoot Span Quote Note Reference BibEntry Code Link Annot Ruby RB RT RP Warichu WT WP Figure Formula Form".split(separator: " ").map(String.init))
        // Adobe PDF Reference 1.4 §9.7.4, tables 9.18–9.24. Later
        // structure types can still be custom types if explicitly role-mapped.
        return profile.part == 1 ? tags.subtracting(["THead", "TBody", "TFoot", "Annot", "Ruby", "RB", "RT", "RP", "Warichu", "WT", "WP"]) : tags
    }

    init(reader: PDFStructureDocument, profile: PDFArchiveProfile) { self.reader = reader; self.profile = profile }

    /// Base PDF2 associated-file relationships apply beyond the closed
    /// catalogue's embedded-file predicates, including external Filespecs.
    var modelChecks: [PDFArchiveRuleResult] {
        guard !reader.encrypted else { return [] }
        var results: [PDFArchiveRuleResult] = []
        if let logical = logicalChecks.modelCheck { results.append(logical) }
        guard profile.part == 4, let model = try? loadModel() else { return results }
        if model.associationCount > 0 || !model.associationIssues.isEmpty || !model.associationGaps.isEmpty {
            let status: PDFArchiveRuleStatus = !model.associationIssues.isEmpty ? .failed : (!model.associationGaps.isEmpty ? .notVerified : .passed)
            results.append(.init(id: "CartaPDF:ISO32000:associated-file-relationships",
                      specification: "ISO 32000-2:2020", clause: "14.13.1, 14.13.5",
                      testNumber: "native-associated-file-relationships", objectType: "AssociatedFileModel",
                      requirement: "AF/MCAF sono array di specifiche file con AFRelationship; il tag AF descrive sequenze e non punti MP/DP.",
                      status: status,
                      detail: "Associazioni PDF2 nei dizionari attivi e nelle sequenze marcate; errata §14.13 e AN002. " + model.associationGaps.joined(separator: "; "),
                      locations: Array(model.associationIssues.prefix(64))))
        }
        if profile == .pdfa4e {
            var seen = Set<String>()
            for record in model.threeD + model.engineeringAssets where seen.insert(record.key).inserted {
                let subtype = (try? name(record.value["Subtype"])) ?? ""
                guard ["U3D", "PRC"].contains(subtype) else { continue } // Independent catalogue predicate.
                let audit: PDFArchiveEngineeringChecks.Audit
                do {
                    guard let id = record.id, try reader.object(id).stream != nil else {
                        audit = .init(structure: .check(false, "3DD non è un oggetto stream indiretto."),
                                      payload: .unknown("Payload 3D assente/non referenziabile."))
                        results += engineeringResults(audit, subtype: subtype, location: record.location, key: record.key)
                        continue
                    }
                    audit = PDFArchiveEngineeringChecks.audit(try reader.decodedStream(id), subtype: subtype)
                } catch {
                    audit = .init(structure: .unknown("Flusso 3D non decodificato: " + error.localizedDescription),
                                  payload: .unknown("Payload 3D non visitato."))
                }
                results += engineeringResults(audit, subtype: subtype, location: record.location, key: record.key)
            }
        }
        return results
    }

    private func engineeringResults(_ audit: PDFArchiveEngineeringChecks.Audit, subtype: String, location: String, key: String) -> [PDFArchiveRuleResult] {
        [("structure", audit.structure), ("payload", audit.payload)].map { category, evaluation in
            .init(id: "CartaPDF:Engineering:\(subtype):\(category):\(key)",
                  specification: subtype == "U3D" ? "ECMA-363, 3rd edition" : "ISO 14739-1",
                  clause: subtype == "U3D" ? "5.2, 8.10, 9.1–9.4, 10.4.2" : "6",
                  testNumber: "native-\(subtype.lowercased())-\(category)", objectType: "EngineeringModel",
                  requirement: category == "structure" ? "Il flusso 3D deve rispettare la struttura del formato dichiarato." : "Il payload 3D richiede la validazione delle entità geometriche e delle estensioni.",
                  status: evaluation.status, detail: location + ": " + evaluation.detail,
                  locations: evaluation.locations.map { location + ": " + $0 })
        }
    }

    func evaluate(_ rule: PDFArchiveCatalogueRule) throws -> PDFArchiveRuleEvaluation? {
        let object = rule.objectType, expression = rule.expression
        let owned = Set(["PDAnnot", "PDWidgetAnnot", "PDFormField", "PDAcroForm", "PDAdditionalActions", "PDOCConfig", "SENonStandard", "CosLang", "CosFileSpecification", "EmbeddedFile", "PDSignature", "PKCSDataObject", "PDSigRef", "PD3DStream"])
        let logical = object == "PDDocument" && expression == "containsStructTreeRoot == true"
        let marked = object == "CosDocument" && expression == "Marked == true"
        let embedded = object == "CosDocument" && ["containsEmbeddedFiles == true", "containsEmbeddedFiles == false"].contains(expression)
        guard owned.contains(object) || logical || marked || embedded else { return nil }
        if reader.encrypted { return .unknown("Contenuti strutturali cifrati: controlli non eseguiti.") }
        let model = try loadModel(), root = try dictionary(.reference(reader.rootID))
        switch object {
        case "PDAnnot": return try annotation(rule, model: model)
        case "PDWidgetAnnot":
            let widgets = try model.annotations.filter { try name($0.value["Subtype"]) == "Widget" }
            if expression == "AP != null" { return try check(widgets, "Appearance dei widget") { try self.resolved($0.value["AP"])?.dictionary != nil } }
            return try check(widgets, "Azioni nei widget") {
                if expression.contains("containsA == false"), try self.resolved($0.value["A"]) != nil { return false }
                if expression.contains("containsAA == false"), try self.resolved($0.value["AA"]) != nil { return false }
                return true
            }
        case "PDFormField":
            guard expression == "containsAA == false" else { return .unknown("Predicato del campo non implementato.") }
            return try check(model.fields, "AA nei campi modulo") { try self.resolved($0.value["AA"]) == nil }
        case "PDAcroForm":
            if expression == "containsXFA == false" { return try check(model.forms, "XFA assente") { try self.resolved($0.value["XFA"]) == nil } }
            if expression == "NeedAppearances == null || NeedAppearances == false" { return try check(model.forms, "NeedAppearances assente o false") { record in
                guard let value = try self.resolved(record.value["NeedAppearances"]) else { return true }
                if case .boolean(false) = value { return true }; return false
            } }
            return .unknown("Predicato AcroForm non implementato.")
        case "PDAdditionalActions": return try additionalActions(root: root, model: model)
        case "PDOCConfig": return try optionalContent(rule, root: root)
        case "SENonStandard": return try roleMap(rule, model: model)
        case "CosLang": return try language(rule, model: model)
        case "CosFileSpecification", "EmbeddedFile":
            let result = try object == "CosFileSpecification" ? fileSpecification(rule, model: model) : embeddedFile(rule, model: model)
            if result.status == .failed || model.associationGaps.isEmpty { return result }
            return .unknown(model.associationGaps.joined(separator: "; "))
        case "PDSignature", "PKCSDataObject", "PDSigRef": return try signature(rule, root: root, model: model)
        case "PD3DStream":
            guard expression == "Subtype == 'U3D' || Subtype == 'PRC'" else { return .unknown("Predicato 3D non implementato.") }
            return try check(model.threeD, "Sottotipo dei flussi 3D referenziati; payload U3D/PRC verificato separatamente") { try ["U3D", "PRC"].contains(self.name($0.value["Subtype"]) ?? "") }
        default:
            if marked {
                let mark = try dictionary(root["MarkInfo"])
                if case .boolean(true)? = try resolved(mark["Marked"]) { return .check(true, "Catalog/MarkInfo/Marked è boolean true.") }
                return .check(false, "Catalog/MarkInfo/Marked deve essere boolean true.")
            }
            if logical {
                guard model.structureRoot != nil else { return .check(false, "StructTreeRoot assente o non è un dizionario.") }
                if !model.structureIssues.isEmpty { return .check(false, "Albero strutturale, ParentTree o riferimenti incoerenti.", locations: model.structureIssues) }
                if !model.structureGaps.isEmpty { return .unknown(model.structureGaps.joined(separator: "; ")) }
                return .check(true, "Albero strutturale, parent e ParentTree coerenti; documento senza contenuto dipinto da assegnare alla struttura.")
            }
            if embedded {
                let names = try dictionary(root["Names"]), present = try resolved(names["EmbeddedFiles"]) != nil
                return .check(expression.hasSuffix("true") ? present : !present, "Chiave Catalog/Names/EmbeddedFiles: \(present).")
            }
            return nil
        }
    }

    private func resolved(_ original: PDFSyntaxValue?) throws -> PDFSyntaxValue? {
        try PDFArchiveStructureReferences.resolve(original, reader: reader).value
    }
    private func identity(_ original: PDFSyntaxValue?) throws -> PDFObjectID? { try PDFArchiveStructureReferences.resolve(original, reader: reader).id }
    private func dictionary(_ value: PDFSyntaxValue?) throws -> [String: PDFSyntaxValue] {
        guard let value = try resolved(value) else { return [:] }
        guard let dictionary = value.dictionary else { throw PDFStructureError.malformed("dizionario strutturale atteso") }
        return dictionary
    }
    private func array(_ value: PDFSyntaxValue?) throws -> [PDFSyntaxValue] {
        guard let value = try resolved(value) else { return [] }
        guard let array = value.array else { throw PDFStructureError.malformed("array strutturale atteso") }
        return array
    }
    private func name(_ value: PDFSyntaxValue?) throws -> String? { try resolved(value)?.name }
    private func integer(_ value: PDFSyntaxValue?) throws -> Int? { try resolved(value)?.int }
    private func record(_ value: PDFSyntaxValue, _ location: String) throws -> Record { .init(value: try dictionary(value), id: try identity(value), location: location) }
    private func check(_ records: [Record], _ summary: String, _ predicate: (Record) throws -> Bool) throws -> PDFArchiveRuleEvaluation {
        guard !records.isEmpty else { return .absent("Nessun oggetto applicabile: " + summary) }
        var failed: [String] = []
        for record in records { try Task.checkCancellation(); if try !predicate(record) { failed.append(record.location) } }
        return .check(failed.isEmpty, "\(records.count) oggetti: " + summary, locations: Array(failed.prefix(64)))
    }
    private func loadModel() throws -> Model {
        if cached == nil { cached = Result { try buildModel() } }
        return try cached!.get()
    }
    private func buildModel() throws -> Model {
        var model = Model(), fieldKeys = Set<String>(), visits = 0
        let root = try dictionary(.reference(reader.rootID))
        func associated(_ dictionary: [String: PDFSyntaxValue], _ location: String, key: String = "AF") throws {
            let values: [PDFSyntaxValue]
            if profile.part == 4 {
                guard let actual = try resolved(dictionary[key]) else { return }
                model.associationCount += 1
                guard let array = actual.array else { model.associationIssues.append(location + "/\(key): array richiesto"); return }
                values = array
            } else { values = try array(dictionary[key]) }
            for (index, value) in values.enumerated() {
                if profile.part == 4 {
                    guard let spec = try resolved(value)?.dictionary else {
                        model.associationIssues.append(location + "/\(key)[\(index)]: specifica file non dizionario"); continue
                    }
                    if let type = try resolved(spec["Type"]), type.name != "Filespec" {
                        model.associationIssues.append(location + "/\(key)[\(index)]: Type diverso da Filespec")
                    }
                    if try name(spec["AFRelationship"]) == nil {
                        model.associationIssues.append(location + "/\(key)[\(index)]: AFRelationship assente/non Name")
                    }
                }
                let file = try record(value, location + "/\(key)[\(index)]")
                model.associated.insert(file.key)
                if model.fileKeys.insert(file.key).inserted { model.files.append(file) }
            }
        }
        var actionKeys = Set<String>()
        func action(_ value: PDFSyntaxValue, _ location: String, depth: Int) throws {
            guard depth < 80 else { throw PDFStructureError.limit }
            guard try resolved(value)?.dictionary != nil else { return }
            let item = try record(value, location)
            guard actionKeys.insert(item.key).inserted else { return }
            let subtype = try name(item.value["S"])
            if ["GoToR", "GoToE", "Launch", "SubmitForm", "ImportData"].contains(subtype ?? ""),
               let fileValue = item.value["F"], try resolved(fileValue)?.dictionary != nil {
                let file = try record(fileValue, location + "/F")
                if model.fileKeys.insert(file.key).inserted { model.files.append(file) }
            }
            if let next = item.value["Next"] {
                if let children = try resolved(next)?.array { for (i, child) in children.enumerated() { try action(child, location + "/Next[\(i)]", depth: depth + 1) } }
                else { try action(next, location + "/Next", depth: depth + 1) }
            }
        }
        func actions(_ dictionary: [String: PDFSyntaxValue], _ location: String) throws {
            for key in ["A", "OpenAction"] { if let value = dictionary[key] { try action(value, location + "/" + key, depth: 0) } }
            for (event, value) in try self.dictionary(dictionary["AA"]) { try action(value, location + "/AA/" + event, depth: 0) }
        }
        func richMediaFile(_ value: PDFSyntaxValue, _ location: String) throws {
            let file = try record(value, location)
            if model.fileKeys.insert(file.key).inserted { model.files.append(file) }
            guard profile == .pdfa4e else { return }
            for (key, stream) in try dictionary(file.value["EF"]) where ["F", "UF", "DOS", "Mac", "Unix"].contains(key) {
                let payload = try record(stream, location + "/EF/" + key)
                let mime = try name(payload.value["Subtype"])?.lowercased()
                guard let format = ["model/u3d": "U3D", "model/prc": "PRC"][mime ?? ""] else { continue }
                // MIME is read from the actual embedded-file stream. The
                // normalized copy belongs only to EngineeringModel; it never
                // invents a PD3DStream object or alters the catalogue predicate.
                var value = payload.value; value["Subtype"] = .name(format)
                model.engineeringAssets.append(.init(value: value, id: payload.id, location: payload.location))
            }
        }
        func annotationRecord(_ value: PDFSyntaxValue, _ location: String) throws {
            let item = try record(value, location)
            guard model.annotationKeys.insert(item.key).inserted else { return }
            model.annotations.append(item); try associated(item.value, location); try actions(item.value, location)
            if let file = item.value["FS"], try name(item.value["Subtype"]) == "FileAttachment" {
                let file = try record(file, location + "/FS")
                if model.fileKeys.insert(file.key).inserted { model.files.append(file) }
            }
            let subtype = try name(item.value["Subtype"])
            if subtype == "3D", let value = item.value["3DD"] {
                var data = try record(value, location + "/3DD")
                if try name(data.value["Type"]) == "3DRef", let target = data.value["3DD"] { data = try record(target, location + "/3DD/3DD") }
                model.threeD.append(data)
            }
            if subtype == "RichMedia", let content = item.value["RichMediaContent"] {
                let content = try dictionary(content)
                if let assets = content["Assets"] {
                    for (index, value) in try treeValues(assets, pairs: "Names").enumerated() {
                        try richMediaFile(value, location + "/RichMediaContent/Assets[\(index)]")
                    }
                }
                // ISO32000-2 Table343, approved erratum: an Instance/Asset may
                // reference a Filespec outside the Assets name tree.
                for (index, configuration) in try array(content["Configurations"]).enumerated() {
                    let configuration = try dictionary(configuration)
                    for (j, instance) in try array(configuration["Instances"]).enumerated() {
                        let instance = try dictionary(instance)
                        if let asset = instance["Asset"] {
                            try richMediaFile(asset, location + "/RichMediaContent/Configurations[\(index)]/Instances[\(j)]/Asset")
                        }
                    }
                }
            }
        }
        func resource(_ value: PDFSyntaxValue?, _ location: String, depth: Int) throws {
            guard depth < 80 else { throw PDFStructureError.limit }
            guard let value = try resolved(value) else { return }
            let resources = try dictionary(value)
            for category in ["XObject", "Pattern", "Font"] {
                for (key, value) in try dictionary(resources[category]) {
                    let object = try record(value, location + "/\(category)/" + key)
                    guard model.resourceKeys.insert(object.key).inserted else { continue }
                    if category == "XObject" { model.contentObjectKeys.insert(object.key) }
                    // PDF/A-3 Table E.1 is a closed list. PDF 2.0 opens AF to
                    // additional object dictionaries, including font resources.
                    if category == "XObject" || profile.part == 4 { try associated(object.value, object.location) }
                    try resource(object.value["Resources"], object.location + "/Resources", depth: depth + 1)
                    let subtype = try name(object.value["Subtype"])
                    if let id = object.id, try reader.object(id).stream != nil, category == "Pattern" || subtype == "Form" {
                        model.contentStreams.append((id, try dictionary(object.value["Resources"])))
                    }
                    if category == "Font", try name(object.value["Subtype"]) == "Type3" {
                        for (glyph, value) in try dictionary(object.value["CharProcs"]) {
                            if let id = value.reference { model.contentStreams.append((id, try dictionary(object.value["Resources"]))); _ = glyph }
                        }
                    }
                }
            }
            for (_, property) in try dictionary(resources["Properties"]) {
                let property = try dictionary(property)
                if let language = property["Lang"] { model.languages.append((language, location + "/Properties/Lang")) }
            }
        }
        func field(_ value: PDFSyntaxValue, _ location: String, depth: Int) throws {
            guard depth < 80 else { throw PDFStructureError.limit }
            let item = try record(value, location)
            guard fieldKeys.insert(item.key).inserted else { throw PDFStructureError.unsupported("albero campi circolare o condiviso") }
            model.fields.append(item)
            if profile.part == 4 { try associated(item.value, location) }
            try actions(item.value, location)
            if try name(item.value["Subtype"]) == "Widget" { try annotationRecord(value, location) }
            if try inheritedName("FT", in: item) == "Sig", let value = try resolved(item.value["V"]), value.dictionary != nil {
                let signature = try record(item.value["V"]!, location + "/V")
                if !model.signatures.contains(where: { $0.key == signature.key }) { model.signatures.append(signature) }
            }
            for (index, child) in try array(item.value["Kids"]).enumerated() { try field(child, location + "/Kids[\(index)]", depth: depth + 1) }
        }
        try associated(root, "Catalog")
        try actions(root, "Catalog")
        if let language = root["Lang"] { model.languages.append((language, "Catalog/Lang")) }
        let names = try dictionary(root["Names"])
        if let tree = names["EmbeddedFiles"] {
            for (index, value) in try treeValues(tree, pairs: "Names").enumerated() {
                let file = try record(value, "Catalog/Names/EmbeddedFiles[\(index)]")
                if model.fileKeys.insert(file.key).inserted { model.files.append(file) }
            }
        }
        if let form = root["AcroForm"] {
            let form = try record(form, "Catalog/AcroForm"); model.forms.append(form)
            for (index, value) in try array(form.value["Fields"]).enumerated() { try field(value, "Catalog/AcroForm/Fields[\(index)]", depth: 0) }
            try resource(form.value["DR"], "Catalog/AcroForm/DR", depth: 0)
        }
        for (index, id) in try reader.pageIDs().enumerated() {
            try Task.checkCancellation(); visits += 1; guard visits < 100_000 else { throw PDFStructureError.limit }
            let page = try dictionary(.reference(id)); try associated(page, "pagina \(index + 1)"); try actions(page, "pagina \(index + 1)")
            let resources = try dictionary(reader.inherited("Resources", pageID: id))
            try resource(.dictionary(resources), "pagina \(index + 1)/Resources", depth: 0)
            for stream in try reader.contentStreamIDs(on: id) { model.contentStreams.append((stream, resources)) }
            for (j, annotation) in try array(page["Annots"]).enumerated() { try annotationRecord(annotation, "pagina \(index + 1)/Annots[\(j)]") }
        }
        // Normal, rollover and down appearance streams can have their own resources.
        for annotation in model.annotations {
            guard let appearances = try resolved(annotation.value["AP"])?.dictionary else { continue }
            for (_, value) in appearances {
                let states: [PDFSyntaxValue]
                if try isStream(value) { states = [value] }
                else { states = Array((try resolved(value)?.dictionary ?? [:]).values) }
                for state in states {
                    guard let id = state.reference, try reader.object(id).stream != nil else { continue }
                    let dictionary = try dictionary(state), resources = try self.dictionary(dictionary["Resources"])
                    model.contentStreams.append((id, resources)); try resource(dictionary["Resources"], annotation.location + "/AP/Resources", depth: 0)
                }
            }
        }
        if let value = root["StructTreeRoot"], try resolved(value)?.dictionary != nil {
            model.structureRoot = try record(value, "Catalog/StructTreeRoot")
            try readStructure(into: &model)
            for element in model.elements { try associated(element.value, element.location) }
        }
        if profile.part >= 3 {
            var scanned = Set<PDFObjectID>()
            for (id, resources) in model.contentStreams where scanned.insert(id).inserted {
                let properties = try markedProperties(id: id, resources: resources)
                if properties.incomplete { model.associationGaps.append("Associazioni dopo immagini inline non completamente analizzate: " + id.syntax) }
                if profile.part == 4 { model.associationIssues += properties.associationIssues.map { "stream " + id.syntax + ": " + $0 } }
                for (index, property) in properties.values.enumerated() {
                    try associated(property, "stream " + id.syntax + "/property[\(index)]")
                }
                if profile.part == 4 {
                    for (index, property) in properties.mcaf.enumerated() {
                        try associated(property, "stream " + id.syntax + "/AF-property[\(index)]", key: "MCAF")
                    }
                }
            }
        }
        for (key, value) in try dictionary(root["Perms"]) where ["DocMDP", "UR", "UR3"].contains(key) {
            let sig = try record(value, "Catalog/Perms/" + key)
            if !model.signatures.contains(where: { $0.key == sig.key }) { model.signatures.append(sig) }
        }
        if profile.part == 4 {
            // ISO32000-2 §14.13 deliberately opens AF to arbitrary object
            // dictionaries; AN002 §§3.2,6.2 confirms that a closed list loses
            // associations (including an attachment's own schema attachment).
            // Walk only the live Catalog graph, never bytes in a stream or an
            // unreachable historical object. A1–3 keep their contextual model.
            var seen = Set<PDFObjectID>(), steps = 0
            func walkAssociations(_ value: PDFSyntaxValue, _ location: String, depth: Int, objectID: PDFObjectID? = nil) throws {
                try Task.checkCancellation(); steps += 1
                guard depth < 100, steps < 1_000_000 else { throw PDFStructureError.limit }
                if let id = value.reference {
                    guard seen.insert(id).inserted else { return }
                    try walkAssociations(reader.object(id).value, "oggetto " + id.syntax, depth: depth + 1, objectID: id)
                } else if let dictionary = value.dictionary {
                    if try name(dictionary["Type"]) == "Filespec" {
                        let spec = Record(value: dictionary, id: objectID, location: location)
                        if model.fileKeys.insert(spec.key).inserted { model.files.append(spec) }
                    }
                    try associated(dictionary, location)
                    for key in dictionary.keys.sorted() {
                        try walkAssociations(dictionary[key]!, location + "/" + key, depth: depth + 1)
                    }
                } else if let values = value.array {
                    for (index, child) in values.enumerated() { try walkAssociations(child, location + "[\(index)]", depth: depth + 1) }
                }
            }
            do { try walkAssociations(.reference(reader.rootID), "Catalog", depth: 0) }
            catch is CancellationError { throw CancellationError() }
            catch { model.associationGaps.append("Visita AF PDF2 incompleta: " + error.localizedDescription) }
        }
        return model
    }

    private func inheritedName(_ key: String, in record: Record) throws -> String? {
        var current = record.value, seen = Set<PDFObjectID>()
        while true {
            if let value = try name(current[key]) { return value }
            guard let parent = current["Parent"]?.reference else { return nil }
            guard seen.insert(parent).inserted, seen.count < 100 else { throw PDFStructureError.unsupported("parent campo circolare") }
            current = try dictionary(.reference(parent))
        }
    }
    private func treeValues(_ value: PDFSyntaxValue, pairs: String) throws -> [PDFSyntaxValue] {
        var seen = Set<PDFObjectID>(), count = 0, output: [PDFSyntaxValue] = []
        func walk(_ value: PDFSyntaxValue, depth: Int) throws {
            try Task.checkCancellation(); count += 1
            guard depth < 80, count < 100_000 else { throw PDFStructureError.limit }
            if let id = value.reference, !seen.insert(id).inserted { throw PDFStructureError.unsupported("name/number tree circolare") }
            let dictionary = try self.dictionary(value), values = try array(dictionary[pairs])
            guard values.count % 2 == 0 else { throw PDFStructureError.malformed("coppie name/number tree") }
            for index in stride(from: 1, to: values.count, by: 2) { output.append(values[index]) }
            for child in try array(dictionary["Kids"]) { try walk(child, depth: depth + 1) }
        }
        try walk(value, depth: 0); return output
    }

    /// Only independently calculated sample counts prove inline boundaries.
    /// A declared length or delimiter guess never proves traversal completeness.
    private func markedProperties(id: PDFObjectID, resources: [String: PDFSyntaxValue]) throws
        -> (values: [[String: PDFSyntaxValue]], incomplete: Bool, associationIssues: [String], mcaf: [[String: PDFSyntaxValue]]) {
        try markedProperties(data: reader.decodedStream(id), resources: resources)
    }
    private func markedProperties(data: Data, resources: [String: PDFSyntaxValue]) throws
        -> (values: [[String: PDFSyntaxValue]], incomplete: Bool, associationIssues: [String], mcaf: [[String: PDFSyntaxValue]]) {
        var lexer = PDFSyntaxLexer(data), operands: [PDFSyntaxValue] = []
        var values: [[String: PDFSyntaxValue]] = [], mcaf: [[String: PDFSyntaxValue]] = [], associationIssues: [String] = [], count = 0
        while true {
            try Task.checkCancellation(); lexer.skip()
            if lexer.offset == lexer.bytes.count { return (values, false, associationIssues, mcaf) }
            count += 1; guard count < 1_000_000 else { throw PDFStructureError.limit }
            let value = try lexer.value()
            if case .keyword(let operation) = value {
                if operation == "BI" {
                    let image = try PDFArchiveInlineImage.read(from: &lexer)
                    guard image.lengthReliable else { return (values, true, associationIssues, mcaf) }
                    operands.removeAll(keepingCapacity: true); continue
                }
                if ["BDC", "DP"].contains(operation), let property = operands.last {
                    let dictionary: [String: PDFSyntaxValue]
                    if let key = property.name { dictionary = try self.dictionary(self.dictionary(resources["Properties"])[key]) }
                    else { dictionary = try self.dictionary(property) }
                    values.append(dictionary)
                    if profile.part == 4, operands.first?.name == "AF" {
                        if operation == "DP" { associationIssues.append("tag AF vietato con DP") }
                        else if try resolved(dictionary["MCAF"])?.array == nil { associationIssues.append("tag AF senza array MCAF") }
                        else { mcaf.append(dictionary) }
                    }
                }
                if profile.part == 4, ["MP", "BMC"].contains(operation), operands.first?.name == "AF" {
                    associationIssues.append(operation == "MP" ? "tag AF vietato con MP" : "tag AF BMC senza property list MCAF")
                }
                operands.removeAll(keepingCapacity: true)
            } else { operands.append(value); guard operands.count < 100_000 else { throw PDFStructureError.limit } }
        }
    }

    private func annotation(_ rule: PDFArchiveCatalogueRule, model: Model) throws -> PDFArchiveRuleEvaluation {
        let expression = rule.expression
        if expression.hasPrefix("Subtype =="), !expression.contains("F != null") {
            let allowed = quoted(expression)
            return try check(model.annotations, "Sottotipi annotazione ammessi dal profilo") { try allowed.contains(self.name($0.value["Subtype"]) ?? "") }
        }
        if expression == "CA == null || CA == 1.0" { return try check(model.annotations, "Opacità annotazioni PDF/A-1") { record in
            guard let value = try self.resolved(record.value["CA"]) else { return true }; return value.real == 1
        } }
        if expression.contains("F != null") || expression.hasPrefix("F == null") {
            return try check(model.annotations, "Flag annotazione, incluse eccezioni Popup/riquadro nullo") { record in
                let subtype = try self.name(record.value["Subtype"]), flag = try self.integer(record.value["F"])
                if expression.contains("Subtype == \"Popup\""), subtype == "Popup" { return true }
                if expression.contains("width == 0"), try self.zeroArea(record) { return true }
                if expression.hasPrefix("F == null"), try self.resolved(record.value["F"]) == nil { return true }
                guard let flag else { return false }
                if expression.contains("(F &") { return flag & 4 == 4 && flag & (1 | 2 | 32 | (self.profile.part == 1 ? 0 : 256)) == 0 }
                return true
            }
        }
        if expression.contains("containsC") {
            let colored = try model.annotations.filter { try resolved($0.value["C"]) != nil || resolved($0.value["IC"]) != nil }
            guard !colored.isEmpty else { return .absent("Nessuna annotazione con C o IC.") }
            let root = try dictionary(.reference(reader.rootID))
            var spaces: [String] = []
            for value in try array(root["OutputIntents"]) {
                let intent = try dictionary(value)
                guard try name(intent["S"]) == "GTS_PDFA1", let id = intent["DestOutputProfile"]?.reference else { continue }
                let bytes = try reader.decodedStream(id)
                guard bytes.count >= 128 else { return .unknown("ICC troppo corto per stabilire lo spazio colore.") }
                spaces.append(String(decoding: bytes[16..<20], as: UTF8.self))
            }
            return .check(!spaces.isEmpty && spaces.allSatisfy { $0 == "RGB " }, "C e IC richiedono output PDF/A-1 RGB; validità ICC verificata separatamente.")
        }
        if expression.contains("AP != null") { return try check(model.annotations, "Appearance obbligatoria con eccezioni previste") { record in
            let subtype = try self.name(record.value["Subtype"]) ?? ""
            if try self.zeroArea(record) { return true }
            if ["Popup", "Link"].contains(subtype) || (self.profile.part == 4 && subtype == "Projection") { return true }
            return try self.resolved(record.value["AP"])?.dictionary != nil
        } }
        if expression == "AP == null || AP == \"N\"" { return try check(model.annotations, "AP contiene soltanto N") { record in
            guard let value = try self.resolved(record.value["AP"]) else { return true }
            return Set(value.dictionary?.keys.map { $0 } ?? []) == ["N"]
        } }
        if expression.contains("N_type") { return try check(model.annotations, "Tipo della appearance normale, FT ereditato dal campo") { record in
            guard let appearance = try self.resolved(record.value["AP"])?.dictionary, Set(appearance.keys) == ["N"] else { return true }
            let button = try self.name(record.value["Subtype"]) == "Widget" && self.inheritedName("FT", in: record) == "Btn"
            if expression.contains("N_type == \"Dict\"") && !button { return true }
            if expression.contains("N_type == \"Stream\"") && button { return true }
            guard let normal = appearance["N"] else { return false }
            if expression.contains("N_type == \"Stream\"") { return try self.isStream(normal) }
            if try self.isStream(normal) { return false }
            guard let states = try self.resolved(normal)?.dictionary, !states.isEmpty else { return false }
            return try states.values.allSatisfy { try self.isStream($0) }
        } }
        return .unknown("Predicato annotazione non implementato: " + expression)
    }
    private func isStream(_ value: PDFSyntaxValue) throws -> Bool { guard let id = value.reference else { return false }; return try reader.object(id).stream != nil }
    private func zeroArea(_ record: Record) throws -> Bool {
        let values = try array(record.value["Rect"])
        guard values.count == 4 else { return false }
        let numbers = try values.map { try resolved($0)?.real }
        guard numbers.allSatisfy({ $0?.isFinite == true }) else { return false }
        return numbers[0] == numbers[2] && numbers[1] == numbers[3]
    }
    private func quoted(_ expression: String) -> Set<String> {
        let regex = try! NSRegularExpression(pattern: "[\"']([^\"']+)[\"']"), text = expression as NSString
        return Set(regex.matches(in: expression, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range(at: 1)) })
    }

    private func additionalActions(root: [String: PDFSyntaxValue], model: Model) throws -> PDFArchiveRuleEvaluation {
        var records = [Record(value: root, id: try reader.rootID, location: "Catalog")]
        records += try reader.pageIDs().map { try record(.reference($0), "Page " + $0.syntax) }
        records += try model.annotations.filter { try name($0.value["Subtype"]) != "Widget" }
        let allowed = Set(["E", "X", "D", "U", "Fo", "Bl"])
        return try check(records, "Chiavi AA ammesse sui contenitori non Widget/FormField") { record in
            let actions = try self.dictionary(record.value["AA"])
            return Set(actions.keys).isSubset(of: allowed)
        }
    }

    private func optionalContent(_ rule: PDFArchiveCatalogueRule, root: [String: PDFSyntaxValue]) throws -> PDFArchiveRuleEvaluation {
        let properties = try dictionary(root["OCProperties"])
        var configs: [Record] = [], seen = Set<String>()
        if let value = properties["D"] { let item = try record(value, "OCProperties/D"); configs.append(item); seen.insert(item.key) }
        for (i, value) in try array(properties["Configs"]).enumerated() {
            let item = try record(value, "OCProperties/Configs[\(i)]")
            if seen.insert(item.key).inserted { configs.append(item) }
        }
        guard !configs.isEmpty else { return .absent("Nessuna configurazione OCG.") }
        let expression = rule.expression
        if expression.hasPrefix("Name != null") { return try check(configs, "Nome configurazione OCG") { record in
            guard let text = try self.resolved(record.value["Name"])?.text else { return false }
            return !expression.contains("length()") || !text.isEmpty
        } }
        if expression == "hasDuplicateName == false" {
            let names = try configs.compactMap { try resolved($0.value["Name"])?.text }
            return .check(Set(names).count == names.count, "Nomi unici fra tutte le configurazioni OCG.")
        }
        if expression == "AS == null" { return try check(configs, "AS assente") { try self.resolved($0.value["AS"]) == nil } }
        if expression == "OCGsNotContainedInOrder == null" {
            let groups = try array(properties["OCGs"])
            guard groups.allSatisfy({ $0.reference != nil }) else { return .unknown("OCG diretti/non referenziabili nel catalogo.") }
            let ids = Set(groups.compactMap(\.reference))
            return try check(configs, "Ogni Order esplicito comprende tutti gli OCG") { record in
                guard let order = try self.resolved(record.value["Order"]) else { return true }
                var found = Set<PDFObjectID>(), visits = 0
                func walk(_ value: PDFSyntaxValue, depth: Int) throws {
                    visits += 1; guard depth < 80, visits < 100_000 else { throw PDFStructureError.limit }
                    if let id = value.reference, ids.contains(id) { found.insert(id); return }
                    if let items = try self.resolved(value)?.array { for item in items { try walk(item, depth: depth + 1) } }
                }
                try walk(order, depth: 0); return ids.isSubset(of: found)
            }
        }
        return .unknown("Predicato OCG non implementato.")
    }

    private func fileSpecification(_ rule: PDFArchiveCatalogueRule, model: Model) throws -> PDFArchiveRuleEvaluation {
        let expression = rule.expression
        if expression == "containsEF == false" { return try check(model.files, "EF vietato in PDF/A-1") { try self.resolved($0.value["EF"]) == nil } }
        if expression.contains("F != null && UF != null") { return try check(model.files, "F e UF delle specifiche con allegati") { record in
            if try self.resolved(record.value["EF"]) == nil { return true }
            return try self.resolved(record.value["F"])?.data != nil && self.resolved(record.value["UF"])?.data != nil
        } }
        if expression.contains("AFRelationship != null") { return try check(model.files, "AFRelationship di tipo Name") { record in
            if try self.resolved(record.value["EF"]) == nil { return true }
            return try self.name(record.value["AFRelationship"]) != nil
        } }
        if expression == "isAssociatedFile == true" { return try check(model.files, "Ogni specifica allegata è referenziata da un AF standard") { record in
            try self.resolved(record.value["EF"]) == nil || model.associated.contains(record.key)
        } }
        return .unknown("Predicato specifica file non implementato.")
    }

    private func embeddedFile(_ rule: PDFArchiveCatalogueRule, model: Model) throws -> PDFArchiveRuleEvaluation {
        var files: [Record] = [], seen = Set<String>()
        for spec in model.files {
            for (key, value) in try dictionary(spec.value["EF"]) where ["F", "UF", "DOS", "Mac", "Unix"].contains(key) {
                let file = try record(value, spec.location + "/EF/" + key)
                if seen.insert(file.key).inserted { files.append(file) }
            }
        }
        if rule.expression.contains("Subtype != null") { return try check(files, "Sintassi media type degli stream incorporati: " +
            (profile.part == 4 ? "RFC6838 §4.2" : "RFC4288 §4.2") +
            ". Espressione XML storica conservata: \(rule.expression). La verifica sintattica nativa corregge l'insieme dei caratteri e i limiti; registrazione IANA e corrispondenza payload sono controlli separati.") { record in
            guard let mime = try self.name(record.value["Subtype"]) else { return false }
            return Self.validMediaType(mime, requireInitialAlphanumeric: self.profile.part == 4)
        } }
        guard rule.expression.contains("isValidPDFA") else { return .unknown("Predicato file incorporato non implementato.") }
        guard !files.isEmpty else { return .absent("Nessun allegato referenziato.") }
        var unknown: [String] = [], failures: [String] = []
        let budget = Self.recursion.budget ?? AttachmentBudget()
        for file in files {
            try Task.checkCancellation()
            guard let id = file.id else { unknown.append(file.location + ": stream indiretto non disponibile"); continue }
            let bytes = try reader.decodedStream(id), hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            var state = Self.recursion
            guard state.depth < 5, !state.hashes.contains(hash), budget.reserve(bytes.count) else {
                unknown.append(file.location + ": limite o ciclo della validazione ricorsiva"); continue
            }
            guard let declared = PDFArchiveValidator.declaredProfile(data: bytes) else { failures.append(file.location + ": identificazione PDF/A assente/non valida"); continue }
            let allowed = rule.expression.contains("124") ? [1, 2, 4] : [1, 2]
            guard allowed.contains(declared.part) else { failures.append(file.location + ": parte PDF/A \(declared.part) non ammessa"); continue }
            state.hashes.insert(hash); state.depth += 1; state.budget = budget
            let report = Self.$recursion.withValue(state) { PDFArchiveValidator.validate(data: bytes, profile: declared) }
            switch report.verdict {
            case .nonconforming: failures.append(file.location + ": PDF/A figlio non conforme (\(report.failedCount) regole violate)")
            case .indeterminate: unknown.append(file.location + ": validazione PDF/A figlio incompleta")
            case .conforming: break
            }
        }
        if !failures.isEmpty { return .check(false, "Allegati PDF/A non validi.", locations: failures) }
        if !unknown.isEmpty { return .unknown(unknown.joined(separator: "; ")) }
        return .check(true, "Ogni allegato supera ricorsivamente il profilo PDF/A ammesso.")
    }

    /// RFC6838 §4.2 ABNF, applied to PDF2; PDF/A-3 predates RFC6838 and
    /// retains RFC4288 §4.2's reg-name grammar (same alphabet/length but no
    /// first-character restriction). PDF names have already expanded #xx;
    /// percent escaping and MIME parameters are not part of these names.
    private static func validMediaType(_ value: String, requireInitialAlphanumeric: Bool) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return false }
        func alphanumeric(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
        let punctuation = Set("!#$&-^_.+".utf8)
        return components.allSatisfy { component in
            let bytes = Array(component.utf8)
            guard (1...127).contains(bytes.count), !requireInitialAlphanumeric || alphanumeric(bytes[0]) else { return false }
            return bytes.allSatisfy { alphanumeric($0) || punctuation.contains($0) }
        }
    }

    private func readStructure(into model: inout Model) throws {
        guard let root = model.structureRoot else { return }
        if try name(root.value["Type"]) != "StructTreeRoot" { model.structureIssues.append("StructTreeRoot/Type non valido") }
        var seen = Set<PDFObjectID>(), steps = 0
        var references: [(owner: Record, container: PDFSyntaxValue?, mcid: Int?, object: PDFSyntaxValue?)] = []
        func walk(_ value: PDFSyntaxValue, parent: Record, depth: Int) throws {
            try Task.checkCancellation(); steps += 1
            guard depth < 80, steps < 100_000 else { throw PDFStructureError.limit }
            guard let actual = try resolved(value) else { return }
            if let values = actual.array { for value in values { try walk(value, parent: parent, depth: depth + 1) }; return }
            if let mcid = actual.int {
                if mcid < 0 { model.structureIssues.append(parent.location + "/K: MCID negativo") }
                references.append((parent, parent.value["Pg"], mcid, nil)); return
            }
            guard actual.dictionary != nil else { model.structureIssues.append(parent.location + "/K: tipo non valido"); return }
            let item = try record(value, parent.location + "/K"), type = try name(item.value["Type"])
            if type == "MCR" {
                guard let mcid = try integer(item.value["MCID"]), mcid >= 0 else { model.structureIssues.append(item.location + ": MCID assente/non valido"); return }
                let container: PDFSyntaxValue?
                if try resolved(item.value["Stm"]) != nil { container = item.value["Stm"] }
                else if try resolved(item.value["Pg"]) != nil { container = item.value["Pg"] }
                else { container = parent.value["Pg"] }
                references.append((parent, container, mcid, nil)); return
            }
            if type == "OBJR" { references.append((parent, nil, nil, item.value["Obj"])); return }
            if let id = item.id, !seen.insert(id).inserted { model.structureIssues.append(item.location + ": struttura condivisa/circolare"); return }
            let tag = try name(item.value["S"])
            if (type != nil && type != "StructElem") || tag == nil { model.structureIssues.append(item.location + ": StructElem/Type/S non valido") }
            if let expected = parent.id {
                if try identity(item.value["P"]) != expected { model.structureIssues.append(item.location + ": P non corrisponde al parent") }
            } else { model.structureGaps.append("Parent strutturale diretto: identità non verificabile integralmente") }
            model.elements.append(item)
            if let language = item.value["Lang"] { model.languages.append((language, item.location + "/Lang")) }
            if let child = item.value["K"] { try walk(child, parent: item, depth: depth + 1) }
        }
        if let children = root.value["K"] { try walk(children, parent: root, depth: 0) }
        let tree = try numberTree(root.value["ParentTree"])
        if let next = try integer(root.value["ParentTreeNextKey"]), let maximum = tree.keys.max(), next <= maximum { model.structureIssues.append("ParentTreeNextKey non supera le chiavi utilizzate") }
        let pages = Set(try reader.pageIDs())
        var mcidCache: [PDFObjectID: (ids: Set<Int>, incomplete: Bool)] = [:]
        func actualMCIDs(in id: PDFObjectID) throws -> (ids: Set<Int>, incomplete: Bool)? {
            if let value = mcidCache[id] { return value }
            let resources: [String: PDFSyntaxValue], content: Data
            if pages.contains(id) {
                resources = try dictionary(reader.inherited("Resources", pageID: id))
                var bytes = Data()
                for stream in try PDFArchiveStructureReferences.contentStreams(on: id, reader: reader) {
                    bytes += try reader.decodedStream(stream); bytes.append(32)
                    guard bytes.count <= 128 * 1024 * 1024 else { throw PDFStructureError.limit }
                }
                content = bytes
            } else {
                let object = try reader.object(id)
                guard object.stream != nil else { return nil }
                resources = try dictionary(object.value.dictionary?["Resources"])
                content = try reader.decodedStream(id)
            }
            let properties = try markedProperties(data: content, resources: resources)
            var ids = Set<Int>()
            for property in properties.values {
                guard let value = try resolved(property["MCID"]) else { continue }
                guard let mcid = value.int, mcid >= 0 else {
                    model.structureIssues.append(id.syntax + ": MCID nel contenuto non intero/non negativo"); continue
                }
                if !ids.insert(mcid).inserted { model.structureIssues.append(id.syntax + ": MCID ripetuto nel medesimo contenuto") }
            }
            let result = (ids, properties.incomplete); mcidCache[id] = result; return result
        }
        for reference in references {
            guard let owner = reference.owner.id else { model.structureGaps.append("StructElem diretto senza identità verificabile"); continue }
            if let object = reference.object {
                let dictionary = try self.dictionary(object)
                if let id = try identity(object), !model.annotationKeys.contains(id.syntax), !model.contentObjectKeys.contains(id.syntax) {
                    model.structureGaps.append(reference.owner.location + ": OBJR non riferito ad annotazione/XObject registrato")
                }
                guard let key = try integer(dictionary["StructParent"]), let entry = tree[key], try identity(entry) == owner else {
                    model.structureIssues.append(reference.owner.location + ": OBJR/StructParent/ParentTree incoerente"); continue
                }
            } else if let container = reference.container, let mcid = reference.mcid {
                let dictionary = try self.dictionary(container)
                guard let key = try integer(dictionary["StructParents"]), let values = try resolved(tree[key])?.array,
                      values.indices.contains(mcid), try identity(values[mcid]) == owner else {
                    model.structureIssues.append(reference.owner.location + ": MCID/StructParents/ParentTree incoerente"); continue
                }
                if let id = try identity(container), let actual = try actualMCIDs(in: id) {
                    if actual.incomplete { model.structureGaps.append(id.syntax + ": MCID oltre immagini inline non determinabili") }
                    else if !actual.ids.contains(mcid) { model.structureIssues.append(id.syntax + ": MCID \(mcid) referenziato ma inesistente nel contenuto") }
                } else { model.structureGaps.append(reference.owner.location + ": contenuto MCID non identificabile come pagina/stream") }
            } else { model.structureGaps.append(reference.owner.location + ": contesto di pagina/stream del contenuto non determinabile") }
        }
        for value in tree.values {
            let values = try resolved(value)?.array ?? [value]
            for value in values {
                guard let resolved = try self.resolved(value) else { continue }
                if let id = try identity(value), seen.contains(id) { continue }
                if resolved.dictionary != nil { model.structureIssues.append("ParentTree referenzia una struttura fuori dall’albero") }
                else { model.structureIssues.append("ParentTree contiene un valore non strutturale") }
            }
        }
        // Graph consistency does not prove assignment or meaningful tag semantics.
        for (id, _) in model.contentStreams {
            var lexer = PDFSyntaxLexer(try reader.decodedStream(id)); lexer.skip()
            if lexer.offset < lexer.bytes.count {
                model.structureGaps.append("Assegnazione completa del contenuto, MCID effettivi e semantica dei tag non provate per lo stream " + id.syntax)
                break
            }
        }
    }
    private func numberTree(_ root: PDFSyntaxValue?) throws -> [Int: PDFSyntaxValue] {
        guard let root = try resolved(root) else { return [:] }
        var result: [Int: PDFSyntaxValue] = [:], seen = Set<PDFObjectID>(), count = 0
        func walk(_ value: PDFSyntaxValue, depth: Int) throws {
            try Task.checkCancellation(); count += 1
            guard depth < 80, count < 100_000 else { throw PDFStructureError.limit }
            if let id = value.reference, !seen.insert(id).inserted { throw PDFStructureError.unsupported("ParentTree circolare") }
            let dictionary = try self.dictionary(value), pairs = try array(dictionary["Nums"])
            guard pairs.count % 2 == 0 else { throw PDFStructureError.malformed("ParentTree/Nums") }
            var prior: Int?
            for offset in stride(from: 0, to: pairs.count, by: 2) {
                guard let key = try integer(pairs[offset]), result[key] == nil, prior == nil || key > prior! else { throw PDFStructureError.malformed("chiavi ParentTree duplicate/non ordinate") }
                result[key] = pairs[offset + 1]; prior = key
            }
            for child in try array(dictionary["Kids"]) { try walk(child, depth: depth + 1) }
        }
        try walk(root, depth: 0); return result
    }
    private func roleMap(_ rule: PDFArchiveCatalogueRule, model: Model) throws -> PDFArchiveRuleEvaluation {
        guard let root = model.structureRoot else { return .absent("Nessuna struttura; presenza richiesta da una regola separata.") }
        let mappings = try dictionary(root.value["RoleMap"])
        let used = Set(try model.elements.compactMap { try name($0.value["S"]) })
        let nonstandard = used.subtracting(standardTags)
        if rule.expression == "remappedStandardType == null" {
            var invalid: [String] = [], unknown = false
            for tag in used.union(Set(mappings.keys)).intersection(standardTags) {
                guard let value = mappings[tag] else { continue }
                if let target = try name(value), !standardTags.contains(target) { invalid.append(tag + " → " + target) }
                else { unknown = true }
            }
            if !invalid.isEmpty { return .check(false, "Tag standard rimappati a tipi non standard.", locations: invalid) }
            if unknown { return .unknown("RoleMap rimappa tipi standard: dipendenza ISO 32000 da riconciliare.") }
            return .check(true, "Nessun tag standard rimappato a tipo non standard.")
        }
        guard !nonstandard.isEmpty else { return .absent("Nessun tipo strutturale personalizzato utilizzato.") }
        var cycles: [String] = [], unmapped: [String] = []
        for tag in nonstandard {
            var current = tag, seen = Set<String>()
            while !standardTags.contains(current) {
                guard seen.count < 100 else { throw PDFStructureError.limit }
                guard seen.insert(current).inserted else { cycles.append(tag); break }
                guard let target = try name(mappings[current]) else { unmapped.append(tag); break }
                current = target
            }
        }
        if rule.expression == "circularMappingExist != true" { return .check(cycles.isEmpty, "Catene RoleMap senza cicli per tipi utilizzati.", locations: cycles) }
        if rule.expression == "isNotMappedToStandardType == false" {
            return .check(unmapped.isEmpty && cycles.isEmpty, "Ogni tipo utilizzato raggiunge un tipo standard; equivalenza semantica non dedotta dal nome.", locations: unmapped + cycles)
        }
        return .unknown("Predicato RoleMap non implementato.")
    }
    private func language(_ rule: PDFArchiveCatalogueRule, model: Model) throws -> PDFArchiveRuleEvaluation {
        var languages = model.languages, incomplete = false
        for (id, resources) in model.contentStreams {
            let properties = try markedProperties(id: id, resources: resources)
            incomplete = incomplete || properties.incomplete
            for property in properties.values {
                if let language = property["Lang"] { languages.append((language, "stream " + id.syntax + "/property/Lang")) }
            }
        }
        let pattern = profile.part == 1 ? "^[a-zA-Z]{1,8}(-[a-zA-Z]{1,8})*$" : "^[a-zA-Z]{1,8}(-[a-zA-Z0-9]{1,8})*$"
        var invalid: [String] = [], applicable = 0
        for (value, location) in languages {
            guard let value = try resolved(value) else { continue }; applicable += 1
            guard let text = value.text, text.isEmpty || text.range(of: pattern, options: .regularExpression) != nil else { invalid.append(location); continue }
        }
        if !invalid.isEmpty { return .check(false, "Lang non conforme alla sintassi RFC del profilo.", locations: invalid) }
        if incomplete { return .unknown("Lang noti validi; property list successive a immagini inline non completamente analizzate.") }
        return applicable == 0 ? .absent("Nessun Lang in catalogo, struttura o property list referenziate.") : .check(true, "\(applicable) identificatori Lang sintatticamente validi secondo il profilo.")
    }

    private func signature(_ rule: PDFArchiveCatalogueRule, root: [String: PDFSyntaxValue], model: Model) throws -> PDFArchiveRuleEvaluation {
        if rule.objectType == "PDSigRef" {
            guard try resolved(dictionary(root["Perms"])["DocMDP"]) != nil else { return .absent("DocMDP assente.") }
            var references: [Record] = []
            for signature in model.signatures {
                for (index, value) in try array(signature.value["Reference"]).enumerated() { references.append(try record(value, signature.location + "/Reference[\(index)]")) }
            }
            return try check(references, "DigestLocation/Method/Value assenti quando DocMDP è presente") { reference in
                try ["DigestLocation", "DigestMethod", "DigestValue"].allSatisfy { try self.resolved(reference.value[$0]) == nil }
            }
        }
        guard !model.signatures.isEmpty else { return .absent("Nessun campo firmato o firma DocMDP referenziata.") }
        if rule.objectType == "PDSignature" {
            var unknown: [String] = [], invalid: [String] = []
            for signature in model.signatures {
                guard let id = signature.id else { unknown.append(signature.location + ": posizione di Contents diretto non disponibile"); continue }
                let object = try reader.object(id), values = try array(signature.value["ByteRange"])
                let numbers = try values.map { try integer($0) }
                guard numbers.count == 4, numbers.allSatisfy({ $0 != nil }), let a = numbers[0], let b = numbers[1], let c = numbers[2], let d = numbers[3],
                      a == 0, b > 0, c > b, d >= 0, c <= reader.source.count, d <= reader.source.count - c else {
                    invalid.append(signature.location + ": ByteRange non canonico"); continue
                }
                guard let gap = object.memberRanges["Contents"] else { unknown.append(signature.location + ": offset lessicale Contents non disponibile"); continue }
                guard gap.lowerBound == b, gap.upperBound == c else { invalid.append(signature.location + ": esclusione diversa dal solo Contents"); continue }
                let end = c + d
                if end < reader.source.count {
                    let prefix = reader.source.prefix(end)
                    guard let eof = prefix.range(of: Data("%%EOF".utf8), options: .backwards),
                          [Data(), Data([10]), Data([13]), Data([13, 10])].contains(Data(prefix[eof.upperBound...])),
                          let revision = try? PDFStructureDocument(data: Data(prefix)),
                          let earlier = try? revision.object(id), earlier.memberRanges["Contents"] == gap else {
                        invalid.append(signature.location + ": ByteRange non termina una revisione contenente la firma"); continue
                    }
                }
            }
            if !invalid.isEmpty { return .check(false, "ByteRange non copre integralmente la revisione firmata.", locations: invalid) }
            if !unknown.isEmpty { return .unknown(unknown.joined(separator: "; ")) }
            return .check(true, "ByteRange copre ogni revisione firmata, escludendo esattamente il relativo Contents; integrità crittografica separata.")
        }
        if rule.objectType == "PKCSDataObject" {
            return try check(model.signatures, "PKCS#7 DER decodificato con Security, firmatari e certificati incorporati") { signature in
                guard let bytes = try self.resolved(signature.value["Contents"])?.data else { return false }
                let der: Data
                do { der = try self.derEnvelope(bytes) }
                catch PDFStructureError.limit { throw PDFStructureError.unsupported("limite della visita DER; canonicità non provata") }
                catch is CancellationError { throw CancellationError() }
                catch { return false }
                var value: CMSDecoder?
                guard CMSDecoderCreate(&value) == errSecSuccess, let decoder = value else { throw PDFStructureError.security(errSecInternalComponent) }
                let update = der.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, $0.count) }
                guard update == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { return false }
                var count = 0
                guard CMSDecoderGetNumSigners(decoder, &count) == errSecSuccess else { return false }
                if rule.expression == "SignerInfoCount == 1" { return count == 1 }
                guard rule.expression == "signingCertificatePresent == true" else { throw PDFStructureError.unsupported("predicato PKCS") }
                guard count > 0 else { return false }
                var certificates: CFArray?
                guard CMSDecoderCopyAllCerts(decoder, &certificates) == errSecSuccess, let embedded = certificates as? [SecCertificate], !embedded.isEmpty else { return false }
                let encoded = embedded.map { SecCertificateCopyData($0) as Data }
                for signer in 0..<count {
                    var certificate: SecCertificate?
                    guard CMSDecoderCopySignerCert(decoder, signer, &certificate) == errSecSuccess, let certificate,
                          encoded.contains(SecCertificateCopyData(certificate) as Data) else { return false }
                }
                return true
            }
        }
        return .unknown("Predicato firma non implementato.")
    }
    private func derEnvelope(_ data: Data) throws -> Data {
        let envelope = try PDFArchiveDEREnvelope(data)
        try envelope.checkSignedDataSets()
        return envelope.data
    }
}

/// Original bounded ASN.1 reader. Security's CMS decoder also accepts BER, so a
/// successful Security decode alone cannot establish the DER requirement of
/// PDF/A-2/3 §6.4.3. X.690 (2021) §§8,10,11 govern these encoding checks.
/// Opaque extension payloads and DEFAULT fields require their own schemas;
/// these checks do not claim complete CMS/X.509 or cryptographic validation.
struct PDFArchiveDEREnvelope {
    struct Node {
        let tagClass: Int, tag: Int
        let constructed: Bool
        let range: Range<Int>, content: Range<Int>
        let children: [Node]
        func isTag(_ tag: Int, _ tagClass: Int = 0) -> Bool { self.tag == tag && self.tagClass == tagClass }
    }
    let data: Data
    let root: Node
    private let bytes: [UInt8]

    init(_ input: Data) throws {
        guard input.count <= 32 * 1024 * 1024 else { throw PDFStructureError.limit }
        let source = Array(input)
        var offset = 0, steps = 0
        let node = try Self.read(source, offset: &offset, end: source.count, depth: 0, steps: &steps)
        guard node.isTag(16), node.constructed, source[offset...].allSatisfy({ $0 == 0 }) else {
            throw PDFStructureError.malformed("PKCS DER: SEQUENCE esterna o padding non nullo")
        }
        data = Data(source[..<offset]); bytes = Array(data); root = node
    }

    private static func read(_ bytes: [UInt8], offset: inout Int, end: Int, depth: Int, steps: inout Int) throws -> Node {
        steps += 1
        if steps % 1024 == 0 { try Task.checkCancellation() }
        guard depth < 64, steps < 100_000 else { throw PDFStructureError.limit }
        guard offset < end else { throw PDFStructureError.malformed("DER: identificatore troncato") }
        let start = offset, first = bytes[offset]; offset += 1
        let tagClass = Int(first >> 6), constructed = first & 0x20 != 0
        var tag = Int(first & 31)
        if tag == 31 {
            tag = 0
            guard offset < end, bytes[offset] & 127 != 0 else { throw PDFStructureError.malformed("DER: tag non minimo") }
            while true {
                guard offset < end, tag <= (Int.max - 127) / 128 else { throw PDFStructureError.malformed("DER: tag troncato/troppo grande") }
                let byte = bytes[offset]; offset += 1; tag = tag * 128 + Int(byte & 127)
                if byte & 128 == 0 { break }
            }
            guard tag >= 31 else { throw PDFStructureError.malformed("DER: tag lungo non minimo") }
        }
        guard offset < end else { throw PDFStructureError.malformed("DER: lunghezza assente") }
        var length = Int(bytes[offset]); offset += 1
        if length & 128 != 0 {
            let count = length & 127
            guard count > 0, count <= MemoryLayout<Int>.size, count <= end - offset, bytes[offset] != 0 else {
                throw PDFStructureError.malformed("DER: lunghezza indefinita/non minima/troncata")
            }
            length = 0
            for _ in 0..<count {
                guard length <= (Int.max - 255) / 256 else { throw PDFStructureError.malformed("DER: lunghezza eccessiva") }
                length = length * 256 + Int(bytes[offset]); offset += 1
            }
            guard length >= 128 else { throw PDFStructureError.malformed("DER: lunghezza lunga non minima") }
        }
        guard length <= end - offset else { throw PDFStructureError.malformed("DER: valore troncato") }
        let content = offset..<(offset + length)
        if tagClass == 0 {
            guard tag != 0, tag != 15 else { throw PDFStructureError.malformed("DER: tag universale riservato/EOC") }
            if [16, 17, 8, 11, 29].contains(tag) {
                guard constructed else { throw PDFStructureError.malformed("DER: tipo costruito codificato primitivo") }
            } else if [1, 2, 3, 4, 5, 6, 9, 10, 12, 13, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 30].contains(tag) {
                guard !constructed else { throw PDFStructureError.malformed("DER: tipo primitivo/stringa costruita") }
            }
            if !constructed { try primitive(bytes, tag: tag, content: content) }
        }
        var children: [Node] = []
        if constructed {
            while offset < content.upperBound {
                children.append(try read(bytes, offset: &offset, end: content.upperBound, depth: depth + 1, steps: &steps))
            }
        } else { offset = content.upperBound }
        return .init(tagClass: tagClass, tag: tag, constructed: constructed, range: start..<offset, content: content, children: children)
    }

    private static func primitive(_ bytes: [UInt8], tag: Int, content: Range<Int>) throws {
        let value = Array(bytes[content])
        func require(_ valid: Bool, _ message: String) throws {
            guard valid else { throw PDFStructureError.malformed("DER: " + message) }
        }
        switch tag {
        case 1: try require(value.count == 1 && [0, 255].contains(value[0]), "BOOLEAN non canonico")
        case 2, 10:
            try require(!value.isEmpty, "INTEGER/ENUMERATED vuoto")
            if value.count > 1 {
                try require(!(value[0] == 0 && value[1] & 128 == 0) && !(value[0] == 255 && value[1] & 128 != 0), "INTEGER/ENUMERATED non minimo")
            }
        case 3:
            try require(!value.isEmpty && value[0] <= 7, "BIT STRING: unused bits")
            if value.count == 1 { try require(value[0] == 0, "BIT STRING vuoto con bit inutilizzati") }
            else if value[0] > 0 { try require(value.last! & UInt8((1 << Int(value[0])) - 1) == 0, "BIT STRING: bit inutilizzati non nulli") }
        case 5: try require(value.isEmpty, "NULL con contenuto")
        case 6, 13:
            try require(!value.isEmpty, "OBJECT IDENTIFIER vuoto")
            var first = true
            for byte in value {
                if first { try require(byte != 128, "OBJECT IDENTIFIER: componente non minimo") }
                first = byte & 128 == 0
            }
            try require(first, "OBJECT IDENTIFIER troncato")
        case 12: try require(String(bytes: value, encoding: .utf8) != nil, "UTF8String non valido")
        case 18: try require(value.allSatisfy { $0 == 32 || (48...57).contains($0) }, "NumericString non valido")
        case 19:
            let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 '()+,-./:=?".utf8)
            try require(value.allSatisfy { alphabet.contains($0) }, "PrintableString non valido")
        case 22: try require(value.allSatisfy { $0 < 128 }, "IA5String non ASCII")
        case 23, 24: try require(validTime(value, generalized: tag == 24), "tempo non canonico/non valido")
        case 26: try require(value.allSatisfy { (32...126).contains($0) }, "VisibleString non valido")
        case 28:
            try require(value.count % 4 == 0, "UniversalString troncato")
            for i in stride(from: 0, to: value.count, by: 4) {
                let scalar = value[i..<(i + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                try require(UnicodeScalar(scalar) != nil, "UniversalString: scalar non valido")
            }
        case 30:
            try require(value.count % 2 == 0, "BMPString troncato")
            for i in stride(from: 0, to: value.count, by: 2) {
                let scalar = UInt32(value[i]) * 256 + UInt32(value[i + 1])
                try require(UnicodeScalar(scalar) != nil, "BMPString: surrogate non valido")
            }
        default: break
        }
    }

    private static func validTime(_ bytes: [UInt8], generalized: Bool) -> Bool {
        let digits = generalized ? 14 : 12
        guard bytes.count >= digits + 1, bytes.last == 90, bytes.prefix(digits).allSatisfy({ (48...57).contains($0) }) else { return false }
        if bytes.count != digits + 1 {
            guard generalized, bytes.count >= digits + 3, bytes[digits] == 46, bytes[bytes.count - 2] != 48,
                  bytes[(digits + 1)..<(bytes.count - 1)].allSatisfy({ (48...57).contains($0) }) else { return false }
        }
        func number(_ index: Int, _ count: Int = 2) -> Int { bytes[index..<(index + count)].reduce(0) { $0 * 10 + Int($1 - 48) } }
        let yearDigits = generalized ? 4 : 2
        let shortYear = number(0, yearDigits), year = generalized ? shortYear : shortYear + (shortYear >= 50 ? 1900 : 2000)
        let month = number(yearDigits), day = number(yearDigits + 2), hour = number(yearDigits + 4), minute = number(yearDigits + 6), second = number(yearDigits + 8)
        guard year > 0, (1...12).contains(month), (0...23).contains(hour), minute < 60, second < 60 else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...days[month - 1]).contains(day)
    }

    /// SET and SET OF have different ordering rules. Only schema-identified
    /// SET OF nodes are compared lexicographically; arbitrary unknown SETs
    /// are never guessed to have SET OF semantics.
    func checkSetOf(_ node: Node) throws {
        guard node.constructed else { throw PDFStructureError.malformed("DER SET OF primitivo") }
        for index in 1..<max(1, node.children.count) {
            let a = Array(bytes[node.children[index - 1].range]), b = Array(bytes[node.children[index].range])
            for i in 0..<max(a.count, b.count) {
                let left: UInt8 = i < a.count ? a[i] : 0, right: UInt8 = i < b.count ? b[i] : 0
                if left < right { break }
                if left > right { throw PDFStructureError.malformed("DER SET OF non ordinato") }
            }
        }
    }

    func checkSignedDataSets() throws {
        let signedDataOID: [UInt8] = [42, 134, 72, 134, 247, 13, 1, 7, 2]
        guard root.children.count == 2, root.children[0].isTag(6), Array(bytes[root.children[0].content]) == signedDataOID,
              root.children[1].isTag(0, 2), root.children[1].constructed, root.children[1].children.count == 1 else {
            throw PDFStructureError.malformed("PKCS#7: ContentInfo signedData atteso")
        }
        let signed = root.children[1].children[0], values = signed.children
        guard signed.isTag(16), values.count >= 4, values[0].isTag(2), values[1].isTag(17),
              values[2].isTag(16), values.last!.isTag(17) else { throw PDFStructureError.malformed("PKCS#7: SignedData non valido") }
        try checkSetOf(values[1]); try checkSetOf(values.last!)
        for value in values.dropFirst(3).dropLast() {
            guard value.tagClass == 2, [0, 1].contains(value.tag) else { throw PDFStructureError.malformed("PKCS#7: campo SignedData non valido") }
            try checkSetOf(value) // certificates / crls are IMPLICIT SET OF.
        }
        for signer in values.last!.children {
            guard signer.isTag(16), signer.children.count >= 5 else { throw PDFStructureError.malformed("PKCS#7: SignerInfo non valido") }
            let sid = signer.children[1]
            if sid.isTag(16), let issuer = sid.children.first { try checkName(issuer) }
            for field in signer.children where field.tagClass == 2 && [0, 1].contains(field.tag) && field.constructed {
                try checkSetOf(field) // authenticated / unauthenticated attributes.
                for attribute in field.children {
                    guard attribute.isTag(16), attribute.children.count == 2, attribute.children[0].isTag(6), attribute.children[1].isTag(17) else {
                        throw PDFStructureError.malformed("PKCS#7: Attribute non valido")
                    }
                    try checkSetOf(attribute.children[1])
                }
            }
        }
        for certificates in values.dropFirst(3).dropLast() where certificates.isTag(0, 2) {
            for certificate in certificates.children where certificate.isTag(16) {
                guard let tbs = certificate.children.first, tbs.isTag(16) else { throw PDFStructureError.malformed("X.509: TBSCertificate assente") }
                let shift = tbs.children.first?.isTag(0, 2) == true ? 1 : 0
                guard tbs.children.count >= shift + 6 else { throw PDFStructureError.malformed("X.509: TBSCertificate troncato") }
                try checkName(tbs.children[shift + 2]); try checkName(tbs.children[shift + 4])
                if shift == 1 {
                    let version = tbs.children[0]
                    guard version.children.count == 1, version.children[0].isTag(2) else { throw PDFStructureError.malformed("X.509: versione non valida") }
                    // Version v1(0) has DEFAULT v1 and must be omitted in DER.
                    if Array(bytes[version.children[0].content]) == [0] { throw PDFStructureError.malformed("X.509: DEFAULT v1 esplicito") }
                }
                for extensionField in tbs.children.dropFirst(shift + 6) where extensionField.isTag(3, 2) {
                    guard extensionField.children.count == 1, extensionField.children[0].isTag(16) else { throw PDFStructureError.malformed("X.509: Extensions non valido") }
                    for ext in extensionField.children[0].children {
                        guard ext.isTag(16), (2...3).contains(ext.children.count), ext.children[0].isTag(6), ext.children.last!.isTag(4) else { throw PDFStructureError.malformed("X.509: Extension non valida") }
                        if ext.children.count == 3 {
                            let critical = ext.children[1]
                            guard critical.isTag(1) else { throw PDFStructureError.malformed("X.509: critical non booleano") }
                            if Array(bytes[critical.content]) == [0] { throw PDFStructureError.malformed("X.509: DEFAULT critical false esplicito") }
                        }
                    }
                }
            }
        }
    }

    private func checkName(_ node: Node) throws {
        guard node.isTag(16) else { throw PDFStructureError.malformed("X.509: Name non SEQUENCE") }
        for rdn in node.children {
            guard rdn.isTag(17) else { throw PDFStructureError.malformed("X.509: RDN non SET OF") }
            try checkSetOf(rdn)
        }
    }
}
