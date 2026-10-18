import Foundation

/// Original mechanical logical-structure audit. ISO32000-1 §§7.9,14.7 and
/// the approved PDF2 §14.7 corrections define these typed relationships.
/// This reader never judges the human meaning of a tag or reading order.
final class PDFArchiveLogicalStructureChecks {
    private struct Element {
        let id: PDFObjectID?
        let value: [String: PDFSyntaxValue]
        let location: String
    }
    private struct Content: Hashable { let container: PDFObjectID; let mcid: Int }
    private struct Reference {
        let owner: PDFObjectID?, page: PDFObjectID?, stream: PDFObjectID?, object: PDFObjectID?, mcid: Int?
        let location: String
    }
    private struct Facts {
        var ids = Set<Int>(), nested: [(Int, Int)] = [], invocations: [(Int, PDFObjectID)] = []
        var complete = true
    }
    private let reader: PDFStructureDocument
    private let profile: PDFArchiveProfile
    private var issues: [String] = [], gaps: [String] = []
    private var steps = 0
    private var elements: [Element] = [], seen = Set<PDFObjectID>(), references: [Reference] = []
    private var pages = Set<PDFObjectID>(), parentTree: [Int: PDFSyntaxValue] = [:]
    private var namespaceIDs = Set<PDFObjectID>()
    private var keys: [Int: PDFObjectID] = [:], mcidOwners: [Content: PDFObjectID] = [:], objectOwners: [PDFObjectID: PDFObjectID] = [:]
    private var facts: [PDFObjectID: Facts] = [:]
    private var cached: PDFArchiveRuleResult?
    init(reader: PDFStructureDocument, profile: PDFArchiveProfile) { self.reader = reader; self.profile = profile }

    var modelCheck: PDFArchiveRuleResult? {
        if let cached { return cached }
        guard !reader.encrypted else { return nil }
        do {
            let catalog = try dictionary(.reference(reader.rootID))
            guard let root = try resolved(catalog["StructTreeRoot"]) else { return nil }
            guard root.dictionary != nil else { throw Invalid(L10n.tr("StructTreeRoot non dizionario")) }
            try audit(rootValue: catalog["StructTreeRoot"]!, root: root.dictionary!)
        } catch let error as Invalid { issues.append(error.detail) }
        catch is CancellationError { gaps.append(L10n.tr("Visita strutturale annullata")) }
        catch { gaps.append(L10n.tr("Visita strutturale interrotta: ") + error.localizedDescription) }
        let status: PDFArchiveRuleStatus = !issues.isEmpty ? .failed : gaps.isEmpty ? .passed : .notVerified
        let row = PDFArchiveRuleResult(id: "CartaPDF:ISO32000:logical-structure-mechanics",
            specification: profile.part == 1 ? "PDF Reference 1.4" : profile.part == 4 ? "ISO 32000-2:2020" : "ISO 32000-1:2008",
            clause: profile.part == 1 ? "3.8; 9.7; 9.8" : "7.9; 14.7; 14.8.5", testNumber: "native-logical-structure-mechanics", objectType: "LogicalStructureModel",
            requirement: L10n.tr("Gerarchia, identificatori, riferimenti ai contenuti, ParentTree e attributi strutturali devono avere tipi e relazioni coerenti."),
            status: status,
            detail: L10n.tr("\(elements.count) elementi: verifica meccanica di gerarchia, IDTree, MCID/OBJR e ParentTree, classi/attributi e NS modellati. Significato umano, ordine di lettura e conformità PDF/UA non attestati. ") + Array(Set(gaps)).sorted().joined(separator: "; "),
            locations: Array(issues.prefix(64)))
        cached = row; return row
    }

    private struct Invalid: Error { let detail: String; init(_ detail: String) { self.detail = detail } }
    private func tick(_ depth: Int = 0) throws {
        try Task.checkCancellation(); steps += 1
        guard depth < 100, steps < 1_000_000 else { throw PDFStructureError.limit }
    }
    private func resolved(_ value: PDFSyntaxValue?) throws -> PDFSyntaxValue? {
        try PDFArchiveStructureReferences.resolve(value, reader: reader).value
    }
    private func identity(_ value: PDFSyntaxValue?) throws -> PDFObjectID? {
        try PDFArchiveStructureReferences.resolve(value, reader: reader).id
    }
    private func dictionary(_ value: PDFSyntaxValue?) throws -> [String: PDFSyntaxValue] {
        guard let actual = try resolved(value) else { return [:] }
        guard let dictionary = actual.dictionary else { throw Invalid(L10n.tr("Dizionario strutturale richiesto")) }
        return dictionary
    }
    private func present(_ key: String, _ value: [String: PDFSyntaxValue]) throws -> Bool { try resolved(value[key]) != nil }
    private func page(_ value: PDFSyntaxValue?, _ location: String, required: Bool = false) throws -> PDFObjectID? {
        guard let actual = try resolved(value) else {
            if required { issues.append(location + L10n.tr(": Pg richiesto")) }; return nil
        }
        guard let id = try identity(value), actual.dictionary != nil, pages.contains(id) else {
            issues.append(location + L10n.tr(": Pg deve riferire una pagina indiretta del documento")); return nil
        }
        return id
    }
    private func audit(rootValue: PDFSyntaxValue, root: [String: PDFSyntaxValue]) throws {
        pages = Set(try reader.pageIDs())
        if try resolved(root["Type"])?.name != "StructTreeRoot" { issues.append(L10n.tr("StructTreeRoot/Type non valido")) }
        if let k = root["K"] { try children(k, parent: .init(id: try identity(rootValue), value: root, location: "StructTreeRoot"), rootChildren: true, depth: 0) }
        parentTree = try numberTree(root["ParentTree"], "ParentTree")
        if let next = try resolved(root["ParentTreeNextKey"]) {
            guard let value = next.int else { throw Invalid(L10n.tr("ParentTreeNextKey non intero")) }
            if let maximum = parentTree.keys.max(), value <= maximum { issues.append(L10n.tr("ParentTreeNextKey non supera tutte le chiavi")) }
        }
        try identifiers(root)
        try namespaces(root)
        for (name, value) in try dictionary(root["RoleMap"]) {
            guard try resolved(value) != nil else { continue }
            if try resolved(value)?.name == nil { issues.append(L10n.tr("RoleMap/\(name): target non Name")) }
        }
        let classes = try dictionary(root["ClassMap"])
        for (name, value) in classes where try resolved(value) != nil {
            try attributeObjects(value, revisionPairs: false, location: "ClassMap/" + name)
        }
        for element in elements {
            if let r = try resolved(element.value["R"]), r.int == nil || r.int! < 0 { issues.append(element.location + L10n.tr("/R non intero non negativo")) }
            // §7.3.9 makes an optional dictionary entry whose value resolves
            // to null equivalent to an absent entry. Null array members keep
            // their separate, explicitly forbidden grammar below.
            if let a = try resolved(element.value["A"]) { try attributeObjects(a, revisionPairs: true, location: element.location + "/A") }
            if let c = try resolved(element.value["C"]) { try attributeClasses(c, location: element.location + "/C") }
            if profile.part == 4, let ref = try resolved(element.value["Ref"]) {
                guard let values = ref.array else { issues.append(element.location + L10n.tr("/Ref non array")); continue }
                for value in values {
                    if let id = try identity(value), seen.contains(id) { continue }
                    issues.append(element.location + L10n.tr("/Ref non riferisce un elemento dell’albero"))
                }
            }
        }
        for reference in references { try forward(reference) }
        try reverse()
        let attributes = PDFArchiveStructureAttributeChecks(reader: reader, profile: profile).audit(root: root,
            elements: elements.map { .init(value: $0.value, location: $0.location) })
        issues += attributes.issues; gaps += attributes.gaps
    }

    private func children(_ value: PDFSyntaxValue, parent: Element, rootChildren: Bool, depth: Int) throws {
        try tick(depth)
        guard let actual = try resolved(value) else {
            if profile.part == 4 { issues.append(parent.location + "/K null vietato in PDF2") }; return
        }
        if let values = actual.array {
            for (index, child) in values.enumerated() {
                if try resolved(child)?.array != nil { issues.append(parent.location + L10n.tr("/K[\(index)] array annidato non ammesso")); continue }
                if try resolved(child) == nil { issues.append(parent.location + L10n.tr("/K[\(index)] null non è un figlio strutturale")); continue }
                try children(child, parent: parent, rootChildren: rootChildren, depth: depth + 1)
            }
            return
        }
        if let mcid = actual.int {
            if rootChildren { issues.append(L10n.tr("StructTreeRoot/K può contenere solo StructElem")); return }
            if mcid < 0 { issues.append(parent.location + L10n.tr(": MCID negativo")); return }
            let pg = try page(parent.value["Pg"], parent.location, required: true)
            references.append(.init(owner: parent.id, page: pg, stream: nil, object: nil, mcid: mcid, location: parent.location + "/K"))
            return
        }
        guard let dictionary = actual.dictionary else { issues.append(parent.location + L10n.tr("/K: tipo figlio non valido")); return }
        let type = try resolved(dictionary["Type"])?.name, location = value.reference?.syntax ?? parent.location + "/K diretto"
        if !rootChildren, type == "MCR" || type == "OBJR" {
            let pgValue = try present("Pg", dictionary) ? dictionary["Pg"] : parent.value["Pg"]
            let pg = try page(pgValue, location, required: true)
            if type == "OBJR" {
                guard let object = try identity(dictionary["Obj"]), try resolved(dictionary["Obj"])?.dictionary != nil else {
                    issues.append(location + L10n.tr(": OBJR/Obj deve essere un riferimento indiretto con StructParent")); return
                }
                references.append(.init(owner: parent.id, page: pg, stream: nil, object: object, mcid: nil, location: location))
            } else {
                guard let mcid = try resolved(dictionary["MCID"])?.int, mcid >= 0 else { issues.append(location + L10n.tr(": MCR/MCID non intero/non negativo")); return }
                var stream: PDFObjectID?
                if try present("Stm", dictionary) {
                    guard let id = try identity(dictionary["Stm"]), try reader.object(id).stream != nil else { issues.append(location + L10n.tr(": MCR/Stm non stream indiretto")); return }
                    stream = id
                }
                if try present("StmOwn", dictionary), try identity(dictionary["StmOwn"]) == nil { issues.append(location + L10n.tr(": StmOwn non indiretto")) }
                references.append(.init(owner: parent.id, page: pg, stream: stream, object: nil, mcid: mcid, location: location))
            }
            return
        }
        if type != nil && type != "StructElem" { issues.append(location + L10n.tr(": Type non StructElem")); return }
        if try resolved(dictionary["S"])?.name == nil { issues.append(location + L10n.tr(": S non Name")) }
        if let expected = parent.id {
            if try identity(dictionary["P"]) != expected { issues.append(location + L10n.tr(": P non corrisponde al parent indiretto")) }
        } else { issues.append(location + L10n.tr(": parent diretto non può essere destinazione di P indiretto")) }
        let elementID = try identity(value)
        if let id = elementID, !seen.insert(id).inserted { issues.append(location + L10n.tr(": StructElem condiviso/circolare")); return }
        let element = Element(id: elementID, value: dictionary, location: location)
        elements.append(element)
        if try present("Pg", dictionary) { _ = try page(dictionary["Pg"], location) }
        if let k = dictionary["K"] { try children(k, parent: element, rootChildren: false, depth: depth + 1) }
    }

    private func numberTree(_ value: PDFSyntaxValue?, _ location: String) throws -> [Int: PDFSyntaxValue] {
        guard let actual = try resolved(value) else { return [:] }
        var output: [Int: PDFSyntaxValue] = [:], visited = Set<PDFObjectID>()
        func walk(_ value: PDFSyntaxValue, depth: Int) throws -> (Int, Int)? {
            try tick(depth)
            if let id = try identity(value), !visited.insert(id).inserted { throw Invalid(location + L10n.tr(": nodo condiviso/circolare")) }
            let d = try dictionary(value), numsValue = try resolved(d["Nums"]), kidsValue = try resolved(d["Kids"])
            let nums = numsValue?.array, kids = kidsValue?.array
            if numsValue != nil && nums == nil || kidsValue != nil && kids == nil { throw Invalid(location + L10n.tr(": Nums/Kids non array")) }
            guard (nums != nil) != (kids != nil) else { throw Invalid(location + L10n.tr(": un solo Nums o Kids richiesto")) }
            var low: Int?, high: Int?
            if let nums {
                guard nums.count % 2 == 0 else { throw Invalid(location + L10n.tr(": coppie Nums incomplete")) }
                for index in stride(from: 0, to: nums.count, by: 2) {
                    guard let key = try resolved(nums[index])?.int, output[key] == nil, high == nil || key > high! else { throw Invalid(location + L10n.tr(": chiavi duplicate/non intere/non ordinate")) }
                    output[key] = nums[index + 1]; low = low ?? key; high = key
                }
            } else if let kids {
                guard !kids.isEmpty else { throw Invalid(location + L10n.tr(": Kids vuoto")) }
                for child in kids {
                    guard try identity(child) != nil else { throw Invalid(location + L10n.tr(": Kids deve contenere riferimenti indiretti")) }
                    if let range = try walk(child, depth: depth + 1) {
                        if let high, range.0 <= high { throw Invalid(location + L10n.tr(": intervalli Kids sovrapposti/non ordinati")) }
                        low = low ?? range.0; high = range.1
                    }
                }
            }
            if let limits = try resolved(d["Limits"]) {
                if depth == 0 { throw Invalid(location + L10n.tr(": Limits vietato nel nodo root")) }
                guard let values = limits.array, values.count == 2, let a = try resolved(values[0])?.int, let b = try resolved(values[1])?.int,
                      a == low, b == high else { throw Invalid(location + L10n.tr(": Limits non corrisponde alle chiavi effettive")) }
            } else if depth > 0 { throw Invalid(location + L10n.tr(": Limits obbligatorio nel nodo non root")) }
            return low.flatMap { a in high.map { (a, $0) } }
        }
        _ = try walk(actual, depth: 0); return output
    }

    private func identifiers(_ root: [String: PDFSyntaxValue]) throws {
        var ids: [Data: Element] = [:]
        for element in elements {
            guard let value = try resolved(element.value["ID"]) else { continue }
            guard let id = value.data else { issues.append(element.location + L10n.tr("/ID non byte string")); continue }
            if ids[id] != nil { issues.append(element.location + "/ID duplicato") }; ids[id] = element
        }
        guard let tree = try resolved(root["IDTree"]) else {
            if !ids.isEmpty { issues.append(L10n.tr("IDTree richiesto per gli elementi con ID")) }; return
        }
        var found = Set<Data>(), nodes = Set<PDFObjectID>()
        func walk(_ value: PDFSyntaxValue, depth: Int) throws -> (Data, Data)? {
            try tick(depth)
            if let id = try identity(value), !nodes.insert(id).inserted { throw Invalid(L10n.tr("IDTree condiviso/circolare")) }
            let d = try dictionary(value)
            let namesValue = try resolved(d["Names"]), kidsValue = try resolved(d["Kids"])
            guard (namesValue != nil) != (kidsValue != nil) else { throw Invalid(L10n.tr("IDTree: un solo Names o Kids richiesto")) }
            var low: Data?, high: Data?
            if let namesValue {
                guard let names = namesValue.array else { throw Invalid(L10n.tr("IDTree/Names non array")) }
                guard names.count % 2 == 0 else { throw Invalid(L10n.tr("IDTree/Names non coppie")) }
                for index in stride(from: 0, to: names.count, by: 2) {
                    guard let key = try resolved(names[index])?.data, !found.contains(key), high == nil || high!.lexicographicallyPrecedes(key) else { throw Invalid(L10n.tr("IDTree: chiavi duplicate/non byte string/non ordinate")) }
                    found.insert(key); low = low ?? key; high = key
                    guard let element = ids[key] else { issues.append(L10n.tr("IDTree contiene ID senza elemento corrispondente")); continue }
                    if let id = element.id {
                        if try identity(names[index + 1]) != id { issues.append(element.location + L10n.tr(": IDTree punta all’elemento errato")) }
                    } else { gaps.append(L10n.tr("Identità IDTree di StructElem diretto non provata")) }
                }
            }
            if let kidsValue {
                guard let kids = kidsValue.array, !kids.isEmpty else { throw Invalid(L10n.tr("IDTree/Kids non array o vuoto")) }
                for child in kids {
                    guard try identity(child) != nil else { throw Invalid(L10n.tr("IDTree/Kids non indiretto")) }
                    if let range = try walk(child, depth: depth + 1) {
                        if let high, !high.lexicographicallyPrecedes(range.0) { throw Invalid(L10n.tr("IDTree: intervalli Kids sovrapposti/non ordinati")) }
                        low = low ?? range.0; high = range.1
                    }
                }
            }
            if let limits = try resolved(d["Limits"]) {
                guard depth > 0, let array = limits.array, array.count == 2,
                      let a = try resolved(array[0])?.data, let b = try resolved(array[1])?.data,
                      a == low, b == high else { throw Invalid(L10n.tr("IDTree: Limits non valido per il nodo")) }
            } else if depth > 0 { throw Invalid(L10n.tr("IDTree: Limits richiesto nel nodo non root")) }
            return low.flatMap { a in high.map { (a, $0) } }
        }
        _ = try walk(tree, depth: 0)
        if found != Set(ids.keys) { issues.append(L10n.tr("IDTree non comprende tutti gli ID degli elementi")) }
    }

    private func namespaces(_ root: [String: PDFSyntaxValue]) throws {
        guard profile.part == 4 else { return }
        if let declared = try resolved(root["Namespaces"]) {
            guard let values = declared.array else { throw Invalid(L10n.tr("Namespaces non array")) }
            for value in values {
                guard let id = try identity(value), try resolved(value)?.dictionary != nil else { issues.append(L10n.tr("Namespaces contiene un valore non dizionario indiretto")); continue }
                namespaceIDs.insert(id)
            }
        }
        for element in elements {
            guard try present("NS", element.value) else { continue }
            guard let id = try identity(element.value["NS"]), namespaceIDs.contains(id) else {
                issues.append(element.location + L10n.tr(": NS deve essere indiretto e presente in Namespaces")); continue
            }
        }
        for id in namespaceIDs {
            let d = try dictionary(.reference(id))
            if let type = try resolved(d["Type"]), type.name != "Namespace" { issues.append(id.syntax + L10n.tr(": Type namespace errato")) }
            if let ns = try resolved(d["NS"]), ns.data == nil { issues.append(id.syntax + L10n.tr(": nome NS non text string")) }
            if let map = try resolved(d["RoleMapNS"]) {
                guard let values = map.dictionary else { issues.append(id.syntax + L10n.tr(": RoleMapNS non dizionario")); continue }
                for (name, value) in values {
                    let actual = try resolved(value)
                    guard let actual else { continue }
                    if actual.name != nil { continue }
                    if let pair = actual.array, pair.count == 2, try resolved(pair[0])?.name != nil, let target = try identity(pair[1]),
                       try reader.object(target).value.dictionary != nil { continue }
                    issues.append(id.syntax + "/RoleMapNS/" + name + L10n.tr(": target non Name o coppia Name/Namespace indiretto"))
                }
            }
        }
    }

    private func attributeObjects(_ value: PDFSyntaxValue, revisionPairs: Bool, location: String) throws {
        guard let actual = try resolved(value) else { if profile.part == 4 { issues.append(location + L10n.tr(": attributo null")) }; return }
        if let array = actual.array {
            var mayHaveRevision = false
            for item in array {
                let actualItem = try resolved(item)
                if let number = actualItem?.int {
                    if !revisionPairs || !mayHaveRevision || number < 0 { issues.append(location + L10n.tr(": revisione non associata/non negativa")) }
                    mayHaveRevision = false
                } else {
                    if actualItem?.array != nil || actualItem == nil {
                        issues.append(location + L10n.tr(": elemento attributo null/array annidato")); mayHaveRevision = false; continue
                    }
                    try attributeObjects(item, revisionPairs: false, location: location)
                    mayHaveRevision = true
                }
            }
        } else if let dictionary = actual.dictionary {
            guard let owner = try resolved(dictionary["O"])?.name else { issues.append(location + L10n.tr(": O richiesto di tipo Name")); return }
            if profile.part == 4, owner == "NSO", try resolved(dictionary["NS"])?.dictionary == nil { issues.append(location + L10n.tr(": attributo NSO senza namespace NS")) }
        } else { issues.append(location + L10n.tr(": attributo non dizionario/stream")) }
    }
    private func attributeClasses(_ value: PDFSyntaxValue, location: String) throws {
        guard let actual = try resolved(value) else { if profile.part == 4 { issues.append(location + L10n.tr(": classi null")) }; return }
        if actual.name != nil { return }
        guard let values = actual.array else { issues.append(location + L10n.tr(": C non Name/array")); return }
        var mayHaveRevision = false
        for item in values {
            let value = try resolved(item)
            if value?.name != nil { mayHaveRevision = true }
            else if let revision = value?.int, revision >= 0, mayHaveRevision { mayHaveRevision = false }
            else { issues.append(location + L10n.tr(": classe o revisione non valida")); mayHaveRevision = false }
        }
        // A missing ClassMap name denotes an empty class (PDF2 approved note);
        // it must not be invented to be an undefined resource violation.
    }

    private func forward(_ reference: Reference) throws {
        guard let owner = reference.owner else { gaps.append(reference.location + L10n.tr(": contenuto con parent StructElem diretto")); return }
        if let object = reference.object {
            let d = try dictionary(.reference(object))
            try ownershipKey(d, object: object, singular: true, location: reference.location)
            guard let key = try resolved(d["StructParent"])?.int, try identity(parentTree[key]) == owner else { issues.append(reference.location + L10n.tr(": OBJR non ricambia ParentTree")); return }
            if let previous = objectOwners[object], previous != owner { issues.append(reference.location + L10n.tr(": OBJR attribuito a parent diversi")) }
            objectOwners[object] = owner
        } else if let page = reference.page, let mcid = reference.mcid {
            var container = reference.stream ?? page
            if let stream = reference.stream, try PDFArchiveStructureReferences.contentStreams(on: page, reader: reader).contains(stream) { container = page }
            let d = try dictionary(.reference(container))
            try ownershipKey(d, object: container, singular: false, location: reference.location)
            guard let key = try resolved(d["StructParents"])?.int, let array = try resolved(parentTree[key])?.array,
                  array.indices.contains(mcid), try identity(array[mcid]) == owner else { issues.append(reference.location + L10n.tr(": MCR/MCID non ricambia ParentTree")); return }
            let item = Content(container: container, mcid: mcid)
            if let previous = mcidOwners[item], previous != owner { issues.append(reference.location + L10n.tr(": MCID attribuito a parent diversi")) }
            mcidOwners[item] = owner
            let actual = try scan(container)
            if !actual.ids.contains(mcid) {
                if actual.complete { issues.append(reference.location + L10n.tr(": MCID non presente in BDC")) }
                else { gaps.append(reference.location + L10n.tr(": MCID non risolto dopo confine inline ambiguo")) }
            }
        }
    }
    private func ownershipKey(_ d: [String: PDFSyntaxValue], object: PDFObjectID, singular: Bool, location: String) throws {
        if try present("StructParent", d), try present("StructParents", d) { issues.append(location + L10n.tr(": StructParent e StructParents entrambi presenti")) }
        let name = singular ? "StructParent" : "StructParents"
        guard let key = try resolved(d[name])?.int else { issues.append(location + L10n.tr(": \(name) intero richiesto")); return }
        if let previous = keys[key], previous != object { issues.append(location + L10n.tr(": chiave ParentTree condivisa da contenitori diversi")) }
        keys[key] = object
    }
    private func reverse() throws {
        for (key, value) in parentTree {
            if let values = try resolved(value)?.array {
                for (mcid, value) in values.enumerated() {
                    guard try resolved(value) != nil else { continue }
                    guard let owner = try identity(value), seen.contains(owner), let container = keys[key], mcidOwners[.init(container: container, mcid: mcid)] == owner else {
                        issues.append(L10n.tr("ParentTree[\(key)][\(mcid)] senza corrispondente K/MCR del parent")); continue
                    }
                }
            } else {
                guard let owner = try identity(value), seen.contains(owner), let object = keys[key], objectOwners[object] == owner else {
                    issues.append(L10n.tr("ParentTree[\(key)] senza corrispondente K/OBJR del parent")); continue
                }
            }
        }
        for (container, facts) in facts {
            for (a, b) in facts.nested where mcidOwners[.init(container: container, mcid: a)] != nil && mcidOwners[.init(container: container, mcid: b)] != nil {
                issues.append(container.syntax + L10n.tr(": content item MCID \(b) annidato nel content item \(a)"))
            }
            for (mcid, object) in facts.invocations where mcidOwners[.init(container: container, mcid: mcid)] != nil && objectOwners[object] != nil {
                issues.append(container.syntax + L10n.tr(": content item MCID \(mcid) invoca XObject che è un content item intero"))
            }
        }
    }
    private func scan(_ container: PDFObjectID) throws -> Facts {
        if let cached = facts[container] { return cached }
        let resources: [String: PDFSyntaxValue], data: Data, resourcesKnown: Bool
        if pages.contains(container) {
            resourcesKnown = true
            resources = try dictionary(reader.inherited("Resources", pageID: container))
            var bytes = Data()
            for id in try PDFArchiveStructureReferences.contentStreams(on: container, reader: reader) {
                bytes += try reader.decodedStream(id); bytes.append(32)
                guard bytes.count <= 128 * 1024 * 1024 else { throw PDFStructureError.limit }
            }
            data = bytes
        } else {
            let object = try reader.object(container)
            guard object.stream != nil else { throw Invalid(container.syntax + L10n.tr(": contenitore MCID non stream")) }
            resourcesKnown = try resolved(object.value.dictionary?["Resources"]) != nil
            resources = try dictionary(object.value.dictionary?["Resources"]); data = try reader.decodedStream(container)
        }
        let properties = try dictionary(resources["Properties"])
        var result = Facts(), lexer = PDFSyntaxLexer(data), operands: [PDFSyntaxValue] = [], stack: [Int?] = []
        while true {
            try tick(); lexer.skip(); if lexer.offset == lexer.bytes.count { break }
            let value = try lexer.value()
            if case .keyword(let op) = value {
                if op == "BI" {
                    let image = try PDFArchiveInlineImage.read(from: &lexer)
                    if !image.lengthReliable { result.complete = false; break }
                } else if op == "BDC" {
                    var mcid: Int?
                    if let property = operands.last {
                        if property.name != nil && !resourcesKnown {
                            result.complete = false; gaps.append(container.syntax + L10n.tr(": proprietà nominali con risorse ereditate non provate"))
                            stack.append(nil); operands.removeAll(keepingCapacity: true); continue
                        }
                        let d = try dictionary(property.name.flatMap { properties[$0] } ?? property)
                        if let value = try resolved(d["MCID"]) {
                            if let id = value.int, id >= 0 {
                                mcid = id
                                if !result.ids.insert(id).inserted { issues.append(container.syntax + L10n.tr(": MCID BDC duplicato")) }
                                if let outer = stack.compactMap({ $0 }).last { result.nested.append((outer, id)) }
                            } else { issues.append(container.syntax + L10n.tr(": MCID BDC non intero/non negativo")) }
                        }
                    }
                    stack.append(mcid)
                } else if op == "BMC" { stack.append(nil) }
                else if op == "EMC" {
                    if stack.isEmpty { issues.append(container.syntax + L10n.tr(": EMC senza BMC/BDC")) } else { stack.removeLast() }
                } else if op == "Do", let mcid = stack.compactMap({ $0 }).last, let name = operands.last?.name {
                    if !resourcesKnown { result.complete = false; gaps.append(container.syntax + L10n.tr(": invocazione con risorse ereditate non provate")) }
                    else if let object = try identity(dictionary(resources["XObject"])[name]) { result.invocations.append((mcid, object)) }
                }
                operands.removeAll(keepingCapacity: true)
            } else { operands.append(value); guard operands.count < 100_000 else { throw PDFStructureError.limit } }
        }
        if result.complete && !stack.isEmpty { issues.append(container.syntax + L10n.tr(": BMC/BDC senza EMC")) }
        if !result.complete { gaps.append(container.syntax + L10n.tr(": inventario MCID incompleto dopo immagine inline")) }
        facts[container] = result; return result
    }
}

/// Preserve the terminal indirect identity while following ordinary aliases
/// (§7.3.10). Reading each object body prevents a general reader resolver from
/// collapsing the chain before its identity has been established.
enum PDFArchiveStructureReferences {
    static func resolve(_ original: PDFSyntaxValue?, reader: PDFStructureDocument) throws -> (value: PDFSyntaxValue?, id: PDFObjectID?) {
        var value = original, terminal: PDFObjectID?, seen = Set<PDFObjectID>()
        while let id = value?.reference {
            try Task.checkCancellation()
            guard seen.insert(id).inserted, seen.count <= 100 else { throw PDFStructureError.unsupported(L10n.tr("riferimenti strutturali circolari/profondi")) }
            terminal = id
            do { value = try reader.object(id).value }
            catch {
                // Undefined/free references have null semantics. An existing
                // malformed object retains the original parsing failure.
                if case .null? = try reader.resolve(.reference(id)) { return (nil, nil) }
                throw error
            }
        }
        if case .null? = value { return (nil, nil) }
        return (value, terminal)
    }
    static func contentStreams(on page: PDFObjectID, reader: PDFStructureDocument) throws -> [PDFObjectID] {
        let pageValue = try resolve(.reference(page), reader: reader).value
        let raw = pageValue?.dictionary?["Contents"]
        guard let actual = try resolve(raw, reader: reader).value else { return [] }
        let values = actual.array ?? raw.map { [$0] } ?? []
        return try values.map { value in
            guard let id = try resolve(value, reader: reader).id, try reader.object(id).stream != nil else {
                throw PDFStructureError.malformed(L10n.tr("Contents strutturale non stream indiretto"))
            }
            return id
        }
    }
}
