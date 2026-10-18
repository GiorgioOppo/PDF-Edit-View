import Foundation
import CryptoKit

/// Original ISO 32000 §7.10 checks. Only functions reached through semantic
/// resource links are inventoried; private dictionaries are not guessed to be
/// functions. Static calculator checks never prove arbitrary real arithmetic.
final class PDFArchiveFunctionChecks {
    private let reader:PDFStructureDocument
    private var rows:[PDFArchiveRuleResult] = []
    private var scanned = false, visits = 0
    private var reportLimited = false
    private var limitedFailureRecorded = false
    private var resourceContexts = Set<String>()
    init(reader:PDFStructureDocument) { self.reader = reader }
    var modelChecks:[PDFArchiveRuleResult] {
        if !scanned {
            scanned = true
            do { try inventory() }
            catch { append(.notVerified,"Inventario funzioni incompleto: "+error.localizedDescription,"inventory") }
        }
        return rows
    }
    private func append(_ status:PDFArchiveRuleStatus,_ detail:String,_ location:String) {
        if rows.count >= 1024 {
            if !reportLimited {
                reportLimited = true
                rows.append(.init(id:"CartaPDF:Function:report-limit",specification:"ISO 32000-1/2",clause:"7.10",testNumber:"native-function",objectType:"FunctionModel",requirement:"Inventario delle funzioni nel budget disponibile.",status:.notVerified,detail:"Limite applicativo del numero di risultati raggiunto; inventario incompleto.",locations:[]))
            }
            if status == .failed,!limitedFailureRecorded {
                limitedFailureRecorded = true
                rows.append(.init(id:"CartaPDF:Function:limited-failure",specification:"ISO 32000-1/2",clause:"7.10",testNumber:"native-function",objectType:"FunctionModel",requirement:"Le violazioni dimostrate restano visibili anche oltre il budget del rapporto.",status:.failed,detail:detail,locations:[location]))
            };return
        }
        rows.append(.init(id:"CartaPDF:Function:\(rows.count)",specification:"ISO 32000-1/2",clause:"7.10",testNumber:"native-function",objectType:"FunctionModel",requirement:"Dimensioni, parametri, campioni e sintassi delle funzioni PDF raggiunte nei contesti indicati; nessuna attestazione di esecuzione integrale del modello grafico.",status:status,detail:detail,locations:[location]))
    }
    private func dictionary(_ value:PDFSyntaxValue?) throws -> [String:PDFSyntaxValue] {
        var result = try reader.dictionary(value)
        // ISO32000§7.3.9: null dictionary entries are equivalent to omission,
        // including references that resolve to the null object.
        for (key,value) in result { if case .null? = try reader.resolve(value) { result.removeValue(forKey:key) } }
        return result
    }
    private func inventory() throws {
        for (index,id) in try reader.pageIDs().enumerated() {
            try Task.checkCancellation()
            let page = try dictionary(.reference(id))
            let resources = try dictionary(reader.inherited("Resources",pageID:id))
            try scanResources(resources,location:"pagina \(index+1)/Resources",depth:0)
            for (n,annotation) in (try reader.resolve(page["Annots"])?.array ?? []).enumerated() {
                let appearance = try dictionary(dictionary(annotation)["AP"])
                for (key,value) in appearance.sorted(by:{$0.key < $1.key}) {
                    if let id = try reader.resolvedObjectID(value),try reader.object(id).stream != nil { try form(value,resources:resources,location:"pagina \(index+1)/Annots[\(n)]/AP/"+key,depth:0) }
                    else { for (state,target) in try dictionary(value).sorted(by:{$0.key < $1.key}) { try form(target,resources:resources,location:"pagina \(index+1)/Annots[\(n)]/AP/"+key+"/"+state,depth:0) } }
                }
            }
        }
    }
    private func scanResources(_ resources:[String:PDFSyntaxValue],location:String,depth:Int) throws {
        try Task.checkCancellation();guard depth < 48 else { throw PDFStructureError.limit }
        visits += 1;guard visits <= 10_000 else { throw PDFStructureError.limit }
        let hash = SHA256.hash(data:PDFSyntaxValue.dictionary(resources).encoded).map{String(format:"%02x",$0)}.joined()
        guard resourceContexts.insert(hash).inserted else { return }
        for (name,value) in try dictionary(resources["ColorSpace"]).sorted(by:{$0.key < $1.key}) { _ = try colorComponents(value,resources:resources,location:location+"/ColorSpace/"+name,depth:depth+1) }
        for (name,value) in try dictionary(resources["Shading"]).sorted(by:{$0.key < $1.key}) { try shading(value,resources:resources,location:location+"/Shading/"+name,depth:depth+1) }
        for (name,value) in try dictionary(resources["ExtGState"]).sorted(by:{$0.key < $1.key}) { try state(value,resources:resources,location:location+"/ExtGState/"+name,depth:depth+1) }
        for (name,value) in try dictionary(resources["Pattern"]).sorted(by:{$0.key < $1.key}) {
            let dictionary = try dictionary(value),path = location+"/Pattern/"+name
            if dictionary["PatternType"]?.int == 2 {
                try shading(dictionary["Shading"],resources:resources,location:path+"/Shading",depth:depth+1)
                try state(dictionary["ExtGState"],resources:resources,location:path+"/ExtGState",depth:depth+1)
            } else if dictionary["PatternType"]?.int == 1 { try form(value,resources:resources,location:path,depth:depth+1) }
        }
        for (name,value) in try dictionary(resources["XObject"]).sorted(by:{$0.key < $1.key}) {
            let d = try dictionary(value),path = location+"/XObject/"+name
            if d["Subtype"]?.name == "Form" { try form(value,resources:resources,location:path,depth:depth+1) }
            else if d["Subtype"]?.name == "Image",let cs = d["ColorSpace"] { _ = try colorComponents(cs,resources:resources,location:path+"/ColorSpace",depth:depth+1) }
        }
        for (name,value) in try dictionary(resources["Font"]).sorted(by:{$0.key < $1.key}) {
            let d = try dictionary(value)
            if d["Subtype"]?.name == "Type3",let own = d["Resources"] { try scanResources(dictionary(own),location:location+"/Font/"+name+"/Resources",depth:depth+1) }
        }
    }
    private func form(_ value:PDFSyntaxValue?,resources:[String:PDFSyntaxValue],location:String,depth:Int) throws {
        let d = try dictionary(value)
        let own = d["Resources"] == nil ? resources:try dictionary(d["Resources"])
        try scanResources(own,location:location+"/Resources",depth:depth+1)
    }
    private func state(_ value:PDFSyntaxValue?,resources:[String:PDFSyntaxValue],location:String,depth:Int) throws {
        let d = try dictionary(value)
        for key in ["TR","TR2","BG","BG2","UCR","UCR2"] {
            guard let value = d[key],try reader.resolve(value)?.name == nil else { continue }
            let resolved = try reader.resolve(value)
            if ["TR","TR2"].contains(key),let array = resolved?.array {
                if array.count != 4 { append(.failed,"L’array di funzioni transfer richiede quattro funzioni.",location+"/"+key) }
                for (index,item) in array.enumerated() {
                    if let name = try reader.resolve(item)?.name {
                        if name != "Identity" { append(.notVerified,"Nome transfer non risolto come funzione: "+name,location+"/"+key+"[\(index)]") }
                    } else { _ = analyze(item,inputs:1,outputs:1,location:location+"/"+key+"[\(index)]") }
                }
            } else { _ = analyze(value,inputs:1,outputs:1,location:location+"/"+key) }
        }
        if let mask = d["SMask"],try reader.resolve(mask)?.name != "None" {
            let m = try dictionary(mask)
            if let transfer = m["TR"],try reader.resolve(transfer)?.name == nil { _ = analyze(transfer,inputs:1,outputs:1,location:location+"/SMask/TR") }
            if let group = m["G"] { try form(group,resources:resources,location:location+"/SMask/G",depth:depth+1) }
        }
        let ht = try reader.resolve(d["HT"])
        if ht?.dictionary != nil { try halftone(ht,location:location+"/HT",depth:depth+1) }
    }
    private func halftone(_ value:PDFSyntaxValue?,location:String,depth:Int) throws {
        guard depth < 48 else { throw PDFStructureError.limit }
        let d = try dictionary(value)
        if let spot = d["SpotFunction"],try reader.resolve(spot)?.name == nil { _ = analyze(spot,inputs:2,outputs:1,location:location+"/SpotFunction") }
        if let transfer = d["TransferFunction"],try reader.resolve(transfer)?.name == nil { _ = analyze(transfer,inputs:1,outputs:1,location:location+"/TransferFunction") }
        if d["HalftoneType"]?.int == 5 {
            for (key,item) in d.sorted(by:{$0.key < $1.key}) where !["Type","HalftoneType","HalftoneName"].contains(key) { try halftone(item,location:location+"/"+key,depth:depth+1) }
        }
    }
    private func shading(_ value:PDFSyntaxValue?,resources:[String:PDFSyntaxValue],location:String,depth:Int) throws {
        let d = try dictionary(value)
        let outputs = try colorComponents(d["ColorSpace"],resources:resources,location:location+"/ColorSpace",depth:depth+1)
        guard let function = d["Function"] else { return }
        let inputs = d["ShadingType"]?.int == 1 ? 2:1
        if let array = try reader.resolve(function)?.array {
            if array.isEmpty || (outputs != nil && array.count != outputs) { append(.failed,"Numero di funzioni shading incompatibile con le componenti colore.",location+"/Function") }
            for (index,value) in array.enumerated() { _ = analyze(value,inputs:inputs,outputs:1,location:location+"/Function[\(index)]") }
        } else { _ = analyze(function,inputs:inputs,outputs:outputs,location:location+"/Function") }
    }
    private func colorComponents(_ value:PDFSyntaxValue?,resources:[String:PDFSyntaxValue],location:String,depth:Int) throws -> Int? {
        guard depth < 48 else { throw PDFStructureError.limit }
        let resolved = try reader.resolve(value)
        if let name = resolved?.name {
            if let n = ["DeviceGray":1,"DeviceRGB":3,"DeviceCMYK":4][name] { return n }
            let spaces = try dictionary(resources["ColorSpace"])
            if let target = spaces[name] { return try colorComponents(target,resources:resources,location:location+"/"+name,depth:depth+1) }
            return nil
        }
        guard let a = resolved?.array,let kind = a.first?.name else { return nil }
        if let n = ["CalGray":1,"CalRGB":3,"Lab":3][kind] { return n }
        if kind == "ICCBased",a.count == 2 { return try reader.resolve(dictionary(a[1])["N"])?.int }
        if kind == "Indexed",a.count == 4 { _ = try colorComponents(a[1],resources:resources,location:location+"/Indexed",depth:depth+1);return 1 }
        if kind == "Pattern" { if a.count == 2 { _ = try colorComponents(a[1],resources:resources,location:location+"/Pattern",depth:depth+1) };return nil }
        if ["Separation","DeviceN"].contains(kind),a.count >= 4 {
            let n = kind == "Separation" ? 1:try reader.resolve(a[1])?.array?.count
            let outputs = try colorComponents(a[2],resources:resources,location:location+"/Alternate",depth:depth+1)
            _ = analyze(a[3],inputs:n,outputs:outputs,location:location+"/TintTransform")
            if kind == "DeviceN",a.count > 4 {
                let attrs = try dictionary(a[4])
                for (name,space) in try dictionary(attrs["Colorants"]).sorted(by:{$0.key < $1.key}) { _ = try colorComponents(space,resources:resources,location:location+"/Colorants/"+name,depth:depth+1) }
            }
            return n
        }
        return nil
    }
    private struct Shape { let inputs:Int,outputs:Int? }
    @discardableResult private func analyze(_ value:PDFSyntaxValue,inputs:Int? = nil,outputs:Int? = nil,location:String,active:Set<PDFObjectID> = [],depth:Int = 0)->Shape? {
        var issues:[String] = [],gaps:[String] = []
        var shape:Shape?
        do {
            try Task.checkCancellation();visits += 1
            guard visits <= 10_000,depth < 48 else { throw PDFStructureError.limit }
            var nested = active
            if let id = try reader.resolvedObjectID(value) {
                guard nested.insert(id).inserted else { throw PDFStructureError.malformed("riferimento ricorsivo fra funzioni") }
            }
            let d = try dictionary(value)
            let type = try integer(d["FunctionType"],field:"FunctionType")
            let domain = try numbers(d["Domain"],field:"Domain")
            try pairs(domain,field:"Domain")
            let m = domain.count/2
            let range = d["Range"] == nil ? nil:try numbers(d["Range"],field:"Range")
            if let range { try pairs(range,field:"Range") }
            var n = range.map{$0.count/2}
            if let inputs,inputs != m { issues.append("Domain richiede \(m) ingressi; il contesto ne richiede \(inputs).") }
            switch type {
            case 0:
                guard let range else { throw PDFStructureError.malformed("Range obbligatoria nella funzione campionata") }
                let sizeValues = try reader.resolve(d["Size"])?.array ?? []
                guard sizeValues.count == m else { throw PDFStructureError.malformed("Size incompatibile con Domain") }
                var sizes:[Int] = []
                for value in sizeValues { let size = try integer(value,field:"Size");guard size > 0 else { throw PDFStructureError.malformed("Size non positivo") };sizes.append(size) }
                let bits = try integer(d["BitsPerSample"],field:"BitsPerSample")
                guard [1,2,4,8,12,16,24,32].contains(bits) else { throw PDFStructureError.malformed("BitsPerSample non definito") }
                let order = d["Order"] == nil ? 1:try integer(d["Order"],field:"Order")
                guard [1,3].contains(order) else { throw PDFStructureError.malformed("Order non definito") }
                if let encode = d["Encode"],try numbers(encode,field:"Encode").count != 2*m { throw PDFStructureError.malformed("Encode incompatibile con Domain") }
                if let decode = d["Decode"],try numbers(decode,field:"Decode").count != range.count { throw PDFStructureError.malformed("Decode incompatibile con Range") }
                guard let id = try reader.resolvedObjectID(value),try reader.object(id).stream != nil else { throw PDFStructureError.malformed("funzione campionata priva di stream") }
                let data = try reader.decodedStream(id)
                var requiredBits = range.count/2*bits
                for size in sizes {
                    // Compare against the actual byte capacity without overflow.
                    guard requiredBits <= data.count*8/size else { throw PDFStructureError.malformed("stream troppo corto per Size/Range/BitsPerSample") }
                    requiredBits *= size
                }
                // Extra sample bytes are permitted: §7.10.2 requires at least
                // the complete table, not equality with the decoded byte count.
            case 2:
                guard m == 1 else { throw PDFStructureError.malformed("funzione esponenziale non a un ingresso") }
                let c0 = d["C0"] == nil ? [PDFExactFunctionNumber("0")!]:try numbers(d["C0"],field:"C0")
                let c1 = d["C1"] == nil ? [PDFExactFunctionNumber("1")!]:try numbers(d["C1"],field:"C1")
                guard !c0.isEmpty,c0.count == c1.count else { throw PDFStructureError.malformed("C0/C1 hanno dimensioni differenti o nulle") }
                if let n,n != c0.count { issues.append("C0/C1 incompatibili con Range.") };n = c0.count
                let exponent = try number(d["N"],field:"N")
                if !exponent.isInteger,domain[0].sign < 0 { issues.append("N non intero con Domain contenente valori negativi.") }
                if exponent.sign < 0,domain[0].sign <= 0,domain[1].sign >= 0 { issues.append("N negativo con zero incluso nel Domain.") }
            case 3:
                guard m == 1 else { throw PDFStructureError.malformed("funzione stitching non a un ingresso") }
                guard let functions = try reader.resolve(d["Functions"])?.array,!functions.isEmpty else { throw PDFStructureError.malformed("Functions assente/vuoto") }
                let bounds = try numbers(d["Bounds"],field:"Bounds",allowEmpty:true)
                guard bounds.count == functions.count-1 else { throw PDFStructureError.malformed("Bounds incompatibile con Functions") }
                if functions.count > 1,domain[0] >= domain[1] { issues.append("Domain stitching degenere con più sottofunzioni.") }
                for (index,bound) in bounds.enumerated() {
                    if bound <= domain[0] || bound > domain[1] || (index > 0 && bound <= bounds[index-1]) { issues.append("Bounds fuori dominio o non crescenti.") }
                }
                guard try numbers(d["Encode"],field:"Encode").count == 2*functions.count else { throw PDFStructureError.malformed("Encode stitching incompatibile con Functions") }
                for (index,function) in functions.enumerated() {
                    if let child = analyze(function,inputs:1,outputs:n,location:location+"/Functions[\(index)]",active:nested,depth:depth+1) {
                        if let childN = child.outputs {
                            if let n,n != childN { issues.append("Sottofunzioni stitching con dimensionalità di uscita diversa.") }
                            else { n = childN }
                        } else { gaps.append("Dimensionalità della sottofunzione non risolta.") }
                    } else { gaps.append("Sottofunzione stitching non verificata integralmente.") }
                }
            case 4:
                guard let range else { throw PDFStructureError.malformed("Range obbligatoria nella funzione calculator") }
                guard let id = try reader.resolvedObjectID(value),try reader.object(id).stream != nil else { throw PDFStructureError.malformed("funzione calculator priva di stream") }
                var syntax = try PDFCalculatorSyntax(data:reader.decodedStream(id))
                let program = try syntax.parse()
                var audit = PDFCalculatorStaticAudit(inputs:m,outputs:range.count/2)
                audit.check(program)
                issues += audit.issues;gaps += audit.gaps
                gaps.append("Esecuzione aritmetica della funzione calculator sull’intero dominio non dimostrata dal controllo statico.")
            default:throw PDFStructureError.malformed("FunctionType non definito: \(type)")
            }
            if let expected = outputs,let n,expected != n { issues.append("La funzione produce \(n) valori; il contesto ne richiede \(expected).") }
            if outputs == nil,n == nil { gaps.append("Dimensionalità di uscita non risolta.") }
            shape = Shape(inputs:m,outputs:n)
        } catch {
            if let error = error as? PDFStructureError,case .malformed = error { issues.append(error.localizedDescription) }
            else { gaps.append(error.localizedDescription) }
        }
        append(!issues.isEmpty ? .failed:gaps.isEmpty ? .passed:.notVerified,(issues+gaps).isEmpty ? "Parametri, dimensioni e campioni della funzione verificati.":(issues+gaps).joined(separator:"; "),location)
        return shape
    }
    private func number(_ value:PDFSyntaxValue?,field:String) throws -> PDFExactFunctionNumber {
        guard case .number(let token)? = try reader.resolve(value),let number = PDFExactFunctionNumber(token) else { throw PDFStructureError.malformed(field+" non numerico") };return number
    }
    private func integer(_ value:PDFSyntaxValue?,field:String) throws -> Int {
        guard case .number(let token)? = try reader.resolve(value),!token.contains("."),let number = PDFExactFunctionNumber(token) else { throw PDFStructureError.malformed(field+" non integer PDF") }
        guard let value = Int(token) else { if number.sign < 0 { throw PDFStructureError.malformed(field+" negativo fuori intervallo") };throw PDFStructureError.limit };return value
    }
    private func numbers(_ value:PDFSyntaxValue?,field:String,allowEmpty:Bool = false) throws -> [PDFExactFunctionNumber] {
        guard let values = try reader.resolve(value)?.array,allowEmpty || !values.isEmpty else { throw PDFStructureError.malformed(field+" non è un array numerico") }
        guard values.count <= 100_000 else { throw PDFStructureError.limit }
        var result:[PDFExactFunctionNumber] = []
        for (index,value) in values.enumerated() { if index%256 == 0 { try Task.checkCancellation() };result.append(try number(value,field:field)) };return result
    }
    private func pairs(_ numbers:[PDFExactFunctionNumber],field:String) throws {
        guard !numbers.isEmpty,numbers.count%2 == 0 else { throw PDFStructureError.malformed(field+" non contiene coppie complete") }
        for index in stride(from:0,to:numbers.count,by:2) { if index%256 == 0 { try Task.checkCancellation() };if numbers[index] > numbers[index+1] { throw PDFStructureError.malformed(field+" con estremi invertiti") } }
    }
}

/// Exact decimal ordering, including values beyond Double/Decimal precision.
/// PDF numbers have no exponent notation; leading/trailing zeros are semantic.
struct PDFExactFunctionNumber:Comparable {
    let sign:Int,digits:[UInt8],power:Int,isInteger:Bool
    init?(_ token:String) {
        var b = Array(token.utf8),s = 1
        if let first = b.first,[43,45].contains(first) { s = first == 45 ? -1:1;b.removeFirst() }
        guard !b.isEmpty,b.filter({$0 == 46}).count <= 1,b.allSatisfy({$0 == 46 || (48...57).contains($0)}),b.contains(where:{(48...57).contains($0)}) else { return nil }
        let dot = b.firstIndex(of:46) ?? b.count
        isInteger = b.dropFirst(min(dot+1,b.count)).allSatisfy{$0 == 48}
        b.removeAll{$0 == 46}
        if let first = b.firstIndex(where:{$0 != 48}),let last = b.lastIndex(where:{$0 != 48}) {
            sign = s;digits = Array(b[first...last]);power = dot-first
        } else { sign = 0;digits = [];power = 0 }
    }
    static func ==(a:Self,b:Self)->Bool { a.sign == b.sign && (a.sign == 0 || (a.power == b.power && a.digits == b.digits)) }
    static func <(a:Self,b:Self)->Bool {
        if a.sign != b.sign { return a.sign < b.sign };if a.sign == 0 { return false }
        if a.power != b.power { return a.sign > 0 ? a.power < b.power:a.power > b.power }
        for index in 0..<max(a.digits.count,b.digits.count) {
            let left = index<a.digits.count ? a.digits[index]:48,right = index<b.digits.count ? b.digits[index]:48
            if left != right { return a.sign > 0 ? left < right:left > right }
        };return false
    }
}

private indirect enum PDFCalculatorInstruction { case token(String),conditional([Self],[Self]?) }
private struct PDFCalculatorSyntax {
    let bytes:[UInt8]
    private(set) var cursor = 0,count = 0
    init(data:Data) throws { guard data.count <= 16*1024*1024 else { throw PDFStructureError.limit };bytes = Array(data) }
    private mutating func skip() {
        while cursor<bytes.count {
            if PDFSyntaxLexer.space(bytes[cursor]) { cursor += 1 }
            else if bytes[cursor] == 37 { while cursor<bytes.count && ![10,13].contains(bytes[cursor]) { cursor += 1 } }
            else { break }
        }
    }
    private mutating func word() throws -> String {
        skip();let start = cursor
        while cursor<bytes.count,!PDFSyntaxLexer.space(bytes[cursor]),![37,123,125].contains(bytes[cursor]) { cursor += 1 }
        guard cursor > start else { throw PDFStructureError.malformed("token calculator assente") }
        return String(decoding:bytes[start..<cursor],as:UTF8.self)
    }
    mutating func parse() throws -> [PDFCalculatorInstruction] {
        let code = try block(depth:0);skip()
        guard cursor == bytes.count else { throw PDFStructureError.malformed("token esterni alle parentesi calculator") };return code
    }
    private mutating func block(depth:Int) throws -> [PDFCalculatorInstruction] {
        guard depth < 64 else { throw PDFStructureError.limit };skip()
        guard cursor<bytes.count,bytes[cursor] == 123 else { throw PDFStructureError.malformed("calculator non racchiuso fra parentesi graffe") };cursor += 1
        var code:[PDFCalculatorInstruction] = []
        while true {
            skip();try Task.checkCancellation();count += 1;guard count <= 100_000 else { throw PDFStructureError.limit }
            guard cursor<bytes.count else { throw PDFStructureError.malformed("parentesi calculator non bilanciate") }
            if bytes[cursor] == 125 { cursor += 1;return code }
            if bytes[cursor] == 123 {
                let first = try block(depth:depth+1);skip()
                if cursor<bytes.count,bytes[cursor] == 123 {
                    let second = try block(depth:depth+1)
                    guard try word() == "ifelse" else { throw PDFStructureError.malformed("due blocchi calculator non seguiti da ifelse") }
                    code.append(.conditional(first,second))
                } else {
                    guard try word() == "if" else { throw PDFStructureError.malformed("blocco calculator non seguito da if") };code.append(.conditional(first,nil))
                }
            } else {
                let token = try word()
                guard PDFExactFunctionNumber(token) != nil || PDFCalculatorStaticAudit.operators.contains(token),!["if","ifelse"].contains(token) else { throw PDFStructureError.malformed("operatore/operando calculator non permesso: "+token) }
                code.append(.token(token))
            }
        }
    }
}

/// Proves type/count failures only on straight-line or constant-condition paths.
/// Unknown input values never become a concrete arithmetic failure witness.
private struct PDFCalculatorStaticAudit {
    static let operators = Set("abs add atan ceiling cos cvi cvr div exp floor idiv ln log mod mul neg round sin sqrt sub truncate and bitshift eq false ge gt le lt ne not or true xor if ifelse copy dup exch index pop roll".split(separator:" ").map(String.init))
    private enum Value { case number(Int?),boolean(Bool?) }
    private var stack:[Value]
    private let outputs:Int
    var issues:[String] = [],gaps:[String] = []
    init(inputs:Int,outputs:Int) { stack = Array(repeating:.number(nil),count:inputs);self.outputs = outputs }
    mutating func check(_ code:[PDFCalculatorInstruction]) {
        do {
            try execute(code)
            guard stack.count == outputs else { throw PDFStructureError.malformed("numero di risultati calculator incompatibile con Range") }
            for value in stack { if case .boolean = value { throw PDFStructureError.malformed("risultato calculator booleano, richiesto numero") } }
        } catch PDFStructureError.malformed(let message) { issues.append(message) }
        catch { gaps.append(error.localizedDescription) }
    }
    private mutating func pop() throws -> Value { guard let value = stack.popLast() else { throw PDFStructureError.malformed("stack underflow calculator") };return value }
    private mutating func num() throws -> Int? { guard case .number(let n) = try pop() else { throw PDFStructureError.malformed("tipo calculator: richiesto numero") };return n }
    private mutating func bool() throws -> Bool? { guard case .boolean(let n) = try pop() else { throw PDFStructureError.malformed("tipo calculator: richiesto booleano") };return n }
    private mutating func exactIndex() throws -> Int { guard let n = try num() else { throw PDFStructureError.unsupported("indice stack dipendente dall’ingresso o da numeri non esatti") };return n }
    private mutating func execute(_ code:[PDFCalculatorInstruction]) throws {
        for instruction in code {
            try Task.checkCancellation();guard stack.count <= 4096 else { throw PDFStructureError.limit }
            switch instruction {
            case .conditional(let yes,let no):
                guard let test = try bool() else { throw PDFStructureError.unsupported("rami calculator dipendenti dai valori d’ingresso") }
                if test { try execute(yes) } else if let no { try execute(no) }
            case .token(let token):
                if let number = PDFExactFunctionNumber(token) {
                    let exact = token.contains(".") ? nil:Int(token).flatMap{Int32(exactly:$0).map{Int($0)}}
                    stack.append(.number(number.sign == 0 && !token.contains(".") ? 0:exact));continue
                }
                switch token {
                case "true","false":stack.append(.boolean(token == "true"))
                case "dup":let value = try pop();stack += [value,value]
                case "exch":let b = try pop(),a = try pop();stack += [b,a]
                case "pop":_ = try pop()
                case "copy":let n = try exactIndex();guard n >= 0,n <= stack.count else { throw PDFStructureError.malformed("copy calculator fuori intervallo") };stack += stack.suffix(n)
                case "index":let n = try exactIndex();guard n >= 0,n < stack.count else { throw PDFStructureError.malformed("index calculator fuori intervallo") };stack.append(stack[stack.count-1-n])
                case "roll":
                    let j = try exactIndex(),n = try exactIndex();guard n >= 0,n <= stack.count else { throw PDFStructureError.malformed("roll calculator fuori intervallo") }
                    if n > 0 { let shift = (j%n+n)%n,tail = Array(stack.suffix(n));stack.removeLast(n);stack += tail.suffix(shift)+tail.prefix(n-shift) }
                case "eq","ne":
                    let b = try pop(),a = try pop();var equal:Bool?
                    switch (a,b) { case (.number(let x),.number(let y)):if let x,let y { equal = x == y };case (.boolean(let x),.boolean(let y)):if let x,let y { equal = x == y };default:equal = false }
                    stack.append(.boolean(equal.map{token == "eq" ? $0:!$0}))
                case "gt","ge","lt","le":let b = try num(),a = try num();var result:Bool?;if let a,let b { result = token == "gt" ? a>b:token == "ge" ? a>=b:token == "lt" ? a<b:a<=b };stack.append(.boolean(result))
                case "and","or","xor":
                    let b = try pop(),a = try pop()
                    switch (a,b) {
                    case (.boolean(let a),.boolean(let b)):stack.append(.boolean(a.flatMap{x in b.map{token == "and" ? x && $0:token == "or" ? x || $0:x != $0}}))
                    case (.number(let a),.number(let b)):guard let a,let b else { throw PDFStructureError.unsupported("tipo integer/real bitwise non risolto") };stack.append(.number(token == "and" ? a & b:token == "or" ? a | b:a ^ b))
                    default:throw PDFStructureError.malformed("operandi bitwise/booleani di tipi diversi")
                    }
                case "not":switch try pop() { case .boolean(let n):stack.append(.boolean(n.map{!$0}));case .number(let n):guard let n else { throw PDFStructureError.unsupported("tipo integer/real di not non risolto") };stack.append(.number(~n)) }
                case "add","sub","mul":
                    let b = try num(),a = try num();var result:Int?
                    if let a,let b { let pair = token == "add" ? a.addingReportingOverflow(b):token == "sub" ? a.subtractingReportingOverflow(b):a.multipliedReportingOverflow(by:b);if !pair.overflow,Int32(exactly:pair.partialValue) != nil { result = pair.partialValue } }
                    stack.append(.number(result))
                case "idiv","mod","bitshift":
                    let b = try num(),a = try num();guard let a,let b else { throw PDFStructureError.unsupported("operandi integer calculator non risolti") }
                    if token == "bitshift" { throw PDFStructureError.unsupported("semantica bitshift e larghezza integer non dimostrate") }
                    guard b != 0 else { throw PDFStructureError.malformed("divisione integer calculator per zero") }
                    if a == Int.min,b == -1 { stack.append(.number(nil)) } else { stack.append(.number(token == "idiv" ? a/b:a%b)) }
                case "div":let b = try num();_ = try num();if b == 0 { throw PDFStructureError.malformed("divisione calculator per zero costante") };stack.append(.number(nil))
                case "exp","atan":_ = try num();_ = try num();stack.append(.number(nil))
                case "abs","neg":let n = try num();if let n,n != Int.min { let result = token == "abs" ? Swift.abs(n):-n;stack.append(.number(Int32(exactly:result).map{Int($0)})) } else { stack.append(.number(nil)) }
                case "sqrt","ln","log":let n = try num();if let n,(token == "sqrt" ? n < 0:n <= 0) { throw PDFStructureError.malformed("dominio calculator non valido per "+token) };stack.append(.number(nil))
                case "ceiling","floor","round","truncate","cvi":let n = try num();stack.append(.number(n))
                case "cvr":_ = try num();stack.append(.number(nil))
                case "sin","cos":_ = try num();stack.append(.number(nil))
                default:throw PDFStructureError.unsupported("semantica calculator non modellata: "+token)
                }
            }
        }
    }
}
