import Foundation
import CryptoKit

/// Contextual PDF object predicates implemented from the pinned profile data
/// and public PDF specifications. Private dictionaries are not classified by
/// finding a coincidentally familiar key.
final class PDFArchiveObjectChecks {
    private struct Value {
        let value: PDFSyntaxValue
        let location: String
    }
    private struct Halftone {
        let dictionary: [String: PDFSyntaxValue]
        let colorant: String?
        let location: String
    }
    private struct IntentArray {
        let values: [Value]
        let location: String
    }
    private static let families: Set<String> = [
        "CosBM", "CosRenderingIntent", "CosUnicodeName", "CosXRef",
        "CosIIFilter", "PDHalftone", "PDOutputIntent", "OutputIntents"
    ]
    private static let resourceFamilies = families.subtracting(["CosXRef", "PDOutputIntent", "OutputIntents"])
    private static let contentFamilies: Set<String> = ["CosRenderingIntent", "CosUnicodeName", "CosIIFilter"]
    private static let appearanceFamilies: Set<String> = ["CosBM", "CosRenderingIntent", "PDHalftone"]
    private static let usageOperators = Set("b B b* B* BDC BI BMC BT BX c cm CS cs d d0 d1 Do DP EI EMC ET EX f F f* G g gs h i ID j J K k l m M MP n q Q re RG rg ri s S SC sc SCN scn sh T* Tc Td TD Tf Tj TJ TL Tm Tr Ts Tw Tz v w W W* y ' \"".split(separator: " ").map(String.init))
    private let reader: PDFStructureDocument
    private let profile: PDFArchiveProfile
    private var scanned: Result<Void, Error>?
    private lazy var colorModels = PDFArchiveColorSpaceChecks(reader:reader,part:profile.part)
    private var blendModes: [Value] = [], renderingIntents: [Value] = [], unicodeNames: [Value] = []
    private var inlineFilters: [Value] = [], halftones: [Halftone] = [], outputs: [IntentArray] = []
    private var gaps: [String: Set<String>] = [:]
    private var seenResources = Set<String>(), seenFonts = Set<String>(), seenObjects = Set<String>()
    private var seenContent = Set<String>(), seenStructures = Set<String>(), seenFields = Set<String>()
    private var seenUsedStreams = Set<String>(), seenUsedFonts = Set<String>(), seenUsedAnnotations = Set<String>()
    private var inventoryResourceFamilies: Set<String> { profile.part == 4 ? Self.resourceFamilies : Self.resourceFamilies.subtracting(Self.appearanceFamilies) }
    private var inventoryContentFamilies: Set<String> { profile.part == 4 ? Self.contentFamilies : Self.contentFamilies.subtracting(Self.appearanceFamilies) }
    private var typeFiveIssues: [String] = []
    private var typeFiveCount = 0
    private var steps = 0

    init(reader: PDFStructureDocument, profile: PDFArchiveProfile) {
        self.reader = reader; self.profile = profile
    }

    func evaluate(_ rule: PDFArchiveCatalogueRule) throws -> PDFArchiveRuleEvaluation? {
        guard Self.families.contains(rule.objectType) else { return nil }
        if rule.objectType == "CosXRef" { return try xref(rule) }
        if reader.encrypted { return .unknown("Oggetti cifrati: il modello contestuale non è stato analizzato.") }
        try ensureScanned()
        switch rule.objectType {
        case "CosBM":
            let allowed = quoted(rule.expression)
            return try names(blendModes, allowed: allowed, family: "CosBM",
                             detail: "BM negli ExtGState e nelle annotazioni, inclusi tutti gli elementi degli array.")
        case "CosRenderingIntent":
            return try names(renderingIntents, allowed: quoted(rule.expression), family: "CosRenderingIntent",
                             detail: "Rendering intent negli operatori ri, ExtGState/RI e Image/Intent.")
        case "CosUnicodeName":
            var failed: [String] = []
            for item in unicodeNames {
                try Task.checkCancellation()
                guard let name = try resolved(item.value)?.name, let bytes = originalNameBytes(name),
                      String(data: bytes, encoding: .utf8) != nil else { failed.append(item.location); continue }
            }
            return result(failed, count: unicodeNames.count, family: rule.objectType,
                          detail: "UTF-8 dei nomi font, coloranti e tipi strutturali dopo espansione #xx; nessun requisito NFC aggiunto.")
        case "CosIIFilter":
            let allowed = quoted(rule.expression)
            var failed: [String] = []
            for item in inlineFilters {
                guard let name = try resolved(item.value)?.name else { failed.append(item.location); continue }
                let valid = rule.expression.contains("!=") ? !["LZW", "LZWDecode"].contains(name) : allowed.contains(name)
                if !valid { failed.append(item.location + ": " + name) }
            }
            return result(failed, count: inlineFilters.count, family: rule.objectType,
                          detail: "Filtri dichiarati nelle vere immagini inline, anche array e abbreviazioni.")
        case "PDHalftone": return try halftone(rule)
        case "PDOutputIntent": return try outputIntent(rule)
        case "OutputIntents": return try outputArrays(rule)
        default: return nil
        }
    }

    /// Native model checks stay outside the immutable catalogue rule counts.
    /// ISO 32000-2:2020 Table132, with approved issues12/310/311, explicitly
    /// requires Default and forbids Type5 in component/default halftones.
    var modelChecks: [PDFArchiveRuleResult] {
        guard !reader.encrypted else { return [] }
        do { try ensureScanned() } catch { colorModels.inventoryGap(error.localizedDescription) }
        if let missing = gaps["CosUnicodeName"], !missing.isEmpty { colorModels.inventoryGap(missing.sorted().prefix(8).joined(separator:"; ")) }
        var rows = colorModels.modelChecks
        guard profile.part == 4, typeFiveCount > 0 else { return rows }
        let evaluation = result(typeFiveIssues, count: 1, family: "PDHalftone",
                                detail: "Type5: Default obbligatorio; componenti e Default non possono essere Type5. Fonte: ISO32000-2:2020 §10.6.5.6 Table132, errata approvati12/310/311.")
        rows.append(.init(id: "CartaPDF:ISO32000:halftone-type5-components",
                      specification: "ISO 32000-2:2020", clause: "10.6.5.6, Table132",
                      testNumber: "native-type5-components", objectType: "HalftoneModel",
                      requirement: "Un retino Type5 richiede Default e non può contenere componenti o Default di Type5.",
                      status: evaluation.status, detail: evaluation.detail, locations: evaluation.locations))
        return rows
    }

    private func ensureScanned() throws {
        if scanned == nil { scanned = Result { try scan() } }
        do { try scanned!.get() }
        catch is CancellationError { throw CancellationError() }
        catch { gap(Self.families.subtracting(["CosXRef"]), "Visita interrotta: " + error.localizedDescription) }
    }
    private func resolved(_ original: PDFSyntaxValue?) throws -> PDFSyntaxValue? {
        let value = try reader.resolve(original)
        if case .null? = value { return nil };return value
    }
    private func dictionary(_ value: PDFSyntaxValue?) throws -> [String: PDFSyntaxValue] {
        guard let value = try resolved(value) else { return [:] }
        guard let dictionary = value.dictionary else { throw PDFStructureError.malformed("dizionario atteso nel modello PDF") }
        return dictionary
    }
    private func array(_ value: PDFSyntaxValue?) throws -> [PDFSyntaxValue] {
        guard let value = try resolved(value) else { return [] }
        guard let array = value.array else { throw PDFStructureError.malformed("array atteso nel modello PDF") }
        return array
    }
    private func step(_ depth: Int) throws {
        try Task.checkCancellation(); steps += 1
        guard depth < 80, steps < 200_000 else { throw PDFStructureError.limit }
    }
    private func gap(_ families: Set<String>, _ message: String) {
        for family in families where (gaps[family]?.count ?? 0) < 128 { gaps[family, default: []].insert(message) }
    }
    private func capture(_ families: Set<String>, _ location: String, _ action: () throws -> Void) throws {
        do { try action() }
        catch is CancellationError { throw CancellationError() }
        catch { gap(families, location + ": " + error.localizedDescription) }
    }
    private func result(_ failures: [String], count: Int, family: String, detail: String) -> PDFArchiveRuleEvaluation {
        if !failures.isEmpty { return .check(false, detail, locations: Array(failures.prefix(64))) }
        if let unresolved = gaps[family], !unresolved.isEmpty { return .unknown(detail + " Contesti irrisolti: " + unresolved.sorted().prefix(8).joined(separator: "; ")) }
        return count == 0 ? .absent(detail + " Nessun valore applicabile.") : .check(true, detail)
    }
    private func names(_ values: [Value], allowed: Set<String>, family: String, detail: String) throws -> PDFArchiveRuleEvaluation {
        var failures: [String] = []
        for item in values {
            try Task.checkCancellation()
            guard let name = try resolved(item.value)?.name, allowed.contains(name) else { failures.append(item.location); continue }
        }
        return result(failures, count: values.count, family: family, detail: detail)
    }
    private func quoted(_ expression: String) -> Set<String> {
        let regex = try! NSRegularExpression(pattern: "[\"']([^\"']+)[\"']"), text = expression as NSString
        return Set(regex.matches(in: expression, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range(at: 1)) })
    }
    private func originalNameBytes(_ name: String) -> Data? {
        let scalars = name.unicodeScalars
        guard scalars.allSatisfy({ $0.value <= 255 }) else { return nil }
        return Data(scalars.map { UInt8($0.value) })
    }
    private func add(_ value: PDFSyntaxValue?, to values: inout [Value], location: String, flatten: Bool = false) throws {
        guard let actual = try resolved(value) else { return }
        if flatten, let array = actual.array {
            for (index, value) in array.enumerated() { values.append(.init(value: value, location: location + "[\(index)]")) }
        } else { values.append(.init(value: actual, location: location)) }
    }

    private func scan() throws {
        let root = try dictionary(.reference(reader.rootID))
        try capture(["OutputIntents", "PDOutputIntent"], "Catalog/OutputIntents") { try collectOutput(root, "Catalog") }
        let form = try dictionary(root["AcroForm"]), defaultResources = try dictionary(form["DR"])
        try capture(inventoryResourceFamilies, "AcroForm/DR") { try resources(form["DR"], "AcroForm/DR", depth: 0) }
        if let appearance = try resolved(form["DA"])?.data {
            try capture(inventoryContentFamilies, "AcroForm/DA") { try content(appearance, resources: defaultResources, location: "AcroForm/DA") }
        }
        for (index, field) in try array(form["Fields"]).enumerated() {
            try capture(inventoryResourceFamilies, "AcroForm/Fields[\(index)]") {
                try fieldTree(field, resources: defaultResources, location: "AcroForm/Fields[\(index)]", depth: 0)
            }
        }
        for (index, pageID) in try reader.pageIDs().enumerated() {
            try step(0)
            let page = try dictionary(.reference(pageID)), location = "pagina \(index + 1)"
            if profile.part == 4 { try capture(["OutputIntents", "PDOutputIntent"], location) { try collectOutput(page, location) } }
            let localResources = try dictionary(reader.inherited("Resources", pageID: pageID))
            try capture(inventoryResourceFamilies, location + "/Resources") { try resources(.dictionary(localResources), location + "/Resources", depth: 0) }
            try capture(inventoryContentFamilies, location + "/Contents") {
                var data = Data()
                for id in try reader.contentStreamIDs(on: pageID) {
                    data += try reader.decodedStream(id); data.append(32)
                    guard data.count <= 128 * 1024 * 1024 else { throw PDFStructureError.limit }
                }
                try content(data, resources: localResources, location: location + "/Contents")
            }
            for (j, value) in try array(page["Annots"]).enumerated() {
                try capture(inventoryResourceFamilies, location + "/Annots[\(j)]") {
                    try annotation(value, resources: localResources, location: location + "/Annots[\(j)]", depth: 0)
                }
            }
        }
        if let structure = root["StructTreeRoot"] {
            try capture(["CosUnicodeName"], "StructTreeRoot") { try structureTree(structure, location: "StructTreeRoot", depth: 0, root: true) }
        }
        // TechNote0010 A010 / ISO WG resolution: A1–3 resource objects never
        // named by their associated content are exempt beyond §6.1. The
        // inventory above deliberately retains Unicode/filter/base-format checks.
        if profile.part <= 3 { try scanReferencedAppearance(root: root) }
    }
    private func collectOutput(_ container: [String: PDFSyntaxValue], _ location: String) throws {
        guard try resolved(container["OutputIntents"]) != nil else { return }
        let entries = try array(container["OutputIntents"])
        outputs.append(.init(values: entries.enumerated().map { .init(value: $0.element, location: location + "/OutputIntents[\($0.offset)]") }, location: location + "/OutputIntents"))
    }
    private func resources(_ value: PDFSyntaxValue?, _ location: String, depth: Int) throws {
        try step(depth)
        guard let actual = try resolved(value) else { return }
        let key = value?.reference?.syntax ?? location
        guard seenResources.insert(key).inserted else { return }
        let d = try dictionary(actual)
        for (name, value) in try dictionary(d["ExtGState"]) {
            try capture(inventoryResourceFamilies, location + "/ExtGState/" + name) {
                try graphicsState(value, resources: d, location: location + "/ExtGState/" + name, depth: depth + 1)
            }
        }
        for (name, value) in try dictionary(d["Font"]) {
            try capture(inventoryResourceFamilies, location + "/Font/" + name) { try font(value, resources: d, location: location + "/Font/" + name, depth: depth + 1) }
        }
        for (name, value) in try dictionary(d["ColorSpace"]).sorted(by:{$0.key < $1.key}) {
            try capture(["CosUnicodeName"], location + "/ColorSpace/" + name) { try colorSpace(value, resources: d, location: location + "/ColorSpace/" + name, active: [], depth: depth + 1) }
        }
        for (name, value) in try dictionary(d["XObject"]) {
            try capture(inventoryResourceFamilies, location + "/XObject/" + name) { try xobject(value, resources: d, location: location + "/XObject/" + name, depth: depth + 1) }
        }
        for (name, value) in try dictionary(d["Pattern"]) {
            try capture(inventoryResourceFamilies, location + "/Pattern/" + name) {
                let object = try dictionary(value)
                try graphicsState(object["ExtGState"], resources: d, location: location + "/Pattern/" + name + "/ExtGState", depth: depth + 1)
                if let shading = object["Shading"] { try colorSpace(dictionary(shading)["ColorSpace"], resources: d, location: location + "/Pattern/" + name + "/Shading/ColorSpace", active: [], depth: depth + 1) }
                if let id = try reader.resolvedObjectID(value), try reader.object(id).stream != nil {
                    try form(id, resources: d, location: location + "/Pattern/" + name, depth: depth + 1)
                }
            }
        }
        for (name, value) in try dictionary(d["Shading"]) {
            try capture(["CosUnicodeName"], location + "/Shading/" + name) {
                try colorSpace(dictionary(value)["ColorSpace"], resources: d, location: location + "/Shading/" + name + "/ColorSpace", active: [], depth: depth + 1)
            }
        }
    }
    private func graphicsState(_ value: PDFSyntaxValue?, resources: [String: PDFSyntaxValue], location: String, depth: Int) throws {
        try step(depth); let d = try dictionary(value)
        if profile.part == 4 {
            try add(d["BM"], to: &blendModes, location: location + "/BM", flatten: true)
            try add(d["RI"], to: &renderingIntents, location: location + "/RI")
            if let ht = d["HT"] { try collectHalftone(ht, colorant: nil, location: location + "/HT", active: [], depth: depth + 1) }
        }
        if let fontArray = try resolved(d["Font"])?.array, let first = fontArray.first {
            try font(first, resources: resources, location: location + "/Font[0]", depth: depth + 1)
        }
        if let mask = try resolved(d["SMask"])?.dictionary, let id = mask["G"]?.reference {
            try form(id, resources: resources, location: location + "/SMask/G", depth: depth + 1)
        }
    }
    private func font(_ value: PDFSyntaxValue, resources: [String: PDFSyntaxValue], location: String, depth: Int) throws {
        try step(depth); let key = value.reference?.syntax ?? location
        guard seenFonts.insert(key).inserted else { return }
        let d = try dictionary(value)
        try add(d["BaseFont"], to: &unicodeNames, location: location + "/BaseFont")
        let descriptor = try dictionary(d["FontDescriptor"])
        try add(descriptor["FontName"], to: &unicodeNames, location: location + "/FontDescriptor/FontName")
        for (index, child) in try array(d["DescendantFonts"]).enumerated() {
            try font(child, resources: resources, location: location + "/DescendantFonts[\(index)]", depth: depth + 1)
        }
        if try resolved(d["Subtype"])?.name == "Type3" {
            let own = d["Resources"] == nil ? resources : try dictionary(d["Resources"])
            try self.resources(d["Resources"], location + "/Resources", depth: depth + 1)
            for (glyph, value) in try dictionary(d["CharProcs"]) {
                if let id = value.reference { try contentStream(id, resources: own, location: location + "/CharProcs/" + glyph) }
                else { gap(inventoryContentFamilies, location + "/CharProcs/" + glyph + ": stream indiretto assente") }
            }
        }
    }
    private func xobject(_ value: PDFSyntaxValue, resources: [String: PDFSyntaxValue], location: String, depth: Int) throws {
        try step(depth); let d = try dictionary(value), subtype = try resolved(d["Subtype"])?.name
        if subtype == "Form", let id = value.reference {
            try form(id, resources: resources, location: location, depth: depth + 1)
        } else if subtype == "Image" {
            let key = value.reference?.syntax ?? location
            guard seenObjects.insert("Image:" + key).inserted else { return }
            if profile.part == 4 { try add(d["Intent"], to: &renderingIntents, location: location + "/Intent") }
            try colorSpace(d["ColorSpace"], resources: resources, location: location + "/ColorSpace", active: [], depth: depth + 1)
            for name in ["SMask", "Mask"] {
                if let child = d[name], try resolved(child)?.dictionary != nil {
                    try xobject(child, resources: resources, location: location + "/" + name, depth: depth + 1)
                }
            }
            for (i, alternate) in try array(d["Alternates"]).enumerated() {
                if let image = try dictionary(alternate)["Image"] { try xobject(image, resources: resources, location: location + "/Alternates[\(i)]/Image", depth: depth + 1) }
            }
        }
    }
    private func form(_ id: PDFObjectID, resources: [String: PDFSyntaxValue], location: String, depth: Int) throws {
        try step(depth)
        let d = try dictionary(.reference(id)), own = d["Resources"] == nil ? resources : try dictionary(d["Resources"])
        let context = id.syntax + ":" + SHA256.hash(data: PDFSyntaxValue.dictionary(own).encoded).map { String(format: "%02x", $0) }.joined()
        guard seenObjects.insert("Form:" + context).inserted else { return }
        try self.resources(d["Resources"], location + "/Resources", depth: depth + 1)
        try colorSpace(dictionary(d["Group"])["CS"], resources: own, location: location + "/Group/CS", active: [], depth: depth + 1)
        try contentStream(id, resources: own, location: location)
    }
    private func contentStream(_ id: PDFObjectID, resources: [String: PDFSyntaxValue], location: String) throws {
        let context = id.syntax + ":" + SHA256.hash(data: PDFSyntaxValue.dictionary(resources).encoded).map { String(format: "%02x", $0) }.joined()
        guard seenContent.insert(context).inserted else { return }
        guard let terminal = try reader.resolvedObjectID(.reference(id)), try reader.object(terminal).stream != nil else { throw PDFStructureError.malformed("contenuto non è uno stream") }
        try content(reader.decodedStream(id), resources: resources, location: location)
    }
    private func annotation(_ value: PDFSyntaxValue, resources: [String: PDFSyntaxValue], location: String, depth: Int) throws {
        try step(depth); let key = value.reference?.syntax ?? location
        guard seenObjects.insert("Annot:" + key).inserted else { return }
        let d = try dictionary(value)
        if profile.part == 4 { try add(d["BM"], to: &blendModes, location: location + "/BM", flatten: true) }
        for (name, value) in try dictionary(d["AP"]) {
            if let id = try reader.resolvedObjectID(value), try reader.object(id).stream != nil {
                try form(id, resources: resources, location: location + "/AP/" + name, depth: depth + 1)
            } else {
                for (state, value) in try dictionary(value) {
                    if let id = value.reference { try form(id, resources: resources, location: location + "/AP/" + name + "/" + state, depth: depth + 1) }
                    else { gap(inventoryContentFamilies, location + "/AP/" + name + ": appearance non referenziabile") }
                }
            }
        }
        if let popup = d["Popup"] { try annotation(popup, resources: resources, location: location + "/Popup", depth: depth + 1) }
    }
    private func fieldTree(_ value: PDFSyntaxValue, resources: [String: PDFSyntaxValue], location: String, depth: Int) throws {
        try step(depth); let key = value.reference?.syntax ?? location
        guard seenFields.insert(key).inserted else { return }
        let d = try dictionary(value)
        if try resolved(d["Subtype"])?.name == "Widget" { try annotation(value, resources: resources, location: location, depth: depth + 1) }
        if let appearance = try resolved(d["DA"])?.data { try content(appearance, resources: resources, location: location + "/DA") }
        for (index, child) in try array(d["Kids"]).enumerated() { try fieldTree(child, resources: resources, location: location + "/Kids[\(index)]", depth: depth + 1) }
    }
    private func colorSpace(_ value: PDFSyntaxValue?, resources: [String: PDFSyntaxValue], location: String, active: Set<String>, depth: Int, inline:Bool = false) throws {
        colorModels.record(value,resources:resources,location:location,inline:inline)
        try step(depth); guard let actual = try resolved(value) else { return }
        if let name = actual.name {
            if ["DeviceGray", "DeviceRGB", "DeviceCMYK", "G", "RGB", "CMYK", "Pattern"].contains(name) { return }
            guard !active.contains(name) else { throw PDFStructureError.unsupported("alias colore circolare") }
            guard let target = try dictionary(resources["ColorSpace"])[name] else { throw PDFStructureError.unsupported("spazio colore nominato non risolto: " + name) }
            try colorSpace(target, resources: resources, location: location, active: active.union([name]), depth: depth + 1,inline:inline); return
        }
        guard let values = actual.array, let kind = try resolved(values.first)?.name else { throw PDFStructureError.malformed("spazio colore") }
        if kind == "Separation" {
            guard values.count >= 4 else { throw PDFStructureError.malformed("Separation troncata") }
            try add(values[1], to: &unicodeNames, location: location + "/SeparationName")
            try colorSpace(values[2], resources: resources, location: location + "/Alternate", active: active, depth: depth + 1,inline:inline)
        } else if kind == "DeviceN" {
            guard values.count >= 4 else { throw PDFStructureError.malformed("DeviceN troncato") }
            for (i, value) in try array(values[1]).enumerated() { try add(value, to: &unicodeNames, location: location + "/Names[\(i)]") }
            try colorSpace(values[2], resources: resources, location: location + "/Alternate", active: active, depth: depth + 1,inline:inline)
            if values.count > 4 {
                let attributes = try dictionary(values[4])
                for (name, color) in try dictionary(attributes["Colorants"]).sorted(by:{$0.key < $1.key}) {
                    guard try resolved(color) != nil else { continue }
                    unicodeNames.append(.init(value: .name(name), location: location + "/Colorants/" + name))
                    try colorSpace(color, resources: resources, location: location + "/Colorants/" + name, active: active, depth: depth + 1,inline:inline)
                }
            }
        } else if ["Indexed", "I", "Pattern"].contains(kind), values.count > 1 {
            try colorSpace(values[1], resources: resources, location: location + "/Base", active: active, depth: depth + 1,inline:inline)
        } else if kind == "ICCBased" {
            guard values.count > 1 else { throw PDFStructureError.malformed("ICCBased privo di profilo") }
            try colorSpace(dictionary(values[1])["Alternate"], resources: resources,
                           location: location + "/ICCBased/Alternate", active: active, depth: depth + 1,inline:inline)
        } else if !["CalGray", "CalRGB", "Lab"].contains(kind) {
            throw PDFStructureError.unsupported("famiglia colore non riconosciuta: " + kind)
        }
    }
    private func structureTree(_ value: PDFSyntaxValue, location: String, depth: Int, root: Bool = false) throws {
        try step(depth); guard let actual = try resolved(value) else { return }
        if let values = actual.array {
            for (i, value) in values.enumerated() { try structureTree(value, location: location + "[\(i)]", depth: depth + 1) }; return
        }
        guard let d = actual.dictionary else { return }
        let key = value.reference?.syntax ?? location
        guard seenStructures.insert(key).inserted else { return }
        let type = try resolved(d["Type"])?.name
        if root || type == "StructTreeRoot" {
            try roleNames(d["RoleMap"], location: location + "/RoleMap")
            for (i, namespace) in try array(d["Namespaces"]).enumerated() { try roleNames(dictionary(namespace)["RoleMapNS"], location: location + "/Namespaces[\(i)]/RoleMapNS") }
        } else if type == "StructElem" || (type == nil && d["S"] != nil) {
            try add(d["S"], to: &unicodeNames, location: location + "/S")
            if let namespace = d["NS"] { try roleNames(dictionary(namespace)["RoleMapNS"], location: location + "/NS/RoleMapNS") }
        }
        if root || type == "StructTreeRoot" || type == "StructElem" || (type == nil && d["S"] != nil) {
            if let children = d["K"] { try structureTree(children, location: location + "/K", depth: depth + 1) }
        }
    }
    private func roleNames(_ value: PDFSyntaxValue?, location: String) throws {
        for (name, target) in try dictionary(value) {
            unicodeNames.append(.init(value: .name(name), location: location + "/" + name))
            if let values = try resolved(target)?.array {
                if let targetName = values.first { try add(targetName, to: &unicodeNames, location: location + "/" + name + "/target") }
            } else { try add(target, to: &unicodeNames, location: location + "/" + name + "/target") }
        }
    }
    private func content(_ data: Data, resources: [String: PDFSyntaxValue], location: String) throws {
        var lexer = PDFSyntaxLexer(data), operands: [PDFSyntaxValue] = [], count = 0
        while true {
            try Task.checkCancellation(); lexer.skip(); if lexer.offset == lexer.bytes.count { return }
            count += 1; guard count < 1_000_000 else { throw PDFStructureError.limit }
            let offset = lexer.offset, value = try lexer.value()
            if case .keyword(let operation) = value {
                if operation == "ri", profile.part == 4 {
                    renderingIntents.append(.init(value: operands.last ?? .null, location: location + "/ri@" + String(offset)))
                } else if ["cs", "CS"].contains(operation), let value = operands.last {
                    try capture(["CosUnicodeName"], location + "/\(operation)@\(offset)") {
                        try colorSpace(value, resources: resources, location: location + "/\(operation)@\(offset)", active: [], depth: 0)
                    }
                } else if operation == "BI" {
                    let image = try PDFArchiveInlineImage.read(from: &lexer)
                    try add(image.dictionary["Filter"], to: &inlineFilters, location: location + "/BI@\(offset)/Filter", flatten: true)
                    if profile.part == 4 { try add(image.dictionary["Intent"], to: &renderingIntents, location: location + "/BI@\(offset)/Intent") }
                    try colorSpace(image.dictionary["ColorSpace"], resources: resources, location: location + "/BI@\(offset)/ColorSpace", active: [], depth: 0,inline:true)
                    guard image.lengthReliable else { gap(inventoryContentFamilies, location + "/BI@\(offset): confine binario non dimostrato"); return }
                }
                operands.removeAll(keepingCapacity: true)
            } else { operands.append(value); guard operands.count < 100_000 else { throw PDFStructureError.limit } }
        }
    }

    private func scanReferencedAppearance(root: [String: PDFSyntaxValue]) throws {
        for (index, pageID) in try reader.pageIDs().enumerated() {
            let page = try dictionary(.reference(pageID)), local = try dictionary(reader.inherited("Resources", pageID: pageID))
            let location = "pagina \(index + 1)"
            try capture(Self.appearanceFamilies, location + "/Contents/uso") {
                var data = Data()
                for id in try reader.contentStreamIDs(on: pageID) {
                    data += try reader.decodedStream(id); data.append(32)
                    guard data.count <= 128 * 1024 * 1024 else { throw PDFStructureError.limit }
                }
                try usedContent(data, resources: local, location: location + "/Contents", depth: 0, active: [])
            }
            for (i, value) in try array(page["Annots"]).enumerated() {
                try capture(Self.appearanceFamilies, location + "/Annots[\(i)]/uso") {
                    try usedAnnotation(value, resources: local, location: location + "/Annots[\(i)]", depth: 0)
                }
            }
        }
        let form = try dictionary(root["AcroForm"]), resources = try dictionary(form["DR"])
        if let data = try resolved(form["DA"])?.data {
            try capture(Self.appearanceFamilies, "AcroForm/DA/uso") { try usedContent(data, resources: resources, location: "AcroForm/DA", depth: 0, active: []) }
        }
        var seen = Set<String>()
        func fields(_ value: PDFSyntaxValue, _ location: String, depth: Int) throws {
            try step(depth)
            guard seen.insert(value.reference?.syntax ?? location).inserted else { return }
            let d = try dictionary(value)
            if try resolved(d["Subtype"])?.name == "Widget" { try usedAnnotation(value, resources: resources, location: location, depth: depth + 1) }
            if let data = try resolved(d["DA"])?.data { try usedContent(data, resources: resources, location: location + "/DA", depth: depth + 1, active: []) }
            for (index, child) in try array(d["Kids"]).enumerated() { try fields(child, location + "/Kids[\(index)]", depth: depth + 1) }
        }
        for (index, field) in try array(form["Fields"]).enumerated() {
            try capture(Self.appearanceFamilies, "AcroForm/Fields[\(index)]/uso") { try fields(field, "AcroForm/Fields[\(index)]", depth: 0) }
        }
    }
    private func usedResource(_ category: String, name: String?, resources: [String: PDFSyntaxValue]) throws -> PDFSyntaxValue {
        guard let name, let value = try dictionary(resources[category])[name] else {
            throw PDFStructureError.unsupported("risorsa nominalmente referenziata non risolta: " + category + "/" + (name ?? "?"))
        }
        return value
    }
    private func usedContent(_ data: Data, resources: [String: PDFSyntaxValue], location: String, depth: Int, active: Set<String>) throws {
        try step(depth)
        var lexer = PDFSyntaxLexer(data), operands: [PDFSyntaxValue] = [], count = 0
        while true {
            try Task.checkCancellation(); lexer.skip(); if lexer.offset == lexer.bytes.count { return }
            count += 1; guard count < 1_000_000 else { throw PDFStructureError.limit }
            let offset = lexer.offset, value = try lexer.value()
            guard case .keyword(let operation) = value else {
                operands.append(value); guard operands.count < 100_000 else { throw PDFStructureError.limit }; continue
            }
            let at = location + "/\(operation)@\(offset)"
            switch operation {
            case "ri": renderingIntents.append(.init(value: operands.last ?? .null, location: at))
            case "gs":
                try usedGraphicsState(usedResource("ExtGState", name: operands.last?.name, resources: resources), resources: resources, location: at, depth: depth + 1, active: active)
            case "Do":
                try usedXObject(usedResource("XObject", name: operands.last?.name, resources: resources), resources: resources, location: at, depth: depth + 1, active: active)
            case "scn", "SCN":
                if let name = operands.last?.name {
                    let value = try usedResource("Pattern", name: name, resources: resources), d = try dictionary(value)
                    try usedGraphicsState(d["ExtGState"], resources: resources, location: at + "/ExtGState", depth: depth + 1, active: active)
                    if let id = try reader.resolvedObjectID(value), try reader.object(id).stream != nil { try usedStream(id, resources: resources, location: at, depth: depth + 1, active: active) }
                }
            case "Tf":
                guard operands.count >= 2 else { throw PDFStructureError.unsupported("Tf privo di nome font") }
                try usedFont(usedResource("Font", name: operands[operands.count - 2].name, resources: resources), resources: resources, location: at, depth: depth + 1, active: active)
            case "BI":
                let image = try PDFArchiveInlineImage.read(from: &lexer)
                try add(image.dictionary["Intent"], to: &renderingIntents, location: at + "/Intent")
                guard image.lengthReliable else { gap(Self.appearanceFamilies, at + ": usi successivi al confine binario non dimostrato"); return }
            default:
                if !Self.usageOperators.contains(operation) { gap(Self.appearanceFamilies, at + ": operatore non risolto per l’applicabilità delle risorse") }
            }
            operands.removeAll(keepingCapacity: true)
        }
    }
    private func usedGraphicsState(_ value: PDFSyntaxValue?, resources: [String: PDFSyntaxValue], location: String, depth: Int, active: Set<String>) throws {
        try step(depth); let d = try dictionary(value)
        try add(d["BM"], to: &blendModes, location: location + "/BM", flatten: true)
        try add(d["RI"], to: &renderingIntents, location: location + "/RI")
        if let ht = d["HT"] { try collectHalftone(ht, colorant: nil, location: location + "/HT", active: [], depth: depth + 1) }
        if let font = try resolved(d["Font"])?.array?.first { try usedFont(font, resources: resources, location: location + "/Font", depth: depth + 1, active: active) }
        if let group = try resolved(d["SMask"])?.dictionary?["G"]?.reference {
            try usedStream(group, resources: resources, location: location + "/SMask/G", depth: depth + 1, active: active)
        }
    }
    private func usedXObject(_ value: PDFSyntaxValue, resources: [String: PDFSyntaxValue], location: String, depth: Int, active: Set<String>) throws {
        try step(depth); let d = try dictionary(value), subtype = try resolved(d["Subtype"])?.name
        if subtype == "Form", let id = value.reference { try usedStream(id, resources: resources, location: location, depth: depth + 1, active: active) }
        else if subtype == "Image" {
            let key = "Image:" + (value.reference?.syntax ?? location)
            guard !active.contains(key) else { throw PDFStructureError.unsupported("immagini/maschere circolari") }
            try add(d["Intent"], to: &renderingIntents, location: location + "/Intent")
            for name in ["SMask", "Mask"] {
                if let image = d[name], try resolved(image)?.dictionary != nil { try usedXObject(image, resources: resources, location: location + "/" + name, depth: depth + 1, active: active.union([key])) }
            }
            for (index, alternate) in try array(d["Alternates"]).enumerated() {
                if let image = try dictionary(alternate)["Image"] { try usedXObject(image, resources: resources, location: location + "/Alternates[\(index)]", depth: depth + 1, active: active.union([key])) }
            }
        } else { gap(Self.appearanceFamilies, location + ": XObject referenziato di tipo non risolto") }
    }
    private func usedStream(_ id: PDFObjectID, resources: [String: PDFSyntaxValue], location: String, depth: Int, active: Set<String>) throws {
        try step(depth)
        let object = try reader.object(id), d = try dictionary(.reference(id))
        guard object.stream != nil else { throw PDFStructureError.unsupported("stream referenziato non disponibile") }
        let own = d["Resources"] == nil ? resources : try dictionary(d["Resources"])
        let key = id.syntax + ":" + SHA256.hash(data: PDFSyntaxValue.dictionary(own).encoded).map { String(format: "%02x", $0) }.joined()
        guard !active.contains(key) else { throw PDFStructureError.unsupported("contenuti referenziati circolari") }
        guard seenUsedStreams.insert(key).inserted else { return }
        try usedContent(reader.decodedStream(id), resources: own, location: location, depth: depth + 1, active: active.union([key]))
    }
    private func usedFont(_ value: PDFSyntaxValue, resources: [String: PDFSyntaxValue], location: String, depth: Int, active: Set<String>) throws {
        try step(depth); let d = try dictionary(value)
        guard try resolved(d["Subtype"])?.name == "Type3" else { return }
        let own = d["Resources"] == nil ? resources : try dictionary(d["Resources"])
        let key = (value.reference?.syntax ?? location) + ":" + SHA256.hash(data: PDFSyntaxValue.dictionary(own).encoded).map { String(format: "%02x", $0) }.joined()
        guard seenUsedFonts.insert(key).inserted else { return }
        for (glyph, value) in try dictionary(d["CharProcs"]) {
            guard let id = value.reference else { throw PDFStructureError.unsupported("CharProc del font referenziato non è uno stream") }
            try usedStream(id, resources: own, location: location + "/CharProcs/" + glyph, depth: depth + 1, active: active)
        }
    }
    private func usedAnnotation(_ value: PDFSyntaxValue, resources: [String: PDFSyntaxValue], location: String, depth: Int) throws {
        try step(depth); let key = value.reference?.syntax ?? location
        guard seenUsedAnnotations.insert(key).inserted else { return }
        let d = try dictionary(value)
        try add(d["BM"], to: &blendModes, location: location + "/BM", flatten: true)
        for (name, value) in try dictionary(d["AP"]) {
            if let id = try reader.resolvedObjectID(value), try reader.object(id).stream != nil { try usedStream(id, resources: resources, location: location + "/AP/" + name, depth: depth + 1, active: []) }
            else {
                for (state, value) in try dictionary(value) {
                    guard let id = value.reference else { throw PDFStructureError.unsupported("appearance non referenziabile") }
                    try usedStream(id, resources: resources, location: location + "/AP/" + name + "/" + state, depth: depth + 1, active: [])
                }
            }
        }
        if let popup = d["Popup"] { try usedAnnotation(popup, resources: resources, location: location + "/Popup", depth: depth + 1) }
    }

    private func collectHalftone(_ value: PDFSyntaxValue, colorant: String?, location: String, active: Set<PDFObjectID>, depth: Int) throws {
        try step(depth); guard let actual = try resolved(value) else { return }
        if actual.name == "Default" { return }
        guard let d = actual.dictionary else { gap(["PDHalftone"], location + ": retino non risolto come dizionario"); return }
        if let id = value.reference, active.contains(id) { throw PDFStructureError.unsupported("retino circolare") }
        halftones.append(.init(dictionary: d, colorant: colorant, location: location))
        guard try resolved(d["HalftoneType"])?.int == 5 else { return }
        typeFiveCount += 1
        let nested = value.reference.map { active.union([$0]) } ?? active
        if try resolved(d["Default"]) == nil { typeFiveIssues.append(location + ": Default assente") }
        for (name, child) in d where !["Type", "HalftoneType", "HalftoneName", "TransferFunction"].contains(name) {
            guard let childDictionary = try resolved(child)?.dictionary else { gap(["PDHalftone"], location + "/" + name + ": componente non è un retino"); continue }
            if try resolved(childDictionary["HalftoneType"])?.int == 5 { typeFiveIssues.append(location + "/" + name + ": componente Type5 vietato") }
            try collectHalftone(child, colorant: name, location: location + "/" + name, active: nested, depth: depth + 1)
        }
    }
    private func halftone(_ rule: PDFArchiveCatalogueRule) throws -> PDFArchiveRuleEvaluation {
        var failures: [String] = []
        for item in halftones {
            let d = item.dictionary
            if rule.expression.hasPrefix("HalftoneType") {
                if ![1, 5].contains(try resolved(d["HalftoneType"])?.int ?? -1) { failures.append(item.location) }
            } else if rule.expression == "HalftoneName == null" {
                if try resolved(d["HalftoneName"]) != nil { failures.append(item.location) }
            } else if rule.expression.contains("TransferFunction") {
                let present = try resolved(d["TransferFunction"]) != nil
                if item.colorant == "Default" { continue }
                let primary = item.colorant == nil || ["Cyan", "Magenta", "Yellow", "Black"].contains(item.colorant!)
                if present == primary { failures.append(item.location + ": TransferFunction non ammesso/richiesto per " + (item.colorant ?? "retino globale")) }
            } else { return .unknown("Predicato retino non implementato.") }
        }
        return result(failures, count: halftones.count, family: "PDHalftone", detail: "Retini HT e componenti Type5 con colorante e contesto effettivi: " + rule.expression)
    }
    private func outputIntent(_ rule: PDFArchiveCatalogueRule) throws -> PDFArchiveRuleEvaluation {
        guard rule.expression.contains("containsDestOutputProfileRef") else { return .unknown("Predicato OutputIntent non implementato.") }
        var failures: [String] = [], count = 0
        for group in outputs {
            for item in group.values {
                count += 1; let d = try dictionary(item.value)
                if rule.expression.contains("GTS_PDFX"), try resolved(d["S"])?.name != "GTS_PDFX" { continue }
                if try resolved(d["DestOutputProfileRef"]) != nil { failures.append(item.location) }
            }
        }
        return result(failures, count: count, family: "PDOutputIntent", detail: "OutputIntent standard del catalogo e, per PDF/A-4, delle pagine.")
    }
    private func outputArrays(_ rule: PDFArchiveCatalogueRule) throws -> PDFArchiveRuleEvaluation {
        var failures: [String] = []
        for group in outputs {
            if rule.expression == "numberOfPDFAOutputIntents <= 1" {
                var count = 0
                for item in group.values { if try resolved(dictionary(item.value)["S"])?.name == "GTS_PDFA1" { count += 1 } }
                if count > 1 { failures.append(group.location + ": \(count) intent PDF/A") }
            } else if rule.expression == "sameOutputProfileIndirect == true" {
                // ISO19005-1 §6.2.2 / -2,-3,-4 §6.2.3: this conditional
                // identity/ICC requirement applies only to arrays with more
                // than one entry. A single profile's validity belongs to its
                // independent ICC predicates and ICCStructuralModel.
                guard group.values.count > 1 else { continue }
                var ids = Set<PDFObjectID>()
                for item in group.values {
                    let d = try dictionary(item.value)
                    guard try resolved(d["DestOutputProfile"]) != nil else { continue }
                    guard let id = d["DestOutputProfile"]?.reference, try reader.object(id).stream != nil else { failures.append(item.location + ": profilo non è stream indiretto"); continue }
                    ids.insert(id)
                    do {
                        let icc = try PDFArchiveICCProfile(data: reader.decodedStream(id))
                        if !icc.structuralIssues.isEmpty { failures.append(item.location + ": " + icc.structuralIssues.joined(separator: ", ")) }
                    } catch is CancellationError { throw CancellationError() }
                    catch PDFStructureError.malformed(let detail) { failures.append(item.location + ": struttura ICC non valida: " + detail) }
                    catch { gap(["OutputIntents"],item.location + ": ICC non verificato: " + error.localizedDescription) }
                }
                if ids.count > 1 { failures.append(group.location + ": profili indiretti differenti") }
            } else { return .unknown("Predicato array OutputIntents non implementato.") }
        }
        return result(failures, count: outputs.count, family: "OutputIntents", detail: "Ogni array OutputIntents valutato separatamente; identità indiretta e struttura ICC, conformità ICC completa separata.")
    }
    private func xref(_ rule: PDFArchiveCatalogueRule) throws -> PDFArchiveRuleEvaluation {
        let bytes = reader.sourceBytes
        var failures: [String] = [], count = 0, offsets = Set<Int>()
        for revision in reader.revisions where offsets.insert(revision.offset).inserted {
            try Task.checkCancellation()
            var lexer = PDFSyntaxLexer(bytes: bytes, offset: revision.offset)
            guard try lexer.word() == "xref" else { continue }
            count += 1
            if rule.expression.contains("xrefEOLMarkersComplyPDFA") {
                var position = lexer.offset
                if position < bytes.count, bytes[position] == 13 {
                    position += 1; if position < bytes.count, bytes[position] == 10 { position += 1 }
                } else if position < bytes.count, bytes[position] == 10 { position += 1 }
                else { failures.append("xref byte \(revision.offset): EOL non immediato"); continue }
                if position >= bytes.count || !(48...57).contains(bytes[position]) { failures.append("xref byte \(revision.offset): separazione diversa da un solo EOL") }
            } else if rule.expression == "subsectionHeaderSpaceSeparated == true" {
                var sections = 0
                while true {
                    try Task.checkCancellation(); sections += 1; guard sections < 1_000_000 else { throw PDFStructureError.limit }
                    let first = try lexer.word()
                    if first == "trailer" { break }
                    let endFirst = lexer.offset, second = try lexer.word(), startSecond = lexer.offset - second.utf8.count
                    guard Int(first) != nil, let entries = Int(second), entries >= 0, entries < 1_000_000 else { throw PDFStructureError.malformed("header sottosezione xref") }
                    if Array(bytes[endFirst..<startSecond]) != [32] { failures.append("sottosezione xref byte \(endFirst): separatore diverso da SPACE singolo") }
                    for _ in 0..<entries { _ = try lexer.word(); _ = try lexer.word(); _ = try lexer.word() }
                }
            } else { return .unknown("Predicato CosXRef non implementato.") }
        }
        return count == 0 ? .absent("Nessuna tabella xref classica nelle revisioni fisiche.") :
            .check(failures.isEmpty, "\(count) tabelle xref classiche, incluse revisioni precedenti/ibride.", locations: Array(failures.prefix(64)))
    }
}
