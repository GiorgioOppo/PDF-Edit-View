import Foundation

// Metadata-only evaluator. The model and tables are implemented locally from the
// published Adobe XMP specifications (Jan 2004, Sep 2005, Part 1 Apr 2012),
// W3C RDF/XML and the pinned veraPDF profile data. No toolkit code is imported.
private enum ArchiveMetadataNS {
    static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let xml = "http://www.w3.org/XML/1998/namespace"
    static let id = "http://www.aiim.org/pdfa/ns/id/"
    static let ext = "http://www.aiim.org/pdfa/ns/extension/"
    static let schema = "http://www.aiim.org/pdfa/ns/schema#"
    static let property = "http://www.aiim.org/pdfa/ns/property#"
    static let type = "http://www.aiim.org/pdfa/ns/type#"
    static let field = "http://www.aiim.org/pdfa/ns/field#"
    static let dc = "http://purl.org/dc/elements/1.1/"
    static let xmp = "http://ns.adobe.com/xap/1.0/"
    static let pdf = "http://ns.adobe.com/pdf/1.3/"
}

private struct ArchiveMetadataName: Hashable {
    let uri: String
    let local: String
    let prefix: String
    // RDF identity is the expanded name, not a preferred spelling of its prefix.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.uri == rhs.uri && lhs.local == rhs.local }
    func hash(into hasher: inout Hasher) { hasher.combine(uri); hasher.combine(local) }
    var expanded: String { "{\(uri)}\(local)" }
}

private enum ArchiveMetadataIssue: Error, LocalizedError {
    case invalid(String), unresolved(String)
    var errorDescription: String? { switch self { case .invalid(let s), .unresolved(let s): return s } }
}

private final class ArchiveMetadataXMLNode {
    let name: ArchiveMetadataName
    var attributes: [ArchiveMetadataName: String]
    var baseURI: String?
    var children: [ArchiveMetadataXMLNode] = []
    var text = ""
    init(name: ArchiveMetadataName, attributes: [ArchiveMetadataName: String]) { self.name = name; self.attributes = attributes }
    func attribute(_ uri: String, _ local: String) -> String? { attributes[.init(uri: uri, local: local, prefix: "")] }
}

private final class ArchiveMetadataXML: NSObject, XMLParserDelegate {
    private(set) var root: ArchiveMetadataXMLNode?
    private(set) var instructions: [(String, String)] = []
    private(set) var instructionPhases: [Int] = [] // 0 before root, 1 inside, 2 after root
    private var stack: [ArchiveMetadataXMLNode] = []
    private var mappings: [String: [String]] = ["xml": [ArchiveMetadataNS.xml]]
    private var nodes = 0
    private var issue: Error?
    let actualEncoding: String
    init(data: Data) throws {
        guard data.count <= 8 * 1024 * 1024 else { throw ArchiveMetadataIssue.unresolved("Pacchetto XMP oltre il limite di 8 MiB.") }
        let encoding: String.Encoding
        if data.starts(with: [0, 0, 0xFE, 0xFF]) || data.starts(with: [0, 0, 0, 0x3C]) { encoding = .utf32BigEndian; actualEncoding = "UTF-32BE" }
        else if data.starts(with: [0xFF, 0xFE, 0, 0]) || data.starts(with: [0x3C, 0, 0, 0]) { encoding = .utf32LittleEndian; actualEncoding = "UTF-32LE" }
        else if data.starts(with: [0xFE, 0xFF]) || data.starts(with: [0, 0x3C, 0, 0x3F]) { encoding = .utf16BigEndian; actualEncoding = "UTF-16BE" }
        else if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0x3C, 0, 0x3F, 0]) { encoding = .utf16LittleEndian; actualEncoding = "UTF-16LE" }
        else { encoding = .utf8; actualEncoding = "UTF-8" }
        guard let source = String(data: data, encoding: encoding) else { throw ArchiveMetadataIssue.invalid("La codifica effettiva non è una codifica Unicode XMP valida.") }
        if let declaration = source.range(of: "^\u{FEFF}?<\\?xml[^?]*encoding\\s*=\\s*['\"]([^'\"]+)['\"]", options: .regularExpression) {
            let header = String(source[declaration])
            if let regex = try? NSRegularExpression(pattern: "encoding\\s*=\\s*['\"]([^'\"]+)['\"]"),
               let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) {
                let declared = (header as NSString).substring(with: match.range(at: 1)).uppercased()
                guard ["UTF-8", "UTF8", "UTF-16", "UTF-16LE", "UTF-16BE", "UTF-32", "UTF-32LE", "UTF-32BE"].contains(declared) else {
                    throw ArchiveMetadataIssue.invalid("Dichiarazione XML con codifica non Unicode: " + declared)
                }
            }
        }
        let localSource = try ArchiveMetadataDTD.prepare(source)
        super.init()
        // Foundation does not consistently emit the literal prefix of internal
        // entities through foundCharacters when external resolution is disabled.
        // Expand only the bounded, plain-text subset proven safe by prepare().
        let parser = XMLParser(data: localSource == source ? data : (localSource.data(using: encoding) ?? data))
        parser.shouldProcessNamespaces = true; parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false; parser.delegate = self
        guard parser.parse() else { throw issue ?? ArchiveMetadataIssue.invalid("XML non ben formato: " + (parser.parserError?.localizedDescription ?? "errore")) }
        guard root != nil else { throw ArchiveMetadataIssue.invalid("Pacchetto XMP vuoto.") }
    }
    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI uri: String) { mappings[prefix, default: []].append(uri) }
    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) { _ = mappings[prefix]?.popLast() }
    func parser(_ parser: XMLParser, didStartElement local: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        nodes += 1
        if Task.isCancelled || nodes > 100_000 || stack.count >= 128 {
            issue = Task.isCancelled ? CancellationError() : ArchiveMetadataIssue.unresolved("Limite di nodi/profondità XML raggiunto."); parser.abortParsing(); return
        }
        func name(_ qualified: String) -> ArchiveMetadataName {
            let pieces = qualified.split(separator: ":", maxSplits: 1).map(String.init)
            return .init(uri: pieces.count == 2 ? (mappings[pieces[0]]?.last ?? "") : "", local: pieces.last ?? qualified, prefix: pieces.count == 2 ? pieces[0] : "")
        }
        let prefix = qualifiedName?.split(separator: ":", maxSplits: 1).dropLast().first.map(String.init) ?? ""
        var expanded: [ArchiveMetadataName: String] = [:]
        for (key, value) in attributes where key != "xmlns" && !key.hasPrefix("xmlns:") {
            let key = name(key)
            if expanded.updateValue(value, forKey: key) != nil { issue = ArchiveMetadataIssue.invalid("Attributo XML duplicato per nome espanso."); parser.abortParsing(); return }
        }
        let node = ArchiveMetadataXMLNode(name: .init(uri: namespaceURI ?? "", local: local, prefix: prefix), attributes: expanded)
        if let parent = stack.last { parent.children.append(node) } else if root == nil { root = node }
        else { issue = ArchiveMetadataIssue.invalid("Più elementi XML radice."); parser.abortParsing(); return }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { stack.last?.text += String(decoding: data, as: UTF8.self) }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        instructions.append((target, data ?? "")); instructionPhases.append(stack.isEmpty ? (root == nil ? 0 : 2) : 1)
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
    func parser(_ parser: XMLParser, foundSkippedEntityName name: String) {
        issue = ArchiveMetadataIssue.unresolved("Entità XML non risolta localmente: " + name); parser.abortParsing()
    }
}

private enum ArchiveMetadataDTD {
    // XML 1.0 §§2.8, 4.2 and 4.4. General internal entities containing plain
    // text are enough for a useful local subset. Parameter entities, external
    // identifiers, default attributes and markup-valued replacements stay
    // unresolved. No DTD is obtained from a URL or file system.
    static func prepare(_ source: String) throws -> String {
        let bytes = Array(source.utf8)
        var index = 0, declarations: [Range<Int>] = [], entities: [String: String] = [:]
        func starts(_ token: String, at offset: Int) -> Bool {
            let token = Array(token.utf8)
            return offset + token.count <= bytes.count && bytes[offset..<(offset + token.count)].elementsEqual(token)
        }
        func ending(_ token: String, from offset: Int) -> Int? {
            var cursor = offset
            while cursor < bytes.count {
                if starts(token, at: cursor) { return cursor + token.utf8.count }
                cursor += 1
            }
            return nil
        }
        while index < bytes.count {
            if starts("<!--", at: index) { index = ending("-->", from: index + 4) ?? bytes.count; continue }
            if starts("<![CDATA[", at: index) { index = ending("]]>", from: index + 9) ?? bytes.count; continue }
            if starts("<?", at: index) { index = ending("?>", from: index + 2) ?? bytes.count; continue }
            guard starts("<!DOCTYPE", at: index) else { index += 1; continue }
            let start = index
            var quote: UInt8?, brackets = 0
            index += 9
            while index < bytes.count {
                let byte = bytes[index]
                if let active = quote { if byte == active { quote = nil } }
                else if byte == 34 || byte == 39 { quote = byte }
                else if starts("<!--", at: index) { index = ending("-->", from: index + 4) ?? bytes.count; continue }
                else if byte == 91 { brackets += 1 }
                else if byte == 93 { brackets -= 1 }
                else if byte == 62 && brackets == 0 { index += 1; break }
                index += 1
            }
            guard index <= bytes.count, quote == nil, brackets == 0, index > start, bytes[index - 1] == 62 else {
                throw ArchiveMetadataIssue.invalid("Dichiarazione DOCTYPE XML non terminata.")
            }
            declarations.append(start..<index)
            guard declarations.count == 1 else { throw ArchiveMetadataIssue.invalid("Più dichiarazioni DOCTYPE XML.") }
            let declaration = String(decoding: bytes[start..<index], as: UTF8.self)
            let pattern = "^<!DOCTYPE[ \\t\\r\\n]+[A-Za-z_:][A-Za-z0-9_.:-]*[ \\t\\r\\n]*(?:\\[([\\s\\S]*)\\][ \\t\\r\\n]*)?>$"
            let regex = try NSRegularExpression(pattern: pattern)
            guard let match = regex.firstMatch(in: declaration, range: NSRange(declaration.startIndex..., in: declaration)) else {
                throw ArchiveMetadataIssue.unresolved("DOCTYPE esterna o sintassi DTD non modellata: nessuna risorsa esterna viene letta.")
            }
            let ns = declaration as NSString
            let body = match.range(at: 1).location == NSNotFound ? "" : ns.substring(with: match.range(at: 1))
            let entity = try NSRegularExpression(pattern: #"<!ENTITY[ \t\r\n]+([A-Za-z_:][A-Za-z0-9_.:-]*)[ \t\r\n]+(['"])(.*?)\2[ \t\r\n]*>"#, options: .dotMatchesLineSeparators)
            var cursor = body.startIndex
            while cursor < body.endIndex {
                if body[cursor].isWhitespace { cursor = body.index(after: cursor); continue }
                if body[cursor...].hasPrefix("<!--"), let end = body.range(of: "-->", range: body.index(cursor, offsetBy: 4)..<body.endIndex) {
                    cursor = end.upperBound; continue
                }
                guard let found = entity.firstMatch(in: body, range: NSRange(cursor..<body.endIndex, in: body)),
                      found.range.location == NSRange(cursor..<cursor, in: body).location,
                      let whole = Range(found.range, in: body) else {
                    throw ArchiveMetadataIssue.unresolved("Sottoinsieme DTD non modellato: entità parametriche/esterne o dichiarazioni aggiuntive.")
                }
                let text = body as NSString, name = text.substring(with: found.range(at: 1)), value = text.substring(with: found.range(at: 3))
                guard entities.count < 64, value.utf8.count <= 4096,
                      !value.contains(where: { "<&%'\"\r\n\t".contains($0) }),
                      !["amp", "lt", "gt", "apos", "quot"].contains(name) else {
                    throw ArchiveMetadataIssue.unresolved("Entità interna oltre il sottoinsieme testuale limitato; espansione non eseguita.")
                }
                // XML 1.0 §4.2: the first declaration is binding.
                if entities[name] == nil { entities[name] = value }
                cursor = whole.upperBound
            }
        }
        guard !entities.isEmpty else { return source }
        var result = [UInt8](), quote: UInt8?, inTag = false
        index = 0
        result.reserveCapacity(bytes.count)
        while index < bytes.count {
            let skipped: Int?
            if let declaration = declarations.first(where: { $0.lowerBound == index }) { skipped = declaration.upperBound }
            else if starts("<!--", at: index) { skipped = ending("-->", from: index + 4) }
            else if starts("<![CDATA[", at: index) { skipped = ending("]]>", from: index + 9) }
            else if starts("<?", at: index) { skipped = ending("?>", from: index + 2) }
            else { skipped = nil }
            if let end = skipped {
                guard result.count + end - index <= 8 * 1024 * 1024 else { throw ArchiveMetadataIssue.unresolved("Espansione delle entità XML oltre il limite di 8 MiB.") }
                result += bytes[index..<end]; index = end; continue
            }
            let byte = bytes[index]
            if byte == 38, (!inTag || quote != nil), let end = bytes[index..<min(bytes.count, index + 257)].firstIndex(of: 59),
               let value = entities[String(decoding: bytes[(index + 1)..<end], as: UTF8.self)] {
                guard result.count + value.utf8.count <= 8 * 1024 * 1024 else { throw ArchiveMetadataIssue.unresolved("Espansione delle entità XML oltre il limite di 8 MiB.") }
                result += value.utf8; index = end + 1; continue
            }
            if inTag {
                if let active = quote { if byte == active { quote = nil } }
                else if byte == 34 || byte == 39 { quote = byte }
                else if byte == 62 { inTag = false }
            } else if byte == 60 { inTag = true }
            result.append(byte); index += 1
            guard result.count <= 8 * 1024 * 1024 else { throw ArchiveMetadataIssue.unresolved("Espansione delle entità XML oltre il limite di 8 MiB.") }
        }
        return String(decoding: result, as: UTF8.self)
    }
}

private final class ArchiveMetadataValue {
    enum Kind { case text, uri, array(String), structure }
    let kind: Kind
    var text: String
    var language: String?
    var fields: [ArchiveMetadataProperty]
    var items: [ArchiveMetadataValue]
    var qualifiers: [ArchiveMetadataProperty]
    var baseURI: String?
    init(_ kind: Kind, text: String = "", language: String? = nil, fields: [ArchiveMetadataProperty] = [], items: [ArchiveMetadataValue] = [], qualifiers: [ArchiveMetadataProperty] = [], baseURI: String? = nil) {
        self.kind = kind; self.text = text; self.language = language; self.fields = fields; self.items = items; self.qualifiers = qualifiers; self.baseURI = baseURI
    }
    var scalar: String? { switch kind { case .text, .uri: return text; default: return nil } }
}
private struct ArchiveMetadataProperty {
    let name: ArchiveMetadataName
    let value: ArchiveMetadataValue
    let location: String
}

private final class ArchiveMetadataGraph {
    let xml: ArchiveMetadataXML
    let properties: [ArchiveMetadataProperty]
    let location: String
    init(data: Data, location: String, profile: PDFArchiveProfile) throws {
        xml = try ArchiveMetadataXML(data: data); self.location = location
        guard let root = xml.root else { throw ArchiveMetadataIssue.invalid("XML senza radice.") }
        // RDF/XML §6.1.2 computes the base URI before removing reserved XML
        // attributes from the grammar's attribute set. The source PDF's path
        // is deliberately never used as an implicit document/base URI.
        func context(_ node: ArchiveMetadataXMLNode, inherited: String?) throws {
            if let raw = node.attribute(ArchiveMetadataNS.xml, "base") {
                guard raw.utf8.count <= 65_536 else { throw ArchiveMetadataIssue.unresolved("xml:base oltre il limite locale di 64 KiB.") }
                let reference = ArchiveMetadataURI.xmlBaseReference(raw)
                guard ArchiveMetadataLexical.uri(reference) else { throw ArchiveMetadataIssue.unresolved("xml:base non è un URI-reference valido; comportamento XML Base dipendente dall’applicazione.") }
                guard let resolved = ArchiveMetadataURI.resolve(reference, against: inherited) else { throw ArchiveMetadataIssue.unresolved("xml:base relativo senza base assoluta esplicita: nessun percorso locale viene presunto.") }
                node.baseURI = resolved
                node.attributes.removeValue(forKey: .init(uri: ArchiveMetadataNS.xml, local: "base", prefix: "xml"))
            } else { node.baseURI = inherited }
            for child in node.children { try context(child, inherited: node.baseURI) }
        }
        try context(root, inherited: nil)
        var rdf = root
        if root.name.uri == "adobe:ns:meta/", ["xmpmeta", "xapmeta"].contains(root.name.local) {
            guard root.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, root.children.count == 1 else { throw ArchiveMetadataIssue.invalid("xmpmeta deve contenere un solo elemento RDF.") }
            rdf = root.children[0]
        }
        guard rdf.name.uri == ArchiveMetadataNS.rdf, rdf.name.local == "RDF", rdf.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ArchiveMetadataIssue.invalid("La radice XMP deve essere rdf:RDF, eventualmente in xmpmeta.") }
        guard rdf.attributes.isEmpty else { throw ArchiveMetadataIssue.invalid("Attributi non ammessi su rdf:RDF.") }
        var result: [ArchiveMetadataProperty] = [], abouts = Set<String>()
        for node in rdf.children {
            guard node.name.uri == ArchiveMetadataNS.rdf, node.name.local == "Description" else { throw ArchiveMetadataIssue.invalid("Nodo RDF tipizzato al livello principale: non è XMP.") }
            if node.attribute(ArchiveMetadataNS.rdf, "nodeID") != nil {
                if profile.part == 4 { throw ArchiveMetadataIssue.invalid("rdf:nodeID non è ammesso nel modello XMP ISO.") }
                if profile.part == 1 { throw ArchiveMetadataIssue.unresolved("rdf:nodeID non definito dall’edizione Adobe 2004 consultata.") }
            }
            if node.attribute(ArchiveMetadataNS.rdf, "ID") != nil, profile.part == 4 { throw ArchiveMetadataIssue.invalid("rdf:ID non è ammesso da ISO 16684-1.") }
            guard node.attribute(ArchiveMetadataNS.xml, "lang") == nil else { throw ArchiveMetadataIssue.invalid("xml:lang non è ammesso su rdf:Description.") }
            // Adobe/ISO processors treat omitted rdf:about as the empty URI.
            let about = node.attribute(ArchiveMetadataNS.rdf, "about") ?? ""
            if !ArchiveMetadataLexical.uri(about) { throw ArchiveMetadataIssue.invalid("rdf:about non è un URI-reference valido.") }
            abouts.insert(ArchiveMetadataURI.resolve(about, against: node.baseURI) ?? about)
            result += try Self.fields(node, location: location, topLevel: true, profile: profile)
        }
        // January 2004 does not impose the matching-about constraint introduced
        // by Adobe in September 2005, page 23. Do not apply later syntax to PDF/A-1.
        if profile.part > 1, abouts.count > 1 { throw ArchiveMetadataIssue.invalid("rdf:Description descrivono risorse diverse (rdf:about discordanti).") }
        try Self.unique(result)
        properties = result
    }
    func values(_ uri: String, _ local: String) -> [ArchiveMetadataProperty] { properties.filter { $0.name.uri == uri && $0.name.local == local } }
    private static func unique(_ properties: [ArchiveMetadataProperty]) throws {
        guard Set(properties.map(\.name)).count == properties.count else { throw ArchiveMetadataIssue.invalid("Proprietà/campo XMP duplicato per namespace e nome.") }
    }
    private static func fields(_ node: ArchiveMetadataXMLNode, location: String, topLevel: Bool = false, profile: PDFArchiveProfile) throws -> [ArchiveMetadataProperty] {
        guard node.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ArchiveMetadataIssue.invalid("Testo misto in una struttura RDF.") }
        var fields: [ArchiveMetadataProperty] = []
        for (name, text) in node.attributes {
            if name.uri == ArchiveMetadataNS.xml {
                if name.local == "lang" && node.attribute(ArchiveMetadataNS.rdf, "parseType") == "Resource" { continue }
                throw ArchiveMetadataIssue.unresolved("Attributo XML contestuale \(name.local) non risolto.")
            }
            if name.uri == ArchiveMetadataNS.rdf {
                if ["about", "ID", "bagID", "nodeID"].contains(name.local) {
                    if name.local == "nodeID" && profile.part == 1 { throw ArchiveMetadataIssue.unresolved("rdf:nodeID non definito dall’edizione Adobe 2004 consultata.") }
                    if !topLevel && name.local == "about" { throw ArchiveMetadataIssue.invalid("rdf:about su struttura interna XMP.") }
                    if profile.part == 4 && name.local != "about" { throw ArchiveMetadataIssue.invalid("Attributo RDF storico non ammesso da ISO 16684-1.") }
                    continue
                }
                if name.local == "parseType", text == "Resource" { continue }
                if name.local != "value" || topLevel { throw ArchiveMetadataIssue.invalid("Attributo RDF non ammesso nella struttura: \(name.local).") }
            }
            guard !name.uri.isEmpty else { throw ArchiveMetadataIssue.invalid("Campo/attributo XMP privo di namespace.") }
            fields.append(.init(name: name, value: .init(.text, text: text, baseURI: node.baseURI), location: location + "/" + name.local))
        }
        for (index, child) in node.children.enumerated() {
            guard !child.name.uri.isEmpty else { throw ArchiveMetadataIssue.invalid("Proprietà XMP senza namespace.") }
            if child.name.uri == ArchiveMetadataNS.rdf && (child.name.local != "value" || topLevel) { throw ArchiveMetadataIssue.invalid("Termine RDF usato come proprietà: \(child.name.local).") }
            if child.name.uri == ArchiveMetadataNS.rdf && child.name.local == "value", index != 0 { throw ArchiveMetadataIssue.invalid("rdf:value deve precedere gli altri elementi qualificatori.") }
            fields.append(.init(name: child.name, value: try value(child, location: location + "/" + child.name.local, profile: profile), location: location + "/" + child.name.local))
        }
        try unique(fields)
        return fields
    }
    private static func value(_ node: ArchiveMetadataXMLNode, location: String, profile: PDFArchiveProfile) throws -> ArchiveMetadataValue {
        let result = try valueBody(node, location: location, profile: profile)
        if result.baseURI == nil { result.baseURI = node.baseURI }
        return result
    }
    private static func valueBody(_ node: ArchiveMetadataXMLNode, location: String, profile: PDFArchiveProfile) throws -> ArchiveMetadataValue {
        let rdf = ArchiveMetadataNS.rdf, xml = ArchiveMetadataNS.xml
        if node.attribute(rdf, "nodeID") != nil {
            if profile.part == 4 { throw ArchiveMetadataIssue.invalid("Riferimenti rdf:nodeID non ammessi in XMP ISO.") }
            if profile.part == 1 { throw ArchiveMetadataIssue.unresolved("rdf:nodeID non definito dall’edizione Adobe 2004 consultata.") }
        }
        if profile.part == 4 && (node.attribute(rdf, "ID") != nil || node.attribute(rdf, "bagID") != nil) { throw ArchiveMetadataIssue.invalid("rdf:ID/bagID non ammesso in XMP ISO.") }
        if let datatype = node.attribute(rdf, "datatype") {
            // Adobe XMP Part 1 (2012), C.2.7 explicitly excludes rdf:datatype.
            // Older Adobe editions are not silently constrained by the later text.
            if profile.part == 4 { throw ArchiveMetadataIssue.invalid("rdf:datatype non è ammesso dalla serializzazione XMP ISO 16684-1.") }
            guard node.children.isEmpty, node.attribute(rdf, "resource") == nil, node.attribute(rdf, "parseType") == nil,
                  node.attribute(rdf, "value") == nil, ArchiveMetadataLexical.uri(datatype) else {
                throw ArchiveMetadataIssue.invalid("Literal rdf:datatype con contenuto/attributi incompatibili con RDF/XML §7.2.16.")
            }
            throw ArchiveMetadataIssue.unresolved("Literal RDF con rdf:datatype nell’edizione Adobe precedente: semantica XMP non risolta.")
        }
        let language = node.attribute(xml, "lang")
        if let parse = node.attribute(rdf, "parseType") {
            guard parse == "Resource" else { throw ArchiveMetadataIssue.invalid("rdf:parseType=\(parse) non è una produzione XMP ammessa.") }
            guard node.attribute(rdf, "resource") == nil, node.attribute(rdf, "value") == nil else { throw ArchiveMetadataIssue.invalid("parseType Resource combinato con valore/resource.") }
            return try structured(try fields(node, location: location, profile: profile), language: language)
        }
        let attributes = node.attributes.filter { name, _ in !(name.uri == xml && name.local == "lang") && !(name.uri == rdf && ["ID", "bagID", "nodeID"].contains(name.local)) }
        if !node.children.isEmpty {
            guard attributes.isEmpty, node.children.count == 1, node.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ArchiveMetadataIssue.invalid("Property element RDF con attributi/contenuto incompatibili.") }
            let child = node.children[0]
            if child.name.uri == rdf, ["Bag", "Seq", "Alt"].contains(child.name.local) {
                guard child.attributes.isEmpty, child.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ArchiveMetadataIssue.invalid("Contenitore RDF con attributi/testo non ammessi.") }
                var items: [ArchiveMetadataValue] = []
                for item in child.children {
                    guard item.name.uri == rdf, item.name.local == "li" else { throw ArchiveMetadataIssue.invalid("Gli array XMP devono contenere soltanto rdf:li.") }
                    items.append(try value(item, location: location + "[\(items.count + 1)]", profile: profile))
                }
                return .init(.array(child.name.local), language: language, items: items)
            }
            guard child.name.uri != rdf || child.name.local == "Description" else { throw ArchiveMetadataIssue.invalid("Nodo RDF interno non ammesso.") }
            let result = try structured(try fields(child, location: location, profile: profile), language: language)
            if child.name.uri != rdf {
                result.qualifiers.append(.init(name: .init(uri: rdf, local: "type", prefix: "rdf"), value: .init(.uri, text: child.name.uri + child.name.local), location: location + "/rdf:type"))
            }
            return result
        }
        if let literal = node.attribute(rdf, "value") {
            guard node.text.isEmpty, node.attribute(rdf, "resource") == nil else { throw ArchiveMetadataIssue.invalid("rdf:value abbreviato con valore concorrente.") }
            let qualifiers = try attributeProperties(attributes.filter { !($0.key.uri == rdf && $0.key.local == "value") }, location: location, baseURI: node.baseURI)
            return .init(.text, text: literal, language: language, qualifiers: qualifiers)
        }
        if let resource = node.attribute(rdf, "resource") {
            guard node.text.isEmpty else { throw ArchiveMetadataIssue.invalid("rdf:resource con contenuto testuale.") }
            guard ArchiveMetadataLexical.uri(resource) else { throw ArchiveMetadataIssue.invalid("rdf:resource non è un URI-reference valido.") }
            let qualifiers = try attributeProperties(attributes.filter { !($0.key.uri == rdf && $0.key.local == "resource") }, location: location, baseURI: node.baseURI)
            return .init(.uri, text: ArchiveMetadataURI.resolve(resource, against: node.baseURI) ?? resource, language: language, qualifiers: qualifiers)
        }
        if !attributes.isEmpty {
            guard node.text.isEmpty else { throw ArchiveMetadataIssue.invalid("Attributi-campo abbreviati con contenuto testuale.") }
            return .init(.structure, language: language, fields: try attributeProperties(attributes, location: location, baseURI: node.baseURI))
        }
        return .init(.text, text: node.text, language: language)
    }
    private static func attributeProperties(_ values: [ArchiveMetadataName: String], location: String, baseURI: String?) throws -> [ArchiveMetadataProperty] {
        try values.map { name, text in
            guard !name.uri.isEmpty, name.uri != ArchiveMetadataNS.rdf, name.uri != ArchiveMetadataNS.xml else { throw ArchiveMetadataIssue.invalid("Attributo di proprietà RDF non ammesso: \(name.local).") }
            return .init(name: name, value: .init(.text, text: text, baseURI: baseURI), location: location + "/" + name.local)
        }
    }
    private static func structured(_ fields: [ArchiveMetadataProperty], language: String?) throws -> ArchiveMetadataValue {
        let values = fields.filter { $0.name.uri == ArchiveMetadataNS.rdf && $0.name.local == "value" }
        if let value = values.first {
            value.value.qualifiers += fields.filter { $0.name != value.name }
            if let language {
                guard value.value.language == nil || value.value.language == language else { throw ArchiveMetadataIssue.invalid("Qualificatori xml:lang discordanti.") }
                value.value.language = language
            }
            return value.value
        }
        guard language == nil else { throw ArchiveMetadataIssue.invalid("xml:lang su valore struttura senza rdf:value.") }
        return .init(.structure, fields: fields)
    }
}

private enum ArchiveMetadataTruth {
    case yes, no, unknown(String)
}

/// Public integration surface: nil means another evaluator owns the family.
final class PDFArchiveMetadataChecks {
    private let reader: PDFStructureDocument
    private let profile: PDFArchiveProfile
    private struct Package {
        let id: PDFObjectID
        let main: Bool
        let dictionary: [String: PDFSyntaxValue]
        let data: Data?
        let graph: Result<ArchiveMetadataGraph, Error>
        var location: String { "Metadata \(id.syntax)" }
    }
    private var packagesCache: Result<[Package], Error>?
    init(reader: PDFStructureDocument, profile: PDFArchiveProfile) { self.reader = reader; self.profile = profile }

    func evaluate(_ rule: PDFArchiveCatalogueRule) throws -> PDFArchiveRuleEvaluation? {
        let families = ["XMPPackage", "MainXMPPackage", "PDFAIdentification", "PDMetadata", "XMPProperty", "ExtensionSchemaObject", "ExtensionSchemasContainer", "ExtensionSchemaDefinition", "ExtensionSchemaProperty", "ExtensionSchemaValueType", "ExtensionSchemaField"]
        let infoRule = rule.objectType == "CosInfo" && (rule.expression.contains("XMP") || rule.expression.contains("DatesMatch"))
        let containsMetadata = rule.objectType == "PDDocument" && rule.expression == "containsMetadata == true"
        guard families.contains(rule.objectType) || infoRule || containsMetadata else { return nil }
        if reader.encrypted { return .unknown("Metadati cifrati: il contenuto non viene decifrato per la validazione.") }
        let root = try reader.dictionary(.reference(reader.rootID))
        if containsMetadata {
            guard let id = try reader.resolvedObjectID(root["Metadata"]) else { return .check(false, "Il catalogo non referenzia uno stream Metadata indiretto.", locations: ["Catalog/Metadata"]) }
            let object = try reader.object(id)
            return .check(object.stream != nil && object.value.dictionary != nil, "Metadata del catalogo deve essere uno stream.", locations: [id.syntax])
        }
        let packages = try self.packages()
        if infoRule { return try infoEvaluation(rule, packages: packages) }
        if rule.objectType == "PDMetadata" {
            guard rule.expression == "isCatalogMetadata == false || Filter == null" else { return .unknown("Predicato PDMetadata non implementato: \(rule.expression)") }
            let main = packages.filter(\.main)
            return aggregate(main.map { ($0.dictionary["Filter"] == nil ? .yes : .no, $0.location) }, summary: "PDF/A-1: assenza Filter nel Metadata del catalogo.")
        }
        if rule.objectType == "XMPPackage" { return packageEvaluation(rule, packages: packages) }
        if rule.objectType == "MainXMPPackage" || rule.objectType == "PDFAIdentification" {
            guard let main = packages.first(where: \.main) else { return rule.objectType == "MainXMPPackage" ? .check(false, "Pacchetto XMP principale assente.") : .absent("Nessuno schema identificativo principale: obbligo controllato separatamente.") }
            guard case .success(let graph) = main.graph else { return .unknown("XMP principale non analizzabile; identificazione non attestata.") }
            if rule.objectType == "MainXMPPackage" {
                guard rule.expression == "containsPDFAIdentification == true" else { return .unknown("Predicato XMP principale non implementato.") }
                return .check(hasIdentification(graph), "Schema identificativo PDF/A: namespace, proprietà obbligatorie, forma e valori identificativi validi; il confronto con il profilo scelto è separato.", locations: [main.location])
            }
            return identificationEvaluation(rule, graph: graph)
        }
        var graphs: [ArchiveMetadataGraph] = [], unavailable: [String] = []
        for package in packages {
            switch package.graph { case .success(let graph): graphs.append(graph); case .failure: unavailable.append(package.location) }
        }
        let result: PDFArchiveRuleEvaluation
        if rule.objectType == "XMPProperty" { result = propertyEvaluation(rule, graphs: graphs, mainLocation: packages.first(where: \.main)?.location) }
        else { result = extensionEvaluation(rule, graphs: graphs) }
        if !unavailable.isEmpty, result.status != .failed { return .unknown("Pacchetti non analizzabili impediscono di stabilire tutti gli oggetti applicabili: " + unavailable.joined(separator: ", ")) }
        return result
    }

    private func packages() throws -> [Package] {
        if let packagesCache { return try packagesCache.get() }
        let result = Result { () throws -> [Package] in
            let root = try reader.dictionary(.reference(reader.rootID)), main = try reader.resolvedObjectID(root["Metadata"])
            var ids = Set<PDFObjectID>()
            if let main { ids.insert(main) }
            func inspect(_ value: PDFSyntaxValue, depth: Int) throws {
                guard depth < 100 else { throw PDFStructureError.limit }
                if let array = value.array { for item in array { try inspect(item, depth: depth + 1) } }
                if let dictionary = value.dictionary {
                    if let metadata = dictionary["Metadata"] {
                        if let id = try reader.resolvedObjectID(metadata) { ids.insert(id) }
                        else if case .null? = try reader.resolve(metadata) {} else { throw ArchiveMetadataIssue.unresolved("Voce Metadata non referenziata a uno stream indiretto.") }
                    }
                    for item in dictionary.values { if item.reference == nil { try inspect(item, depth: depth + 1) } }
                }
            }
            for id in reader.allObjectIDs() {
                try Task.checkCancellation()
                let object = try reader.object(id)
                if try reader.resolve(object.value.dictionary?["Type"])?.name == "Metadata" { ids.insert(id) }
                try inspect(object.value, depth: 0)
            }
            return try ids.sorted().map { id in
                try Task.checkCancellation()
                let object = try reader.object(id), dictionary = object.value.dictionary ?? [:]
                var bytes: Data?
                let graph = Result { () throws -> ArchiveMetadataGraph in
                    guard object.stream != nil else { throw ArchiveMetadataIssue.invalid("L’oggetto Metadata non contiene uno stream.") }
                    bytes = try reader.decodedStream(id)
                    return try ArchiveMetadataGraph(data: bytes!, location: "Metadata \(id.syntax)", profile: profile)
                }
                return Package(id: id, main: id == main, dictionary: dictionary, data: bytes, graph: graph)
            }
        }
        packagesCache = result
        return try result.get()
    }

    private func aggregate(_ observations: [(ArchiveMetadataTruth, String)], summary: String) -> PDFArchiveRuleEvaluation {
        if observations.isEmpty { return .absent("Nessun oggetto applicabile. " + summary) }
        var failed: [String] = [], unknown: [String] = []
        for (truth, location) in observations {
            switch truth { case .yes: break; case .no: failed.append(location); case .unknown(let detail): unknown.append(location + ": " + detail) }
        }
        if !failed.isEmpty { return .check(false, summary, locations: Array(failed.prefix(64))) }
        if !unknown.isEmpty { return .unknown(summary + " Non risolto: " + unknown.prefix(8).joined(separator: "; ")) }
        return .check(true, "\(observations.count) oggetti controllati. " + summary, locations: Array(observations.prefix(8).map(\.1)))
    }

    private func packageEvaluation(_ rule: PDFArchiveCatalogueRule, packages: [Package]) -> PDFArchiveRuleEvaluation {
        let observations: [(ArchiveMetadataTruth, String)] = packages.map { package in
            let truth: ArchiveMetadataTruth
            if rule.expression == "actualEncoding == \"UTF-8\"", let data = package.data {
                let valid = ArchiveMetadataLexical.isUTF8(data)
                return (valid ? .yes : .no, package.location)
            }
            switch package.graph {
            case .failure(let issue):
                if rule.expression == "isSerializationValid", let issue = issue as? ArchiveMetadataIssue, case .invalid = issue { truth = .no }
                else { truth = .unknown(issue.localizedDescription) }
            case .success(let graph):
                switch rule.expression {
                case "isSerializationValid": truth = packetWrapper(graph.xml)
                case "bytes == null", "encoding == null":
                    let attribute = rule.expression.hasPrefix("bytes") ? "bytes" : "encoding"
                    let pattern = "(?:^|\\s)" + attribute + "\\s*="
                    truth = graph.xml.instructions.contains { $0.0 == "xpacket" && $0.1.range(of: pattern, options: .regularExpression) != nil } ? .no : .yes
                case "actualEncoding == \"UTF-8\"": truth = graph.xml.actualEncoding == "UTF-8" ? .yes : .no
                default: truth = .unknown("Predicato XMPPackage non implementato: " + rule.expression)
                }
            }
            return (truth, package.location)
        }
        return aggregate(observations, summary: "Controllo di tutti i pacchetti Metadata, inclusi quelli secondari: " + rule.expression)
    }

    private func packetWrapper(_ xml: ArchiveMetadataXML) -> ArchiveMetadataTruth {
        let packets = xml.instructions.enumerated().filter { $0.element.0 == "xpacket" }
        // Adobe allows raw XMP where the enclosing file format locates the XML.
        guard !packets.isEmpty else { return .yes }
        guard packets.count == 2, xml.instructionPhases[packets[0].offset] == 0, xml.instructionPhases[packets[1].offset] == 2 else { return .no }
        func attributes(_ source: String) -> [String: String]? {
            guard let pattern = try? NSRegularExpression(pattern: "\\s*([A-Za-z_][A-Za-z0-9_.:-]*)\\s*=\\s*(['\"])(.*?)\\2", options: [.dotMatchesLineSeparators]) else { return nil }
            let text = source as NSString, matches = pattern.matches(in: source, range: NSRange(location: 0, length: text.length))
            var fields: [String: String] = [:], end = 0
            for match in matches {
                guard match.range.location == end else { return nil }
                let key = text.substring(with: match.range(at: 1))
                guard fields[key] == nil else { return nil }
                fields[key] = text.substring(with: match.range(at: 3)); end = NSMaxRange(match.range)
            }
            guard text.substring(from: end).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return fields
        }
        guard let begin = attributes(packets[0].element.1), let end = attributes(packets[1].element.1),
              begin["id"] == "W5M0MpCehiHzreSzNTczkc9d", let marker = begin["begin"], marker.isEmpty || marker == "\u{FEFF}",
              let mode = end["end"], ["r", "w"].contains(mode) else { return .no }
        guard Set(begin.keys).isSubset(of: ["id", "begin", "bytes", "encoding"]), Set(end.keys) == ["end"] else {
            return .unknown("Attributi del wrapper xpacket non definiti dall’edizione Adobe consultata.")
        }
        return .yes
    }

    private func identificationEvaluation(_ rule: PDFArchiveCatalogueRule, graph: ArchiveMetadataGraph) -> PDFArchiveRuleEvaluation {
        let expression = rule.expression
        for name in ["part", "conformance", "rev", "amd", "corr"] {
            let values = graph.values(ArchiveMetadataNS.id, name)
            if expression.hasPrefix(name + "Prefix") {
                return .check(values.allSatisfy { $0.name.prefix == "pdfaid" }, "Prefisso obbligatorio pdfaid per \(name), valutato indipendentemente dall’URI.", locations: values.map(\.location))
            }
            if expression.hasPrefix(name + " ==") {
                if expression == name + " == null" { return .check(values.isEmpty, "\(name) deve essere assente.", locations: [graph.location]) }
                guard values.count == 1, let text = values[0].value.scalar else { return .check(false, "\(name) deve essere una sola proprietà semplice.", locations: [graph.location]) }
                if name == "part" { return .check(text.range(of: "^[+-]?[0-9]+$", options: .regularExpression) != nil && Int(text) == profile.part, "Numero parte effettivo \(text); atteso \(profile.part).", locations: values.map(\.location)) }
                let allowed = expression.components(separatedBy: "\"").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
                return .check(allowed.contains(text), "\(name)=\(text); valori ammessi \(allowed.joined(separator: ", ")).", locations: values.map(\.location))
            }
        }
        return .unknown("Predicato identificativo non implementato: " + expression)
    }

    private func hasIdentification(_ graph: ArchiveMetadataGraph) -> Bool {
        func scalar(_ name: String) -> String? {
            let properties = graph.values(ArchiveMetadataNS.id, name)
            guard properties.count == 1, properties[0].name.prefix == "pdfaid", case .text = properties[0].value.kind else { return nil }
            return properties[0].value.text
        }
        guard let partText = scalar("part"), ArchiveMetadataLexical.matches(partText, "^[+]?[0-9]+$"), let part = Int(partText), (1...4).contains(part) else { return false }
        if part < 4 {
            guard let conformance = scalar("conformance") else { return false }
            return (part == 1 ? ["A", "B"] : ["A", "B", "U"]).contains(conformance)
        }
        guard let revision = scalar("rev"), ArchiveMetadataLexical.matches(revision, "^[0-9]{4}$") else { return false }
        let conformance = graph.values(ArchiveMetadataNS.id, "conformance")
        return conformance.isEmpty || scalar("conformance").map { ["E", "F"].contains($0) } == true
    }
}

private struct ArchiveMetadataExtensionRecord {
    let value: ArchiveMetadataValue
    let location: String
    var fields: [ArchiveMetadataProperty] { value.fields }
    func property(_ uri: String, _ name: String) -> ArchiveMetadataProperty? {
        let matches = fields.filter { $0.name.uri == uri && $0.name.local == name }
        return matches.count == 1 ? matches[0] : nil
    }
    func text(_ uri: String, _ name: String) -> String? {
        guard let value = property(uri, name)?.value, let text = value.scalar else { return nil }
        if name == "namespaceURI", [ArchiveMetadataNS.schema, ArchiveMetadataNS.type].contains(uri) {
            return ArchiveMetadataURI.resolve(text, against: value.baseURI) ?? text
        }
        return text
    }
}

private struct ArchiveMetadataExtensions {
    let graph: ArchiveMetadataGraph
    var containers: [ArchiveMetadataProperty] { graph.values(ArchiveMetadataNS.ext, "schemas") }
    var schemas: [ArchiveMetadataExtensionRecord] {
        containers.flatMap { container in container.value.items.enumerated().map { .init(value: $0.element, location: container.location + "[\($0.offset + 1)]") } }
    }
    func children(_ schema: ArchiveMetadataExtensionRecord, uri: String, field: String) -> [ArchiveMetadataExtensionRecord] {
        guard let property = schema.property(uri, field) else { return [] }
        return property.value.items.enumerated().map { .init(value: $0.element, location: property.location + "[\($0.offset + 1)]") }
    }
    var properties: [(ArchiveMetadataExtensionRecord, ArchiveMetadataExtensionRecord)] {
        schemas.flatMap { schema in children(schema, uri: ArchiveMetadataNS.schema, field: "property").map { (schema, $0) } }
    }
    var types: [(ArchiveMetadataExtensionRecord, ArchiveMetadataExtensionRecord)] {
        schemas.flatMap { schema in children(schema, uri: ArchiveMetadataNS.schema, field: "valueType").map { (schema, $0) } }
    }
    var fields: [(ArchiveMetadataExtensionRecord, ArchiveMetadataExtensionRecord)] {
        types.flatMap { schema, type in children(type, uri: ArchiveMetadataNS.type, field: "field").map { (schema, $0) } }
    }
    func customType(_ name: String) -> ArchiveMetadataExtensionRecord? {
        let matches = types.filter { $0.1.text(ArchiveMetadataNS.type, "type") == name }
        return matches.count == 1 ? matches[0].1 : nil
    }
    func propertyType(_ name: ArchiveMetadataName) -> String? {
        let matches = properties.filter { schema, property in
            schema.text(ArchiveMetadataNS.schema, "namespaceURI") == name.uri && property.text(ArchiveMetadataNS.property, "name") == name.local
        }
        guard matches.count == 1 else { return nil }
        let schema = matches[0].0, property = matches[0].1
        guard textField(schema, uri: ArchiveMetadataNS.schema, local: "schema", prefix: "pdfaSchema"),
              textField(schema, uri: ArchiveMetadataNS.schema, local: "prefix", prefix: "pdfaSchema"),
              uriField(schema, uri: ArchiveMetadataNS.schema, local: "namespaceURI", prefix: "pdfaSchema"),
              sequenceField(schema, uri: ArchiveMetadataNS.schema, local: "property", prefix: "pdfaSchema"),
              textField(property, uri: ArchiveMetadataNS.property, local: "name", prefix: "pdfaProperty"),
              textField(property, uri: ArchiveMetadataNS.property, local: "valueType", prefix: "pdfaProperty"),
              textField(property, uri: ArchiveMetadataNS.property, local: "description", prefix: "pdfaProperty"),
              textField(property, uri: ArchiveMetadataNS.property, local: "category", prefix: "pdfaProperty"),
              ["external", "internal"].contains(property.text(ArchiveMetadataNS.property, "category") ?? "") else { return nil }
        return property.text(ArchiveMetadataNS.property, "valueType")
    }
    func textField(_ record: ArchiveMetadataExtensionRecord, uri: String, local: String, prefix: String) -> Bool {
        guard let field = record.property(uri, local), field.name.prefix == prefix, case .text = field.value.kind else { return false }
        return true
    }
    func uriField(_ record: ArchiveMetadataExtensionRecord, uri: String, local: String, prefix: String) -> Bool {
        guard let field = record.property(uri, local), field.name.prefix == prefix, let value = field.value.scalar else { return false }
        return ArchiveMetadataURI.resolve(value, against: field.value.baseURI) != nil
    }
    func sequenceField(_ record: ArchiveMetadataExtensionRecord, uri: String, local: String, prefix: String) -> Bool {
        guard let field = record.property(uri, local) else { return true }
        guard field.name.prefix == prefix, case .array("Seq") = field.value.kind else { return false }
        return field.value.items.allSatisfy { if case .structure = $0.kind { return true }; return false }
    }
    func typeDefined(_ type: String, visited: Set<String> = []) -> Bool {
        let base = ArchiveMetadataLexical.arrayType(type)?.1 ?? type
        if ArchiveMetadataRegistry.definedTypes.contains(base) { return true }
        guard let record = customType(base),
              textField(record, uri: ArchiveMetadataNS.type, local: "type", prefix: "pdfaType"),
              uriField(record, uri: ArchiveMetadataNS.type, local: "namespaceURI", prefix: "pdfaType"),
              textField(record, uri: ArchiveMetadataNS.type, local: "prefix", prefix: "pdfaType"),
              textField(record, uri: ArchiveMetadataNS.type, local: "description", prefix: "pdfaType"),
              sequenceField(record, uri: ArchiveMetadataNS.type, local: "field", prefix: "pdfaType") else { return false }
        if visited.contains(base) { return true }
        for field in children(record, uri: ArchiveMetadataNS.type, field: "field") {
            guard let name = field.text(ArchiveMetadataNS.field, "valueType"), typeDefined(name, visited: visited.union([base])) else { return false }
        }
        return true
    }
}

private extension PDFArchiveMetadataChecks {
    func extensionEvaluation(_ rule: PDFArchiveCatalogueRule, graphs: [ArchiveMetadataGraph]) -> PDFArchiveRuleEvaluation {
        var observations: [(ArchiveMetadataTruth, String)] = []
        for graph in graphs {
            let ext = ArchiveMetadataExtensions(graph: graph)
            switch rule.objectType {
            case "ExtensionSchemasContainer":
                guard rule.expression == "isValidBag == true && prefix == \"pdfaExtension\"" else { return .unknown("Predicato contenitore extension non implementato.") }
                for container in ext.containers {
                    var valid = false
                    if case .array("Bag") = container.value.kind { valid = container.value.items.allSatisfy { if case .structure = $0.kind { return true }; return false } }
                    observations.append((valid && container.name.prefix == "pdfaExtension" ? .yes : .no, container.location))
                }
            case "ExtensionSchemaObject":
                guard rule.expression == "containsUndefinedFields == false" else { return .unknown("Predicato campi extension non implementato.") }
                for property in graph.properties where property.name.uri == ArchiveMetadataNS.ext && property.name.local != "schemas" {
                    observations.append((.no, property.location))
                }
                let groups: [([ArchiveMetadataExtensionRecord], String, Set<String>)] = [
                    (ext.schemas, ArchiveMetadataNS.schema, ["schema", "namespaceURI", "prefix", "property", "valueType"]),
                    (ext.properties.map(\.1), ArchiveMetadataNS.property, ["name", "valueType", "category", "description"]),
                    (ext.types.map(\.1), ArchiveMetadataNS.type, ["type", "namespaceURI", "prefix", "description", "field"]),
                    (ext.fields.map(\.1), ArchiveMetadataNS.field, ["name", "valueType", "description"])
                ]
                for (records, uri, names) in groups {
                    for record in records { observations.append((record.fields.allSatisfy { $0.name.uri == uri && names.contains($0.name.local) } ? .yes : .no, record.location)) }
                }
            default:
                let records: [ArchiveMetadataExtensionRecord], uri: String, prefix: String
                switch rule.objectType {
                case "ExtensionSchemaDefinition": records = ext.schemas; uri = ArchiveMetadataNS.schema; prefix = "pdfaSchema"
                case "ExtensionSchemaProperty": records = ext.properties.map(\.1); uri = ArchiveMetadataNS.property; prefix = "pdfaProperty"
                case "ExtensionSchemaValueType": records = ext.types.map(\.1); uri = ArchiveMetadataNS.type; prefix = "pdfaType"
                case "ExtensionSchemaField": records = ext.fields.map(\.1); uri = ArchiveMetadataNS.field; prefix = "pdfaField"
                default: return .unknown("Famiglia extension non risolta.")
                }
                let mapping: [(String, String)] = [("isSchemaValidText", "schema"), ("isNamespaceURIValidURI", "namespaceURI"), ("isPrefixValidText", "prefix"),
                    ("isPropertyValidSeq", "property"), ("isValueTypeValidSeq", "valueType"), ("isNameValidText", "name"), ("isValueTypeValidText", "valueType"),
                    ("isCategoryValidText", "category"), ("isDescriptionValidText", "description"), ("isTypeValidText", "type"), ("isFieldValidSeq", "field")]
                guard let (predicate, field) = mapping.first(where: { rule.expression.hasPrefix($0.0 + " == true") }) else { return .unknown("Predicato extension non implementato: " + rule.expression) }
                for record in records {
                    var valid: Bool
                    if predicate.hasSuffix("ValidSeq") { valid = ext.sequenceField(record, uri: uri, local: field, prefix: prefix) }
                    else if predicate.hasSuffix("ValidURI") { valid = ext.uriField(record, uri: uri, local: field, prefix: prefix) }
                    else { valid = ext.textField(record, uri: uri, local: field, prefix: prefix) }
                    if field == "category" { valid = valid && ["external", "internal"].contains(record.text(uri, field) ?? "") }
                    if rule.expression.contains("isValueTypeDefined") { valid = valid && ext.typeDefined(record.text(uri, field) ?? "") }
                    observations.append((valid ? .yes : .no, record.location + "/" + field))
                }
            }
        }
        return aggregate(observations, summary: "Extension schema: namespace, prefissi obbligatori, forma RDF, campi e tipi dichiarati. " + rule.expression)
    }
}

/// Pure identifier transformation. This type cannot open a URL, file or socket.
/// RFC 3986 §§5.2–5.3; percent-encoded dot octets remain ordinary path segments.
private enum ArchiveMetadataURI {
    static func xmlBaseReference(_ value: String) -> String {
        // XML Base (2001) §3.1: UTF-8 percent-escape excluded characters,
        // preserving existing %, # and IPv6 bracket syntax. The 2009 LEIRI
        // edition defers this escaping until a URI is needed, as it is here.
        let excluded = Set(Array("<>\"{}|\\^".utf8))
        return value.utf8.map { byte -> String in
            if byte <= 32 || byte >= 127 || byte == 96 || excluded.contains(byte) { return String(format: "%%%02X", byte) }
            return String(UnicodeScalar(byte))
        }.joined()
    }
    private struct Parts {
        var scheme: String?, authority: String?, path: String, query: String?, fragment: String?
        init(_ text: String) {
            var remainder = text
            if let marker = remainder.firstIndex(of: "#") { fragment = String(remainder[remainder.index(after: marker)...]); remainder = String(remainder[..<marker]) }
            if let marker = remainder.firstIndex(of: "?") { query = String(remainder[remainder.index(after: marker)...]); remainder = String(remainder[..<marker]) }
            if let colon = remainder.firstIndex(of: ":"), remainder[..<colon].range(of: "^[A-Za-z][A-Za-z0-9+.-]*$", options: .regularExpression) != nil {
                scheme = String(remainder[..<colon]); remainder = String(remainder[remainder.index(after: colon)...])
            }
            if remainder.hasPrefix("//") {
                remainder.removeFirst(2)
                let end = remainder.firstIndex(of: "/") ?? remainder.endIndex
                authority = String(remainder[..<end]); remainder = String(remainder[end...])
            }
            path = remainder
        }
        var string: String {
            (scheme.map { $0 + ":" } ?? "") + (authority.map { "//" + $0 } ?? "") + path +
                (query.map { "?" + $0 } ?? "") + (fragment.map { "#" + $0 } ?? "")
        }
    }
    static func resolve(_ reference: String, against base: String?) -> String? {
        guard reference.utf8.count <= 65_536, ArchiveMetadataLexical.uri(reference) else { return nil }
        var result = Parts(reference)
        if result.scheme != nil { result.path = removeDots(result.path); return result.string }
        guard let base, base.utf8.count <= 65_536, ArchiveMetadataLexical.uri(base, requireAbsolute: true) else { return nil }
        let parent = Parts(base)
        if result.authority != nil { result.path = removeDots(result.path) }
        else {
            if result.path.isEmpty {
                result.path = parent.path
                if result.query == nil { result.query = parent.query }
            } else if result.path.hasPrefix("/") { result.path = removeDots(result.path) }
            else {
                let prefix: String
                if parent.authority != nil && parent.path.isEmpty { prefix = "/" }
                else if let slash = parent.path.lastIndex(of: "/") { prefix = String(parent.path[...slash]) }
                else { prefix = "" }
                result.path = removeDots(prefix + result.path)
            }
            result.authority = parent.authority
        }
        result.scheme = parent.scheme
        let value = result.string
        return value.utf8.count <= 65_536 ? value : nil
    }
    private static func removeDots(_ path: String) -> String {
        var input = path[...], output = ""
        while !input.isEmpty {
            if input.hasPrefix("../") { input = input.dropFirst(3) }
            else if input.hasPrefix("./") { input = input.dropFirst(2) }
            else if input.hasPrefix("/./") { input = input.dropFirst(2) }
            else if input == "/." { input = "/" }
            else if input.hasPrefix("/../") || input == "/.." {
                input = input == "/.." ? "/" : input.dropFirst(3)
                if let slash = output.lastIndex(of: "/") { output = String(output[..<slash]) } else { output = "" }
            } else if input == "." || input == ".." { input = "" }
            else {
                let start = input.first == "/" ? input.index(after: input.startIndex) : input.startIndex
                let end = input[start...].firstIndex(of: "/") ?? input.endIndex
                output += input[..<end]; input = input[end...]
            }
        }
        return output
    }
}

private enum ArchiveMetadataLexical {
    static func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
    static func uri(_ value: String, requireAbsolute: Bool = false) -> Bool {
        guard !matches(value, "[\\s<>\"{}|\\\\^`]"), !matches(value, "%(?![0-9A-Fa-f]{2})"),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }), let components = URLComponents(string: value) else { return false }
        // URLComponents repairs malformed URI strings by percent-encoding
        // them. RFC 3986 §§2.2, 3.3–3.5 requires the original spelling.
        let fragments = value.split(separator: "#", omittingEmptySubsequences: false)
        guard fragments.count <= 2 else { return false }
        let beforeFragment = fragments.first.map(String.init) ?? ""
        let query = beforeFragment.firstIndex(of: "?")
        var path = query.map { String(beforeFragment[..<$0]) } ?? beforeFragment
        let queryText = query.map { String(beforeFragment[beforeFragment.index(after: $0)...]) }
        if components.scheme != nil, let colon = path.firstIndex(of: ":") { path = String(path[path.index(after: colon)...]) }
        if path.hasPrefix("//") {
            let end = path.dropFirst(2).firstIndex(of: "/") ?? path.endIndex
            let authority = path[path.index(path.startIndex, offsetBy: 2)..<end]
            guard authority.filter({ $0 == "@" }).count <= 1 else { return false }
            path = String(path[end...])
        }
        let pchar = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@%")
        func validComponent(_ text: String, query: Bool) -> Bool {
            text.unicodeScalars.allSatisfy { scalar in
                // XML namespace IRIs remain supported; URI property values
                // with raw Unicode receive a separate unknown result.
                scalar.value > 127 || pchar.contains(scalar) || scalar == "/" || (query && scalar == "?")
            }
        }
        guard validComponent(path, query: false), queryText.map({ validComponent($0, query: true) }) ?? true,
              fragments.count < 2 || validComponent(String(fragments[1]), query: true) else { return false }
        if requireAbsolute { return components.scheme != nil && !value.isEmpty }
        return true // XMP includes URI references, relative paths and empty URI values.
    }
    static func mime(_ value: String) -> ArchiveMetadataTruth {
        // RFC 2045 §5.1: MIME tokens and quoted-string parameters. Comments and
        // folded RFC 822 whitespace remain explicitly unresolved, not invalid.
        let bytes = Array(value.utf8)
        guard bytes.count <= 65_536 else { return .unknown("Valore MIME oltre il limite locale di 64 KiB.") }
        if bytes.contains(13) || bytes.contains(10) { return .unknown("Spaziatura MIME ripiegata RFC 822 non modellata.") }
        var quoted = false, escaped = false
        for byte in bytes {
            if escaped { escaped = false; continue }
            if quoted && byte == 92 { escaped = true; continue }
            if byte == 34 { quoted.toggle() }
            else if !quoted && (byte == 40 || byte == 41) { return .unknown("Commenti MIME RFC 822 non modellati.") }
        }
        let specials = Set(Array("()<>@,;:\\\"/[]?=".utf8))
        func isToken(_ byte: UInt8) -> Bool { byte > 32 && byte < 127 && !specials.contains(byte) }
        var index = 0
        func whitespace() { while index < bytes.count, bytes[index] == 32 || bytes[index] == 9 { index += 1 } }
        func token() -> Bool {
            let start = index
            while index < bytes.count, isToken(bytes[index]) { index += 1 }
            return index > start
        }
        whitespace()
        guard token() else { return bytes.contains(40) || bytes.contains(41) ? .unknown("Commenti MIME RFC 822 non modellati.") : .no }
        whitespace()
        guard index < bytes.count, bytes[index] == 47 else { return .no }
        index += 1; whitespace()
        guard token() else { return .no }
        whitespace()
        while index < bytes.count {
            if bytes[index] == 40 || bytes[index] == 41 { return .unknown("Commenti MIME RFC 822 non modellati.") }
            guard bytes[index] == 59 else { return .no }
            index += 1; whitespace()
            guard token() else { return .no }
            whitespace()
            guard index < bytes.count, bytes[index] == 61 else { return .no }
            index += 1; whitespace()
            guard index < bytes.count else { return .no }
            if bytes[index] == 34 {
                index += 1
                var closed = false
                while index < bytes.count {
                    let byte = bytes[index]; index += 1
                    if byte == 34 { closed = true; break }
                    if byte == 92 {
                        guard index < bytes.count, bytes[index] == 9 || (32...126).contains(bytes[index]) else { return .no }
                        index += 1
                    } else if byte != 9 && !(32...126).contains(byte) { return .no }
                }
                guard closed else { return .no }
            } else { guard token() else { return .no } }
            whitespace()
        }
        return .yes
    }
    static func arrayType(_ type: String) -> (String, String)? {
        let pieces = type.split(separator: " ", maxSplits: 1).map(String.init)
        guard pieces.count == 2, ["bag", "seq", "alt"].contains(pieces[0].lowercased()) else { return nil }
        return (pieces[0].capitalized, pieces[1])
    }
    static func isUTF8(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8), !data.contains(0), !data.starts(with: [0xFF, 0xFE]), !data.starts(with: [0xFE, 0xFF]) else { return false }
        guard let regex = try? NSRegularExpression(pattern: "^\u{FEFF}?<\\?xml[^?]*encoding\\s*=\\s*['\"]([^'\"]+)['\"]"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return true }
        return ["UTF-8", "UTF8"].contains((text as NSString).substring(with: match.range(at: 1)).uppercased())
    }
}

private struct ArchiveMetadataDate {
    let components: [Int]
    let precision: Int
    let offset: Int?
    let fraction: String
    var date: Date? {
        let year = components[0], month = components[1], day = components[2]
        guard year > 0, (1...12).contains(month) else { return nil }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...lengths[month - 1]).contains(day) else { return nil }
        // Proleptic Gregorian arithmetic avoids Calendar's historical cutover and locale.
        let adjustedYear = year - (month <= 2 ? 1 : 0), era = adjustedYear / 400
        let yearOfEra = adjustedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        let seconds = days * 86_400 + components[3] * 3_600 + components[4] * 60 + components[5]
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
    static func xmp(_ string: String) -> Self? {
        let pattern = "^([0-9]{4})(?:-([0-9]{2})(?:-([0-9]{2})(?:T([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:\\.([0-9]+))?)?(Z|[+-][0-9]{2}:[0-9]{2})?)?)?)?$"
        guard let values = captures(string, pattern), let year = Int(values[0]), year > 0 else { return nil }
        let numbers = [year, Int(values[1]) ?? 1, Int(values[2]) ?? 1, Int(values[3]) ?? 0, Int(values[4]) ?? 0, Int(values[5]) ?? 0]
        guard numbers[3] < 24, numbers[4] < 60, numbers[5] < 60 else { return nil }
        let offset = timezone(values[7])
        guard values[7].isEmpty || offset != nil else { return nil }
        let fraction = String(values[6].reversed().drop(while: { $0 == "0" }).reversed())
        let precision = values.prefix(6).lastIndex(where: { !$0.isEmpty }).map { $0 + 1 } ?? 1
        let result = Self(components: numbers, precision: precision, offset: offset, fraction: fraction)
        return result.date == nil ? nil : result
    }
    static func pdf(_ string: String) -> Self? {
        let pattern = "^(?:D:)?([0-9]{4})([0-9]{2})?([0-9]{2})?([0-9]{2})?([0-9]{2})?([0-9]{2})?(Z|[+-][0-9]{2}(?:'?[0-9]{2}'?)?)?$"
        guard let values = captures(string, pattern), let year = Int(values[0]), year > 0 else { return nil }
        let numbers = [year, Int(values[1]) ?? 1, Int(values[2]) ?? 1, Int(values[3]) ?? 0, Int(values[4]) ?? 0, Int(values[5]) ?? 0]
        guard numbers[3] < 24, numbers[4] < 60, numbers[5] < 60 else { return nil }
        var zone = values[6].replacingOccurrences(of: "'", with: "")
        if zone.count == 3 { zone += "00" }
        if zone.count == 5 { zone.insert(":", at: zone.index(zone.startIndex, offsetBy: 3)) }
        let offset = timezone(zone)
        guard zone.isEmpty || offset != nil else { return nil }
        let precision = values.prefix(6).lastIndex(where: { !$0.isEmpty }).map { $0 + 1 } ?? 1
        let result = Self(components: numbers, precision: precision, offset: offset, fraction: "")
        return result.date == nil ? nil : result
    }
    private static func captures(_ value: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), match.range.length == (value as NSString).length else { return nil }
        return (1..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : (value as NSString).substring(with: match.range(at: $0)) }
    }
    private static func timezone(_ zone: String) -> Int? {
        if zone == "Z" { return 0 }
        guard zone.count == 6, let hours = Int(zone.dropFirst().prefix(2)), let minutes = Int(zone.suffix(2)), hours < 24, minutes < 60 else { return nil }
        return (zone.first == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)
    }
    func equivalent(to other: Self) -> ArchiveMetadataTruth {
        guard (offset == nil) == (other.offset == nil) else { return .unknown("Una data non specifica il fuso; il fuso locale del Mac non viene presunto.") }
        if precision != other.precision {
            // NOTE-datetime leaves comparison across granularities to adopting
            // specifications. Prove contradictions in supplied components,
            // but never manufacture equal seconds from an omitted component.
            if offset == other.offset && Array(components.prefix(min(precision, other.precision))) != Array(other.components.prefix(min(precision, other.precision))) { return .no }
            if precision >= 5, other.precision >= 5, let offset, let otherOffset = other.offset, let first = date, let second = other.date,
               floor((first.timeIntervalSince1970 - Double(offset)) / 60) != floor((second.timeIntervalSince1970 - Double(otherOffset)) / 60) { return .no }
            return .unknown("Precisioni delle date differenti; equivalenza non attestata per componenti omesse.")
        }
        if let offset, let otherOffset = other.offset, let first = date, let second = other.date {
            return first.addingTimeInterval(TimeInterval(-offset)) == second.addingTimeInterval(TimeInterval(-otherOffset)) && fraction == other.fraction ? .yes : .no
        }
        return components == other.components && fraction == other.fraction ? .yes : .no
    }
}

private extension PDFArchiveMetadataChecks {
    func propertyEvaluation(_ rule: PDFArchiveCatalogueRule, graphs: [ArchiveMetadataGraph], mainLocation: String?) -> PDFArchiveRuleEvaluation {
        let isMembership = rule.expression.hasPrefix("isPredefinedInXMP2004") || rule.expression.hasPrefix("isPredefinedInXMP2005")
        guard isMembership || rule.expression == "isValueTypeCorrect == true" else { return .unknown("Predicato XMPProperty non implementato: " + rule.expression) }
        let year = rule.expression.contains("2004") || profile.part == 1 ? 2004 : 2005
        let mainExtensions = graphs.first(where: { $0.location == mainLocation }).map(ArchiveMetadataExtensions.init)
        var observations: [(ArchiveMetadataTruth, String)] = []
        func qualifiers(_ value: ArchiveMetadataValue) -> [ArchiveMetadataProperty] {
            value.qualifiers.filter { $0.name.uri != ArchiveMetadataNS.rdf } + value.qualifiers.flatMap { qualifiers($0.value) } + value.items.flatMap(qualifiers) + value.fields.flatMap { qualifiers($0.value) }
        }
        for graph in graphs {
            let ext = ArchiveMetadataExtensions(graph: graph)
            let properties = graph.properties + graph.properties.flatMap { qualifiers($0.value) }
            for property in properties {
                let predefined = ArchiveMetadataRegistry.type(property.name, year: year)
                let current = ext.propertyType(property.name)
                let main = rule.expression.contains("isDefinedInMainPackage") || profile.part > 1 ? mainExtensions?.propertyType(property.name) : nil
                let type = predefined ?? current ?? main
                let truth: ArchiveMetadataTruth
                if isMembership { truth = type != nil ? .yes : .no }
                else if let type {
                    // Adobe explicitly defines this URI-valued property as a relative path.
                    let effectiveType = property.name.uri == "http://ns.adobe.com/xmp/1.0/DynamicMedia/" && property.name.local == "relativePeakAudioFilePath" ? "RelativeURI" : (ArchiveMetadataRegistry.closedChoice(property.name, year: year) ?? type)
                    truth = checkValue(property.value, type: effectiveType, extensions: ext, fallback: profile.part == 1 ? nil : mainExtensions, visited: [])
                }
                else { truth = .unknown("Tipo della proprietà non definito: " + property.name.expanded) }
                observations.append((truth, property.location + " " + property.name.expanded))
            }
        }
        return aggregate(observations, summary: isMembership ? "Proprietà dell’edizione Adobe \(year), oppure descrizione extension valida nel pacchetto ammesso." : "Tipo effettivo di proprietà, array, strutture e qualificatori XMP.")
    }

    func checkValue(_ value: ArchiveMetadataValue, type: String, extensions: ArchiveMetadataExtensions, fallback: ArchiveMetadataExtensions?, visited: Set<String>) -> ArchiveMetadataTruth {
        if let (kind, itemType) = ArchiveMetadataLexical.arrayType(type) {
            guard case .array(let actual) = value.kind, actual == kind else { return .no }
            return combine(value.items.map { checkValue($0, type: itemType, extensions: extensions, fallback: fallback, visited: visited) })
        }
        if type == "Lang Alt" {
            guard case .array("Alt") = value.kind else { return .no }
            var languages = Set<String>()
            for item in value.items {
                guard case .text = item.kind, let language = item.language, ArchiveMetadataLexical.matches(language, "^[A-Za-z]{1,8}(?:-[A-Za-z0-9]{1,8})*$"), languages.insert(language.lowercased()).inserted else { return .no }
            }
            return .yes
        }
        if ["Schema", "Property", "ValueType", "Field"].contains(type) { return extensionValue(value, type: type, extensions: extensions, fallback: fallback, visited: visited) }
        if let shape = builtinStructure(type) {
            guard case .structure = value.kind else { return .no }
            return combine(value.fields.map { property in
                guard property.name.uri == shape.0, let fieldType = shape.1[property.name.local] else { return .unknown("Campo aggiuntivo della struttura \(type): \(property.name.expanded)") }
                return checkValue(property.value, type: fieldType, extensions: extensions, fallback: fallback, visited: visited)
            })
        }
        if let custom = extensions.customType(type) ?? fallback?.customType(type) {
            guard !visited.contains(type) else { return .unknown("Tipo extension ricorsivo: " + type) }
            guard extensions.typeDefined(type) || fallback?.typeDefined(type) == true else { return .no }
            let defs = extensions.children(custom, uri: ArchiveMetadataNS.type, field: "field")
            if defs.isEmpty { return .unknown("Tipo extension opaco senza descrizione dei campi: " + type) }
            guard case .structure = value.kind, let uri = custom.text(ArchiveMetadataNS.type, "namespaceURI") else { return .no }
            return combine(value.fields.map { field in
                let matches = defs.filter { $0.text(ArchiveMetadataNS.field, "name") == field.name.local }
                guard field.name.uri == uri, matches.count == 1, let fieldType = matches[0].text(ArchiveMetadataNS.field, "valueType") else { return .no }
                return checkValue(field.value, type: fieldType, extensions: extensions, fallback: fallback, visited: visited.union([type]))
            })
        }
        let scalarTypes: Set<String> = ["Text", "ProperName", "AgentName", "open Choice", "RenditionClass", "XPath", "Boolean", "Integer", "Real", "Rational", "URI", "URL", "RelativeURI", "Date", "MIMEType", "Locale", "GPSCoordinate", "ExifVersion", "ApplicationIntegerChoice", "Closed Choice", "closed Choice", "Closed choice"]
        guard scalarTypes.contains(type) || type.hasPrefix("choice:") || type.hasPrefix("choiceInteger:") || type.hasPrefix("integerRange:") || type.hasPrefix("realRange:") || type.hasPrefix("choiceSequence:") else {
            return .unknown("Semantica del tipo XMP non ancora modellata: " + type)
        }
        if type.hasPrefix("choiceSequence:") {
            guard case .array("Seq") = value.kind else { return .no }
            let options = type.dropFirst("choiceSequence:".count).split(separator: "|").map { $0.split(separator: ",").map(String.init) }
            let numbers = value.items.compactMap { item -> Int? in
                guard case .text = item.kind, ArchiveMetadataLexical.matches(item.text, "^[+-]?[0-9]+$") else { return nil }; return Int(item.text)
            }
            guard numbers.count == value.items.count else { return .no }
            return options.contains { $0.compactMap(Int.init) == numbers } ? .yes : .no
        }
        guard let text = value.scalar else { return .no }
        if case .uri = value.kind, !["URI", "URL", "RelativeURI"].contains(type) { return .no }
        if type.hasPrefix("choice:") { return type.dropFirst(7).split(separator: "|", omittingEmptySubsequences: false).contains(Substring(text)) ? .yes : .no }
        if type.hasPrefix("choiceInteger:") {
            guard ArchiveMetadataLexical.matches(text, "^[+-]?[0-9]+$"), let number = Int(text) else { return .no }
            return type.dropFirst("choiceInteger:".count).split(separator: "|").compactMap { Int($0) }.contains(number) ? .yes : .no
        }
        if type.hasPrefix("integerRange:") || type.hasPrefix("realRange:") {
            let integer = type.hasPrefix("integerRange:")
            let bounds = type.split(separator: ":").last!.split(separator: ",").compactMap { Double($0) }
            guard bounds.count == 2, ArchiveMetadataLexical.matches(text, integer ? "^[+-]?[0-9]+$" : "^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)$"), let number = Double(text), number.isFinite else { return .no }
            return bounds[0] <= number && number <= bounds[1] ? .yes : .no
        }
        switch type {
        case "Text", "ProperName", "AgentName", "open Choice", "RenditionClass", "XPath":
            if case .text = value.kind { return .yes }; return .no
        case "Boolean": return ["True", "False"].contains(text) ? .yes : .no
        case "Integer": return ArchiveMetadataLexical.matches(text, "^[+-]?[0-9]+$") ? .yes : .no
        case "ApplicationIntegerChoice":
            guard ArchiveMetadataLexical.matches(text, "^[+-]?[0-9]+$") else { return .no }
            return .unknown("Scelta intera con intervallo definito dall’applicazione, non disponibile nel pacchetto.")
        case "ExifVersion":
            guard ArchiveMetadataLexical.matches(text, "^[0-9]{4}$") else { return .no }
            // Adobe 2004/2005 explicitly demonstrates the 2.1 mapping. Later
            // namespace-owner revisions must not silently redefine old tables.
            return text == "0210" ? .yes : .unknown("Versione EXIF non dimostrata dal vocabolario Adobe dell’edizione selezionata.")
        case "Real": return ArchiveMetadataLexical.matches(text, "^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)$") ? .yes : .no
        case "Rational":
            guard ArchiveMetadataLexical.matches(text, "^[+-]?[0-9]+/[+-]?[0-9]+$"), let denominator = text.split(separator: "/").last else { return .no }
            return denominator.trimmingCharacters(in: CharacterSet(charactersIn: "+-0")).isEmpty ? .no : .yes
        case "URI", "URL":
            guard ArchiveMetadataLexical.uri(text) else { return .no }
            if text.unicodeScalars.contains(where: { $0.value > 127 }) { return .unknown("IRI con Unicode non percent-encoded: corrispondenza al tipo URI XMP non attestata.") }
            return ArchiveMetadataURI.resolve(text, against: value.baseURI) != nil ? .yes : .unknown("URI-reference relativo senza schema/base assoluta esplicita: risoluzione non attestata.")
        case "RelativeURI": return ArchiveMetadataLexical.uri(text) ? .yes : .no
        case "Date": return ArchiveMetadataDate.xmp(text) != nil ? .yes : .no
        case "MIMEType": return ArchiveMetadataLexical.mime(text)
        case "Locale":
            guard ArchiveMetadataLexical.matches(text, "^[A-Za-z]{1,8}(?:-[A-Za-z0-9]{1,8})*$") else { return .no }
            let language = String(text.split(separator: "-")[0]).lowercased()
            let known = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier))
            return known.contains(language) || language == "x" || language == "i" ? .yes : .unknown("Lingua non risolta nel registro ISO disponibile localmente.")
        case "GPSCoordinate":
            guard ArchiveMetadataLexical.matches(text, "^[0-9]+,[0-9]+(?:,[0-9]+|\\.[0-9]+)?[NSEW]$") else { return .no }
            guard let direction = text.last, "NSEW".contains(direction) else { return .no }
            let numbers = text.dropLast().split(separator: ",").compactMap { Double($0) }
            guard numbers.count == 2 || numbers.count == 3, numbers.allSatisfy({ $0.isFinite && $0 >= 0 }), numbers[1] < 60, numbers.count < 3 || numbers[2] < 60 else { return .no }
            let limit = "NS".contains(direction) ? 90.0 : 180.0
            return numbers[0] <= limit && (numbers[0] < limit || numbers.dropFirst().allSatisfy { $0 == 0 }) ? .yes : .no
        case "Closed Choice", "closed Choice", "Closed choice": return .unknown("Vocabolario chiuso della proprietà non ancora modellato integralmente.")
        default: return .unknown("Semantica del tipo XMP non ancora modellata: " + type)
        }
    }

    func combine(_ values: [ArchiveMetadataTruth]) -> ArchiveMetadataTruth {
        var unresolved: [String] = []
        for value in values { switch value { case .no: return .no; case .unknown(let message): unresolved.append(message); case .yes: break } }
        return unresolved.isEmpty ? .yes : .unknown(unresolved.prefix(3).joined(separator: "; "))
    }

    func extensionValue(_ value: ArchiveMetadataValue, type: String, extensions: ArchiveMetadataExtensions, fallback: ArchiveMetadataExtensions?, visited: Set<String>) -> ArchiveMetadataTruth {
        guard case .structure = value.kind else { return .no }
        let uri: String, fields: [String: String], mandatory: Set<String>
        switch type {
        case "Schema": uri = ArchiveMetadataNS.schema; fields = ["schema": "Text", "namespaceURI": "URI", "prefix": "Text", "property": "seq Property", "valueType": "seq ValueType"]; mandatory = ["schema", "namespaceURI", "prefix"]
        case "Property": uri = ArchiveMetadataNS.property; fields = ["name": "Text", "valueType": "Text", "category": "Text", "description": "Text"]; mandatory = Set(fields.keys)
        case "ValueType": uri = ArchiveMetadataNS.type; fields = ["type": "Text", "namespaceURI": "URI", "prefix": "Text", "description": "Text", "field": "seq Field"]; mandatory = ["type", "namespaceURI", "prefix", "description"]
        default: uri = ArchiveMetadataNS.field; fields = ["name": "Text", "valueType": "Text", "description": "Text"]; mandatory = Set(fields.keys)
        }
        guard mandatory.isSubset(of: Set(value.fields.filter { $0.name.uri == uri }.map { $0.name.local })) else { return .no }
        return combine(value.fields.map { field in
            guard field.name.uri == uri, let fieldType = fields[field.name.local] else { return .no }
            return checkValue(field.value, type: fieldType, extensions: extensions, fallback: fallback, visited: visited)
        })
    }

    func builtinStructure(_ type: String) -> (String, [String: String])? {
        let base = "http://ns.adobe.com/xap/1.0/"
        let dm = "http://ns.adobe.com/xmp/1.0/DynamicMedia/", exif = "http://ns.adobe.com/exif/1.0/"
        switch type {
        case "Dimensions": return (base + "sType/Dimensions#", ["w": "Real", "h": "Real", "unit": "open Choice"])
        case "Thumbnail": return (base + "g/img/", ["height": "Integer", "width": "Integer", "format": "open Choice", "image": "Text"])
        case "ResourceRef": return (base + "sType/ResourceRef#", ["instanceID": "URI", "documentID": "URI", "versionID": "Text", "renditionClass": "RenditionClass", "renditionParams": "Text", "manager": "AgentName", "managerVariant": "Text", "manageTo": "URI", "manageUI": "URI"])
        case "ResourceEvent": return (base + "sType/ResourceEvent#", ["action": "open Choice", "instanceID": "URI", "parameters": "Text", "softwareAgent": "AgentName", "when": "Date"])
        case "Version": return (base + "sType/Version#", ["comments": "Text", "event": "ResourceEvent", "modifyDate": "Date", "modifier": "ProperName", "version": "Text"])
        case "Job": return (base + "sType/Job#", ["id": "Text", "name": "Text", "url": "URL"])
        case "Colorant": return (base + "g/", ["swatchName": "Text", "mode": "choice:CMYK|RGB|LAB", "type": "choice:PROCESS|SPOT", "cyan": "realRange:0,100", "magenta": "realRange:0,100", "yellow": "realRange:0,100", "black": "realRange:0,100", "red": "integerRange:0,255", "green": "integerRange:0,255", "blue": "integerRange:0,255", "L": "realRange:0,100", "A": "integerRange:-128,127", "B": "integerRange:-128,127"])
        case "Font": return (base + "sType/Font#", ["fontName": "Text", "fontFamily": "Text", "fontFace": "Text", "fontType": "open Choice", "versionString": "Text", "composite": "Boolean", "fontFileName": "Text", "childFontFiles": "seq Text"])
        case "Time": return (dm, ["value": "Integer", "scale": "Rational"])
        case "Timecode": return (dm, ["timeValue": "Text", "timeFormat": "choice:24Timecode|25Timecode|2997DropTimecode|2997NonDropTimecode|30Timecode|50Timecode|5994DropTimecode|5994NonDropTimecode|60Timecode|23976Timecode"])
        case "Marker": return (dm, ["startTime": "Time", "duration": "Time", "comment": "Text", "name": "Text", "location": "URI", "target": "Text", "type": "choice:Chapter|Cue|Beat|Track|Index"])
        case "Media": return (dm, ["path": "URI", "track": "Text", "startTime": "Time", "duration": "Time", "managed": "Boolean", "webStatement": "URI"])
        case "ProjectLink": return (dm, ["type": "choice:movie|still|audio|custom", "path": "URI"])
        case "resampleStretch": return (dm, ["quality": "choice:High|Medium|Low"])
        case "timeScaleStretch": return (dm, ["quality": "choice:High|Medium|Low", "frameSize": "Real", "frameOverlappingPercentage": "Real"])
        case "beatSpliceStretch": return (dm, ["useFileBeatsMarker": "Boolean", "riseInDecibel": "Real", "riseInTimeDuration": "Time"])
        case "Flash": return (exif, ["Fired": "Boolean", "Return": "choiceInteger:0|2|3", "Mode": "choiceInteger:0|1|2|3", "Function": "Boolean", "RedEyeMode": "Boolean"])
        case "OECF/SFR": return (exif, ["Columns": "Integer", "Rows": "Integer", "Names": "seq Text", "Values": "seq Rational"])
        case "CFAPattern": return (exif, ["Columns": "Integer", "Rows": "Integer", "Values": "seq Integer"])
        case "DeviceSettings": return (exif, ["Columns": "Integer", "Rows": "Integer", "Settings": "seq Text"])
        default: return nil
        }
    }

    private func infoEvaluation(_ rule: PDFArchiveCatalogueRule, packages: [Package]) throws -> PDFArchiveRuleEvaluation {
        guard let infoValue = reader.trailer["Info"], let info = try reader.resolve(infoValue)?.dictionary else { return .absent("Dizionario Info assente.") }
        let mappings: [(String, String, String)] = [("Title", ArchiveMetadataNS.dc, "title"), ("Author", ArchiveMetadataNS.dc, "creator"), ("Subject", ArchiveMetadataNS.dc, "description"),
            ("Keywords", ArchiveMetadataNS.pdf, "Keywords"), ("Creator", ArchiveMetadataNS.xmp, "CreatorTool"), ("Producer", ArchiveMetadataNS.pdf, "Producer"),
            ("CreationDate", ArchiveMetadataNS.xmp, "CreateDate"), ("ModDate", ArchiveMetadataNS.xmp, "ModifyDate")]
        let key: String
        if rule.expression == "doCreationDatesMatch != false" { key = "CreationDate" }
        else if rule.expression == "doModDatesMatch != false" { key = "ModDate" }
        else { key = rule.expression.components(separatedBy: " ")[0] }
        guard let mapping = mappings.first(where: { $0.0 == key }) else { return .unknown("Coerenza Info/XMP non implementata: " + rule.expression) }
        guard let raw = info[key] else { return .check(true, "Info/\(key) assente: nessun valore da sincronizzare.") }
        guard let text = try reader.resolve(raw)?.text else { return .check(false, "Info/\(key) non è una stringa PDF.") }
        guard let package = packages.first(where: \.main) else { return .check(false, "Info/\(key) presente, ma Metadata principale assente.") }
        guard case .success(let graph) = package.graph else { return .unknown("Metadata principale non analizzabile; coerenza con Info non attestata.") }
        let properties = graph.values(mapping.1, mapping.2)
        guard properties.count == 1 else { return .check(false, "La proprietà XMP analoga a Info/\(key) deve essere presente una sola volta.") }
        let value = properties[0].value
        let truth: ArchiveMetadataTruth
        if key == "Title" || key == "Subject" {
            if case .array("Alt") = value.kind {
                let defaults = value.items.filter { $0.language?.lowercased() == "x-default" }
                truth = defaults.count == 1 && defaults[0].scalar == text ? .yes : .no
            } else { truth = .no }
        } else if key == "Author" {
            if case .array("Seq") = value.kind { truth = value.items.count == 1 && value.items[0].scalar == text ? .yes : .no } else { truth = .no }
        } else if key == "CreationDate" || key == "ModDate" {
            if let pdfDate = ArchiveMetadataDate.pdf(text), let xmpText = value.scalar, let xmpDate = ArchiveMetadataDate.xmp(xmpText) { truth = pdfDate.equivalent(to: xmpDate) }
            else { truth = .no }
        } else { truth = value.scalar == text ? .yes : .no }
        return aggregate([(truth, "Info/\(key) ↔ \(properties[0].location)")], summary: "Coerenza effettiva Info/XMP, con contenuto Unicode e fusi orari espliciti; nessun fuso locale presunto.")
    }
}

private enum ArchiveMetadataRegistry {
    // Property-name/type facts transcribed from the actual edition tables, not from a current SDK registry.
    private static let edition2004: [String: String] = make([
        ("http://purl.org/dc/elements/1.1/", "contributor=bag ProperName;coverage=Text;creator=seq ProperName;date=seq Date;description=Lang Alt;format=MIMEType;identifier=Text;language=bag Locale;publisher=bag ProperName;relation=bag Text;rights=Lang Alt;source=Text;subject=bag Text;title=Lang Alt;type=bag open Choice"),
        ("http://ns.adobe.com/xap/1.0/", "Advisory=bag XPath;BaseURL=URL;CreateDate=Date;CreatorTool=AgentName;Identifier=bag Text;MetadataDate=Date;ModifyDate=Date;Nickname=Text;Thumbnails=alt Thumbnail"),
        ("http://ns.adobe.com/xap/1.0/rights/", "Certificate=URL;Marked=Boolean;Owner=bag ProperName;UsageTerms=Lang Alt;WebStatement=URL"),
        ("http://ns.adobe.com/xap/1.0/mm/", "DerivedFrom=ResourceRef;DocumentID=URI;History=seq ResourceEvent;LastURL=URL;ManageTo=URI;ManageUI=URI;ManagedFrom=ResourceRef;Manager=AgentName;ManagerVariant=Text;RenditionClass=RenditionClass;RenditionOf=ResourceRef;RenditionParams=Text;SaveID=Integer;VersionID=Text;Versions=seq Version"),
        ("http://ns.adobe.com/xap/1.0/bj/", "JobRef=bag Job"),
        ("http://ns.adobe.com/xap/1.0/t/pg/", "MaxPageSize=Dimensions;NPages=Integer"),
        ("http://ns.adobe.com/pdf/1.3/", "Keywords=Text;PDFVersion=Text;Producer=AgentName"),
        ("http://ns.adobe.com/photoshop/1.0/", "AuthorsPosition=Text;CaptionWriter=ProperName;Category=Text;City=Text;Country=Text;Credit=Text;DateCreated=Date;Headline=Text;Instructions=Text;Source=Text;State=Text;SupplementalCategories=Text;TransmissionReference=Text;Urgency=Integer"),
        ("http://ns.adobe.com/tiff/1.0/", "Artist=ProperName;BitsPerSample=seq Integer;Compression=Closed Choice;Copyright=Lang Alt;DateTime=Date;ImageDescription=Lang Alt;ImageLength=Integer;ImageWidth=Integer;Make=ProperName;Model=ProperName;Orientation=Closed Choice;PhotometricInterpretation=Closed Choice;PlanarConfiguration=Closed Choice;PrimaryChromaticities=seq Rational;ReferenceBlackWhite=seq Rational;ResolutionUnit=Closed Choice;SamplesPerPixel=Integer;Software=AgentName;TransferFunction=seq Integer;WhitePoint=seq Rational;XResolution=Rational;YCbCrCoefficients=seq Rational;YCbCrPositioning=Closed Choice;YCbCrSubSampling=Closed Choice;YResolution=Rational"),
        ("http://ns.adobe.com/exif/1.0/", "ApertureValue=Rational;BrightnessValue=Rational;CFAPattern=CFAPattern;ColorSpace=Closed Choice;ComponentsConfiguration=Closed Choice;CompressedBitsPerPixel=Rational;Contrast=Closed Choice;CustomRendered=Closed Choice;DateTimeDigitized=Date;DateTimeOriginal=Date;DeviceSettingDescription=DeviceSettings;DigitalZoomRatio=Rational;ExifVersion=Closed Choice;ExposureBiasValue=Rational;ExposureIndex=Rational;ExposureMode=Closed Choice;ExposureProgram=Closed Choice;ExposureTime=Rational;FNumber=Rational;FileSource=Closed Choice;Flash=Flash;FlashEnergy=Rational;FlashpixVersion=Closed Choice;FocalLength=Rational;FocalLengthIn35mmFilm=Integer;FocalPlaneResolutionUnit=Closed Choice;FocalPlaneXResolution=Rational;FocalPlaneYResolution=Rational;GPSAltitude=Rational;GPSAltitudeRef=Closed Choice;GPSAreaInformation=Text;GPSDOP=Rational;GPSDestBearing=Rational;GPSDestBearingRef=Closed Choice;GPSDestDistance=Rational;GPSDestDistanceRef=Closed Choice;GPSDestLatitude=GPSCoordinate;GPSDestLongitude=GPSCoordinate;GPSDifferential=Closed choice;GPSImgDirection=Rational;GPSImgDirectionRef=Closed Choice;GPSLatitude=GPSCoordinate;GPSLongitude=GPSCoordinate;GPSMapDatum=Text;GPSMeasureMode=Closed Choice;GPSProcessingMethod=Text;GPSSatellites=Text;GPSSpeed=Rational;GPSSpeedRef=Closed Choice;GPSStatus=Closed Choice;GPSTimeStamp=Date;GPSTrack=Rational;GPSTrackRef=Closed Choice;GPSVersionID=Text;GainControl=Closed Choice;ISOSpeedRatings=seq Integer;ImageUniqueID=Text;LightSource=Closed Choice;MakerNote=Text;MaxApertureValue=Rational;MeteringMode=Closed Choice;OECF=OECF/SFR;PixelXDimension=Integer;PixelYDimension=Integer;RelatedSoundFile=Text;Saturation=Closed Choice;SceneCaptureType=Closed Choice;SceneType=Closed Choice;SensingMethod=Closed Choice;Sharpness=Closed Choice;ShutterSpeedValue=Rational;SpatialFrequencyResponse=OECF/SFR;SpectralSensitivity=Text;SubjectArea=seq Integer;SubjectDistance=Rational;SubjectDistanceRange=Closed Choice;SubjectLocation=seq Integer;UserComment=Lang Alt;WhiteBalance=Closed Choice"),
    ])
    private static let edition2005: [String: String] = make([
        ("http://purl.org/dc/elements/1.1/", "contributor=bag ProperName;coverage=Text;creator=seq ProperName;date=seq Date;description=Lang Alt;format=MIMEType;identifier=Text;language=bag Locale;publisher=bag ProperName;relation=bag Text;rights=Lang Alt;source=Text;subject=bag Text;title=Lang Alt;type=bag open Choice"),
        ("http://ns.adobe.com/xap/1.0/", "Advisory=bag XPath;BaseURL=URL;CreateDate=Date;CreatorTool=AgentName;Identifier=bag Text;Label=Text;MetadataDate=Date;ModifyDate=Date;Nickname=Text;Rating=Closed Choice;Thumbnails=alt Thumbnail"),
        ("http://ns.adobe.com/xap/1.0/rights/", "Certificate=URL;Marked=Boolean;Owner=bag ProperName;UsageTerms=Lang Alt;WebStatement=URL"),
        ("http://ns.adobe.com/xap/1.0/mm/", "DerivedFrom=ResourceRef;DocumentID=URI;History=seq ResourceEvent;InstanceID=URI;LastURL=URL;ManageTo=URI;ManageUI=URI;ManagedFrom=ResourceRef;Manager=AgentName;ManagerVariant=Text;RenditionClass=RenditionClass;RenditionOf=ResourceRef;RenditionParams=Text;SaveID=Integer;VersionID=Text;Versions=seq Version"),
        ("http://ns.adobe.com/xap/1.0/bj/", "JobRef=bag Job"),
        ("http://ns.adobe.com/xap/1.0/t/pg/", "Colorants=seq Colorant;Fonts=bag Font;MaxPageSize=Dimensions;NPages=Integer;PlateNames=seq Text"),
        ("http://ns.adobe.com/pdf/1.3/", "Keywords=Text;PDFVersion=Text;Producer=AgentName"),
        ("http://ns.adobe.com/photoshop/1.0/", "AuthorsPosition=Text;CaptionWriter=ProperName;Category=Text;City=Text;Country=Text;Credit=Text;DateCreated=Date;Headline=Text;Instructions=Text;Source=Text;State=Text;SupplementalCategories=bag Text;TransmissionReference=Text;Urgency=Integer"),
        ("http://ns.adobe.com/tiff/1.0/", "Artist=ProperName;BitsPerSample=seq Integer;Compression=Closed Choice;Copyright=Lang Alt;DateTime=Date;ImageDescription=Lang Alt;ImageLength=Integer;ImageWidth=Integer;Make=ProperName;Model=ProperName;Orientation=Closed Choice;PhotometricInterpretation=Closed Choice;PlanarConfiguration=Closed Choice;PrimaryChromaticities=seq Rational;ReferenceBlackWhite=seq Rational;ResolutionUnit=Closed Choice;SamplesPerPixel=Integer;Software=AgentName;TransferFunction=seq Integer;WhitePoint=seq Rational;XResolution=Rational;YCbCrCoefficients=seq Rational;YCbCrPositioning=Closed Choice;YCbCrSubSampling=Closed Choice;YResolution=Rational"),
        ("http://ns.adobe.com/exif/1.0/", "ApertureValue=Rational;BrightnessValue=Rational;CFAPattern=CFAPattern;ColorSpace=Closed Choice;ComponentsConfiguration=Closed Choice;CompressedBitsPerPixel=Rational;Contrast=Closed Choice;CustomRendered=Closed Choice;DateTimeDigitized=Date;DateTimeOriginal=Date;DeviceSettingDescription=DeviceSettings;DigitalZoomRatio=Rational;ExifVersion=Closed Choice;ExposureBiasValue=Rational;ExposureIndex=Rational;ExposureMode=Closed Choice;ExposureProgram=Closed Choice;ExposureTime=Rational;FNumber=Rational;FileSource=Closed Choice;Flash=Flash;FlashEnergy=Rational;FlashpixVersion=Closed Choice;FocalLength=Rational;FocalLengthIn35mmFilm=Integer;FocalPlaneResolutionUnit=Closed Choice;FocalPlaneXResolution=Rational;FocalPlaneYResolution=Rational;GPSAltitude=Rational;GPSAltitudeRef=Closed Choice;GPSAreaInformation=Text;GPSDOP=Rational;GPSDestBearing=Rational;GPSDestBearingRef=Closed Choice;GPSDestDistance=Rational;GPSDestDistanceRef=Closed Choice;GPSDestLatitude=GPSCoordinate;GPSDestLongitude=GPSCoordinate;GPSDifferential=Closed choice;GPSImgDirection=Rational;GPSImgDirectionRef=Closed Choice;GPSLatitude=GPSCoordinate;GPSLongitude=GPSCoordinate;GPSMapDatum=Text;GPSMeasureMode=Text;GPSProcessingMethod=Text;GPSSatellites=Text;GPSSpeed=Rational;GPSSpeedRef=Closed Choice;GPSStatus=Closed Choice;GPSTimeStamp=Date;GPSTrack=Rational;GPSTrackRef=Closed Choice;GPSVersionID=Text;GainControl=Closed Choice;ISOSpeedRatings=seq Integer;ImageUniqueID=Text;LightSource=Closed Choice;MaxApertureValue=Rational;MeteringMode=Closed Choice;OECF=OECF/SFR;PixelXDimension=Integer;PixelYDimension=Integer;RelatedSoundFile=Text;Saturation=Closed Choice;SceneCaptureType=Closed Choice;SceneType=Closed Choice;SensingMethod=Closed Choice;Sharpness=Closed Choice;ShutterSpeedValue=Rational;SpatialFrequencyResponse=OECF/SFR;SpectralSensitivity=Text;SubjectArea=seq Integer;SubjectDistance=Rational;SubjectDistanceRange=Closed Choice;SubjectLocation=seq Integer;UserComment=Lang Alt;WhiteBalance=Closed Choice"),
        ("http://ns.adobe.com/camera-raw-settings/1.0/", "AutoBrightness=Boolean;AutoContrast=Boolean;AutoExposure=Boolean;AutoShadows=Boolean;BlueHue=Integer;BlueSaturation=Integer;Brightness=Integer;CameraProfile=Text;ChromaticAberrationB=Integer;ChromaticAberrationR=Integer;ColorNoiseReduction=Integer;Contrast=Integer;CropAngle=Real;CropBottom=Real;CropHeight=Real;CropLeft=Real;CropRight=Real;CropTop=Real;CropUnits=Integer;CropWidth=Real;Exposure=Real;GreenHue=Integer;GreenSaturation=Integer;HasCrop=Boolean;HasSettings=Boolean;LuminanceSmoothing=Integer;RawFileName=Text;RedHue=Integer;RedSaturation=Integer;Saturation=Integer;ShadowTint=Integer;Shadows=Integer;Sharpness=Integer;Temperature=Integer;Tint=Integer;ToneCurve=seq Point;ToneCurveName=open Choice;Version=Text;VignetteAmount=Integer;VignetteMidpoint=Integer;WhiteBalance=Closed Choice"),
        ("http://ns.adobe.com/xmp/1.0/DynamicMedia/", "absPeakAudioFilePath=URI;album=Text;altTapeName=Text;altTimecode=Timecode;artist=Text;audioChannelType=closed Choice;audioCompressor=Text;audioModDate=Date;audioSampleRate=Integer;audioSampleType=closed Choice;beatSpliceParams=beatSpliceStretch;composer=Text;contributedMedia=bag Media;copyright=Text;duration=Time;engineer=Text;fileDataRate=Rational;genre=Text;instrument=Text;introTime=Time;key=closed Choice;logComment=Text;loop=Boolean;markers=seq Marker;metadataModDate=Date;numberOfBeats=Real;outCue=Time;projectRef=ProjectLink;pullDown=closed Choice;relativePeakAudioFilePath=URI;relativeTimestamp=Time;releaseDate=Date;resampleParams=resampleStretch;scaleType=closed Choice;scene=Text;shotDate=Date;shotLocation=Text;shotName=Text;speakerPlacement=Text;startTimecode=Timecode;stretchMode=closed Choice;tapeName=Text;tempo=Real;timeScaleParams=timeScaleStretch;timeSignature=closed Choice;trackNumber=Integer;videoAlphaMode=closed Choice;videoAlphaPremultipleColor=Colorant;videoAlphaUnityIsTransparent=Boolean;videoColorSpace=closed Choice;videoCompressor=Text;videoFieldOrder=closed Choice;videoFrameRate=open Choice;videoFrameSize=Dimensions;videoModDate=Date;videoPixelAspectRatio=Rational;videoPixelDepth=closed Choice"),
    ])
    private static func make(_ groups: [(String, String)]) -> [String: String] {
        var result: [String: String] = [:]
        for (uri, fields) in groups { for field in fields.split(separator: ";") {
            let pieces = field.split(separator: "=", maxSplits: 1).map(String.init)
            if pieces.count == 2 { result["{" + uri + "}" + pieces[0]] = pieces[1] }
        } }
        return result
    }
    static let definedTypes: Set<String> = ["Text", "Boolean", "Integer", "Real", "Date", "URI", "URL", "XPath", "MIMEType", "ProperName", "AgentName", "Locale", "Lang Alt", "Rational", "Dimensions", "Thumbnail", "ResourceRef", "ResourceEvent", "RenditionClass", "Version", "Job", "Font", "Colorant", "Flash", "OECF/SFR", "CFAPattern", "DeviceSettings", "GPSCoordinate", "Timecode", "Time", "Marker", "Media", "ProjectLink", "timeScaleStretch", "resampleStretch", "beatSpliceStretch", "Point", "open Choice", "Schema", "Property", "ValueType", "Field"]
    // Finite vocabularies are transcribed facts from the schema tables, not
    // inferred from corpus outcomes. EXIF version-dependent vocabularies remain unknown.
    static func closedChoice(_ name: ArchiveMetadataName, year: Int) -> String? {
        switch name.uri {
        case ArchiveMetadataNS.xmp:
            return year == 2005 && name.local == "Rating" ? "ApplicationIntegerChoice" : nil
        case "http://ns.adobe.com/tiff/1.0/":
            return ["Compression": "choiceInteger:1|6", "PhotometricInterpretation": "choiceInteger:2|6", "Orientation": "choiceInteger:1|2|3|4|5|6|7|8", "PlanarConfiguration": "choiceInteger:1|2", "ResolutionUnit": "choiceInteger:2|3", "YCbCrPositioning": "choiceInteger:1|2", "YCbCrSubSampling": "choiceSequence:2,1|2,2"][name.local]
        case "http://ns.adobe.com/exif/1.0/":
            if name.local == "ExifVersion" { return "ExifVersion" }
            // JEITA CP-3451C / CIPA DC-008-2012, version-related tags:
            // Flashpix 1.0 is 0100; other codes are reserved. Adobe's edition
            // tables map the same EXIF tag to a closed choice of text.
            if name.local == "FlashpixVersion" { return "choice:0100" }
            if name.local == "GPSMeasureMode" { return year == 2004 ? "choiceInteger:2|3" : nil }
            return ["ColorSpace": "choiceInteger:1|65535", "ComponentsConfiguration": "choiceSequence:4,5,6,0|1,2,3,0", "ExposureProgram": "choiceInteger:0|1|2|3|4|5|6|7|8", "MeteringMode": "choiceInteger:0|1|2|3|4|5|6|255", "LightSource": "choiceInteger:0|1|2|3|4|9|10|11|12|13|14|15|17|18|19|20|21|22|23|24|255", "FocalPlaneResolutionUnit": "choiceInteger:2|3", "SensingMethod": "choiceInteger:1|2|3|4|5|7|8", "FileSource": "choiceInteger:3", "SceneType": "choiceInteger:1", "CustomRendered": "choiceInteger:0|1", "ExposureMode": "choiceInteger:0|1|2", "WhiteBalance": "choiceInteger:0|1", "SceneCaptureType": "choiceInteger:0|1|2|3", "GainControl": "choiceInteger:0|1|2|3|4", "Contrast": "choiceInteger:0|1|2", "Saturation": "choiceInteger:0|1|2", "Sharpness": "choiceInteger:0|1|2", "SubjectDistanceRange": "choiceInteger:0|1|2|3", "GPSAltitudeRef": "choiceInteger:0|1", "GPSStatus": "choice:A|V", "GPSSpeedRef": "choice:K|M|N", "GPSTrackRef": "choice:T|M", "GPSImgDirectionRef": "choice:T|M", "GPSDestBearingRef": "choice:T|M", "GPSDestDistanceRef": "choice:K|M|N", "GPSDifferential": "choiceInteger:0|1"][name.local]
        case "http://ns.adobe.com/camera-raw-settings/1.0/":
            return name.local == "WhiteBalance" ? "choice:As Shot|Auto|Daylight|Cloudy|Shade|Tungsten|Fluorescent|Flash|Custom" : nil
        case "http://ns.adobe.com/xmp/1.0/DynamicMedia/":
            let pullDown = ["WSSWW", "SSWWW", "SWWWS", "WWWSS", "WWSSW"]
            return ["videoPixelDepth": "choice:8Int|16Int|32Int|32Float", "videoColorSpace": "choice:sRGB|CCIR-601|CCIR-709", "videoAlphaMode": "choice:straight|pre-multiplied", "videoFieldOrder": "choice:Upper|Lower|Progressive", "pullDown": "choice:" + (pullDown + pullDown.map { $0 + "_24p" }).joined(separator: "|"), "audioSampleType": "choice:8Int|16Int|32Int|32Float", "audioChannelType": "choice:Mono|Stereo|5.1|7.1", "key": "choice:C|C#|D|D#|E|F|F#|G|G#|A|A#|B", "stretchMode": "choice:Fixed length|Time-Scale|Resample|Beat Splice|Hybrid", "timeSignature": "choice:2/4|3/4|4/4|5/4|7/4|6/8|9/8|12/8|other", "scaleType": "choice:Major|Minor|Both|Neither"][name.local]
        default: return nil
        }
    }
    static func type(_ name: ArchiveMetadataName, year: Int) -> String? {
        if name.uri == ArchiveMetadataNS.id { return ["part": "Integer", "conformance": "Text", "rev": "Text", "amd": "Text", "corr": "Text"][name.local] }
        if name.uri == ArchiveMetadataNS.ext && name.local == "schemas" { return "bag Schema" }
        if name.uri == "http://ns.adobe.com/xmp/Identifier/qual/1.0/" && name.local == "Scheme" { return "Text" }
        if year == 2005, name.uri == "http://ns.adobe.com/exif/1.0/aux/", ["Lens", "SerialNumber"].contains(name.local) { return "Text" }
        return (year == 2004 ? edition2004 : edition2005)[name.expanded]
    }
}

