import Foundation

/// Physical facts retained separately from decoded COS values. Odd hexadecimal
/// strings and object spacing cannot be recovered from normalized PDF objects.
final class PDFArchiveSyntaxChecks {
    private let reader: PDFStructureDocument
    private var scanned = false
    private var oddHex: [String] = [], invalidHex: [String] = [], spacing: [String] = [], streamEOL: [String] = [], lengths: [String] = []
    private var issues: [String] = [], unknown: [String] = []
    private var objectCount = 0, streamCount = 0, hexCount = 0
    private var contentLexicalComplete = true
    init(reader: PDFStructureDocument) { self.reader = reader }
    func evaluate(_ rule: PDFArchiveCatalogueRule) throws -> PDFArchiveRuleEvaluation? {
        ensureScanned()
        let object = rule.objectType, expression = rule.expression
        func check(_ failures:[String], count:Int, detail:String) -> PDFArchiveRuleEvaluation {
            if !failures.isEmpty { return .check(false,detail,locations:failures) }
            if !unknown.isEmpty || ((object == "CosString") && !contentLexicalComplete) { return .unknown(detail + " " + unknown.prefix(8).joined(separator:"; ") + (contentLexicalComplete ? "" : " Inventario lessicale dei contenuti incompleto.")) }
            return count == 0 ? .absent(detail) : .check(true,detail)
        }
        if object == "CosString", expression.contains("hexCount") { return check(oddHex,count:hexCount,detail:"Numero pari di cifre esadecimali, prima del padding del lettore PDF.") }
        if object == "CosString", expression.contains("containsOnlyHex") { return check(invalidHex,count:hexCount,detail:"Solo cifre 0–9/A–F/a–f nelle stringhe esadecimali.") }
        if object == "CosIndirect", expression == "spacingCompliesPDFA" { return check(spacing,count:objectCount,detail:"Spazi singoli negli header oggetto ed EOL intorno a obj/endobj.") }
        if object == "CosStream", expression.contains("streamKeywordCRLFCompliant") { return check(streamEOL,count:streamCount,detail:"stream seguito da LF/CRLF; EOL prima di endstream.") }
        if object == "CosStream", expression == "Length == realLength" { return check(lengths,count:streamCount,detail:"Length confrontata con i byte tra stream e l’EOL prima di endstream.") }
        if object == "CosDocument", expression.contains("isLinearized") {
            let directs = reader.revisions.flatMap { revision in revision.entries.compactMap { number, entry -> (Int,Int)? in if case .direct(let offset,_) = entry { return (number,offset) }; return nil } }
            guard let first = directs.min(by:{ $0.1 < $1.1 }) else { return .unknown("Primo oggetto non individuato.") }
            var lexer = PDFSyntaxLexer(reader.source,offset:first.1); _ = try lexer.word(); _ = try lexer.word(); _ = try lexer.word()
            let linearized = try lexer.value().dictionary?["Linearized"]?.real == 1
            let final = reader.revisions.first { $0.offset == reader.lastXref }?.dictionary ?? [:]
            let firstPage = reader.revisions.min(by:{ $0.offset < $1.offset })?.dictionary ?? [:]
            if expression.contains("firstPageID == lastID") {
                guard linearized, let last = final["ID"] else { return .check(true,"Condizione ID linearizzato non applicabile oppure ultimo ID assente.") }
                return .check(firstPage["ID"]?.encoded == last.encoded,"ID dei trailer pagina iniziale e finale confrontati.")
            }
            return .check((linearized ? firstPage["ID"] : final["ID"]) != nil,"ID nel trailer richiesto per file linearizzato o ordinario.")
        }
        return nil
    }
    func modelResult() -> PDFArchiveRuleResult {
        ensureScanned()
        let modelIssues = issues + streamEOL.map { $0 + ": EOL stream/endstream non valida" } + lengths.map { $0 + ": Length non valida" }
        let status:PDFArchiveRuleStatus = !modelIssues.isEmpty ? .failed : (!unknown.isEmpty ? .notVerified : .passed)
        return .init(id:"CartaPDF:ISO32000:physical-syntax",specification:"ISO 32000",clause:"7.3–7.5",testNumber:"native-syntax",objectType:"PhysicalSyntax",
            requirement:"Sintassi lessicale degli oggetti indicizzati, terminatori e riferimenti xref.",
            status:status,detail:modelIssues.isEmpty ? (unknown.isEmpty ? "Controllati \(objectCount) oggetti e \(streamCount) stream, incluse revisioni xref ibride." : unknown.joined(separator:"; ")) : modelIssues.joined(separator:"; "),locations:[])
    }
    private func ensureScanned() {
        guard !scanned else { return }
        scanned = true
        do { try scan() } catch { unknown.append(error.localizedDescription) }
    }
    private func scan() throws {
        let bytes = reader.sourceBytes
        var seen = Set<Int>()
        var physicalStreams:[Int:(dictionary:[String:PDFSyntaxValue],start:Int)] = [:]
        for revision in reader.revisions {
            try Task.checkCancellation()
            let revisionReader = try reader.revisionReader(at:revision.offset)
            try verifyClassicXref(revision.offset)
            for (number,entry) in revision.entries {
                guard case .direct(let offset,let generation) = entry else { continue }
                let location = "oggetto \(number) \(generation), byte \(offset)"
                // Physical header facts are deduplicated. An indirect N/First,
                // Length or Filter can still change the stream's interpretation
                // when the same offset is republished in another revision.
                guard seen.insert(offset).inserted else {
                    if let stream = physicalStreams[offset] {
                        do { try verifyPhysicalObjectStream(stream.dictionary,start:stream.start,revisionReader:revisionReader,location:location + ", revisione xref \(revision.offset)") }
                        catch { if error is CancellationError { throw error };recordSyntaxError(error,location:location) }
                    }
                    continue
                }
                objectCount += 1
                var lexer = PDFSyntaxLexer(bytes:bytes,offset:offset)
                lexer.strict = true; lexer.collectLexicalFacts = true
                do {
                    let n = try lexer.word(), endNumber = lexer.offset
                    let g = try lexer.word(), endGeneration = lexer.offset
                    let obj = try lexer.word(), endHeader = lexer.offset
                    if Int(n) != number || Int(g) != generation || obj != "obj" { issues.append(location + ": xref/header discordanti"); continue }
                    let startGeneration = endGeneration - g.utf8.count, startObj = endHeader - 3
                    if offset == 0 || ![10,13].contains(bytes[offset - 1]) || startGeneration != endNumber + 1 ||
                        startObj != endGeneration + 1 || !PDFSyntaxLexer.space(bytes[endNumber]) ||
                        !PDFSyntaxLexer.space(bytes[endGeneration]) || endHeader >= bytes.count || ![10,13].contains(bytes[endHeader]) { spacing.append(location) }
                    let value = try lexer.value()
                    hexCount += lexer.hexLexemes.count
                    oddHex += lexer.hexLexemes.filter { $0.digits % 2 != 0 }.map { location + ", hex byte \($0.offset)" }
                    invalidHex += lexer.hexLexemes.filter { !$0.valid }.map { location + ", hex byte \($0.offset)" }
                    lexer.skip()
                    let next = try lexer.word()
                    if next == "stream", let dictionary = value.dictionary {
                        streamCount += 1
                        if lexer.offset >= bytes.count { issues.append(location + ": stream troncato"); continue }
                        if bytes[lexer.offset] == 13, lexer.offset + 1 < bytes.count, bytes[lexer.offset + 1] == 10 { lexer.offset += 2 }
                        else if bytes[lexer.offset] == 10 { lexer.offset += 1 }
                        else { streamEOL.append(location); if bytes[lexer.offset] == 13 { lexer.offset += 1 } }
                        let streamStart = lexer.offset
                        physicalStreams[offset] = (dictionary,streamStart)
                        let length:Int?
                        if let direct = dictionary["Length"]?.int { length = direct }
                        else { length = try revisionReader.resolve(dictionary["Length"])?.int }
                        guard let length, length >= 0, length <= bytes.count - lexer.offset else { lengths.append(location); issues.append(location + ": Length fuori dal file"); continue }
                        lexer.offset += length
                        let startSeparator = lexer.offset
                        if lexer.offset < bytes.count && bytes[lexer.offset] == 13 { lexer.offset += 1; if lexer.offset < bytes.count && bytes[lexer.offset] == 10 { lexer.offset += 1 } }
                        else if lexer.offset < bytes.count && bytes[lexer.offset] == 10 { lexer.offset += 1 }
                        else if startSeparator == 0 || ![10,13].contains(bytes[startSeparator - 1]) { streamEOL.append(location) }
                        let expectedKeyword = lexer.offset
                        lexer.skip()
                        if lexer.offset != expectedKeyword { lengths.append(location) }
                        if lexer.offset == 0 || ![10,13].contains(bytes[lexer.offset - 1]) { streamEOL.append(location) }
                        let endstream = try lexer.word()
                        if endstream != "endstream" { lengths.append(location); issues.append(location + ": Length/endstream discordanti"); continue }
                        lexer.skip(); let endobjStart = lexer.offset
                        guard try lexer.word() == "endobj" else { issues.append(location + ": endobj assente"); continue }
                        verifyEnd(lexer.offset,start:endobjStart,location:location)
                        try verifyPhysicalObjectStream(dictionary,start:streamStart,revisionReader:revisionReader,location:location + ", revisione xref \(revision.offset)")
                    } else if next == "endobj" { verifyEnd(lexer.offset,start:lexer.offset - 6,location:location) }
                    else { issues.append(location + ": endobj assente") }
                } catch {
                    if error is CancellationError { throw error }
                    recordSyntaxError(error,location:location)
                }
            }
        }
        let maximum = (reader.allObjectIDs().map(\.number).max() ?? 0) + 1
        if (reader.trailer["Size"]?.int ?? -1) < maximum { issues.append("Trailer/Size inferiore all’intervallo degli oggetti attivi.") }
        // Retain the general active-stream decoder checks. ObjStm lexical
        // inspection above uses each physical revision's bytes and dictionary.
        for id in reader.allObjectIDs() {
            let object = try reader.object(id)
            if object.stream != nil {
                do {
                    let dictionary = try reader.streamDecodingDictionary(object.value.dictionary ?? [:])
                    if PDFStructureDocument.filters(dictionary).allSatisfy({ PDFStreamFilters.supported.contains($0) }) { _ = try reader.decodedStream(id) }
                } catch {
                    if let error = error as? PDFStructureError,case .malformed = error { issues.append("Stream \(id.syntax): " + error.localizedDescription) }
                    else { unknown.append("Stream \(id.syntax): " + error.localizedDescription) }
                }
            }
        }
        // Content strings also carry PDF/A lexical constraints. Binary image
        // samples are excluded by the shared inline-image reader.
        let content = try PDFArchiveContentScanner(reader:reader).scan(allowPartial:true)
        contentLexicalComplete = content.lexicalComplete
        issues += content.lexicalIssues
        hexCount += content.hexLexemes.count
        oddHex += content.hexLexemes.filter { $0.digits % 2 != 0 }.map { $0.location + ", hex byte \($0.offset)" }
        invalidHex += content.hexLexemes.filter { !$0.valid }.map { $0.location + ", hex byte \($0.offset)" }
    }
    private func recordSyntaxError(_ error:Error,location:String) {
        if let error = error as? PDFStructureError,case .unsupported = error { unknown.append(location + ": " + error.localizedDescription) }
        else if let error = error as? PDFStructureError,case .limit = error { unknown.append(location + ": " + error.localizedDescription) }
        else { issues.append(location + ": " + error.localizedDescription) }
    }
    private func verifyPhysicalObjectStream(_ dictionary:[String:PDFSyntaxValue],start:Int,revisionReader:PDFStructureDocument,location:String) throws {
        guard try revisionReader.resolve(dictionary["Type"])?.name == "ObjStm" else { return }
        let bytes = reader.sourceBytes
        guard let length = try revisionReader.resolve(dictionary["Length"])?.int,length>=0,start<=bytes.count,length<=bytes.count-start else { throw PDFStructureError.malformed("ObjStm \(location): Length fuori dal file") }
        var end = start+length
        if end<bytes.count,bytes[end] == 13 { end += 1;if end<bytes.count,bytes[end] == 10 { end += 1 } }
        else if end<bytes.count,bytes[end] == 10 { end += 1 }
        var boundary = PDFSyntaxLexer(bytes:bytes,offset:end)
        let keyword = try boundary.word()
        guard keyword == "endstream",boundary.offset-keyword.utf8.count == end else { throw PDFStructureError.malformed("ObjStm \(location): Length/endstream discordanti nella revisione") }
        try verifyObjectStream(dictionary,encoded:Data(bytes[start..<(start+length)]),revisionReader:revisionReader,location:location)
    }
    /// §7.5.7: N integer pairs followed by exactly N consecutive values.
    /// Bounded slices prevent a malformed value consuming its next neighbour.
    private func verifyObjectStream(_ dictionary:[String:PDFSyntaxValue],encoded:Data,revisionReader:PDFStructureDocument,location:String) throws {
        let context = "ObjStm " + location
        var inventoryComplete = false
        defer { if !inventoryComplete { unknown.append(context + ": inventario lessicale incompleto") } }
        func integer(_ token:String,_ field:String) throws -> Int {
            let bytes = Array(token.utf8),start = bytes.first.map{[43,45].contains($0) ? 1:0} ?? 0
            guard start<bytes.count,bytes[start...].allSatisfy({(48...57).contains($0)}) else { throw PDFStructureError.malformed(context + ": " + field + " non è un token integer PDF") }
            guard let value = Int(token) else { throw PDFStructureError.limit };return value
        }
        func resolvedInteger(_ field:String) throws -> Int {
            guard case .number(let token)? = try revisionReader.resolve(dictionary[field]) else { throw PDFStructureError.malformed(context + ": " + field + " non integer") }
            return try integer(token,field)
        }
        guard !revisionReader.encrypted else { throw PDFStructureError.unsupported("ObjStm cifrato non decodificato") }
        let count = try resolvedInteger("N")
        guard count>=0 else { throw PDFStructureError.malformed(context + ": N negativo") }
        guard count<=100_000 else { throw PDFStructureError.limit }
        let first = try resolvedInteger("First")
        let data = try PDFStructureDocument.decode(encoded,dictionary:revisionReader.streamDecodingDictionary(dictionary))
        guard first>=0,first<=data.count else { throw PDFStructureError.malformed(context + ": First fuori stream") }
        let bytes = Array(data)
        func triviaEnd(_ start:Int,_ end:Int) throws -> Int {
            var position = start
            while position<end {
                if PDFSyntaxLexer.space(bytes[position]) { position += 1 }
                else if bytes[position] == 37 {
                    while position<end && ![10,13].contains(bytes[position]) { position += 1 }
                    if position == end,end<bytes.count,![10,13].contains(bytes[end]) { throw PDFStructureError.malformed(context + ": confine First/slice interrompe un commento") }
                } else { break }
            }
            return position
        }
        var header = PDFSyntaxLexer(bytes:Array(bytes[..<first])),indexes:[Int] = [],numbers = Set<Int>()
        for _ in 0..<count {
            try Task.checkCancellation()
            let number = try integer(header.word(),"numero oggetto"),offset = try integer(header.word(),"offset")
            guard number>0,numbers.insert(number).inserted else { throw PDFStructureError.malformed(context + ": numeri oggetto non positivi/univoci") }
            guard offset>=0,offset<data.count-first,(indexes.last.map{$0<offset} ?? (offset == 0)) else { throw PDFStructureError.malformed(context + ": offsets non crescenti/in bounds oppure primo offset non zero") }
            indexes.append(offset)
        }
        // A comment cannot be truncated at First and have the following bytes
        // reinterpreted as a value on the same physical line.
        guard try triviaEnd(header.offset,first) == first else { throw PDFStructureError.malformed(context + ": First precede la fine dell'header o contiene token oltre le N coppie") }
        if first>0,first<data.count,!PDFSyntaxLexer.delimiter(bytes[first-1]),!PDFSyntaxLexer.delimiter(bytes[first]) { throw PDFStructureError.malformed(context + ": First divide un token integer") }
        if count == 0 {
            var empty = PDFSyntaxLexer(bytes:bytes,offset:first);empty.skip()
            guard empty.offset == bytes.count else { throw PDFStructureError.malformed(context + ": valori presenti con N zero") };inventoryComplete = true;return
        }
        for index in 0..<count {
            try Task.checkCancellation()
            let start = first+indexes[index],end = index+1<count ? first+indexes[index+1]:bytes.count
            if index>0,!PDFSyntaxLexer.delimiter(bytes[start-1]),!PDFSyntaxLexer.delimiter(bytes[start]) {
                issues.append(context + ": offset divide un token, oggetto \(index)");unknown.append(context + ": inventario lessicale incompleto");continue
            }
            var lexer = PDFSyntaxLexer(bytes:Array(bytes[start..<end]));lexer.strict = true;lexer.collectLexicalFacts = true
            defer {
                hexCount += lexer.hexLexemes.count
                oddHex += lexer.hexLexemes.filter{$0.digits%2 != 0}.map{context + ", hex byte \(start+$0.offset)"}
                invalidHex += lexer.hexLexemes.filter{!$0.valid}.map{context + ", hex byte \(start+$0.offset)"}
            }
            do {
                let value = try lexer.value()
                if case .reference = value { throw PDFStructureError.malformed("un valore compresso non può essere soltanto un riferimento") }
                guard try triviaEnd(start+lexer.offset,end) == end else { throw PDFStructureError.malformed("più valori/token nella stessa slice") }
            } catch {
                if error is CancellationError { throw error }
                if let error = error as? PDFStructureError,case .limit = error { unknown.append(context + ": " + error.localizedDescription) }
                else if let error = error as? PDFStructureError,case .unsupported = error { unknown.append(context + ": " + error.localizedDescription) }
                else { issues.append(context + ", valore \(index): " + error.localizedDescription);unknown.append(context + ": inventario lessicale incompleto") }
            }
        }
        inventoryComplete = true
    }
    private func verifyEnd(_ end:Int, start:Int, location:String) {
        let b = reader.sourceBytes
        if start == 0 || ![10,13].contains(b[start - 1]) || end >= b.count || ![10,13].contains(b[end]) { spacing.append(location) }
    }
    private func verifyClassicXref(_ offset:Int) throws {
        var lexer = PDFSyntaxLexer(reader.source,offset:offset)
        guard try lexer.word() == "xref" else { return }
        if lexer.offset - 4 != offset { issues.append("startxref non punta al primo byte di xref.") }
        while true {
            let first = try lexer.word()
            if first == "trailer" { break }
            guard Int(first) != nil, let count = Int(try lexer.word()), count >= 0, count < 1_000_000 else { throw PDFStructureError.malformed("sottosezione xref") }
            lexer.skip()
            for _ in 0..<count {
                guard lexer.offset <= lexer.bytes.count - 20 else { issues.append("riga xref troncata"); return }
                let row = Array(lexer.bytes[lexer.offset..<(lexer.offset + 20)])
                let digits = row[0..<10].allSatisfy { (48...57).contains($0) } && row[11..<16].allSatisfy { (48...57).contains($0) }
                let eol = (row[18] == 32 && [10,13].contains(row[19])) || (row[18] == 13 && row[19] == 10)
                let generation = Int(String(decoding:row[11..<16],as:UTF8.self)) ?? 65536
                if !digits || row[10] != 32 || row[16] != 32 || ![102,110].contains(row[17]) || !eol || generation > 65535 {
                    issues.append("Riga xref non conforme a 20 byte, byte \(lexer.offset).")
                    // Use token boundaries to inspect further sections without
                    // manufacturing a chain of failures from one bad line.
                    for _ in 0..<3 { _ = try lexer.word() }
                    lexer.skip()
                } else { lexer.offset += 20 }
            }
        }
    }
}
