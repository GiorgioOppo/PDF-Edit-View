import Foundation
import CoreGraphics

struct PDFArchiveRuleEvaluation {
    let status: PDFArchiveRuleStatus
    let detail: String
    var locations: [String] = []
    static func unknown(_ detail: String) -> Self { .init(status: .notVerified, detail: detail) }
    static func check(_ success: Bool, _ detail: String, locations: [String] = []) -> Self {
        .init(status: success ? .passed : .failed, detail: detail, locations: locations)
    }
    static func absent(_ detail: String) -> Self { .init(status: .notApplicable, detail: detail) }
}

/// Explicit property implementations, not a JavaScript evaluator. No unknown
/// veraPDF model property is inferred true from an empty collection.
final class PDFArchiveRuleContext {
    struct Node {
        let dictionary: [String: PDFSyntaxValue]
        let location: String
        let role: String
        let stream: Data?
    }
    let reader: PDFStructureDocument
    let profile: PDFArchiveProfile
    let root: [String: PDFSyntaxValue]
    let finalTrailer: [String: PDFSyntaxValue]
    var nodes: [Node] = []
    var primitives: [(PDFSyntaxValue, String)] = []
    var diagnostics: [String] = []
    var xmp: PDFArchiveXMP?
    private var metadataPackages: [(location: String, result: Result<PDFArchiveXMP, Error>)] = []
    private var malformedXMP = false
    private var seenRoles = Set<String>()
    private var indexedObjects: [PDFObjectID: PDFIndirectObject] = [:]
    private var contentEvidence: Result<PDFArchiveContentEvidence, Error>?
    private var primitiveInventory: (values:[(PDFSyntaxValue,String)],complete:Bool)?
    private lazy var syntaxChecks = PDFArchiveSyntaxChecks(reader: reader)
    private lazy var fontChecks = PDFArchiveFontChecks(reader: reader, profile: profile)
    private lazy var metadataChecks = PDFArchiveMetadataChecks(reader: reader, profile: profile)
    private lazy var graphicsChecks = PDFArchiveGraphicsChecks(reader: reader, profile: profile)
    private lazy var structureChecks = PDFArchiveStructureChecks(reader: reader, profile: profile)
    private lazy var objectChecks = PDFArchiveObjectChecks(reader: reader, profile: profile)
    private lazy var functionChecks = PDFArchiveFunctionChecks(reader: reader)
    var modelChecks: [PDFArchiveRuleResult] { [syntaxChecks.modelResult()] + objectChecks.modelChecks + fontChecks.modelChecks + structureChecks.modelChecks + graphicsChecks.modelChecks + functionChecks.modelChecks }

    init(data: Data, profile: PDFArchiveProfile) throws {
        self.profile = profile; reader = try PDFStructureDocument(data: data)
        root = try reader.dictionary(.reference(reader.rootID))
        finalTrailer = try Self.lastTrailer(reader)
        if reader.encrypted { diagnostics.append(L10n.tr("Cifratura rilevata: viene controllato il divieto Encrypt, il contenuto non viene decifrato.")); return }
        for id in reader.allObjectIDs() {
            try Task.checkCancellation()
            let object = try reader.object(id); indexedObjects[id] = object
        }
        for id in reader.allObjectIDs() {
            if let object = indexedObjects[id] { try index(object.value, location: "oggetto \(id.syntax)", stream: object.stream, depth: 0) }
        }
        let mainMetadata = try reader.resolvedObjectID(root["Metadata"])
        var metadataIDs = Set(try nodes.compactMap { try reader.resolvedObjectID($0.dictionary["Metadata"]) })
        metadataIDs.formUnion(indexedObjects.compactMap { id, object in object.value.dictionary?["Type"]?.name == "Metadata" ? id : nil })
        for metadata in metadataIDs.sorted() {
            let result = Result { try PDFArchiveXMP(data: reader.decodedStream(metadata)) }
            metadataPackages.append(("Metadata " + metadata.syntax, result))
            if metadata == mainMetadata {
                switch result {
                case .success(let package): xmp = package
                case .failure(let error):
                    if let structureError = error as? PDFStructureError, case .malformed = structureError { malformedXMP = true }
                }
            }
            if case .failure(let error) = result { diagnostics.append(L10n.tr("Metadata \(metadata.syntax) non analizzabile: ") + error.localizedDescription) }
        }
    }
    private static func lastTrailer(_ reader: PDFStructureDocument) throws -> [String: PDFSyntaxValue] {
        var lexer = PDFSyntaxLexer(reader.source, offset: reader.lastXref)
        if try lexer.word() == "xref" {
            while true {
                let start = try lexer.word(); if start == "trailer" { return try lexer.value().dictionary ?? [:] }
                guard Int(start) != nil, let count = Int(try lexer.word()), count >= 0, count < 1_000_000 else { throw PDFStructureError.limit }
                for _ in 0..<count { _ = try lexer.word(); _ = try lexer.word(); _ = try lexer.word() }
            }
        }
        lexer = PDFSyntaxLexer(reader.source, offset: reader.lastXref)
        _ = try lexer.word(); _ = try lexer.word(); guard try lexer.word() == "obj" else { throw PDFStructureError.malformed(L10n.tr("ultimo trailer")) }
        return try lexer.value().dictionary ?? [:]
    }
    private func index(_ value: PDFSyntaxValue, location: String, role: String = "", stream: Data? = nil, depth: Int) throws {
        guard depth < 100, primitives.count < 2_000_000 else { throw PDFStructureError.limit }
        if let reference = value.reference {
            guard !role.isEmpty else { return }
            let key = reference.syntax + ":" + role; guard seenRoles.insert(key).inserted else { return }
            let object = try reader.object(reference)
            try index(object.value, location: location + " → " + reference.syntax, role: role, stream: object.stream, depth: depth + 1)
            return
        }
        primitives.append((value, location))
        if let array = value.array {
            for (i, item) in array.enumerated() { try index(item, location: location + "[\(i)]", role: role, depth: depth + 1) }
        }
        guard let dictionary = value.dictionary else { return }
        let type = dictionary["Type"]?.name ?? ""
        let actualRole = role.isEmpty ? (type == "Font" ? "UnboundFontObject" : type) : role
        nodes.append(.init(dictionary: dictionary, location: location, role: actualRole, stream: stream))
        for (key, item) in dictionary {
            primitives.append((.name(key),location + "/chiave " + key))
            if key == "Resources" && (["Page", "Pages", "XObject", "Font", "Pattern"].contains(actualRole) || dictionary["Subtype"]?.name == "Form") {
                try index(item, location: location + "/Resources", role: "Resources", depth: depth + 1)
            }
            else if actualRole == "Resources" && ["Font", "ExtGState", "XObject"].contains(key) {
                let resources = try reader.dictionary(item)
                for (name, resource) in resources { try index(resource, location: location + "/\(key)/\(name)", role: key, depth: depth + 1) }
            } else if key == "Annots" { try index(item, location: location + "/Annots", role: "Annot", depth: depth + 1) }
            else if key == "AcroForm" { try index(item, location: location + "/AcroForm", role: "AcroForm", depth: depth + 1) }
            else if key == "Fields" || (key == "Kids" && ["FormField", "AcroForm"].contains(actualRole)) { try index(item, location: location + "/\(key)", role: "FormField", depth: depth + 1) }
            else if key == "DescendantFonts" && actualRole == "Font" { try index(item, location: location + "/\(key)", role: "Font", depth: depth + 1) }
            else if (key == "A" && ["Annot", "FormField", "OutlineItem"].contains(actualRole)) || (key == "OpenAction" && actualRole == "Catalog") {
                // OpenAction may legally be a destination array, not an action.
                let isAction = try reader.resolve(item)?.dictionary != nil
                try index(item, location: location + "/\(key)", role: isAction ? "Action" : "", depth: depth + 1)
            }
            else if key == "Outlines" { try index(item, location: location + "/Outlines", role: "OutlineRoot", depth: depth + 1) }
            else if (key == "First" && ["OutlineRoot", "OutlineItem"].contains(actualRole)) || (["Next", "Prev"].contains(key) && actualRole == "OutlineItem") {
                try index(item, location: location + "/\(key)", role: "OutlineItem", depth: depth + 1)
            }
            else if key == "Next" && actualRole == "Action" { try index(item, location: location + "/Next", role: "Action", depth: depth + 1) }
            else if key == "AA" && ["Catalog", "Page", "Annot", "FormField"].contains(actualRole) {
                for (event, action) in try reader.dictionary(item) { try index(action, location: location + "/AA/" + event, role: "Action", depth: depth + 1) }
            } else { try index(item, location: location + "/" + key, depth: depth + 1) }
        }
    }
    static func fileEvaluation(_ rule: PDFArchiveCatalogueRule, data: Data, profile: PDFArchiveProfile) -> PDFArchiveRuleEvaluation? {
        guard rule.objectType == "CosDocument" else { return nil }
        let bytes = Array(data)
        if rule.clause == "6.1.2" && rule.testNumber == "1" {
            let firstLine = String(decoding: bytes.prefix { $0 != 10 && $0 != 13 }, as: UTF8.self)
            let pattern = profile.part == 4 ? "^%PDF-2\\.[0-9]$" : (profile.part == 1 ? "^%PDF-[0-9]\\.[0-9]$" : "^%PDF-1\\.[0-7]$")
            return .check(firstLine.range(of: pattern, options: .regularExpression) != nil && bytes.count > firstLine.utf8.count, L10n.tr("Intestazione a byte zero: \(firstLine)."), locations: ["byte 0"])
        }
        if rule.clause == "6.1.2" && rule.testNumber == "2" {
            var cursor = bytes.firstIndex { $0 == 10 || $0 == 13 } ?? bytes.count
            if cursor < bytes.count { let eol = bytes[cursor]; cursor += 1; if eol == 13, cursor < bytes.count, bytes[cursor] == 10 { cursor += 1 } }
            let valid = cursor + 5 <= bytes.count && bytes[cursor] == 37 && bytes[(cursor + 1)...(cursor + 4)].allSatisfy { $0 > 127 }
            return .check(valid, L10n.tr("Commento binario immediatamente dopo l’intestazione: quattro byte >127."), locations: ["byte \(cursor)"])
        }
        if rule.clause == "6.1.3" && rule.testNumber == "3" {
            guard let range = data.range(of: Data("%%EOF".utf8), options: .backwards) else { return .unknown(L10n.tr("Marcatore EOF non trovato.")) }
            let tail = data.subdata(in: range.upperBound..<data.count)
            return .check([Data(), Data([10]), Data([13]), Data([13,10])].contains(tail), L10n.tr("Dopo l’ultimo %%EOF: \(tail.count) byte; ammesso solo un EOL opzionale."), locations: ["byte \(range.upperBound)"])
        }
        return nil
    }
    private func checks(_ candidates: [Node], _ summary: String, _ predicate: (Node) throws -> Bool) rethrows -> PDFArchiveRuleEvaluation {
        if candidates.isEmpty { return .absent(L10n.tr("Nessun oggetto applicabile indicizzato: ") + summary) }
        var failures: [String] = []
        for candidate in candidates { if try !predicate(candidate) { failures.append(candidate.location) } }
        return .check(failures.isEmpty, L10n.tr("\(candidates.count) oggetti controllati: \(summary)"), locations: failures.isEmpty ? candidates.prefix(8).map(\.location) : Array(failures.prefix(64)))
    }
    private func values(_ candidates: [(PDFSyntaxValue, String)], _ summary: String, _ predicate: (PDFSyntaxValue) -> Bool) -> PDFArchiveRuleEvaluation {
        let failures = candidates.filter { !predicate($0.0) }.map(\.1)
        if failures.isEmpty, primitiveInventory?.complete == false { return .unknown(L10n.tr("Inventario lessicale dei contenuti incompleto: ") + summary) }
        if candidates.isEmpty { return .absent(L10n.tr("Nessun valore applicabile: ") + summary) }
        return .check(failures.isEmpty, L10n.tr("\(candidates.count) valori controllati: \(summary)"), locations: Array(failures.prefix(64)))
    }
    private func allPrimitiveValues() throws -> [(PDFSyntaxValue,String)] {
        if let primitiveInventory { return primitiveInventory.values }
        let evidence = try PDFArchiveContentScanner(reader:reader).scan(allowPartial:true)
        var combined = primitives
        func append(_ value:PDFSyntaxValue,depth:Int) throws {
            guard depth < 100,combined.count < 2_000_000 else { throw PDFStructureError.limit }
            combined.append((value,"operando nei contenuti"))
            if let array = value.array { for item in array { try append(item,depth:depth + 1) } }
            if let dictionary = value.dictionary {
                for (key,item) in dictionary { combined.append((.name(key),"chiave nei contenuti"));try append(item,depth:depth + 1) }
            }
        }
        for value in evidence.lexicalValues { try append(value,depth:0) }
        primitiveInventory = (combined,evidence.lexicalComplete)
        return combined
    }
    private func resolvedName(_ value: PDFSyntaxValue?) throws -> String? { try reader.resolve(value)?.name }
    private func resolvedInt(_ value: PDFSyntaxValue?) throws -> Int? { try reader.resolve(value)?.int }
    private func resolvedBool(_ value: PDFSyntaxValue?) throws -> Bool? { try reader.resolve(value)?.bool }
    private func quotedValues(_ expression: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "[\\\"']([^\\\"']+)[\\\"']") else { return [] }
        let ns = expression as NSString
        return regex.matches(in: expression, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }
    func evaluate(_ rule: PDFArchiveCatalogueRule) throws -> PDFArchiveRuleEvaluation {
        if let result = Self.fileEvaluation(rule, data: reader.source, profile: profile) { return result }
        let object = rule.objectType, expression = rule.expression
        if object == "CosTrailer", expression == "isEncrypted != true" { return .check(!reader.encrypted, L10n.tr("Presenza Encrypt nel trailer: \(reader.encrypted)."), locations: ["trailer"]) }
        if reader.encrypted { return .unknown(L10n.tr("Contenuto cifrato; controllo non eseguito.")) }
        if let result = try syntaxChecks.evaluate(rule) { return result }
        if let result = try metadataChecks.evaluate(rule) { return result }
        if let result = try fontChecks.evaluate(rule) { return result }
        if let result = try graphicsChecks.evaluate(rule) { return result }
        if let result = try structureChecks.evaluate(rule) { return result }
        if let result = try objectChecks.evaluate(rule) { return result }
        if object == "CosBBox", expression.contains("14400") {
            var failures:[String] = []
            let pages = try reader.pageIDs()
            for (index,id) in pages.enumerated() {
                let dictionary = try reader.dictionary(.reference(id))
                let media = try reader.inherited("MediaBox",pageID:id)
                let crop = try reader.inherited("CropBox",pageID:id) ?? media
                let boundaries:[(String,PDFSyntaxValue?)] = [
                    ("MediaBox",media),("CropBox",crop),("BleedBox",dictionary["BleedBox"] ?? crop),
                    ("TrimBox",dictionary["TrimBox"] ?? crop),("ArtBox",dictionary["ArtBox"] ?? crop)
                ]
                for (name,value) in boundaries {
                    guard let array = try reader.resolve(value)?.array,array.count == 4 else { failures.append("pagina \(index + 1)/" + name);continue }
                    let numbers = try array.compactMap { try reader.resolve($0)?.real }
                    guard numbers.count == 4,numbers.allSatisfy(\.isFinite) else { failures.append("pagina \(index + 1)/" + name);continue }
                    let width = abs(numbers[2] - numbers[0]),height = abs(numbers[3] - numbers[1])
                    if !(3...14400).contains(width) || !(3...14400).contains(height) { failures.append("pagina \(index + 1)/\(name): \(width) × \(height)") }
                }
            }
            return .check(failures.isEmpty,L10n.tr("Dimensioni di tutti i confini pagina effettivi: eredità MediaBox/CropBox e valori di default per Bleed/Trim/Art."),locations:Array(failures.prefix(64)))
        }
        if object == "CosDocument" {
            if expression == "lastID != null && lastID.length() > 0" {
                let id = try reader.resolve(finalTrailer["ID"])?.array
                return .check(id?.count == 2 && id!.allSatisfy { !($0.data?.isEmpty ?? true) }, L10n.tr("ID nell’ultimo trailer: due stringhe non vuote."), locations: ["ultimo trailer/ID"])
            }
            if expression == "containsPieceInfo == true || containsInfo == false" {
                return .check(finalTrailer["Info"] == nil || root["PieceInfo"] != nil, L10n.tr("PDF/A-4: Info ammesso solo con PieceInfo nel catalogo."))
            }
            if expression == "containsEmbeddedFiles == false" {
                let names = try reader.dictionary(root["Names"])
                return .check(names["EmbeddedFiles"] == nil && !nodes.contains { $0.dictionary["EF"] != nil || $0.dictionary["Type"]?.name == "EmbeddedFile" }, L10n.tr("PDF/A-1 vieta file incorporati."))
            }
            if expression == "containsEmbeddedFiles == true" {
                let names = try reader.dictionary(root["Names"])
                return .check(names["EmbeddedFiles"] != nil, L10n.tr("PDF/A-4f richiede Names/EmbeddedFiles; AF/EF da soli non soddisfano questa condizione."))
            }
            if expression == "Requirements == null" { return .check(root["Requirements"] == nil, L10n.tr("Requirements nel catalogo.")) }
            if expression == "NeedsRendering == false" { return .check(try resolvedBool(root["NeedsRendering"]) != true, L10n.tr("NeedsRendering nel catalogo.")) }
            if expression.contains("nrIndirects <=") { return .check(reader.allObjectIDs().count <= 8_388_607, L10n.tr("Numero di oggetti attivi indicizzati: \(reader.allObjectIDs().count).")) }
            if expression == "isOptionalContentPresent == false" {
                if root["OCProperties"] != nil || nodes.contains(where: { $0.dictionary["OC"] != nil || $0.dictionary["Type"]?.name == "OCG" }) { return .check(false, L10n.tr("Contenuto opzionale presente, vietato in PDF/A-1.")) }
                return .unknown(L10n.tr("Assenza catalogo OCG rilevata; presenza di OC negli stream non verificata integralmente."))
            }
        }
        if object == "CosInfo", expression == "size == 1 && ModDate != null" {
            guard let info = finalTrailer["Info"] else { return .absent(L10n.tr("Info assente.")) }
            let dictionary = try reader.dictionary(info)
            return .check(dictionary.count == 1 && dictionary["ModDate"] != nil, L10n.tr("PDF/A-4: Info contiene solo ModDate."))
        }
        if object == "PDDocument" {
            if expression == "containsMetadata == true" { return .check(root["Metadata"] != nil, L10n.tr("Stream Metadata referenziato dal catalogo."), locations: ["Catalog/Metadata"]) }
            if expression == "containsStructTreeRoot == true" { return .check(root["StructTreeRoot"] != nil, L10n.tr("Profilo A: StructTreeRoot obbligatorio; la semantica completa resta non verificata.")) }
            if expression == "containsAA == false" { return .check(root["AA"] == nil, L10n.tr("Azioni aggiuntive nel catalogo.")) }
            if expression == "containsAlternatePresentations == false" {
                let names = try reader.dictionary(root["Names"])
                return .check(names["AlternatePresentations"] == nil, "Names/AlternatePresentations.")
            }
            if expression == "containsXRefStream == false" { return .check(!reader.revisions.contains { $0.dictionary["Type"]?.name == "XRef" }, L10n.tr("PDF/A-1 vieta xref stream, anche non autoindicizzati.")) }
            if expression.contains("Version == null") {
                let version = try resolvedName(root["Version"])
                return .check(version == nil || version!.range(of: "^2\\.[0-9]$", options: .regularExpression) != nil, L10n.tr("PDF/A-4: Version del catalogo \(version ?? "assente")."))
            }
        }
        if object == "PDPage" {
            let pages = nodes.filter { $0.dictionary["Type"]?.name == "Page" }
            if expression == "containsAA == false" { return checks(pages, "AA assente") { $0.dictionary["AA"] == nil } }
            if expression == "containsPresSteps == false" { return checks(pages, "PresSteps assente") { $0.dictionary["PresSteps"] == nil } }
        }
        if ["MainXMPPackage", "PDFAIdentification", "XMPPackage", "PDMetadata"].contains(object) {
            return try metadataEvaluation(rule)
        }
        if object == "CosInteger", expression.contains("2147483647") {
            return values(try allPrimitiveValues().filter { if case .number(let token) = $0.0 { return token.range(of: "^[+-]?[0-9]+$", options: .regularExpression) != nil }; return false }, "interi a 32 bit") { $0.int.map { (-2_147_483_648...2_147_483_647).contains($0) } ?? false }
        }
        if object == "CosReal" {
            let candidates = try allPrimitiveValues().filter { if case .number(let token) = $0.0 { return token.contains(".") }; return false }
            if expression.contains("32767.0") { return values(candidates, "reali PDF/A-1 ±32767") { $0.real.map { $0.isFinite && abs($0) <= 32767 } ?? false } }
            if expression.contains("3.403e+38") { return values(candidates, L10n.tr("reali nel limite Single")) { $0.real.map { $0.isFinite && abs($0) <= 3.403e38 } ?? false } }
            if expression.contains("1.175e-38") { return values(candidates, "reali zero o fuori dall’intervallo di underflow") {
                guard case .number(let token) = $0,let number = $0.real else { return false }
                let exactZero = token.utf8.allSatisfy { [43,45,46,48].contains($0) }
                return exactZero || (number.isFinite && abs(number) >= 1.175e-38)
            } }
        }
        if object == "CosString", expression.contains("value.length() <") {
            let maximum = profile.part == 1 ? 65536 : 32768
            return values(try allPrimitiveValues().filter { $0.0.data != nil }, "stringhe <\(maximum) byte") { ($0.data?.count ?? maximum) < maximum }
        }
        if object == "CosName", expression.contains("<= 127") {
            return values(try allPrimitiveValues().filter { $0.0.name != nil }, "nomi ≤127 byte decodificati") { ($0.name?.data(using: .isoLatin1)?.count ?? 128) <= 127 }
        }
        if object == "CosArray", expression == "size <= 8191" { return values(try allPrimitiveValues().filter { $0.0.array != nil }, "array ≤8191 elementi") { ($0.array?.count ?? 8192) <= 8191 } }
        if object == "CosDict", expression == "size <= 4095" { return values(try allPrimitiveValues().filter { $0.0.dictionary != nil }, "dizionari ≤4095 chiavi") { ($0.dictionary?.count ?? 4096) <= 4095 } }
        if object == "CosStream", expression == "F == null && FFilter == null && FDecodeParms == null" {
            return checks(nodes.filter { $0.stream != nil }, L10n.tr("nessun file/filtro esterno negli stream")) { $0.dictionary["F"] == nil && $0.dictionary["FFilter"] == nil && $0.dictionary["FDecodeParms"] == nil }
        }
        if object == "CosFilter" { return try filterEvaluation(rule) }
        if object == "CosFileSpecification" {
            let files = nodes.filter { $0.dictionary["Type"]?.name == "Filespec" || $0.dictionary["EF"] != nil }
            if expression == "containsEF == false" { return checks(files, "EF assente in PDF/A-1") { $0.dictionary["EF"] == nil } }
            if expression == "containsEF == false || (F != null && UF != null)" { return checks(files, L10n.tr("allegati con F e UF")) { $0.dictionary["EF"] == nil || ($0.dictionary["F"] != nil && $0.dictionary["UF"] != nil) } }
            if expression == "AFRelationship != null" || expression == "containsEF == false || AFRelationship != null" { return checks(files, L10n.tr("AFRelationship obbligatorio per file incorporati")) { $0.dictionary["EF"] == nil || $0.dictionary["AFRelationship"] != nil } }
        }
        if object == "EmbeddedFile" {
            let files = nodes.filter { $0.dictionary["Type"]?.name == "EmbeddedFile" }
            if expression.contains("Subtype != null") {
                return try checks(files, "Subtype MIME esplicito") { node in
                    guard let mime = try resolvedName(node.dictionary["Subtype"]) else { return false }
                    return mime.range(of: "^[-A-Za-z0-9_+.]+/[-A-Za-z0-9_+.]+$", options: .regularExpression) != nil
                }
            }
            if expression.contains("isValidPDFA") {
                if files.isEmpty { return .absent(L10n.tr("Nessun stream EmbeddedFile.")) }
                return .unknown(L10n.tr("Allegati presenti: ogni PDF incorporato richiede validazione ricorsiva completa del profilo ammesso. Nessun allegato viene presunto conforme."))
            }
        }
        if object == "PDPerms" {
            guard let perms = root["Perms"] else { return .absent(L10n.tr("Perms assente.")) }
            let dictionary = try reader.dictionary(perms), allowed = profile.part == 4 ? Set(["DocMDP"]) : Set(["DocMDP", "UR3"])
            return .check(Set(dictionary.keys).isSubset(of: allowed), L10n.tr("Chiavi Perms ammesse: \(allowed.sorted().joined(separator: ", "))."))
        }
        if object == "PDAction" || object == "PDNamedAction" {
            let actions = nodes.filter { $0.role == "Action" || $0.dictionary["Type"]?.name == "Action" }
            if object == "PDNamedAction" { return try checks(actions.filter { $0.dictionary["S"]?.name == "Named" }, "azioni Named ammesse") { quotedValues(expression).contains(try resolvedName($0.dictionary["N"]) ?? "") } }
            return try checks(actions, "tipi di azione ammessi dal profilo selezionato") { quotedValues(expression).contains(try resolvedName($0.dictionary["S"]) ?? "") }
        }
        if object == "PDAcroForm" {
            let forms = nodes.filter { $0.role == "AcroForm" }
            if expression == "NeedAppearances == null || NeedAppearances == false" { return try checks(forms, "NeedAppearances assente o false") { try resolvedBool($0.dictionary["NeedAppearances"]) != true } }
            if expression == "containsXFA == false" { return checks(forms, "XFA assente") { $0.dictionary["XFA"] == nil } }
        }
        if ["PDXImage", "PDMaskImage", "PDXForm", "PDXObject", "PDExtGState", "PDGroup", "PDHalftone"].contains(object) { return try graphicsDictionaryEvaluation(rule) }
        if object == "PDFont" { return try fontDictionaryEvaluation(rule) }
        if object == "Op_Undefined", expression == "false" {
            let evidence = try interpretedContent()
            return .check(evidence.undefinedOperators.isEmpty, L10n.tr("Operatori sconosciuti, inclusi quelli dentro BX/EX."), locations: evidence.undefinedOperators)
        }
        if object == "ICCOutputProfile" || object == "OutputIntents" || object == "PDOutputIntent" { return try outputIntentEvaluation(rule) }
        if object == "PDOCConfig" {
            let oc = try reader.dictionary(root["OCProperties"])
            var configs: [Node] = []
            if let value = oc["D"] { configs.append(.init(dictionary: try reader.dictionary(value), location: "Catalog/OCProperties/D", role: "OCConfig", stream: nil)) }
            for (i, value) in (try reader.resolve(oc["Configs"])?.array ?? []).enumerated() { configs.append(.init(dictionary: try reader.dictionary(value), location: "Catalog/OCProperties/Configs[\(i)]", role: "OCConfig", stream: nil)) }
            if expression.hasPrefix("Name != null") { return checks(configs, "nome configurazione livelli") { if expression.contains("length()") { return !($0.dictionary["Name"]?.text?.isEmpty ?? true) }; return $0.dictionary["Name"] != nil } }
            if expression == "AS == null" { return checks(configs, "AS assente") { $0.dictionary["AS"] == nil } }
        }
        return .unknown(L10n.tr("Proprietà/modello \(object) non implementato integralmente per questa regola; nessuna presunzione di conformità."))
    }
    private func filterEvaluation(_ rule: PDFArchiveCatalogueRule) throws -> PDFArchiveRuleEvaluation {
        let streams = nodes.filter { $0.stream != nil }
        let allowed = Set(["ASCIIHexDecode", "ASCII85Decode", "FlateDecode", "RunLengthDecode", "CCITTFaxDecode", "JBIG2Decode", "DCTDecode", "JPXDecode"])
        return try checks(streams, "filtri stream ammessi") { node in
            let filterValue = try reader.resolve(node.dictionary["Filter"])
            let filters = filterValue?.name.map { [$0] } ?? filterValue?.array?.compactMap(\.name) ?? []
            if filterValue != nil && filters.isEmpty { return false }
            if profile.part == 1 { return !filters.contains("LZWDecode") }
            let parameters = try reader.resolve(node.dictionary["DecodeParms"])
            let parameterValues = parameters?.array ?? [parameters ?? .null]
            return try filters.enumerated().allSatisfy { index, filter in
                if allowed.contains(filter) { return true }
                if filter == "Crypt", index < parameterValues.count { return try reader.dictionary(parameterValues[index])["Name"]?.name == "Identity" }
                return false
            }
        }
    }
    private func graphicsDictionaryEvaluation(_ rule: PDFArchiveCatalogueRule) throws -> PDFArchiveRuleEvaluation {
        let expression = rule.expression, object = rule.objectType
        let images = nodes.filter { $0.dictionary["Subtype"]?.name == "Image" }
        var candidates: [Node]
        switch object {
        case "PDXImage": candidates = images
        case "PDMaskImage": candidates = try images.filter { try resolvedBool($0.dictionary["ImageMask"]) == true }
        case "PDXForm": candidates = nodes.filter { $0.dictionary["Subtype"]?.name == "Form" }
        case "PDXObject": candidates = nodes.filter { $0.dictionary["Type"]?.name == "XObject" || $0.role == "XObject" }
        case "PDExtGState": candidates = nodes.filter { $0.dictionary["Type"]?.name == "ExtGState" || $0.role == "ExtGState" }
        case "PDGroup": candidates = nodes.filter { $0.dictionary["Type"]?.name == "Group" }
        case "PDHalftone": candidates = nodes.filter { $0.dictionary["HalftoneType"] != nil }
        default: candidates = []
        }
        let absentKeys: [String: String] = ["containsAlternates == false":"Alternates", "containsOPI == false":"OPI", "containsRef == false":"Ref", "containsTR == false":"TR", "containsHTP == false":"HTP", "containsHTO == false":"HTO", "HalftoneName == null":"HalftoneName"]
        if let key = absentKeys[expression] { return checks(candidates, "\(key) assente") { $0.dictionary[key] == nil } }
        if expression == "Interpolate == false" { return try checks(candidates, L10n.tr("Interpolate non true")) { try resolvedBool($0.dictionary["Interpolate"]) != true } }
        if expression.contains("BitsPerComponent") {
            return try checks(candidates, "BitsPerComponent ammesso dal profilo") { node in
                if object == "PDXImage", try resolvedBool(node.dictionary["ImageMask"]) == true { return true }
                guard node.dictionary["BitsPerComponent"] != nil else { return true }
                let bits = try resolvedInt(node.dictionary["BitsPerComponent"]) ?? -1
                if object == "PDMaskImage" { return bits == 1 }
                return (profile.part == 1 ? [1,2,4,8] : [1,2,4,8,16]).contains(bits)
            }
        }
        if expression == "containsTR2 == false || TR2NameValue == \"Default\"" { return try checks(candidates, "TR2 assente o Default") { node in
            if node.dictionary["TR2"] == nil { return true }
            return try resolvedName(node.dictionary["TR2"]) == "Default"
        } }
        if expression == "Subtype != \"PS\"" { return checks(candidates, "PostScript XObject vietato") { $0.dictionary["Subtype"]?.name != "PS" } }
        if expression.contains("Subtype2") { return checks(candidates, L10n.tr("Form senza PS, Subtype2 PS o OPI")) { $0.dictionary["Subtype2"]?.name != "PS" && $0.dictionary["PS"] == nil && (!expression.contains("containsOPI") || $0.dictionary["OPI"] == nil) } }
        if expression == "S != \"Transparency\"" { return checks(candidates, "gruppo Transparency vietato in PDF/A-1") { $0.dictionary["S"]?.name != "Transparency" } }
        if expression == "containsSMask == false" || expression == "containsSMask == false || SMaskNameValue == \"None\"" { return checks(candidates, "SMask vietata in PDF/A-1 salvo None in ExtGState") { $0.dictionary["SMask"] == nil || (object == "PDExtGState" && $0.dictionary["SMask"]?.name == "None") } }
        if expression.hasPrefix("CA == null") || expression.hasPrefix("ca == null") {
            let key = expression.hasPrefix("CA") ? "CA" : "ca"
            return checks(candidates, L10n.tr("opacità \(key) pari a 1")) { $0.dictionary[key] == nil || abs(($0.dictionary[key]?.real ?? -1) - 1) < 0.000001 }
        }
        if expression.hasPrefix("containsBM") { return try checks(candidates, "blend mode PDF/A-1") { node in
            if node.dictionary["BM"] == nil { return true }
            return quotedValues(expression).contains(try resolvedName(node.dictionary["BM"]) ?? "")
        } }
        if expression.hasPrefix("HalftoneType != null") { return try checks(candidates, "HalftoneType 1 o 5") { [1,5].contains(try resolvedInt($0.dictionary["HalftoneType"]) ?? -1) } }
        return .unknown(L10n.tr("Analisi grafica contestuale non completa per \(object)."))
    }
    private func fontDictionaryEvaluation(_ rule: PDFArchiveCatalogueRule) throws -> PDFArchiveRuleEvaluation {
        let fonts = nodes.filter { $0.role == "Font" }
        if rule.expression == "Type == \"Font\"" { return checks(fonts, "Type Font obbligatorio") { $0.dictionary["Type"]?.name == "Font" } }
        if rule.expression.hasPrefix("Subtype == \"Type1\"") { return checks(fonts, "sottotipo font ammesso") { quotedValues(rule.expression).contains($0.dictionary["Subtype"]?.name ?? "") } }
        if rule.expression == "Subtype == \"Type3\" || fontName != null" { return checks(fonts, "BaseFont obbligatorio salvo Type3") { $0.dictionary["Subtype"]?.name == "Type3" || $0.dictionary["BaseFont"]?.name != nil } }
        if rule.expression.contains("renderingMode == 3") && rule.expression.contains("containsFontFile") {
            let evidence = try interpretedContent()
            if evidence.fonts.isEmpty { return .absent(L10n.tr("Nessun testo dipinto negli stream interpretati.")) }
            var failures: [String] = []
            for use in evidence.fonts where use.visible {
                var actualFonts = [use.dictionary]
                if use.dictionary["Subtype"]?.name == "Type0" { actualFonts = try (reader.resolve(use.dictionary["DescendantFonts"])?.array ?? []).map { try reader.dictionary($0) } }
                for font in actualFonts where font["Subtype"]?.name != "Type3" {
                    let descriptor = try reader.dictionary(font["FontDescriptor"])
                    let files = ["FontFile", "FontFile2", "FontFile3"].compactMap { descriptor[$0]?.reference }
                    let present = try files.contains { id in let object = try reader.object(id); return !(object.stream?.isEmpty ?? true) }
                    if !present { failures.append(use.location + ": " + (font["BaseFont"]?.name ?? L10n.tr("font senza nome"))) }
                }
            }
            return .check(failures.isEmpty, L10n.tr("Embedding dei font effettivamente usati; testo esclusivamente Tr=3 esente. Validità programmi/glifi/mapping resta separata."), locations: failures)
        }
        // A missing FontFile alone is not a failure: Tr=3 can exempt embedding.
        // Render state, glyph use, embedded program and Unicode mappings must all
        // be modeled before this rule can be conclusively evaluated.
        return .unknown(L10n.tr("Controllo font richiede uso effettivo, rendering mode (inclusa esenzione Tr=3), programmi/glifi/CMap. Presenza FontFile o ToUnicode non assunta sufficiente."))
    }
    private func interpretedContent() throws -> PDFArchiveContentEvidence {
        if contentEvidence == nil { contentEvidence = Result { try PDFArchiveContentScanner(reader: reader).scan() } }
        return try contentEvidence!.get()
    }
    private func outputIntentEvaluation(_ rule: PDFArchiveCatalogueRule) throws -> PDFArchiveRuleEvaluation {
        let intents = try reader.resolve(root["OutputIntents"])?.array ?? []
        let candidates = try intents.enumerated().map { i, item in Node(dictionary: try reader.dictionary(item), location: "Catalog/OutputIntents[\(i)]", role: "OutputIntent", stream: nil) }
        if rule.objectType == "PDOutputIntent", rule.expression.contains("containsDestOutputProfileRef") {
            return checks(candidates, "profili output esterni vietati nei casi specificati") { rule.expression.hasPrefix("S !=") && $0.dictionary["S"]?.name != "GTS_PDFX" || $0.dictionary["DestOutputProfileRef"] == nil }
        }
        if rule.objectType == "OutputIntents", rule.expression == "numberOfPDFAOutputIntents <= 1" {
            return .check(candidates.filter { $0.dictionary["S"]?.name == "GTS_PDFA1" }.count <= 1, L10n.tr("PDF/A-4: al massimo un OutputIntent PDF/A nel catalogo."))
        }
        if rule.objectType == "OutputIntents", rule.expression == "sameOutputProfileIndirect == true" {
            if candidates.contains(where: { $0.dictionary["DestOutputProfile"] != nil && $0.dictionary["DestOutputProfile"]?.reference == nil }) {
                return .unknown(L10n.tr("DestOutputProfile non indiretto: identità dei profili non verificabile nel modello supportato."))
            }
            let profiles = candidates.compactMap { $0.dictionary["DestOutputProfile"]?.reference }
            if profiles.isEmpty { return .absent(L10n.tr("Nessun DestOutputProfile; ammissibilità dei colori resta da verificare contestualmente.")) }
            return .check(Set(profiles).count == 1, L10n.tr("Tutti gli OutputIntent con profilo incorporato usano lo stesso oggetto indiretto."))
        }
        if rule.objectType == "ICCOutputProfile" {
            if candidates.isEmpty { return .absent(L10n.tr("Nessun OutputIntent; assenza non è automaticamente violazione senza analizzare i colori usati.")) }
            return try checks(candidates.filter { $0.dictionary["DestOutputProfile"] != nil }, L10n.tr("classe, spazio e versione del profilo ICC di output")) { node in
                guard let id = node.dictionary["DestOutputProfile"]?.reference else { return false }
                let bytes = Array(try reader.decodedStream(id))
                guard bytes.count >= 128 else { return false }
                let deviceClass = String(decoding: bytes[12..<16], as: UTF8.self), space = String(decoding: bytes[16..<20], as: UTF8.self)
                return ["prtr","mntr"].contains(deviceClass) && ["RGB ","CMYK","GRAY"].contains(space) && Int(bytes[8]) < (profile.part == 1 ? 3 : 5)
            }
        }
        return .unknown(L10n.tr("Intenti di pagina/trasparenza e profili ICC contestuali non analizzati integralmente."))
    }
    private func metadataEvaluation(_ rule: PDFArchiveCatalogueRule) throws -> PDFArchiveRuleEvaluation {
        if rule.objectType == "XMPPackage" {
            guard !metadataPackages.isEmpty else { return .absent(L10n.tr("Nessun pacchetto Metadata indicizzato; obbligo del catalogo verificato separatamente.")) }
            var failures: [String] = [], unknown: [String] = []
            for package in metadataPackages {
                switch package.result {
                case .failure(let error):
                    if rule.expression == "isSerializationValid", let structureError = error as? PDFStructureError, case .malformed = structureError { failures.append(package.location) }
                    else { unknown.append(package.location) }
                case .success(let xmp):
                    if rule.expression == "bytes == null", xmp.packetAttributes.contains("bytes") { failures.append(package.location) }
                    else if rule.expression == "encoding == null", xmp.packetAttributes.contains("encoding") { failures.append(package.location) }
                    else if rule.expression == "actualEncoding == \"UTF-8\"", !xmp.utf8 { failures.append(package.location) }
                    else if rule.expression == "isSerializationValid" { unknown.append(package.location) }
                    else if !["bytes == null", "encoding == null", "actualEncoding == \"UTF-8\""].contains(rule.expression) { unknown.append(package.location) }
                }
            }
            if !failures.isEmpty { return .check(false,L10n.tr("Violazione in uno o più pacchetti XMP, inclusi quelli fuori dal catalogo."),locations:failures) }
            if !unknown.isEmpty { return .unknown(L10n.tr("Pacchetti XMP non decodificabili o serializzazione RDF completa non verificata: ") + unknown.joined(separator:", ")) }
            return .check(true,L10n.tr("Condizione verificata su tutti i \(metadataPackages.count) pacchetti Metadata indicizzati."))
        }
        guard root["Metadata"] != nil else { return .unknown(L10n.tr("XMP catalogo assente: regola identificativa non verificabile (assenza segnalata separatamente).")) }
        if rule.objectType == "XMPPackage", rule.expression == "isSerializationValid", malformedXMP {
            return .check(false, L10n.tr("Metadati decodificati ma XML non ben formato: la serializzazione XMP è invalida."))
        }
        guard let xmp else { return .unknown(L10n.tr("XMP non decodificabile/XML non analizzabile integralmente.")) }
        let expression = rule.expression
        if rule.objectType == "MainXMPPackage", expression == "containsPDFAIdentification == true" { return .check(xmp.hasIdentification, L10n.tr("Schema di identificazione http://www.aiim.org/pdfa/ns/id/ nel modello RDF riconosciuto.")) }
        if rule.objectType == "PDFAIdentification" {
            for name in ["part", "conformance", "rev"] {
                if expression.hasPrefix(name + " ==") {
                    let values = xmp.values(name)
                    if expression == name + " == null" { return .check(values.isEmpty, L10n.tr("\(profile.title): \(name) deve essere assente.")) }
                    if name == "part" { return .check(values.count == 1 && Int(values[0]) == profile.part, L10n.tr("part intero=\(values.joined(separator: ", ")); valore ammesso \(profile.part).")) }
                    let allowed = name == "part" ? [String(profile.part)] : quotedValues(expression)
                    return .check(values.count == 1 && allowed.contains(values.first ?? ""), L10n.tr("\(name)=\(values.joined(separator: ", ")); valori ammessi \(allowed.joined(separator: ", "))."))
                }
                if expression.hasPrefix(name + "Prefix") {
                    let prefixes = xmp.prefixes(name)
                    return .check(prefixes.allSatisfy { $0 == "pdfaid" }, L10n.tr("Prefisso identificativo \(name): pdfaid."))
                }
            }
            if expression.hasPrefix("amdPrefix") || expression.hasPrefix("corrPrefix") {
                let name = expression.hasPrefix("amd") ? "amd" : "corr"
                return .check(xmp.prefixes(name).allSatisfy { $0 == "pdfaid" }, L10n.tr("Prefisso identificativo \(name): pdfaid."))
            }
        }
        if rule.objectType == "XMPPackage" {
            if expression == "bytes == null" || expression == "encoding == null" {
                let name = expression.hasPrefix("bytes") ? "bytes" : "encoding"
                return .check(!xmp.packetAttributes.contains(name), L10n.tr("Attributo xpacket \(name) assente."))
            }
            if expression == "actualEncoding == \"UTF-8\"" { return .check(xmp.utf8, L10n.tr("Codifica effettiva dei byte XMP UTF-8.")) }
            if expression == "isSerializationValid" { return .unknown(L10n.tr("XML ben formato verificato; serializzazione XMP/RDF completa ISO16684 non ancora verificata.")) }
        }
        if rule.objectType == "PDMetadata", expression.contains("Filter == null") {
            let dictionary = try reader.dictionary(root["Metadata"])
            return .check(dictionary["Filter"] == nil, L10n.tr("PDF/A-1: metadati del catalogo non filtrati."))
        }
        return .unknown(L10n.tr("Semantica XMP/RDF/extension schema non completamente verificata."))
    }
}

/// Namespace-aware extraction supports both rdf:Description attributes and
/// property elements. Parsing XML is deliberately not called full XMP validation.
final class PDFArchiveXMP: NSObject, XMLParserDelegate {
    static let identificationURI = "http://www.aiim.org/pdfa/ns/id/"
    private var properties: [String: [String]] = [:], propertyPrefixes: [String: [String]] = [:]
    private var mappings: [String: [String]] = [:]
    private var stack: [(name: String, prefix: String, text: String, identification: Bool, uri: String)] = []
    private(set) var packetAttributes = Set<String>()
    let utf8: Bool
    init(data: Data) throws {
        guard data.count <= 8 * 1024 * 1024 else { throw PDFStructureError.limit }
        utf8 = String(data: data, encoding: .utf8) != nil && !data.contains(0) && !data.starts(with: Data([0xFF,0xFE])) && !data.starts(with: Data([0xFE,0xFF]))
        super.init()
        if String(data: data, encoding: .utf8)?.range(of: "<!DOCTYPE", options: .caseInsensitive) != nil { throw PDFStructureError.unsupported(L10n.tr("DOCTYPE nei metadati")) }
        let parser = XMLParser(data: data); parser.shouldProcessNamespaces = true; parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false; parser.delegate = self
        guard parser.parse() else { throw PDFStructureError.malformed(L10n.tr("XML XMP: \(parser.parserError?.localizedDescription ?? L10n.tr("errore"))")) }
    }
    func values(_ property: String) -> [String] { properties[property] ?? [] }
    func prefixes(_ property: String) -> [String] { propertyPrefixes[property] ?? [] }
    var hasIdentification: Bool { !properties.isEmpty }
    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) { mappings[prefix, default: []].append(namespaceURI) }
    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) { _ = mappings[prefix]?.popLast() }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let prefix = (qName?.split(separator: ":").count ?? 0) > 1 ? String(qName!.split(separator: ":")[0]) : ""
        let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
        let parentIsDescription = stack.last?.name == "Description" && stack.last?.uri == rdf
        let isDescription = elementName == "Description" && namespaceURI == rdf && stack.last?.name == "RDF" && stack.last?.uri == rdf
        stack.append((elementName, prefix, "", namespaceURI == Self.identificationURI && parentIsDescription, namespaceURI ?? ""))
        for (key, value) in attributes where isDescription {
            let components = key.split(separator: ":", maxSplits: 1).map(String.init)
            if components.count == 2, mappings[components[0]]?.last == Self.identificationURI {
                properties[components[1], default: []].append(value.trimmingCharacters(in: .whitespacesAndNewlines))
                propertyPrefixes[components[1], default: []].append(components[0])
            }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if !stack.isEmpty { stack[stack.count - 1].text += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let item = stack.popLast() else { return }
        if item.identification { properties[item.name, default: []].append(item.text.trimmingCharacters(in: .whitespacesAndNewlines)); propertyPrefixes[item.name, default: []].append(item.prefix) }
    }
    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        guard target == "xpacket", let data, let regex = try? NSRegularExpression(pattern: "\\b(bytes|encoding)\\s*=") else { return }
        let string = data as NSString
        for match in regex.matches(in: data, range: NSRange(location: 0, length: string.length)) { packetAttributes.insert(string.substring(with: match.range(at: 1))) }
    }
}

