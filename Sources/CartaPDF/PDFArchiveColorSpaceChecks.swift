import Foundation

/// Original schema checks for colour spaces reached through semantic PDF roles.
/// Rendering, tint-function execution and ICC colorimetry are separate obligations.
final class PDFArchiveColorSpaceChecks {
    private let reader:PDFStructureDocument,part:Int
    private var rows:[PDFArchiveRuleResult] = [],overflowFailure:PDFArchiveRuleResult?,overflow = false
    private var inventory:Set<String> = []
    private var visits = 0,usesAbbreviation = false
    init(reader:PDFStructureDocument,part:Int) { self.reader = reader;self.part = part }
    func inventoryGap(_ text:String) { if inventory.count < 16 { inventory.insert(text) } }
    private func row(_ status:PDFArchiveRuleStatus,_ detail:String,_ location:String,_ suffix:String)->PDFArchiveRuleResult {
        .init(id:"CartaPDF:ISO32000:colour-space:"+suffix,specification:part == 1 ? "PDF Reference 1.4":"ISO 32000-\(part == 4 ? 2:1)",clause:part == 1 ? "4.5.4":"8.6.5; 8.6.6",testNumber:"native-colour-space",objectType:"ColorSpaceModel",requirement:"Parametri strutturali, dimensioni e restrizioni degli spazi colore nel contesto PDF devono essere coerenti.",status:status,detail:detail,locations:location.isEmpty ? []:[location])
    }
    var modelChecks:[PDFArchiveRuleResult] {
        var result = rows
        if overflow { result.append(row(.notVerified,"Inventario oltre il limite locale di1024 righe.","","row-limit")) }
        if let overflowFailure { result.append(overflowFailure) }
        if !inventory.isEmpty { result.append(row(.notVerified,"Inventario colore incompleto: "+inventory.sorted().joined(separator:"; "),"","inventory")) }
        return result
    }
    func record(_ value:PDFSyntaxValue?,resources:[String:PDFSyntaxValue],location:String,inline:Bool = false) {
        guard value != nil else { return }
        visits += 1
        guard visits <= 100_000 else { inventoryGap("Limite locale di visite raggiunto.");return }
        let status:PDFArchiveRuleStatus,detail:String
        do {
            guard let actual = try present(value) else { return }
            // Named resources are audited when their definitions are reached.
            usesAbbreviation = false
            if let name = actual.name {
                guard ["G","RGB","CMYK"].contains(name),!inline else { return }
                throw PDFStructureError.unsupported("Abbreviazione colore fuori dal contesto inline non riconciliata")
            }
            let audited = try audit(actual,resources:resources)
            if usesAbbreviation,!inline { throw PDFStructureError.unsupported("Abbreviazione colore fuori dal contesto inline non riconciliata") }
            detail = audited;status = .passed
        } catch {
            status = (error as? PDFStructureError).map { if case .malformed = $0 { return .failed };return .notVerified } ?? .notVerified
            detail = error.localizedDescription
        }
        let result = row(status,detail,location,String(visits))
        if rows.count < 1024 { rows.append(result) }
        else { overflow = true;if status == .failed,overflowFailure == nil { overflowFailure = result } }
    }
    private func present(_ value:PDFSyntaxValue?) throws -> PDFSyntaxValue? {
        let actual = try reader.resolve(value);if case .null? = actual { return nil };return actual
    }
    private func invalid(_ reason:String) throws -> Never { throw PDFStructureError.malformed(reason) }
    private func numbers(_ value:PDFSyntaxValue?,count:Int,key:String) throws -> [PDFExactFunctionNumber] {
        guard let a = try present(value)?.array,a.count == count else { try invalid(key+": dimensione numerica attesa \(count)") }
        return try a.map { item in
            guard case .number(let token)? = try present(item),let n = PDFExactFunctionNumber(token) else { try invalid(key+": valore non numerico") };return n
        }
    }
    private func dictionary(_ value:PDFSyntaxValue?,key:String) throws -> [String:PDFSyntaxValue] {
        guard let d = try present(value)?.dictionary else { try invalid(key+": dizionario richiesto") };return d
    }
    private struct Space { let family:String,components:Int }
    private func space(_ value:PDFSyntaxValue,resources:[String:PDFSyntaxValue],active:Set<String> = [],depth:Int = 0) throws -> Space {
        try Task.checkCancellation();guard depth < 48 else { throw PDFStructureError.limit }
        guard let actual = try present(value) else { try invalid("Spazio colore richiesto nullo") }
        if let name = actual.name {
            if ["G","RGB","CMYK"].contains(name) { usesAbbreviation = true }
            if let n = ["DeviceGray":1,"G":1,"DeviceRGB":3,"RGB":3,"DeviceCMYK":4,"CMYK":4,"Pattern":0][name] { return Space(family:name,components:n) }
            guard !active.contains(name) else { throw PDFStructureError.unsupported("Alias colore circolare") }
            guard let target = try present(resources["ColorSpace"])?.dictionary?[name] else { throw PDFStructureError.unsupported("Alias colore non risolto: "+name) }
            return try space(target,resources:resources,active:active.union([name]),depth:depth+1)
        }
        guard let a = actual.array,let family = try present(a.first)?.name else { try invalid("Definizione colore non è nome/array con famiglia") }
        if let n = ["DeviceGray":1,"DeviceRGB":3,"DeviceCMYK":4,"CalGray":1,"CalRGB":3,"Lab":3,"Indexed":1,"I":1,"Separation":1,"Pattern":0][family] { return Space(family:family,components:n) }
        if family == "DeviceN",a.count >= 2,let names = try present(a[1])?.array { return Space(family:family,components:names.count) }
        if family == "ICCBased",a.count == 2,let n = try present(dictionary(a[1],key:"ICCBased")["N"])?.int,[1,3,4].contains(n) { return Space(family:family,components:n) }
        throw PDFStructureError.unsupported("Famiglia colore non modellata: "+family)
    }
    private func tint(_ value:PDFSyntaxValue,input:Int,output:Int) throws {
        let d = try dictionary(value,key:"TintTransform")
        guard let domain = try present(d["Domain"])?.array,domain.count == 2*input else { try invalid("TintTransform/Domain incompatibile con i componenti di ingresso") }
        if let range = try present(d["Range"]) { guard range.array?.count == 2*output else { try invalid("TintTransform/Range incompatibile con lo spazio alternativo") } }
        else if try present(d["FunctionType"])?.int == 2 {
            let n = try present(d["C0"])?.array?.count ?? 1
            guard n == output else { try invalid("TintTransform Type2 incompatibile con lo spazio alternativo") }
        }
    }
    private func audit(_ actual:PDFSyntaxValue,resources:[String:PDFSyntaxValue]) throws -> String {
        try Task.checkCancellation()
        guard let a = actual.array,let family = try present(a.first)?.name else { try invalid("Spazio colore: array/famiglia assente") }
        let zero = PDFExactFunctionNumber("0")!,one = PDFExactFunctionNumber("1")!
        switch family {
        case "CalGray","CalRGB","Lab":
            guard a.count == 2 else { try invalid(family+": array deve avere due elementi") }
            let d = try dictionary(a[1],key:family),white = try numbers(d["WhitePoint"],count:3,key:"WhitePoint")
            guard white[0] > zero,white[1] == one,white[2] > zero else { try invalid("WhitePoint richiede X/Z positivi e Y esattamente1") }
            if try present(d["BlackPoint"]) != nil { guard try numbers(d["BlackPoint"],count:3,key:"BlackPoint").allSatisfy({$0 >= zero}) else { try invalid("BlackPoint negativo") } }
            if family == "CalGray",let gamma = try present(d["Gamma"]) { guard try numbers(.array([gamma]),count:1,key:"Gamma")[0] > zero else { try invalid("Gamma CalGray deve essere positivo") } }
            var ambiguousGamma = false
            if family == "CalRGB" {
                if try present(d["Matrix"]) != nil { _ = try numbers(d["Matrix"],count:9,key:"Matrix") }
                if try present(d["Gamma"]) != nil { ambiguousGamma = try numbers(d["Gamma"],count:3,key:"Gamma").contains{$0 <= zero} }
            }
            if family == "Lab",try present(d["Range"]) != nil {
                let r = try numbers(d["Range"],count:4,key:"Range");guard r[0] <= r[1],r[2] <= r[3] else { try invalid("Range Lab invertito") }
            }
            if ambiguousGamma { throw PDFStructureError.unsupported("Gamma CalRGB non positivo: vincolo d’edizione non riconciliato") }
        case "Indexed","I":
            if family == "I" { usesAbbreviation = true }
            guard a.count == 4 else { try invalid("Indexed richiede quattro elementi") }
            let base = try space(a[1],resources:resources)
            guard !["Pattern","Indexed","I"].contains(base.family) else { try invalid("Base Indexed non può essere Pattern/Indexed") }
            guard let high = try present(a[2])?.int,high >= 0,high <= 255 else { try invalid("Indexed/hival richiede intero0…255") }
            guard let lookup = try present(a[3]) else { try invalid("Lookup Indexed assente") }
            let bytes:Data
            if let data = lookup.data { bytes = data }
            else if let id = try reader.resolvedObjectID(a[3]),try reader.object(id).stream != nil { bytes = try reader.decodedStream(id) }
            else { try invalid("Lookup Indexed non è stringa o stream") }
            guard base.components <= 100_000 else { throw PDFStructureError.limit }
            guard bytes.count == base.components*(high+1) else { try invalid("Lookup Indexed: \(bytes.count) byte, attesi \(base.components*(high+1))") }
        case "Separation","DeviceN":
            guard family == "Separation" ? a.count == 4:(4...5).contains(a.count) else { try invalid(family+": numero elementi errato") }
            let names:[String]
            if family == "Separation" { guard let name = try present(a[1])?.name else { try invalid("Separation: nome colorante richiesto") };names = [name] }
            else {
                guard let entries = try present(a[1])?.array else { try invalid("DeviceN richiede array di nomi") }
                guard entries.count <= 100_000 else { throw PDFStructureError.limit }
                names = try entries.map { guard let name = try present($0)?.name else { try invalid("DeviceN: colorante non è un nome") };return name }
                guard !names.contains("All") else { try invalid("DeviceN vieta All") }
                let ordinary = names.filter{$0 != "None"};guard Set(ordinary).count == ordinary.count else { try invalid("DeviceN: colorante duplicato diverso da None") }
            }
            let alternate = try space(a[2],resources:resources)
            guard !["Pattern","Indexed","I","Separation","DeviceN"].contains(alternate.family) else { try invalid(family+": spazio alternativo speciale vietato") }
            try tint(a[3],input:names.count,output:alternate.components)
            if family == "DeviceN",a.count == 5,try present(a[4]) != nil {
                let attrs = try dictionary(a[4],key:"DeviceN attributes"),subtype = try present(attrs["Subtype"])?.name ?? "DeviceN"
                guard ["DeviceN","NChannel"].contains(subtype) else { try invalid("DeviceN/Subtype non valido") }
                guard subtype != "NChannel" || !names.contains("None") else { try invalid("NChannel vieta None") }
                if let colors = try present(attrs["Colorants"]) {
                    guard let dictionary = colors.dictionary else { try invalid("Colorants deve essere dizionario") }
                    for (name,value) in dictionary {
                        try Task.checkCancellation()
                        guard let actual = try present(value) else { continue }
                        guard let c = actual.array,c.count == 4,try present(c[0])?.name == "Separation",try present(c[1])?.name == name else { try invalid("Colorants: chiave/nome Separation incoerente") }
                    }
                }
                let process = try present(attrs["Process"]),hints = try present(attrs["MixingHints"])
                if subtype == "NChannel" || process != nil || hints != nil { throw PDFStructureError.unsupported("Relazioni complete NChannel/Process/MixingHints non ancora modellate") }
            }
        case "ICCBased":
            guard a.count == 2,let id = try reader.resolvedObjectID(a[1]),try reader.object(id).stream != nil else { try invalid("ICCBased richiede un profilo stream indiretto") }
            let d = try dictionary(a[1],key:"ICCBased")
            guard let n = try present(d["N"])?.int,[1,3,4].contains(n) else { try invalid("ICCBased/N deve essere1,3,4") }
            if try present(d["Range"]) != nil { let r = try numbers(d["Range"],count:2*n,key:"ICCBased/Range");for i in stride(from:0,to:r.count,by:2) { guard r[i] <= r[i+1] else { try invalid("ICCBased/Range invertito") } } }
            if let value = try present(d["Alternate"]) { let alternate = try space(value,resources:resources);guard alternate.family != "Pattern",alternate.components == n else { try invalid("ICCBased/Alternate incompatibile") } }
        case "Pattern":
            guard (1...2).contains(a.count) else { try invalid("Pattern: uno o due elementi richiesti") }
            if a.count == 2 { guard try space(a[1],resources:resources).family != "Pattern" else { try invalid("Pattern non può avere base Pattern") } }
        case "DeviceGray","DeviceRGB","DeviceCMYK":
            guard a.count == 1 else { try invalid("Spazio device in array richiede un solo nome") }
        default:throw PDFStructureError.unsupported("Schema colore non modellato: "+family)
        }
        return family+": parametri strutturali verificati; funzioni, payload ICC e resa cromatica sono controlli separati."
    }
}
