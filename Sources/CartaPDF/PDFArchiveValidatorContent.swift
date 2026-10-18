import Foundation

struct PDFArchiveContentEvidence {
    struct FontUse {
        let dictionary: [String: PDFSyntaxValue]
        let visible: Bool
        let location: String
        var bytes = Data()
        var renderingMode = 0
        var actualText: String?
        var fontReference: PDFObjectID?
    }
    struct ResourceFont {
        let dictionary: [String: PDFSyntaxValue]
        let location: String
        let reference: PDFObjectID?
    }
    var fonts: [FontUse] = []
    var resourceFonts: [ResourceFont] = []
    // Selection by Tf/ExtGState Font is a reference even without any Tj.
    // The lexical inventory of unused containers never appends here.
    var referencedFonts: [ResourceFont] = []
    var actualTexts: [String] = []
    var actualTextComplete = true
    var undefinedOperators: [String] = []
    var incompleteContexts: [String] = []
    // Lexical inventory includes unused containers; it never creates FontUse.
    var lexicalValues: [PDFSyntaxValue] = []
    var hexLexemes: [(offset:Int,digits:Int,valid:Bool,location:String)] = []
    var maxQDepth = 0
    var lexicalComplete = true
    var lexicalIssues: [String] = []
    var inlineImages:[(dictionary:[String:PDFSyntaxValue],length:Int,reliable:Bool,location:String)] = []
    var undefinedResourceNames: [String] = []
    var inheritedResourceNames: [String] = []
    var resourceScanComplete = true
}

/// Interprets text-bearing contexts without drawing or executing actions.
/// Partial results retain proved violations; unvisited contexts block passes.
final class PDFArchiveContentScanner {
    private let reader: PDFStructureDocument
    private var evidence = PDFArchiveContentEvidence()
    private var operationCount = 0
    private var resourceKeys = Set<String>()
    private var inventoriedContainers = Set<String>()
    private var lexicalContainers = Set<String>()
    private var structureActualText:[String:String] = [:]
    private var pageContext:PDFObjectID?
    private struct State {
        var font: [String: PDFSyntaxValue]?
        var fontReference: PDFObjectID?
        var renderingMode = 0
        var fillPattern: String?
        var strokePattern: String?
        var softMask: PDFSyntaxValue?
    }
    private static let operations = Set("b B b* B* BDC BI BMC BT BX c cm CS cs d d0 d1 Do DP EI EMC ET EX f F f* G g gs h i ID j J K k l m M MP n q Q re RG rg ri s S SC sc SCN scn sh T* Tc Td TD Tf Tj TJ TL Tm Tr Ts Tw Tz v w W W* y ' \"".split(separator: " ").map(String.init))
    init(reader: PDFStructureDocument) { self.reader = reader }
    func scan(allowPartial: Bool = false) throws -> PDFArchiveContentEvidence {
        do { try inventoryStructureActualText() } catch { evidence.actualTextComplete = false;evidence.incompleteContexts.append("ActualText strutturale: " + error.localizedDescription) }
        for (index, page) in try reader.pageIDs().enumerated() {
            pageContext = page
            try Task.checkCancellation()
            let resources = try reader.dictionary(reader.inherited("Resources", pageID: page))
            do {
                lexical(streams: try reader.contentStreamIDs(on:page),resources:resources,location:"pagina \(index + 1)",inherited:false)
                try inventory(resources, location: "pagina \(index + 1)", depth: 0)
                try scan(streams: reader.contentStreamIDs(on: page), resources: resources, initial: State(), location: "pagina \(index + 1)", active: [])
                let pageDictionary = try reader.dictionary(.reference(page))
                for annotation in try reader.resolve(pageDictionary["Annots"])?.array ?? [] {
                    let item = try reader.dictionary(annotation), appearances = try reader.dictionary(item["AP"])
                    for key in ["N", "R", "D"] {
                        if let appearance = appearances[key] { try scanAppearance(appearance, inherited: resources, location: "pagina \(index + 1)/AP/\(key)", depth: 0) }
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { evidence.lexicalComplete = false;evidence.resourceScanComplete = false;evidence.incompleteContexts.append("pagina \(index + 1): " + error.localizedDescription) }
        }
        if !allowPartial, !evidence.incompleteContexts.isEmpty { throw PDFStructureError.unsupported(evidence.incompleteContexts.joined(separator: "; ")) }
        return evidence
    }
    /// Resolve replacement text on structure elements through their actual
    /// MCID/Pg/Stm references, without relying on extracted/searchable text.
    private func inventoryStructureActualText() throws {
        let catalog = try reader.dictionary(.reference(reader.rootID)),root = try reader.dictionary(catalog["StructTreeRoot"])
        var visits = 0
        func walk(_ value:PDFSyntaxValue?,page:PDFObjectID?,text:String?,active:Set<PDFObjectID>,depth:Int) throws {
            guard depth<100 else { throw PDFStructureError.limit };visits += 1;guard visits<=100_000 else { throw PDFStructureError.limit }
            guard let value else { return };var next = active
            if let id = value.reference { guard next.insert(id).inserted else { throw PDFStructureError.unsupported("StructTree K ricorsivo") } }
            guard let resolved = try reader.resolve(value) else { return }
            if let array = resolved.array { for child in array { try walk(child,page:page,text:text,active:next,depth:depth+1) };return }
            func record(_ mcid:Int,_ container:PDFObjectID?) throws {
                guard let text else { return };guard let container,mcid>=0 else { throw PDFStructureError.unsupported("ActualText privo di associazione contenuto/MCID") }
                let key = container.syntax + ":" + String(mcid)
                if let prior = structureActualText[key],prior != text { throw PDFStructureError.unsupported("MCID con ActualText strutturale ambiguo") };structureActualText[key] = text
            }
            if let mcid = resolved.int { try record(mcid,page);return }
            guard let dictionary = resolved.dictionary else { return }
            let localPage = dictionary["Pg"]?.reference ?? page
            var replacement = text
            if let actual = dictionary["ActualText"] { guard let decoded = try reader.resolve(actual)?.text else { throw PDFStructureError.unsupported("ActualText strutturale non decodificabile") };replacement = decoded;evidence.actualTexts.append(decoded) }
            if dictionary["Type"]?.name == "MCR" || dictionary["MCID"] != nil {
                if let mcid = try reader.resolve(dictionary["MCID"])?.int,let replacement {
                    let container = dictionary["Stm"]?.reference ?? localPage
                    guard let container,mcid>=0 else { throw PDFStructureError.unsupported("ActualText MCR senza contenuto/MCID") }
                    let key = container.syntax + ":" + String(mcid)
                    if let prior = structureActualText[key],prior != replacement { throw PDFStructureError.unsupported("MCID con ActualText ambiguo") };structureActualText[key] = replacement
                };return
            }
            try walk(dictionary["K"],page:localPage,text:replacement,active:next,depth:depth+1)
        }
        try walk(root["K"],page:nil,text:nil,active:[],depth:0)
    }
    private func inventory(_ resources: [String: PDFSyntaxValue], location: String, depth: Int) throws {
        guard depth < 60 else { throw PDFStructureError.limit }
        for (name, value) in try reader.dictionary(resources["Font"]) {
            let key = value.reference?.syntax ?? (location + "/Font/" + name)
            if resourceKeys.insert(key).inserted {
                let font = try PDFArchiveFontEncoding.resolvedFontHeader(reader.dictionary(value),reader:reader)
                evidence.resourceFonts.append(.init(dictionary:font,location:location + "/Font/" + name,reference:value.reference))
                if font["Subtype"]?.name == "Type3" {
                    let nested = font["Resources"] == nil ? resources:try reader.dictionary(font["Resources"])
                    for (glyph,procedure) in try reader.dictionary(font["CharProcs"]) {
                        if let id = procedure.reference { lexical(streams:[id],resources:nested,location:location + "/Type3/" + glyph,inherited:font["Resources"] == nil) }
                    }
                    if font["Resources"] != nil { try inventory(nested,location:location + "/Type3",depth:depth+1) }
                }
            }
        }
        for kind in ["XObject", "Pattern"] {
            for (name, value) in try reader.dictionary(resources[kind]) {
                let key = value.reference?.syntax ?? location + "/" + kind + "/" + name
                guard inventoriedContainers.insert(key).inserted else { continue }
                let dictionary = try reader.dictionary(value),nestedLocation = location + "/" + kind + "/" + name
                let nested = dictionary["Resources"] == nil ? resources:try reader.dictionary(dictionary["Resources"])
                if (dictionary["Subtype"]?.name == "Form" || dictionary["PatternType"]?.int == 1),let id = value.reference {
                    lexical(streams:[id],resources:nested,location:nestedLocation,inherited:dictionary["Resources"] == nil)
                }
                if dictionary["Resources"] != nil { try inventory(nested,location:nestedLocation,depth:depth+1) }
            }
        }
        for (name,value) in try reader.dictionary(resources["ExtGState"]) {
            let ext = try reader.dictionary(value),mask = try reader.dictionary(ext["SMask"])
            if let id = mask["G"]?.reference {
                let dictionary = try reader.dictionary(.reference(id)),nested = dictionary["Resources"] == nil ? resources:try reader.dictionary(dictionary["Resources"])
                lexical(streams:[id],resources:nested,location:location + "/ExtGState/" + name + "/SMask/G",inherited:dictionary["Resources"] == nil)
                if inventoriedContainers.insert("mask:" + id.syntax).inserted,dictionary["Resources"] != nil { try inventory(nested,location:location + "/SMask/G",depth:depth+1) }
            }
        }
    }
    /// A separate lexical walk avoids treating fonts in unused Form/Pattern
    /// streams as painted. Resource checks are contextual, never name-only COS.
    private func lexical(streams:[PDFObjectID],resources:[String:PDFSyntaxValue],location:String,inherited:Bool) {
        let signature = streams.map(\.syntax).joined(separator:"|") + PDFSyntaxValue.dictionary(resources).encoded.base64EncodedString()
        guard lexicalContainers.insert(signature).inserted else { return }
        var depth = 0
        for stream in streams {
            do {
                var lexer = PDFSyntaxLexer(try reader.decodedStream(stream));lexer.collectLexicalFacts = true;lexer.strict = true;lexer.allowContentOperators = true
                defer { evidence.hexLexemes += lexer.hexLexemes.map { ($0.offset,$0.digits,$0.valid,location + "/stream " + stream.syntax) } }
                var operands:[PDFSyntaxValue] = []
                while true {
                    try Task.checkCancellation();lexer.skip();if lexer.offset == lexer.bytes.count { break }
                    let token = try lexer.value()
                    guard case .keyword(let operation) = token else {
                        evidence.lexicalValues.append(token);operands.append(token)
                        guard operands.count<=100_000,evidence.lexicalValues.count<=1_000_000 else { throw PDFStructureError.limit };continue
                    }
                    if operation == "BI" {
                        let image = try PDFArchiveInlineImage.read(from:&lexer)
                        if let issue = image.decodingIssue { evidence.lexicalIssues.append(location + "/stream " + stream.syntax + ": " + issue) }
                        evidence.lexicalValues.append(.dictionary(image.dictionary))
                        evidence.inlineImages.append((image.dictionary,image.bytes.count,image.lengthReliable,location + "/stream " + stream.syntax))
                        guard image.lengthReliable else { throw PDFStructureError.unsupported("fine immagine inline ambigua") }
                    }
                    if !Self.operations.contains(operation),!evidence.undefinedOperators.contains(location + ": " + operation) { evidence.undefinedOperators.append(location + ": " + operation) }
                    if operation == "q" { depth += 1;evidence.maxQDepth = max(evidence.maxQDepth,depth) }
                    if operation == "Q" { depth = max(0,depth-1) }
                    var category:String?,name:String?
                    switch operation {
                    case "Tf":category = "Font";if operands.count>=2 { name = operands[operands.count-2].name }
                    case "Do":category = "XObject";name = operands.last?.name
                    case "gs":category = "ExtGState";name = operands.last?.name
                    case "sh":category = "Shading";name = operands.last?.name
                    case "cs","CS":category = "ColorSpace";name = operands.last?.name;if ["DeviceGray","DeviceRGB","DeviceCMYK","Pattern"].contains(name ?? "") { name = nil }
                    case "SCN","scn":category = "Pattern";name = operands.last?.name
                    case "BDC","DP":category = "Properties";name = operands.last?.name
                    default:break
                    }
                    if let category,let name {
                        let path = location + "/" + category + "/" + name
                        if try reader.dictionary(resources[category])[name] == nil { evidence.undefinedResourceNames.append(path) }
                        else if inherited { evidence.inheritedResourceNames.append(path) }
                    }
                    operands.removeAll(keepingCapacity:true)
                }
            } catch {
                evidence.lexicalComplete = false;evidence.resourceScanComplete = false
                if let error = error as? PDFStructureError,case .malformed = error { evidence.lexicalIssues.append(location + "/stream " + stream.syntax + ": " + error.localizedDescription) }
            }
        }
    }
    private func scanAppearance(_ value: PDFSyntaxValue, inherited: [String: PDFSyntaxValue], location: String, depth: Int) throws {
        guard depth < 50 else { throw PDFStructureError.limit }
        if let id = value.reference, try reader.object(id).stream != nil {
            try scanContainer(id, inherited: inherited, initial: State(), location: location, active: [])
        } else {
            for (name, appearance) in try reader.dictionary(value) { try scanAppearance(appearance, inherited: inherited, location: location + "/" + name, depth: depth + 1) }
        }
    }
    private func scanContainer(_ id: PDFObjectID, inherited: [String: PDFSyntaxValue], initial: State, location: String, active: Set<PDFObjectID>) throws {
        guard active.count < 60, !active.contains(id) else { throw PDFStructureError.unsupported("contenuto ricorsivo " + id.syntax) }
        let dictionary = try reader.dictionary(.reference(id))
        let resources = dictionary["Resources"] == nil ? inherited : try reader.dictionary(dictionary["Resources"])
        lexical(streams:[id],resources:resources,location:location,inherited:dictionary["Resources"] == nil)
        try inventory(resources, location: location, depth: 0)
        try scan(streams: [id], resources: resources, initial: initial, location: location, active: active.union([id]))
    }
    private func paintPattern(_ name: String?, resources: [String: PDFSyntaxValue], state: State, location: String, active: Set<PDFObjectID>) throws {
        guard let name, let value = try reader.dictionary(resources["Pattern"])[name] else { return }
        let pattern = try reader.dictionary(value)
        if pattern["PatternType"]?.int == 1 {
            guard let id = value.reference else { throw PDFStructureError.unsupported("Pattern stream diretto") }
            var nested = state; nested.fillPattern = nil; nested.strokePattern = nil
            try scanContainer(id, inherited: resources, initial: nested, location: location + "/Pattern/" + name, active: active)
        }
    }
    private func paintMask(_ state: State, resources: [String: PDFSyntaxValue], location: String, active: Set<PDFObjectID>) throws {
        guard let mask = state.softMask, try reader.resolve(mask)?.name != "None" else { return }
        let dictionary = try reader.dictionary(mask)
        guard let id = dictionary["G"]?.reference else { throw PDFStructureError.unsupported("SMask priva di Form G") }
        var nested = state; nested.softMask = nil
        try scanContainer(id, inherited: resources, initial: nested, location: location + "/SMask/G", active: active)
    }
    private func scan(streams: [PDFObjectID], resources: [String: PDFSyntaxValue], initial: State, location: String, active: Set<PDFObjectID>) throws {
        var state = initial, stack: [State] = [], operands: [PDFSyntaxValue] = [], marked: [String?] = []
        for stream in streams {
            var lexer = PDFSyntaxLexer(try reader.decodedStream(stream))
            lexer.strict = true;lexer.allowContentOperators = true
            while true {
                try Task.checkCancellation(); lexer.skip(); if lexer.offset == lexer.bytes.count { break }
                let token = try lexer.value()
                if case .keyword(let operation) = token {
                    operationCount += 1; guard operationCount <= 1_000_000 else { throw PDFStructureError.limit }
                    if operation == "BI" {
                        let image = try PDFArchiveInlineImage.read(from: &lexer)
                        if !image.lengthReliable { throw PDFStructureError.unsupported("fine immagine inline ambigua") }
                        operands.removeAll(keepingCapacity:true); continue
                    }
                    if !Self.operations.contains(operation) { evidence.undefinedOperators.append(location + ": " + operation) }
                    switch operation {
                    case "q": stack.append(state)
                    case "Q": guard let saved = stack.popLast() else { throw PDFStructureError.malformed("Q senza q") }; state = saved
                    case "Tr": guard let mode = operands.last?.int, (0...7).contains(mode) else { throw PDFStructureError.malformed("Tr") }; state.renderingMode = mode
                    case "Tf":
                        guard operands.count >= 2, let name = operands[operands.count-2].name, let value = try reader.dictionary(resources["Font"])[name] else { throw PDFStructureError.malformed("risorsa Tf assente") }
                        state.font = try PDFArchiveFontEncoding.resolvedFontHeader(reader.dictionary(value),reader:reader); state.fontReference = value.reference
                        evidence.referencedFonts.append(.init(dictionary:state.font!,location:location + "/Font/" + name,reference:value.reference))
                    case "gs":
                        guard let name = operands.last?.name, let value = try reader.dictionary(resources["ExtGState"])[name] else { throw PDFStructureError.malformed("ExtGState assente") }
                        let ext = try reader.dictionary(value)
                        if let font = try reader.resolve(ext["Font"])?.array?.first {
                            state.font = try PDFArchiveFontEncoding.resolvedFontHeader(reader.dictionary(font),reader:reader);state.fontReference = font.reference
                            evidence.referencedFonts.append(.init(dictionary:state.font!,location:location + "/ExtGState/" + name + "/Font",reference:font.reference))
                        }
                        if ext["SMask"] != nil { state.softMask = ext["SMask"] }
                    case "BDC", "BMC":
                        var text: String?
                        if operation == "BDC", let last = operands.last {
                            let property: PDFSyntaxValue?
                            if let name = last.name { property = try reader.dictionary(resources["Properties"])[name] } else { property = last }
                            let dictionary = try reader.dictionary(property)
                            if let value = dictionary["ActualText"] { guard let actual = try reader.resolve(value)?.text else { throw PDFStructureError.unsupported("ActualText non decodificabile") };text = actual;evidence.actualTexts.append(actual) }
                            if text == nil,let mcid = try reader.resolve(dictionary["MCID"])?.int {
                                text = structureActualText[stream.syntax + ":" + String(mcid)]
                                if text == nil,let pageContext { text = structureActualText[pageContext.syntax + ":" + String(mcid)] }
                            }
                        }
                        marked.append(text ?? marked.last.flatMap { $0 })
                    case "EMC": guard !marked.isEmpty else { throw PDFStructureError.malformed("EMC senza marked content") }; marked.removeLast()
                    case "SCN": state.strokePattern = operands.last?.name
                    case "scn": state.fillPattern = operands.last?.name
                    case "Tj", "TJ", "'", "\"":
                        let items = operands.last?.array ?? operands.suffix(1).map { $0 }
                        for bytes in items.compactMap(\.data) where !bytes.isEmpty {
                            guard let font = state.font else { throw PDFStructureError.malformed("testo privo di font") }
                            var use = PDFArchiveContentEvidence.FontUse(dictionary:font,visible:state.renderingMode != 3,location:location + "/stream " + stream.syntax)
                            use.bytes = bytes; use.renderingMode = state.renderingMode; use.fontReference = state.fontReference; use.actualText = marked.last.flatMap { $0 }
                            evidence.fonts.append(use)
                            if font["Subtype"]?.name == "Type3" {
                                let procedures = try reader.dictionary(font["CharProcs"]), nested = font["Resources"] == nil ? resources : try reader.dictionary(font["Resources"])
                                try inventory(nested,location:location + "/Type3",depth:0)
                                for byte in Set(bytes) {
                                    guard let name = try PDFArchiveFontEncoding.glyphName(code:byte,font:font,reader:reader), let id = procedures[name]?.reference else { throw PDFStructureError.unsupported("Type3 glyph/Encoding non risolto") }
                                    try scanContainer(id,inherited:nested,initial:state,location:location + "/Type3/" + name,active:active)
                                }
                            }
                        }
                        if state.renderingMode != 3 { try paintPattern(state.fillPattern,resources:resources,state:state,location:location,active:active); try paintMask(state,resources:resources,location:location,active:active) }
                    case "Do":
                        guard let name = operands.last?.name, let value = try reader.dictionary(resources["XObject"])[name] else { throw PDFStructureError.malformed("XObject assente") }
                        let form = try reader.dictionary(value)
                        if form["Subtype"]?.name == "Form" {
                            guard let id = value.reference else { throw PDFStructureError.unsupported("Form diretto") }
                            try scanContainer(id,inherited:resources,initial:state,location:location + "/Form/" + name,active:active)
                        }
                        try paintMask(state,resources:resources,location:location,active:active)
                    case "f", "F", "f*", "B", "B*", "b", "b*":
                        try paintPattern(state.fillPattern,resources:resources,state:state,location:location,active:active)
                        if ["B","B*","b","b*"].contains(operation) { try paintPattern(state.strokePattern,resources:resources,state:state,location:location,active:active) }
                        try paintMask(state,resources:resources,location:location,active:active)
                    case "S", "s": try paintPattern(state.strokePattern,resources:resources,state:state,location:location,active:active); try paintMask(state,resources:resources,location:location,active:active)
                    default: break
                    }
                    operands.removeAll(keepingCapacity:true)
                } else { operands.append(token); guard operands.count <= 100_000 else { throw PDFStructureError.limit } }
            }
        }
        guard stack.isEmpty, marked.isEmpty else { throw PDFStructureError.malformed("q/Q o marked content non bilanciato") }
    }
}
