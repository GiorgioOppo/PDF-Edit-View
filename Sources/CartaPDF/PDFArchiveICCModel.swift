import Foundation

/// Original ICC.1 v2/v4 binary structure checks. No ColorSync acceptance is
/// treated as a proof of tag integrity or of the full colourimetric model.
struct PDFArchiveICCAudit {
    var issues:[String] = []
    var gaps:[String] = []
    var checkedTypes:Set<String> = []
    init(profile:PDFArchiveICCProfile) {
        issues = profile.structuralIssues
        let bytes = Array(profile.bytes)
        func failure(_ message:String) { if issues.count < 128 { issues.append(message) } }
        func unknown(_ message:String) { if !gaps.contains(message),gaps.count < 64 { gaps.append(message) } }
        func u16(_ p:Int)->Int { Int(bytes[p])<<8 | Int(bytes[p+1]) }
        func u32(_ p:Int)->Int { bytes[p..<(p+4)].reduce(0) { $0<<8 | Int($1) } }
        func text(_ p:Int)->String { String(decoding:bytes[p..<(p+4)],as:UTF8.self) }
        let major = profile.majorVersion,minor = Int(bytes[9]>>4),pcs = text(20)
        if ![2,4].contains(major) { unknown("Edizione ICC \(major) non modellata.");return }
        if bytes[9]&15 > 9 || minor > 9 || bytes[10] != 0 || bytes[11] != 0 { failure("Versione ICC BCD/byte riservati non valida.") }
        let reserved = major == 2 ? 84..<128:100..<128
        if bytes[reserved].contains(where:{$0 != 0}) {
            if major == 4 { failure("Header ICC: byte riservati non nulli.") }
            else { unknown("Header ICC v2: campo84–127 riservato per espansioni future; requisito zero v4 non presunto retroattivo.") }
        }
        if !["scnr","mntr","prtr","link","spac","abst","nmcl"].contains(profile.deviceClass) { failure("Classe ICC non definita.") }
        if profile.deviceClass != "link",!["XYZ ","Lab "].contains(pcs) { failure("PCS ICC non è XYZ o Lab.") }
        if !Self.validDate((0..<6).map{u16(24+2*$0)}) { failure("Data di creazione ICC fuori calendario.") }
        let d50 = [0x0000F6D6,0x00010000,0x0000D32D]
        let illuminant = (0..<3).map{u32(68+4*$0)}
        let roundedD50 = [9642,10000,8249]
        if (0..<3).contains(where:{(illuminant[$0]*10000+32768)/65536 != roundedD50[$0]}) { failure("Illuminante PCS ICC incompatibile con D50 a quattro decimali.") }
        else if illuminant != d50,major != 4 || minor < 4 { unknown("Quantizzazione D50 alternativa compatibile a quattro decimali; chiarimento esplicito ICC v4.4 non presunto retroattivo.") }
        if major == 4 && minor > 4 { unknown("Revisione ICC v4 successiva alle specifiche consultate.") }
        if major == 2 && minor > 4 { unknown("Revisione ICC v2 successiva alla specifica consultata.") }
        if major == 2 && minor == 0 { unknown("Modelli obbligatori ICC v2.0 precedenti alle revisioni documentate nell'Annex F; requisiti v2.4 non presunti retroattivi.") }
        var tags:[String:Range<Int>] = [:]
        let count = u32(128)
        guard count <= 4096,count <= (bytes.count-132)/12 else { return }
        for index in 0..<count {
            let p = 132+12*index,start = u32(p+4),length = u32(p+8)
            if start >= 132+12*count,length >= 8,start <= bytes.count,length <= bytes.count-start { tags[text(p)] = start..<(start+length) }
        }
        if let first = tags.values.map(\.lowerBound).min(),first != 132+12*count { failure("Il primo elemento tag ICC non segue immediatamente la tabella.") }
        if major == 2,(1...4).contains(minor) {
            // ICC.1:2001-04 §6.3, Tables21–31. In v2 a display LUT
            // supplements the RGB matrix model; it does not replace it.
            var required = profile.deviceClass == "link" ? ["desc","cprt","pseq","A2B0"]:["desc","cprt","wtpt"]
            let matrix = ["rXYZ","gXYZ","bXYZ","rTRC","gTRC","bTRC"]
            switch profile.deviceClass {
            case "scnr":
                if profile.colorSpace == "GRAY" { required += ["kTRC"] }
                else if tags["A2B0"] == nil {
                    if profile.components == 3 {
                        required += matrix
                        if pcs != "XYZ " { failure("Modello matrice/TRC ICC v2 richiede PCSXYZ oppure A2B0 per PCSLAB.") }
                    } else { required += ["A2B0"] }
                }
            case "mntr":
                if profile.colorSpace == "GRAY" { required += ["kTRC"] }
                else if profile.colorSpace == "RGB " {
                    required += matrix
                    if pcs == "Lab ",!["A2B0","A2B1","A2B2","B2A0","B2A1","B2A2"].contains(where:{tags[$0] != nil}) { failure("Display ICC v2 PCSLAB senza tabella multidimensionale.") }
                } else { unknown("Modello display ICC v2 diverso da GRAY/RGB non definito nei modelli consultati.") }
            case "prtr":required += profile.colorSpace == "GRAY" ? ["kTRC"]:["A2B0","A2B1","A2B2","B2A0","B2A1","B2A2","gamt"]
            case "spac":required += ["A2B0","B2A0"]
            case "abst":required += ["A2B0"]
            case "nmcl":required += ["ncl2"]
            default:break
            }
            for key in required where tags[key] == nil { failure("Tag ICC v2 obbligatorio assente: "+key) }
        }
        if major == 4 {
            var required = profile.deviceClass == "link" ? ["desc","cprt","pseq","A2B0"]:["desc","cprt","wtpt"]
            switch profile.deviceClass {
            case "prtr":required += profile.colorSpace == "GRAY" ? ["kTRC"]:["A2B0","A2B1","A2B2","B2A0","B2A1","B2A2","gamt"]
            case "spac":required += ["A2B0","B2A0"]
            case "abst":required += ["A2B0"]
            case "nmcl":required += ["ncl2"]
            default:break
            }
            if ["prtr","link"].contains(profile.deviceClass),profile.colorSpace.hasSuffix("CLR") { required.append("clrt") }
            if profile.deviceClass == "link",pcs.hasSuffix("CLR") { required.append("clot") }
            for key in required where tags[key] == nil { failure("Tag ICC v4 obbligatorio assente: "+key) }
            if ["scnr","mntr"].contains(profile.deviceClass) {
                if profile.colorSpace == "GRAY" { if tags["kTRC"] == nil { failure("Profilo monocromatico ICC v4 privo di kTRC.") } }
                else if tags["A2B0"] == nil {
                    if profile.components == 3 {
                        for key in ["rXYZ","gXYZ","bXYZ","rTRC","gTRC","bTRC"] where tags[key] == nil { failure("Modello matrice/TRC ICC v4 incompleto: "+key) }
                        if pcs != "XYZ " { failure("Modello matrice/TRC ICC richiede PCSXYZ.") }
                    } else { failure("Profilo ICC v4 di input/display senza modello A2B0.") }
                } else if profile.deviceClass == "mntr",tags["B2A0"] == nil { failure("Profilo display LUT ICC v4 senza B2A0.") }
            }
        }
        for (signature,range) in tags.sorted(by:{$0.key < $1.key}) {
            do {
                try Task.checkCancellation()
                if major == 4 {
                    let alignedEnd = (range.upperBound+3)/4*4
                    if alignedEnd > bytes.count || bytes[range.upperBound..<min(alignedEnd,bytes.count)].contains(where:{$0 != 0}) { failure(signature+": padding ICC v4 assente o non nullo.") }
                }
                let tag = ICCElement(bytes:Array(bytes[range]))
                let kind = try tag.type(0)
                checkedTypes.insert(kind)
                let allowed:Set<String>?
                if ["rXYZ","gXYZ","bXYZ","wtpt","bkpt","lumi"].contains(signature) { allowed = ["XYZ "] }
                else if ["rTRC","gTRC","bTRC","kTRC"].contains(signature) { allowed = major == 2 ? ["curv"]:["curv","para"] }
                else if signature == "desc" { allowed = major == 2 ? ["desc"]:["mluc"] }
                else if signature == "cprt" { allowed = major == 2 ? ["text"]:["mluc"] }
                else if signature == "chad" { allowed = ["sf32"] }
                else if ["A2B0","A2B1","A2B2"].contains(signature) { allowed = major == 2 ? ["mft1","mft2"]:["mft1","mft2","mAB "] }
                else if ["B2A0","B2A1","B2A2"].contains(signature) { allowed = major == 2 ? ["mft1","mft2"]:["mft1","mft2","mBA "] }
                else if ["dmnd","dmdd","vued"].contains(signature) { allowed = major == 2 ? ["desc"]:["mluc"] }
                else if signature == "calt" { allowed = ["dtim"] }
                else if signature == "targ" { allowed = ["text"] }
                else if ["chrm","meas","view","pseq","ncl2"].contains(signature) { allowed = [signature] }
                else if signature == "tech" { allowed = ["sig "] }
                else if signature == "gamt" { allowed = major == 2 ? ["mft1","mft2"]:["mft1","mft2","mBA "] }
                else if ["pre0","pre1","pre2"].contains(signature) { allowed = major == 2 ? ["mft1","mft2"]:(signature == "pre0" ? ["mft1","mft2","mAB ","mBA "]:["mft1","mft2","mBA "]) }
                else if major == 4,["clrt","clot"].contains(signature) { allowed = ["clrt"] }
                else if major == 4,signature == "clro" { allowed = ["clro"] }
                else if major == 4,["ciis","rig0","rig2"].contains(signature) { allowed = ["sig "] }
                else if major == 4,signature == "psid" { allowed = ["psid"] }
                else if major == 4,["D2B0","D2B1","D2B2","D2B3","B2D0","B2D1","B2D2","B2D3"].contains(signature) { allowed = ["mpet"] }
                else { allowed = nil }
                if let allowed,!allowed.contains(kind) { failure(signature+": tipo ICC "+kind+" incompatibile con il tag/edizione.") }
                for detail in try tag.validate(major:major,components:profile.components,pcs:pcs) { unknown(signature+": "+detail) }
                if kind == "mpet",let dataChannels = profile.components {
                    let pcsChannels = profile.deviceClass == "link" ? PDFArchiveICCProfile.channels(pcs):3
                    let forward = ["D2B0","D2B1","D2B2","D2B3"].contains(signature),reverse = ["B2D0","B2D1","B2D2","B2D3"].contains(signature)
                    let input = try tag.u16(8),output = try tag.u16(10)
                    if let pcsChannels,(forward && (input != dataChannels || output != pcsChannels)) || (reverse && (input != pcsChannels || output != dataChannels)) { failure(signature+": canali MPE incompatibili con data space/PCS.") }
                }
                if ["mft1","mft2","mAB ","mBA "].contains(kind),let dataChannels = profile.components {
                    let pcsChannels = profile.deviceClass == "link" ? PDFArchiveICCProfile.channels(pcs):3
                    if let pcsChannels {
                        if ["A2B0","A2B1","A2B2"].contains(signature),Int(tag.bytes[8]) != dataChannels || Int(tag.bytes[9]) != pcsChannels { failure(signature+": canali LUT incompatibili con data space/PCS.") }
                        if ["B2A0","B2A1","B2A2"].contains(signature),Int(tag.bytes[8]) != pcsChannels || Int(tag.bytes[9]) != dataChannels { failure(signature+": canali LUT incompatibili con PCS/data space.") }
                    }
                }
                if ["rXYZ","gXYZ","bXYZ","wtpt","bkpt","lumi"].contains(signature),range.count != 20 { failure(signature+": il tag richiede un unico valore XYZ.") }
                if signature == "chad",range.count != 44 { failure("chad: matrice di adattamento non contiene nove s15Fixed16.") }
            } catch PDFStructureError.unsupported(let message) { unknown(signature+": "+message) }
            catch PDFStructureError.limit { unknown(signature+": budget delle strutture ICC superato.") }
            catch is CancellationError { unknown("Controlli ICC annullati.");break }
            catch { failure(signature+": "+error.localizedDescription) }
        }
        // The contiguous-layout requirement was introduced by ICC.1:2022
        // (v4.4); older profiles may legitimately have gaps between elements.
        if major == 4,minor == 4 {
            let unique = Set(tags.values.map{ICCSpan(start:$0.lowerBound,end:$0.upperBound)}).sorted{$0.start < $1.start}
            var next = 132+12*count
            for span in unique {
                let aligned = (next+3)/4*4
                if span.start != aligned { failure("ICC v4.4: intervallo non contiguo fra gli elementi tag.") }
                if aligned <= bytes.count,next <= aligned,bytes[next..<aligned].contains(where:{$0 != 0}) { failure("ICC v4.4: padding non nullo.") }
                next = span.end
            }
            if (next+3)/4*4 != bytes.count { failure("ICC v4.4: dimensione finale non allineata agli elementi tag.") }
        }
    }
    private struct ICCSpan:Hashable { let start:Int,end:Int }
    fileprivate static func validDate(_ d:[Int])->Bool {
        guard d.count == 6,d[0] > 0,(1...12).contains(d[1]),(0...23).contains(d[3]),(0...59).contains(d[4]),(0...59).contains(d[5]) else { return false }
        let leap = d[0]%4 == 0 && (d[0]%100 != 0 || d[0]%400 == 0)
        return (1...[31,leap ? 29:28,31,30,31,30,31,31,30,31,30,31][d[1]-1]).contains(d[2])
    }
}

private final class ICCParseBudget {
    private var records = 0,bytes = 0
    func spend(records moreRecords:Int = 0,bytes moreBytes:Int = 0) throws {
        try Task.checkCancellation()
        guard moreRecords >= 0,moreRecords <= 65_536-records,moreBytes >= 0,moreBytes <= 16*1024*1024-bytes else { throw PDFStructureError.limit }
        records += moreRecords;bytes += moreBytes
    }
}

private struct ICCElement {
    let bytes:[UInt8]
    private let budget = ICCParseBudget()
    init(bytes:[UInt8]) { self.bytes = bytes }
    func require(_ p:Int,_ count:Int) throws {
        guard p >= 0,count >= 0,p <= bytes.count,count <= bytes.count-p else { throw PDFStructureError.malformed("struttura/tag ICC troncata") }
    }
    func u16(_ p:Int) throws -> Int { try require(p,2);return Int(bytes[p])<<8 | Int(bytes[p+1]) }
    func u32(_ p:Int) throws -> Int { try require(p,4);return bytes[p..<(p+4)].reduce(0) { $0<<8 | Int($1) } }
    func type(_ p:Int) throws -> String { try require(p,8);guard bytes[(p+4)..<(p+8)].allSatisfy({$0 == 0}) else { throw PDFStructureError.malformed("byte riservati del tipo ICC") };return String(decoding:bytes[p..<(p+4)],as:UTF8.self) }
    func curve(_ start:Int) throws -> Int {
        let kind = try type(start)
        if kind == "curv" {
            let count = try u32(start+8)
            guard count <= (bytes.count-start-12)/2 else { throw PDFStructureError.malformed("tabella curveType troncata") }
            return 12+2*count
        }
        if kind == "para" {
            let function = try u16(start+8)
            guard (0...4).contains(function),try u16(start+10) == 0 else { throw PDFStructureError.malformed("tipo funzione parametricCurve/reserved") }
            let length = 12+4*[1,3,4,5,7][function];try require(start,length);return length
        }
        throw PDFStructureError.unsupported("tipo curva ICC "+kind+" non modellato")
    }
    func validate(major:Int,components:Int?,pcs:String) throws -> [String] {
        let kind = try type(0)
        var gaps:[String] = []
        switch kind {
        case "curv","para":_ = try curve(0)
        case "XYZ ":guard (bytes.count-8)%12 == 0 else { throw PDFStructureError.malformed("array XYZ ICC incompleto") }
        case "sf32","uf32","ui32":guard (bytes.count-8)%4 == 0 else { throw PDFStructureError.malformed("array ICC a32bit incompleto") }
        case "ui16":guard (bytes.count-8)%2 == 0 else { throw PDFStructureError.malformed("array ICC a16bit incompleto") }
        case "ui64":guard (bytes.count-8)%8 == 0 else { throw PDFStructureError.malformed("array ICC a64bit incompleto") }
        case "ui08":break
        case "sig ":try require(0,12)
        case "text":try ascii(8,bytes.count-8)
        case "data":
            let flag = try u32(8);guard flag <= 1 else { throw PDFStructureError.malformed("flag dataType ICC riservato") }
            if flag == 0 { try ascii(12,bytes.count-12) }
        case "dtim":
            try require(0,20)
            guard PDFArchiveICCAudit.validDate(try (0..<6).map{try u16(8+2*$0)}) else { throw PDFStructureError.malformed("dateTimeType ICC fuori calendario") }
        case "desc":_ = try description(0)
        case "mluc":_ = try localized(0,limit:bytes.count)
        case "pseq":gaps += try sequenceDescriptions(major:major)
        case "ncl2":gaps += try namedColors(components:components,pcs:pcs)
        case "psid":
            guard major == 4 else { throw PDFStructureError.unsupported("profileSequenceIdentifierType non definito nell'edizione v2 consultata") }
            gaps += try sequenceIdentifiers()
        case "mpet":
            guard major == 4 else { throw PDFStructureError.unsupported("multiProcessElementsType non definito nell'edizione v2 consultata") }
            gaps += try processElements()
        case "mft1","mft2":try lut(kind)
        case "mAB ","mBA ":
            guard major == 4 else { throw PDFStructureError.malformed("LUT A/B richiede ICC v4") };try lutAB(kind)
        case "chrm":
            let channels = try u16(8);_ = try u16(10)
            guard channels > 0,channels <= 15 else { throw PDFStructureError.malformed("canali chromaticityType") };try require(12,channels*8)
        case "meas":try require(0,36)
        case "view":try require(0,36)
        case "clrt":
            let count = try u32(8);guard count <= (bytes.count-12)/38 else { throw PDFStructureError.malformed("colorantTableType troncato") }
            for i in 0..<count { if i%256 == 0 { try Task.checkCancellation() };let p = 12+38*i;guard bytes[p..<(p+32)].contains(0),bytes[p..<(p+32)].allSatisfy({$0 < 128}) else { throw PDFStructureError.malformed("nome colorante ICC ASCII") } }
        case "clro":
            let count = try u32(8);try require(12,count)
        default:throw PDFStructureError.unsupported("payload del tipo ICC "+kind+" non modellato; estensioni private non presunte invalide")
        }
        return gaps
    }
    func ascii(_ start:Int,_ length:Int) throws {
        try require(start,length);guard length > 0,bytes[start+length-1] == 0 else { throw PDFStructureError.malformed("testo ICC ASCII non terminato") }
        try budget.spend(bytes:length)
        for index in start..<(start+length) {
            if (index-start)%16384 == 0 { try Task.checkCancellation() }
            guard bytes[index] < 128 else { throw PDFStructureError.malformed("testo ICC non ASCII") }
        }
    }
    func description(_ start:Int) throws -> Int {
        guard try type(start) == "desc" else { throw PDFStructureError.malformed("textDescriptionType embedded incompatibile") }
        let count = try u32(start+8);try ascii(start+12,count)
        let p = start+12+count;_ = try u32(p);let unicode = try u32(p+4)
        guard unicode <= (bytes.count-p-8)/2 else { throw PDFStructureError.malformed("Unicode textDescriptionType troncato") }
        if unicode > 0 {
            try utf16(p+8,2*unicode)
            guard try u16(p+6+2*unicode) == 0 else { throw PDFStructureError.malformed("Unicode textDescriptionType non terminato") }
        }
        let script = p+8+2*unicode;_ = try u16(script);try require(script+2,68)
        guard bytes[script+2] <= 67 else { throw PDFStructureError.malformed("conteggio ScriptCode ICC") }
        let scriptCount = Int(bytes[script+2])
        if scriptCount > 0,bytes[script+2+scriptCount] != 0 { throw PDFStructureError.malformed("ScriptCode textDescriptionType non terminato") }
        return script+70-start
    }
    func utf16(_ start:Int,_ length:Int) throws {
        try require(start,length)
        guard length%2 == 0 else { throw PDFStructureError.malformed("UTF16BE mluc non valido") }
        try budget.spend(bytes:length)
        var p = start
        while p < start+length {
            if (p-start)%16384 == 0 { try Task.checkCancellation() }
            let value = try u16(p);p += 2
            if (0xD800...0xDBFF).contains(value) {
                guard p < start+length,(0xDC00...0xDFFF).contains(try u16(p)) else { throw PDFStructureError.malformed("UTF16BE mluc non valido") };p += 2
            } else if (0xDC00...0xDFFF).contains(value) { throw PDFStructureError.malformed("UTF16BE mluc non valido") }
        }
    }
    /// Returns the furthest referenced string end, not a guessed storage size.
    /// This is an exact bound inside sized psid records; pseq may remain ambiguous.
    func localized(_ start:Int,limit:Int) throws -> Int {
        guard start >= 0,limit <= bytes.count,start <= limit,limit-start >= 16 else { throw PDFStructureError.malformed("header mluc ICC troncato") }
        guard try type(start) == "mluc" else { throw PDFStructureError.malformed("multiLocalizedUnicodeType embedded incompatibile") }
        let count = try u32(start+8),size = try u32(start+12)
        guard size == 12,count <= (limit-start-16)/12 else { throw PDFStructureError.malformed("record mluc ICC") }
        guard count <= 4096 else { throw PDFStructureError.limit }
        try budget.spend(records:count)
        let tableEnd = 16+12*count
        var extent = tableEnd,seen = Set<Range<Int>>()
        for index in 0..<count {
            try Task.checkCancellation()
            let p = start+16+12*index,length = try u32(p+4),offset = try u32(p+8)
            guard offset >= tableEnd,length%2 == 0,offset <= limit-start,length <= limit-start-offset else { throw PDFStructureError.malformed("offset/lunghezza stringa mluc") }
            let range = (start+offset)..<(start+offset+length)
            if seen.insert(range).inserted { try utf16(range.lowerBound,length) }
            extent = max(extent,offset+length)
        }
        return extent
    }
    func fixedASCII(_ start:Int) throws {
        try require(start,32);try budget.spend(bytes:32)
        guard let end = bytes[start..<(start+32)].firstIndex(of:0) else { throw PDFStructureError.malformed("nome ncl2 ASCII non terminato") }
        guard bytes[start..<end].allSatisfy({$0 < 128}) else { throw PDFStructureError.malformed("nome ncl2 non ASCII") }
    }
    func namedColors(components:Int?,pcs:String) throws -> [String] {
        // ICC v2 §6.5.11 / v4.3 §10.15: header84 + n*(32+6+2m).
        try require(0,84)
        let count = try u32(12),channels = try u32(16),stride = 38+2*channels
        guard count <= (bytes.count-84)/stride else { throw PDFStructureError.malformed("record namedColor2Type troncati") }
        try budget.spend(records:count)
        try fixedASCII(20);try fixedASCII(52)
        var gaps:[String] = []
        if channels != 0,components != channels { gaps.append("Numero di coordinate ncl2 non dimostrato coerente con lo spazio dati del profilo.") }
        if try u32(8)&0xFFFF != 0 { gaps.append("Flag ncl2 riservati per uso ICC non interpretati.") }
        for index in 0..<count {
            if index%256 == 0 { try Task.checkCancellation() }
            let p = 84+stride*index;try fixedASCII(p)
            if pcs == "Lab ",try u16(p+32) > 0xFF00,!gaps.contains("Valore L* ncl2 oltre il dominio legacy documentato; semantica non attestata.") { gaps.append("Valore L* ncl2 oltre il dominio legacy documentato; semantica non attestata.") }
        }
        if 84+stride*count != bytes.count { gaps.append("Byte aggiuntivi oltre i record ncl2; contenuto non attestato.") }
        return gaps
    }
    func sequenceIdentifiers() throws -> [String] {
        // ICC.1:2010 §4.4/10.18: offset and size are relative to psid,
        // while each embedded mluc uses offsets relative to its own beginning.
        let count = try u32(8)
        guard count <= (bytes.count-12)/8 else { throw PDFStructureError.malformed("tabella posizioni psid troncata") }
        guard count <= 4096 else { throw PDFStructureError.limit }
        try budget.spend(records:count)
        let tableEnd = 12+8*count
        var seen = Set<Range<Int>>()
        for index in 0..<count {
            try Task.checkCancellation()
            let p = 12+8*index,offset = try u32(p),size = try u32(p+4)
            guard offset >= tableEnd,offset%4 == 0,size >= 32 else { throw PDFStructureError.malformed("offset/dimensione record psid") }
            try require(offset,size)
            let range = offset..<(offset+size)
            if seen.insert(range).inserted { _ = try localized(offset+16,limit:range.upperBound) }
            let aligned = (range.upperBound+3)/4*4
            if bytes[range.upperBound..<min(aligned,bytes.count)].contains(where:{$0 != 0}) { throw PDFStructureError.malformed("padding record psid non nullo") }
        }
        return []
    }
    func sequenceDescriptions(major:Int) throws -> [String] {
        let count = try u32(8)
        // A short empty mluc can occupy12 bytes: see ICC PSD Technical Note.
        let minimum = major == 2 ? 202:44
        guard count <= (bytes.count-12)/minimum else { throw PDFStructureError.malformed("record profileSequenceDescType troncati") }
        guard count <= 4096 else { throw PDFStructureError.limit }
        try budget.spend(records:count)
        var p = 12,gaps:[String] = []
        func unknown(_ detail:String) { if !gaps.contains(detail),gaps.count < 16 { gaps.append(detail) } }
        func peek(_ at:Int)->String? {
            guard at >= 0,at <= bytes.count-4 else { return nil }
            return String(decoding:bytes[at..<(at+4)],as:UTF8.self)
        }
        if count == 0 { unknown("Sequenza pseq vuota: relazione con i profili originali non attestata.") }
        for index in 0..<count {
            try Task.checkCancellation();try require(p,20);p += 20
            for slot in 0..<2 {
                let kind = try type(p)
                var lengths:[Int]
                if kind == "desc" {
                    lengths = [try description(p)]
                    if major == 4 { unknown("Descrizione legacy desc in pseq v4: conversione da profilo sorgente non attestata.") }
                } else if kind == "mluc",major == 4 {
                    let names = try u32(p+8)
                    if names == 0 {
                        lengths = [12]
                        if p <= bytes.count-16,try u32(p+12) == 12 {
                            lengths.append(16)
                            if p <= bytes.count-28 { lengths.append(28) }
                        }
                    } else { lengths = [try localized(p,limit:bytes.count)] }
                } else { throw PDFStructureError.malformed("tipo descrizione pseq incompatibile con l'edizione") }
                let last = index == count-1 && slot == 1,skip = slot == 0 ? 0:20
                var choices = Set<Int>()
                for length in lengths {
                    let end = p+length,aligned = (end+3)/4*4
                    for next in Set([end,aligned]) where next <= bytes.count {
                        if next > end,bytes[end..<next].contains(where:{$0 != 0}) { continue }
                        if last {
                            if bytes.count-next <= 3,bytes[next..<bytes.count].allSatisfy({$0 == 0}) { choices.insert(bytes.count) }
                        } else if let nextKind = peek(next+skip),nextKind == "desc" || (major == 4 && nextKind == "mluc") { choices.insert(next) }
                    }
                }
                guard choices.count == 1,let next = choices.first else {
                    throw PDFStructureError.unsupported("dimensione/storage delle descrizioni pseq ambigua; nessuna lunghezza inventata")
                }
                if kind == "mluc",try u32(p+8) == 0,next-p != 16 { unknown("Segnaposto mluc pseq con dimensione alternativa descritta dalla nota tecnica ICC.") }
                p = next
            }
        }
        return gaps
    }
    func bounded(_ start:Int,_ length:Int,limit:Int) throws {
        guard start >= 0,length >= 0,limit <= bytes.count,start <= limit,length <= limit-start else { throw PDFStructureError.malformed("struttura MPE ICC troncata") }
    }
    func elementType(_ start:Int,limit:Int) throws -> String { try bounded(start,8,limit:limit);return try type(start) }
    func float32(_ start:Int,limit:Int) throws -> Float {
        try bounded(start,4,limit:limit)
        let bits = UInt32(try u32(start)),exponent = bits>>23 & 0xFF,mantissa = bits & 0x7FFFFF
        // ICC.1:2010/2022 §4.3 excludes stored subnormals, NaN and Infinity.
        // Signed zero is permitted; these tests never evaluate a transform.
        guard exponent != 0xFF,exponent != 0 || mantissa == 0 else { throw PDFStructureError.malformed("float32Number ICC subnormale, infinito o NaN") }
        return Float(bitPattern:bits)
    }
    func floats(_ start:Int,count:Int,limit:Int) throws {
        guard count >= 0,start >= 0,limit <= bytes.count,start <= limit,count <= (limit-start)/4 else { throw PDFStructureError.malformed("array float32 MPE ICC troncato") }
        try bounded(start,4*count,limit:limit);try budget.spend(bytes:4*count)
        for index in 0..<count {
            if index%4096 == 0 { try Task.checkCancellation() }
            _ = try float32(start+4*index,limit:limit)
        }
    }
    func positions(_ start:Int,header:Int,count:Int,limit:Int,minimum:Int) throws -> [Range<Int>] {
        try bounded(start,header,limit:limit)
        guard count <= (limit-start-header)/8 else { throw PDFStructureError.malformed("tabella posizioni MPE ICC troncata") }
        guard count <= 4096 else { throw PDFStructureError.limit };try budget.spend(records:count)
        let tableEnd = start+header+8*count
        var ranges:[Range<Int>] = []
        for index in 0..<count {
            try Task.checkCancellation()
            let p = start+header+8*index,offset = try u32(p),size = try u32(p+4)
            guard offset >= header+8*count,offset%4 == 0,size >= minimum,offset <= limit-start,size <= limit-start-offset else { throw PDFStructureError.malformed("offset/dimensione elemento MPE ICC") }
            let range = (start+offset)..<(start+offset+size),aligned = (range.upperBound+3)/4*4
            if bytes[range.upperBound..<min(aligned,limit)].contains(where:{$0 != 0}) { throw PDFStructureError.malformed("padding elemento MPE ICC non nullo") }
            ranges.append(range)
        }
        if let first = ranges.map(\.lowerBound).min(),first != tableEnd { throw PDFStructureError.malformed("primo elemento MPE ICC non immediatamente dopo la tabella") }
        return ranges
    }
    func processElements() throws -> [String] {
        try bounded(0,16,limit:bytes.count)
        let count = try u32(12),inputs = try u16(8),outputs = try u16(10)
        guard count > 0 else { throw PDFStructureError.malformed("mpet richiede almeno un elemento") }
        let ranges = try positions(0,header:16,count:count,limit:bytes.count,minimum:12)
        var previous = inputs,seen = Set<Range<Int>>(),gaps:[String] = []
        func unknown(_ detail:String) { if !gaps.contains(detail),gaps.count < 64 { gaps.append(detail) } }
        if inputs == 0 || outputs == 0 { unknown("MPE a zero canali: semantica non attestata.") }
        for range in ranges {
            try Task.checkCancellation()
            let p = range.lowerBound,kind = try elementType(p,limit:range.upperBound),input = try u16(p+8),output = try u16(p+10)
            guard input == previous else { throw PDFStructureError.malformed("catena canali MPE ICC incoerente") };previous = output
            if input == 0 || output == 0 { unknown("MPE a zero canali: semantica non attestata.") }
            guard seen.insert(range).inserted else { continue }
            do {
                for detail in try processElement(kind,range:range,inputs:input,outputs:output) { unknown(detail) }
            } catch PDFStructureError.unsupported(let detail) { unknown(detail) }
        }
        guard previous == outputs else { throw PDFStructureError.malformed("uscita finale MPE ICC incompatibile con header") }
        return gaps
    }
    func trailing(_ expected:Int,limit:Int)->[String] {
        expected == limit ? []:["Byte aggiuntivi in un elemento MPE pubblico: contenuto non attestato."]
    }
    func processElement(_ kind:String,range:Range<Int>,inputs:Int,outputs:Int) throws -> [String] {
        let start = range.lowerBound,end = range.upperBound
        switch kind {
        case "matf":
            let count = outputs*(inputs+1)
            try floats(start+12,count:count,limit:end)
            return trailing(start+12+4*count,limit:end)
        case "clut":
            try bounded(start,28,limit:end)
            guard inputs <= 16 else { throw PDFStructureError.malformed("CLUT MPE ICC oltre le sedici dimensioni codificabili") }
            guard bytes[(start+12+inputs)..<(start+28)].allSatisfy({$0 == 0}) else { throw PDFStructureError.malformed("dimensioni CLUT MPE inutilizzate non nulle") }
            var count = outputs
            for index in 0..<inputs {
                let grid = Int(bytes[start+12+index])
                guard grid >= 2,count <= (end-start-28)/4/grid else { throw PDFStructureError.malformed("griglia/numero campioni CLUT MPE ICC") };count *= grid
            }
            try floats(start+28,count:count,limit:end)
            return trailing(start+28+4*count,limit:end)
        case "cvst":
            guard inputs == outputs else { throw PDFStructureError.malformed("curveSet MPE richiede uguali canali ingresso/uscita") }
            let ranges = try positions(start,header:12,count:inputs,limit:end,minimum:12)
            var gaps:[String] = [],seen = Set<Range<Int>>()
            for curve in ranges where seen.insert(curve).inserted {
                try Task.checkCancellation()
                do { for detail in try segmentedCurve(curve) where !gaps.contains(detail) { gaps.append(detail) } }
                catch PDFStructureError.unsupported(let detail) { if !gaps.contains(detail) { gaps.append(detail) } }
            }
            return gaps
        case "bACS","eACS":
            guard inputs == outputs else { throw PDFStructureError.malformed("elemento ACS MPE richiede uguali canali") };try bounded(start,16,limit:end)
            return trailing(start+16,limit:end)
        default:throw PDFStructureError.unsupported("Elemento MPE "+kind+" non definito nelle edizioni consultate; fallback non eseguito né presunto invalido.")
        }
    }
    func segmentedCurve(_ range:Range<Int>) throws -> [String] {
        let start = range.lowerBound,end = range.upperBound
        guard try elementType(start,limit:end) == "curf" else { throw PDFStructureError.unsupported("Tipo di curva MPE non modellato.") }
        try bounded(start,12,limit:end)
        let count = try u16(start+8)
        guard count > 0,try u16(start+10) == 0 else { throw PDFStructureError.malformed("segmenti/reserved curf MPE ICC") }
        guard count <= 4096 else { throw PDFStructureError.limit };try budget.spend(records:count)
        try floats(start+12,count:count-1,limit:end)
        var previous:Float?
        for index in 0..<(count-1) {
            let point = try float32(start+12+4*index,limit:end)
            if let previous,point < previous { throw PDFStructureError.malformed("break-point curf MPE ICC decrescenti") };previous = point
        }
        var p = start+12+4*(count-1)
        for index in 0..<count {
            try Task.checkCancellation()
            let kind = try elementType(p,limit:end);try bounded(p,12,limit:end)
            if kind == "parf" {
                let function = try u16(p+8)
                guard try u16(p+10) == 0 else { throw PDFStructureError.malformed("reserved parf MPE ICC non nullo") }
                guard function <= 2 else { throw PDFStructureError.unsupported("Formula parf MPE non definita nell'edizione consultata.") }
                let values = [4,5,5][function]
                try floats(p+12,count:values,limit:end);p += 12+4*values
            } else if kind == "samf" {
                guard index > 0,index < count-1 else { throw PDFStructureError.malformed("primo/ultimo segmento curf MPE deve essere formula") }
                let samples = try u32(p+8)
                guard samples > 0 else { throw PDFStructureError.malformed("segmento samf MPE senza campioni") }
                try floats(p+12,count:samples,limit:end);p += 12+4*samples
            } else { throw PDFStructureError.unsupported("Tipo segmento MPE "+kind+" non modellato.") }
        }
        return trailing(p,limit:end)+["Validità matematica delle formule curf MPE sull'intero segmento non dimostrata dal controllo binario."]
    }
    func lut(_ kind:String) throws {
        try require(0,kind == "mft1" ? 48:52)
        let inputs = Int(bytes[8]),outputs = Int(bytes[9]),grid = Int(bytes[10])
        guard (1...15).contains(inputs),(1...15).contains(outputs),grid >= 2,bytes[11] == 0 else { throw PDFStructureError.malformed("dimensioni/header LUT ICC") }
        var points = outputs
        for _ in 0..<inputs { guard points <= bytes.count/grid else { throw PDFStructureError.malformed("conteggio CLUT ICC eccede i byte disponibili") };points *= grid }
        let inputCount:Int,outputCount:Int,width:Int,header:Int
        if kind == "mft1" { inputCount = 256;outputCount = 256;width = 1;header = 48 }
        else {
            inputCount = try u16(48);outputCount = try u16(50);width = 2;header = 52
            guard (2...4096).contains(inputCount),(2...4096).contains(outputCount) else { throw PDFStructureError.malformed("dimensione tabelle lut16 ICC") }
        }
        try require(header,width*(inputs*inputCount+points+outputs*outputCount))
    }
    func lutAB(_ kind:String) throws {
        try require(0,32)
        let inputs = Int(bytes[8]),outputs = Int(bytes[9])
        guard (1...15).contains(inputs),(1...15).contains(outputs),bytes[10] == 0,bytes[11] == 0 else { throw PDFStructureError.malformed("canali/reserved LUT A/B ICC") }
        let offsets = try [12,16,20,24,28].map{try u32($0)}
        for offset in offsets where offset != 0 { guard offset >= 32,offset%4 == 0 else { throw PDFStructureError.malformed("offset LUT A/B ICC") };try require(offset,8) }
        func curves(_ start:Int,_ count:Int) throws {
            if start == 0 { return }
            var p = start
            for _ in 0..<count { let length = try curve(p);p = (p+length+3)/4*4 }
        }
        let bCount = kind == "mAB " ? outputs:inputs,aCount = kind == "mAB " ? inputs:outputs
        try curves(offsets[0],bCount);try curves(offsets[2],bCount);try curves(offsets[4],aCount)
        if offsets[1] != 0 { guard bCount == 3 else { throw PDFStructureError.malformed("matrice LUT A/B richiede tre canali") };try require(offsets[1],48) }
        // ICC.1:2010 §§10.10.1/10.11.1: only B, B+matrix+M,
        // B+CLUT+A, or all five elements are permitted.
        if offsets[0] == 0 { throw PDFStructureError.malformed("curve B obbligatorie nella LUT A/B") }
        if (offsets[4] == 0) != (offsets[3] == 0) { throw PDFStructureError.malformed("curve A e CLUT devono comparire insieme") }
        if (offsets[2] == 0) != (offsets[1] == 0) { throw PDFStructureError.malformed("curve M e matrice devono comparire insieme") }
        if inputs != outputs && offsets[3] == 0 { throw PDFStructureError.malformed("CLUT assente con numero canali diverso") }
        if offsets[3] != 0 {
            let p = offsets[3];try require(p,20)
            let precision = Int(bytes[p+16]);guard [1,2].contains(precision),bytes[(p+17)..<(p+20)].allSatisfy({$0 == 0}),bytes[(p+inputs)..<(p+16)].allSatisfy({$0 == 0}) else { throw PDFStructureError.malformed("precisione/reserved CLUT A/B") }
            var length = outputs*precision
            for i in 0..<inputs { let grid = Int(bytes[p+i]);guard grid >= 2,length <= bytes.count/grid else { throw PDFStructureError.malformed("griglia CLUT A/B fuori dimensioni") };length *= grid }
            try require(p+20,length)
        }
    }
}
