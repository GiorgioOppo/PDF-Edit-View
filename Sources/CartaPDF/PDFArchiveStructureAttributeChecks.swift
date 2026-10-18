import Foundation

/// Original typed attribute audit, based on ISO32000-1 §§14.7.5/14.8.5.
/// It validates represented values, not visual layout or the human meaning of
/// a table header. Format-specific and namespace-specific schemas stay unknown.
final class PDFArchiveStructureAttributeChecks {
    struct Element { let value: [String: PDFSyntaxValue]; let location: String }
    struct Result { var issues: [String] = []; var gaps: [String] = [] }
    private struct Attribute { let value: [String: PDFSyntaxValue]; let revision: Int; let location: String }
    private let reader: PDFStructureDocument, profile: PDFArchiveProfile
    private var result = Result(), work = 0, userPropertiesApplied = false
    private var root: [String: PDFSyntaxValue] = [:], elements: [Element] = [], identifiers: [Data: Element] = [:]
    init(reader: PDFStructureDocument, profile: PDFArchiveProfile) { self.reader = reader; self.profile = profile }
    func audit(root: [String: PDFSyntaxValue], elements: [Element]) -> Result {
        self.root = root; self.elements = elements
        do {
            for element in elements {
                if let id = try resolve(element.value["ID"])?.data { identifiers[id] = element }
            }
            let classes = try dictionary(root["ClassMap"])
            for (name, value) in classes {
                for attribute in try attributes(value, revisionPairs: false, location: "ClassMap/" + name) {
                    try values(attribute)
                }
            }
            for element in elements {
                try tick()
                var attached: [Attribute] = []
                if let c = try resolve(element.value["C"]) {
                    let list = c.array ?? [c]; var index = 0
                    while index < list.count {
                        try tick(); let name = try resolve(list[index])?.name; index += 1
                        var revision = 0
                        if index < list.count, let r = try resolve(list[index])?.int { revision = r; index += 1 }
                        if let name, let value = classes[name] {
                            attached += try attributes(value, revisionPairs: false, location: element.location + "/C/" + name)
                                .map { Attribute(value: $0.value, revision: revision, location: $0.location) }
                        }
                    }
                }
                attached += try attributes(element.value["A"], revisionPairs: true, location: element.location + "/A")
                var table: [String: (PDFSyntaxValue, Bool)] = [:]
                let revision = try resolve(element.value["R"])?.int ?? 0
                for attribute in attached {
                    try values(attribute)
                    let owner = try resolve(attribute.value["O"])?.name
                    if owner == "UserProperties", profile.part != 1,
                       try resolve(attribute.value["P"])?.array?.isEmpty == false { userPropertiesApplied = true }
                    if owner == "Table" {
                        for (key, value) in attribute.value where key != "O" {
                            if try resolve(value) != nil { table[key] = (value, attribute.revision == revision) }
                        }
                    }
                }
                try tableRelationships(table, element: element)
            }
            if userPropertiesApplied {
                let catalog = try dictionary(.reference(reader.rootID)), mark = try dictionary(catalog["MarkInfo"])
                if try resolve(mark["UserProperties"])?.bool != true {
                    result.issues.append("MarkInfo/UserProperties deve essere true quando sono applicate proprietà utente")
                }
            }
        } catch is CancellationError { result.gaps.append("Audit attributi strutturali annullato") }
        catch { result.gaps.append("Audit attributi strutturali incompleto: " + error.localizedDescription) }
        return result
    }
    private func tick() throws {
        try Task.checkCancellation(); work += 1
        guard work <= 500_000 else { throw PDFStructureError.limit }
    }
    private func resolve(_ value: PDFSyntaxValue?) throws -> PDFSyntaxValue? {
        try tick(); return try PDFArchiveStructureReferences.resolve(value, reader: reader).value
    }
    private func dictionary(_ value: PDFSyntaxValue?) throws -> [String: PDFSyntaxValue] {
        guard let value = try resolve(value) else { return [:] }
        guard let dictionary = value.dictionary else { throw PDFStructureError.malformed("dizionario attributi strutturali") }
        return dictionary
    }
    private func attributes(_ raw: PDFSyntaxValue?, revisionPairs: Bool, location: String) throws -> [Attribute] {
        guard let value = try resolve(raw) else { return [] }
        if let d = value.dictionary { return [.init(value: d, revision: 0, location: location)] }
        guard let array = value.array else { return [] } // Grammar is checked by the mechanical model.
        var output: [Attribute] = [], index = 0
        while index < array.count {
            let value = try resolve(array[index]); index += 1
            var revision = 0
            if revisionPairs, index < array.count, let r = try resolve(array[index])?.int { revision = r; index += 1 }
            if let d = value?.dictionary { output.append(.init(value: d, revision: revision, location: location)) }
        }
        return output
    }
    private enum Shape {
        case number, nonnegative, integer, name, text, boolean, names(Set<String>), numberOrNames(Set<String>)
        case rgb, borderColor, borderStyle, edgeNumbers(allowNull: Bool, nonnegative: Bool), numericArray, rectangle, headers, glyph
    }
    private func decimal(_ value: PDFSyntaxValue) -> (negative: Bool, whole: String, fraction: String)? {
        guard case .number(let token) = value, PDFSyntaxLexer.numberToken(token) else { return nil }
        let unsigned = token.drop(while: { $0 == "+" || $0 == "-" })
        let parts = unsigned.split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(parts[0].drop(while: { $0 == "0" }))
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        let nonzero = !whole.isEmpty || fraction.contains(where: { $0 != "0" })
        return (token.hasPrefix("-") && nonzero, whole.isEmpty ? "0" : whole, fraction)
    }
    private func valid(_ value: PDFSyntaxValue, _ shape: Shape) throws -> Bool {
        let value = try resolve(value)
        guard let value else { return false }
        switch shape {
        case .number: return decimal(value) != nil
        case .nonnegative: return decimal(value).map { !$0.negative } == true
        case .integer:
            guard case .number(let token) = value else { return false }
            return PDFSyntaxLexer.numberToken(token) && !token.contains(".")
        case .name: return value.name != nil
        case .text: return value.data != nil
        case .boolean: return value.bool != nil
        case .names(let names): return value.name.map { names.contains($0) } == true
        case .numberOrNames(let names): return decimal(value) != nil || value.name.map { names.contains($0) } == true
        case .rgb:
            guard let a = value.array, a.count == 3 else { return false }
            for item in a {
                guard let actual = try resolve(item), let n = decimal(actual), !n.negative,
                      n.whole == "0" || n.whole == "1" && n.fraction.allSatisfy({ $0 == "0" }) else { return false }
            }
            return true
        case .borderColor:
            if try valid(value, .rgb) { return true }
            guard let a = value.array, a.count == 4 else { return false }
            for item in a {
                if let actual = try resolve(item), try !valid(actual, .rgb) { return false }
            }
            return true
        case .borderStyle:
            let names: Set<String> = ["None", "Hidden", "Dotted", "Dashed", "Solid", "Double", "Groove", "Ridge", "Inset", "Outset"]
            if let name = value.name { return names.contains(name) }
            guard let a = value.array, a.count == 4 else { return false }
            for item in a { if let v = try resolve(item), v.name.map({ names.contains($0) }) != true { return false } }
            return true
        case .edgeNumbers(let allowNull, let nonnegative):
            let shape: Shape = nonnegative ? .nonnegative : .number
            if decimal(value) != nil { return try valid(value, shape) }
            guard let a = value.array, a.count == 4 else { return false }
            for item in a {
                if try resolve(item) == nil { if !allowNull { return false } }
                else if try !valid(item, shape) { return false }
            }
            return true
        case .numericArray:
            if decimal(value) != nil { return try valid(value, .number) }
            guard let a = value.array else { return false }
            for item in a { if try !valid(item, .number) { return false } }; return true
        case .rectangle:
            guard let a = value.array, a.count == 4 else { return false }
            for item in a { if try !valid(item, .number) { return false } }; return true
        case .headers:
            guard let a = value.array else { return false }
            for item in a { if try resolve(item)?.data == nil { return false } }; return true
        case .glyph:
            if value.name == "Auto" { return true }
            guard let number = decimal(value), number.fraction.allSatisfy({ $0 == "0" }),
                  let magnitude = Int(number.whole) else { return false }
            let n = number.negative ? -magnitude : magnitude
            guard n >= -180, n <= 360, n % 90 == 0 else { return false }
            return profile.part != 4 || value.int != nil
        }
    }
    private func values(_ attribute: Attribute) throws {
        guard let owner = try resolve(attribute.value["O"])?.name else { return }
        var schema: [String: Shape] = [:]
        switch owner {
        case "Layout":
            schema = ["Placement": .names(["Block","Inline","Before","Start","End"]),
                "WritingMode": .names(profile.part == 4 ? ["LrTb","RlTb","TbRl","TbLr","LrBt","RlBt","BtRl","BtLr"] : ["LrTb","RlTb","TbRl"]),
                "SpaceBefore": .number, "SpaceAfter": .number, "StartIndent": .number, "EndIndent": .number, "TextIndent": .number,
                "TextAlign": .names(["Start","Center","End","Justify"]), "BBox": .rectangle,
                "Width": .numberOrNames(["Auto"]), "Height": .numberOrNames(["Auto"]),
                "BlockAlign": .names(["Before","Middle","After","Justify"]), "InlineAlign": .names(["Start","Center","End"]),
                "LineHeight": .numberOrNames(["Normal","Auto"]), "BaselineShift": .number,
                "TextDecorationType": .names(["None","Underline","Overline","LineThrough"])]
            if profile.part != 1 {
                schema.merge(["BackgroundColor": .rgb, "Color": .rgb, "BorderColor": .borderColor, "BorderStyle": .borderStyle,
                    "BorderThickness": .edgeNumbers(allowNull: true, nonnegative: true), "Padding": .edgeNumbers(allowNull: false, nonnegative: false),
                    "TBorderStyle": .borderStyle, "TPadding": .edgeNumbers(allowNull: false, nonnegative: false),
                    "TextDecorationColor": .rgb, "TextDecorationThickness": .nonnegative,
                    "RubyAlign": .names(["Start","Center","End","Justify","Distribute"]), "RubyPosition": .names(["Before","After","Warichu","Inline"]),
                    "GlyphOrientationVertical": .glyph, "ColumnCount": .integer, "ColumnGap": .numericArray, "ColumnWidths": .numericArray]) { _, new in new }
            }
            if profile.part == 4 {
                schema["TextPosition"] = .names(["Sup","Sub","Normal"])
                schema["ColumnCount"] = .number
            }
        case "List":
            // Table347 explicitly requires readers to accept future numbering
            // names using the None fallback. A closed-name ban would be false.
            schema = ["ListNumbering": .name]
            if profile.part == 4 { schema["ContinuedList"] = .boolean; schema["ContinuedFrom"] = .text }
        case "Table":
            schema = ["RowSpan": .integer, "ColSpan": .integer]
            if profile.part != 1 { schema.merge(["Headers": .headers, "Scope": .names(["Row","Column","Both"]), "Summary": .text]) { _, new in new } }
            if profile.part == 4 { schema["Short"] = .text }
        case "PrintField" where profile.part != 1:
            schema = ["Role": .names(profile.part == 4 ? ["rb","cb","pb","tv","lb"] : ["rb","cb","pb","tv"]),
                "checked": .names(["on","off","neutral"]), "Desc": .text]
            if profile.part == 4 { schema["Checked"] = .names(["on","off","neutral"]) }
        case "UserProperties" where profile.part != 1:
            try userProperties(attribute); return
        default:
            for (key, value) in attribute.value where key != "O" && key != "NS" {
                if try resolve(value) != nil {
                    result.gaps.append(attribute.location + ": schema proprietario " + owner + " non modellato"); break
                }
            }
            return
        }
        for (key, raw) in attribute.value where key != "O" {
            do {
                guard try resolve(raw) != nil else { continue }
                guard let shape = schema[key] else { result.gaps.append(attribute.location + "/" + key + ": schema/versione attributo non modellato"); continue }
                if try !valid(raw, shape) { result.issues.append(attribute.location + "/" + key + ": valore non conforme al tipo/intervallo dell’owner " + owner) }
            } catch PDFStructureError.unsupported(let detail) {
                result.gaps.append(attribute.location + "/" + key + ": " + detail)
            }
        }
    }
    private func userProperties(_ attribute: Attribute) throws {
        guard let values = try resolve(attribute.value["P"])?.array else {
            result.issues.append(attribute.location + ": UserProperties/P array richiesto"); return
        }
        for value in values {
            guard let p = try resolve(value)?.dictionary else { result.issues.append(attribute.location + "/P: proprietà non dizionario"); continue }
            if try resolve(p["N"])?.data == nil { result.issues.append(attribute.location + "/P/N: text string richiesto") }
            if p["V"] == nil { result.issues.append(attribute.location + "/P/V: valore richiesto") }
            else if try resolve(p["V"]) == nil { result.gaps.append(attribute.location + "/P/V: valore null richiesto non attestato") }
            if let f = try resolve(p["F"]), f.data == nil { result.issues.append(attribute.location + "/P/F non text string") }
            if let h = try resolve(p["H"]), h.bool == nil { result.issues.append(attribute.location + "/P/H non boolean") }
            // V may be any PDF type. The recommendation for simple displayable
            // types is not a prohibition on dictionaries or arrays.
        }
    }
    private func role(_ element: Element) throws -> String? {
        guard var name = try resolve(element.value["S"])?.name else { return nil }
        if profile.part == 4, try resolve(element.value["NS"]) != nil {
            let ns = try dictionary(element.value["NS"]), uri = try resolve(ns["NS"])?.text
            guard uri == "http://iso.org/pdf/ssn" || uri == "http://iso.org/pdf2/ssn" else { return nil }
            // Explicit custom RoleMapNS contexts need their complete schema;
            // never infer TH merely from a custom namespace's spelling.
            if try resolve(ns["RoleMapNS"]) != nil { return nil }
            return name
        }
        let map = try dictionary(root["RoleMap"]); var seen = Set<String>()
        while let target = try resolve(map[name]) {
            guard seen.insert(name).inserted, seen.count <= 100 else { return nil }
            guard let next = target.name else { return nil }; name = next
        }
        return name
    }
    private func tableRelationships(_ attributes: [String: (PDFSyntaxValue, Bool)], element: Element) throws {
        let keys = profile.part == 1 ? ["RowSpan","ColSpan"] : ["RowSpan","ColSpan","Headers","Scope","Summary","Short"]
        for key in keys {
            guard let (value, current) = attributes[key] else { continue }
            guard current else { result.gaps.append(element.location + "/" + key + ": revisione attributo non corrente"); continue }
            guard let tag = try role(element) else { result.gaps.append(element.location + "/" + key + ": namespace/RoleMap non risolto per il contesto"); continue }
            let allowed: Set<String> = key == "Summary" ? ["Table"] : key == "Scope" || key == "Short" ? ["TH"] : ["TH","TD"]
            guard allowed.contains(tag) else {
                // PDF2 table entries have no effect on unrelated elements;
                // the older schema explicitly restricts where they are used.
                if profile.part != 4 { result.issues.append(element.location + "/" + key + ": attributo Table non ammesso sul tipo " + tag) }
                continue
            }
            if key == "Headers", let headers = try resolve(value)?.array {
                for header in headers {
                    guard let id = try resolve(header)?.data else { continue }
                    guard let target = identifiers[id] else { result.issues.append(element.location + "/Headers: ID non presente nella gerarchia"); continue }
                    if let targetRole = try role(target) {
                        if targetRole != "TH" { result.issues.append(element.location + "/Headers: ID riferisce un elemento diverso da TH") }
                    } else { result.gaps.append(element.location + "/Headers: ruolo namespace del target non provato") }
                }
            }
        }
    }
}
