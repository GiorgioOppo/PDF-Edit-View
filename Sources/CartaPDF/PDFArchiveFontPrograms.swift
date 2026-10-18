import Foundation
import CoreGraphics
import CoreText
import CryptoKit

/// Public font interfaces inspect exactly the embedded bytes, never a named
/// system-font substitute. Bounded SFNT/CFF readers expose independent facts.
final class PDFArchiveFontProgram {
    enum Format: String { case sfntTrueType, sfntCFF, cff, type1 }
    let data: Data
    private let bytes:[UInt8]
    let format: Format
    let native: CGFont?
    let glyphCount: Int
    let unitsPerEm: Int
    let tables: [String: Range<Int>]
    let cmapRecords: [(platform:Int,encoding:Int,offset:Int)]
    let cff: PDFArchiveCFF?
    let type1: PDFArchiveType1Program?
    private var cffWidthCache:[Int:Result<Double?,Error>] = [:]
    private var cmapAuditCache:[Int:Result<Void,Error>] = [:]
    init(data: Data, type1Length1:Int? = nil, type1Length2:Int? = nil) throws {
        guard !data.isEmpty, data.count <= 64 * 1024 * 1024 else { throw PDFStructureError.limit }
        self.data = data;self.bytes = Array(data)
        native = CGDataProvider(data:data as CFData).flatMap(CGFont.init)
        let bytes = self.bytes
        if bytes.count >= 12, [Data([0,1,0,0]),Data("OTTO".utf8),Data("true".utf8)].contains(Data(bytes[0..<4])) {
            let count = try Self.u16(bytes,4); guard count > 0, count < 4096, 12 + count * 16 <= bytes.count else { throw PDFStructureError.malformed("directory SFNT") }
            var indexed: [String:Range<Int>] = [:]
            for i in 0..<count {
                let position = 12 + i * 16, tag = String(decoding:bytes[position..<(position+4)],as:UTF8.self)
                let start = try Self.u32(bytes,position+8), length = try Self.u32(bytes,position+12)
                guard start <= bytes.count, length <= bytes.count-start, indexed[tag] == nil else { throw PDFStructureError.malformed("tabella SFNT " + tag) }
                indexed[tag] = start..<(start+length)
            }
            tables = indexed; type1 = nil
            guard let head = indexed["head"], head.count >= 54, let maxp = indexed["maxp"], maxp.count >= 6 else { throw PDFStructureError.unsupported("SFNT senza head/maxp") }
            glyphCount = try Self.u16(bytes,maxp.lowerBound+4); unitsPerEm = try Self.u16(bytes,head.lowerBound+18)
            guard glyphCount > 0, (16...16384).contains(unitsPerEm) else { throw PDFStructureError.malformed("unità/glifi SFNT") }
            if let range = indexed["CFF "] { cff = try PDFArchiveCFF(data:Data(bytes[range])); format = .sfntCFF }
            else if indexed["glyf"] != nil, indexed["loca"] != nil { cff = nil; format = .sfntTrueType }
            else { throw PDFStructureError.unsupported("outline SFNT non TrueType/CFF1") }
            var records: [(Int,Int,Int)] = []
            if let range = indexed["cmap"], range.count >= 4 {
                let number = try Self.u16(bytes,range.lowerBound+2)
                guard number < 4096, 4 + number * 8 <= range.count else { throw PDFStructureError.malformed("directory cmap") }
                for i in 0..<number {
                    let position = range.lowerBound+4+i*8, offset = try Self.u32(bytes,position+4)
                    guard offset <= range.count-2 else { throw PDFStructureError.malformed("offset cmap") }
                    records.append((try Self.u16(bytes,position),try Self.u16(bytes,position+2),range.lowerBound+offset))
                }
            }
            cmapRecords = records
        } else if bytes.count >= 4, bytes[0] == 1, bytes[2] >= 4 {
            type1 = nil
            let compact = try PDFArchiveCFF(data:data); cff = compact; format = .cff; glyphCount = compact.glyphCount
            unitsPerEm = Int(native?.unitsPerEm ?? 1000); tables = [:]; cmapRecords = []
        } else if data.starts(with:Data("%!".utf8)) || data.starts(with:Data([0x80,1])) {
            format = .type1; cff = nil; tables = [:]; cmapRecords = []
            let parsed = try PDFArchiveType1Program(data:data,length1:type1Length1,length2:type1Length2); type1 = parsed
            glyphCount = native?.numberOfGlyphs ?? parsed.names.count; unitsPerEm = Int(native?.unitsPerEm ?? 1000)
        } else { throw PDFStructureError.unsupported("programma font non SFNT/CFF1/Type1 supportato") }
    }
    static func u16(_ bytes: [UInt8], _ p: Int) throws -> Int { guard p >= 0, p <= bytes.count-2 else { throw PDFStructureError.malformed("font troncato") }; return Int(bytes[p])<<8 | Int(bytes[p+1]) }
    static func u32(_ bytes: [UInt8], _ p: Int) throws -> Int { guard p >= 0, p <= bytes.count-4 else { throw PDFStructureError.malformed("font troncato") }; return Int(bytes[p])<<24 | Int(bytes[p+1])<<16 | Int(bytes[p+2])<<8 | Int(bytes[p+3]) }
    func glyph(named name: String) -> Int? {
        if name == ".notdef" { return 0 }
        if let cff,let glyph = cff.customNames.first(where:{$0.value == name})?.key { return glyph }
        if let native { let glyph = native.getGlyphWithGlyphName(name:name as CFString); if glyph != 0 { return Int(glyph) } }
        return type1?.names.firstIndex(of:name) ?? cff?.customNames.first(where: { $0.value == name })?.key
    }
    func glyphName(_ glyph: Int) -> String? {
        guard glyph >= 0, glyph < glyphCount else { return nil }
        if glyph == 0 { return ".notdef" }
        if let name = cff?.customNames[glyph] { return name }
        if let native, let name = native.name(for:CGGlyph(glyph)) { return name as String }
        return (type1.flatMap { glyph < $0.names.count ? $0.names[glyph]:nil }) ?? cff?.customNames[glyph]
    }
    func glyph(unicode: UInt32) throws -> Int? {
        if let cmap = tables["cmap"] {
            let preferred = cmapRecords.sorted { lhs,rhs in
                func rank(_ value:(platform:Int,encoding:Int,offset:Int))->Int {
                    if value.platform == 3 && value.encoding == 10 { return 0 }
                    if value.platform == 0 && value.encoding == 4 { return 1 }
                    if value.platform == 0 && value.encoding == 6 { return 2 }
                    let format = (try? Self.u16(bytes,value.offset)) ?? -1
                    if value.platform == 0 && [8,10,12,13].contains(format) { return 3 }
                    return value.platform == 0 ? 4:value.platform == 3 && value.encoding == 1 ? 5:9
                }
                return rank(lhs)<rank(rhs)
            }
            for record in preferred where (record.platform == 0 && record.encoding != 5) || (record.platform == 3 && [1,10].contains(record.encoding)) {
                if try Self.u16(bytes,record.offset) == 8 {
                    try checkedCmap(offset:record.offset,bound:cmap.upperBound)
                    // Microsoft cmap8 and Apple's TrueType manual specify
                    // UTF-16 surrogate units packed into a 32-bit encoded code.
                    // Keep this distinct from the exact raw-code API below.
                    guard unicode<=0x10FFFF,!(0xD800...0xDFFF).contains(unicode) else { return nil }
                    if unicode>65535 {
                        let value = unicode-0x10000,high = 0xD800+(value>>10),low = 0xDC00+(value&1023)
                        return try cmapGlyph((high<<16)|low,offset:record.offset,bound:cmap.upperBound)
                    }
                    if bytes[record.offset+12]&128 != 0 { continue } // non-Unicode mixed encoding
                }
                if let glyph = try cmapGlyph(unicode, offset:record.offset, bound:cmap.upperBound) { return glyph }
            }
        }
        return nil
    }
    func glyph(encodedCode:UInt32,platform:Int,encoding:Int) throws -> Int? {
        guard let cmap = tables["cmap"],let record = cmapRecords.first(where:{$0.platform == platform && $0.encoding == encoding}) else { return nil }
        return try cmapGlyph(encodedCode,offset:record.offset,bound:cmap.upperBound)
    }
    /// Format14 supplements the chosen Unicode mapping; it never replaces it.
    /// nil means the sequence is unsupported; a default sequence uses the base.
    func variationGlyph(unicode:UInt32,selector:UInt32) throws -> Int? {
        guard let cmap = tables["cmap"],let record = cmapRecords.first(where:{$0.platform == 0 && $0.encoding == 5}) else { return nil }
        try checkedCmap(offset:record.offset,bound:cmap.upperBound)
        guard try Self.u16(bytes,record.offset) == 14 else { throw PDFStructureError.malformed("cmap UVS non formato14") }
        let count = try Self.u32(bytes,record.offset+6)
        for i in 0..<count {
            let p = record.offset+10+i*11
            guard Self.u24(bytes,p) == Int(selector) else { continue }
            let fallback = try Self.u32(bytes,p+3),explicit = try Self.u32(bytes,p+7)
            if explicit != 0 {
                let base = record.offset+explicit,n = try Self.u32(bytes,base)
                for j in 0..<n where Self.u24(bytes,base+4+j*5) == Int(unicode) { return try Self.u16(bytes,base+7+j*5) }
            }
            if fallback != 0 {
                let base = record.offset+fallback,n = try Self.u32(bytes,base)
                for j in 0..<n { let start = Self.u24(bytes,base+4+j*4);if Int(unicode)>=start,Int(unicode)<=start+Int(bytes[base+7+j*4]) { return try glyph(unicode:unicode) } }
            }
            return nil
        }
        return nil
    }
    private static func u24(_ bytes:[UInt8],_ p:Int)->Int { Int(bytes[p])<<16 | Int(bytes[p+1])<<8 | Int(bytes[p+2]) }
    private func checkedCmap(offset:Int,bound:Int) throws {
        let result:Result<Void,Error>
        if let cached = cmapAuditCache[offset] { result = cached }
        else { result = Result{try auditCmap(offset:offset,bound:bound)};cmapAuditCache[offset] = result }
        try result.get()
    }
    func symbolicGlyph(code: UInt8) throws -> Int? {
        guard let cmap = tables["cmap"] else { return nil }
        for record in cmapRecords where (record.platform == 3 && record.encoding == 0) || (record.platform == 1 && record.encoding == 0) {
            for offset: UInt32 in record.platform == 3 ? [0,0xF000,0xF100,0xF200]:[0] {
                if let glyph = try cmapGlyph(UInt32(code)+offset,offset:record.offset,bound:cmap.upperBound), glyph != 0 { return glyph }
            }
            return 0
        }
        return nil
    }
    func builtInGlyphName(code:UInt8) -> String? {
        if let type1 { return type1.encoding[code] }
        if let cff {
            if let gid = cff.encoding[code] { return glyphName(gid) }
            if cff.standardEncoding { return PDFArchiveFontEncoding.standardNames[code] ?? ".notdef" }
            if cff.expertEncoding { return ".notdef" }
        }
        return nil
    }
    private func cmapGlyph(_ code: UInt32, offset: Int, bound: Int) throws -> Int? {
        let bytes = self.bytes, format = try Self.u16(bytes,offset)
        func word(_ p:Int) throws -> Int { guard p+2 <= bound else { throw PDFStructureError.malformed("cmap fuori tabella") }; return try Self.u16(bytes,p) }
        if format == 0 { let length = try word(offset+2); guard length >= 262, offset+length <= bound else { throw PDFStructureError.malformed("cmap0") }; return code < 256 ? Int(bytes[offset+6+Int(code)]) : 0 }
        if format == 2 {
            try checkedCmap(offset:offset,bound:bound);guard code<=65535 else { return 0 }
            let high = Int(code)>>8,low = Int(code)&255,key = try word(offset+6+(high == 0 ? low:high)*2)
            if (high == 0 && key != 0) || (high != 0 && key == 0) { return 0 }
            let sub = offset+518+(high == 0 ? 0:key),first = try word(sub),count = try word(sub+2)
            guard low>=first,low<first+count else { return 0 }
            let value = try word(sub+6+(try word(sub+6))+(low-first)*2)
            return value == 0 ? 0:(value+(try word(sub+4)))&65535
        }
        if format == 4 {
            guard code <= 65535 else { return 0 }
            let length = try word(offset+2), count = try word(offset+6)/2
            guard count > 0, count < 32768, length >= 16+count*8, offset+length <= bound else { throw PDFStructureError.malformed("cmap4") }
            let end = offset+14, start = end+count*2+2, delta = start+count*2, ranges = delta+count*2
            for i in 0..<count {
                let first = try word(start+i*2),last = try word(end+i*2)
                guard Int(code)>=first,Int(code)<=last else { continue }
                let adjustment = try word(delta+i*2), range = try word(ranges+i*2)
                if range == 0 { return (Int(code)+adjustment)&65535 }
                let position = ranges+i*2+range+(Int(code)-(try word(start+i*2)))*2
                guard position+2 <= offset+length else { throw PDFStructureError.malformed("cmap4 glyph array") }
                let glyph = try word(position); return glyph == 0 ? 0 : (glyph+adjustment)&65535
            }
            return 0
        }
        if format == 6 {
            let length = try word(offset+2), first = try word(offset+6), count = try word(offset+8)
            guard offset+length <= bound, length >= 10+count*2 else { throw PDFStructureError.malformed("cmap6") }
            return Int(code) >= first && Int(code)<first+count ? try word(offset+10+(Int(code)-first)*2) : 0
        }
        if format == 8 || format == 12 || format == 13 {
            if format == 8 { try checkedCmap(offset:offset,bound:bound) }
            let prefix = format == 8 ? 8208:16
            let length = try Self.u32(bytes,offset+4), count = try Self.u32(bytes,offset+prefix-4)
            guard count < 1_000_000, length >= prefix, count <= (length-prefix)/12, offset+length <= bound else { throw PDFStructureError.malformed("cmap8/12/13") }
            for i in 0..<count {
                let p = offset+prefix+i*12, first = try Self.u32(bytes,p), last = try Self.u32(bytes,p+4)
                if Int(code)>=first && Int(code)<=last { return try Self.u32(bytes,p+8)+(format != 13 ? Int(code)-first : 0) }
            }
            return 0
        }
        if format == 10 {
            try checkedCmap(offset:offset,bound:bound)
            let first = try Self.u32(bytes,offset+12),count = try Self.u32(bytes,offset+16)
            return Int(code)>=first && Int(code)<first+count ? try word(offset+20+(Int(code)-first)*2):0
        }
        return nil
    }
    func advance(glyph: Int) throws -> Double? {
        guard glyph >= 0, glyph < glyphCount else { return nil }
        if let hhea = tables["hhea"], let hmtx = tables["hmtx"], hhea.count >= 36 {
            let bytes = self.bytes, count = try Self.u16(bytes,hhea.lowerBound+34)
            guard count > 0, count <= glyphCount, count*4+(glyphCount-count)*2 <= hmtx.count else { throw PDFStructureError.malformed("hmtx") }
            let width = try Self.u16(bytes,hmtx.lowerBound+min(glyph,count-1)*4)
            return Double(width)*1000/Double(unitsPerEm)
        }
        if let type1, let name = glyphName(glyph) { return try type1.advance(name:name) }
        if let cff {
            let result:Result<Double?,Error>
            if let cached = cffWidthCache[glyph] { result = cached }
            else {
                result = Result { do { return try cff.declaredAdvance(glyph:glyph) } catch PDFStructureError.unsupported { return nil } }
                cffWidthCache[glyph] = result
            }
            if let width = try result.get() { return width }
        }
        if let native {
            var gid = CGGlyph(glyph), width: Int32 = 0
            if native.getGlyphAdvances(glyphs:&gid,count:1,advances:&width) { return Double(width)*1000/Double(unitsPerEm) }
        }
        return nil
    }
    func verticalMetrics(glyph:Int) throws -> (advance:Double,originY:Double?)? {
        guard glyph>=0,glyph<glyphCount,let vhea = tables["vhea"],vhea.count>=36,let vmtx = tables["vmtx"] else { return nil }
        let bytes = self.bytes,count = try Self.u16(bytes,vhea.lowerBound+34)
        guard count>0,count<=glyphCount,count*4+(glyphCount-count)*2<=vmtx.count else { throw PDFStructureError.malformed("vmtx") }
        let advance = try Self.u16(bytes,vmtx.lowerBound+min(glyph,count-1)*4)
        let bearingPosition = glyph<count ? vmtx.lowerBound+glyph*4+2:vmtx.lowerBound+count*4+(glyph-count)*2
        let bearing = Int(Int16(bitPattern:UInt16(try Self.u16(bytes,bearingPosition))))
        var origin:Int?
        if format == .sfntCFF,let vorg = tables["VORG"],vorg.count>=8 {
            origin = Int(Int16(bitPattern:UInt16(try Self.u16(bytes,vorg.lowerBound+4))))
            let count = try Self.u16(bytes,vorg.lowerBound+6)
            guard 8+count*4<=vorg.count else { throw PDFStructureError.malformed("VORG") }
            for i in 0..<count where try Self.u16(bytes,vorg.lowerBound+8+i*4) == glyph { origin = Int(Int16(bitPattern:UInt16(try Self.u16(bytes,vorg.lowerBound+10+i*4)))) }
        } else if let loca = tables["loca"],let glyf = tables["glyf"],let head = tables["head"] {
            let format = try Self.u16(bytes,head.lowerBound+50),size = format == 0 ? 2:4
            guard (glyphCount+1)*size<=loca.count else { throw PDFStructureError.malformed("loca verticale") }
            let start = format == 0 ? try Self.u16(bytes,loca.lowerBound+glyph*2)*2:try Self.u32(bytes,loca.lowerBound+glyph*4)
            let end = format == 0 ? try Self.u16(bytes,loca.lowerBound+(glyph+1)*2)*2:try Self.u32(bytes,loca.lowerBound+(glyph+1)*4)
            guard start<=end,end<=glyf.count else { throw PDFStructureError.malformed("glyf verticale") }
            if start == end { origin = bearing }
            else { guard end-start>=10 else { throw PDFStructureError.malformed("glyph header verticale") };origin = Int(Int16(bitPattern:UInt16(try Self.u16(bytes,glyf.lowerBound+start+8))))+bearing }
        }
        return(Double(advance)*1000/Double(unitsPerEm),origin.map { Double($0)*1000/Double(unitsPerEm) })
    }
    func glyphDataIsPresent(_ glyph: Int) throws -> Bool {
        guard glyph >= 0, glyph < glyphCount else { return false }
        if let type1,let name = glyphName(glyph) { return type1.charStrings[name] != nil }
        if let cff { return glyph < cff.glyphCount && !cff.charStrings[glyph].isEmpty }
        if let loca = tables["loca"], let glyf = tables["glyf"], let head = tables["head"] {
            let bytes = self.bytes, format = try Self.u16(bytes,head.lowerBound+50)
            let stride = format == 0 ? 2 : 4
            guard (glyphCount+1)*stride <= loca.count, format == 0 || format == 1 else { throw PDFStructureError.malformed("loca") }
            func position(_ i:Int) throws -> Int { format == 0 ? try Self.u16(bytes,loca.lowerBound+i*2)*2 : try Self.u32(bytes,loca.lowerBound+i*4) }
            let start = try position(glyph), end = try position(glyph+1)
            guard start <= end, end <= glyf.count else { throw PDFStructureError.malformed("loca/glyf") }
            // Empty outlines (e.g. space) are legitimate glyphs.
            return true
        }
        return native != nil
    }
}


struct PDFArchiveFontProgramAudit {
    var issues:[String] = []
    var gaps:[String] = []
    var checkedGlyphs = 0
    var instructionBytes = 0
    var instructionPrograms = 0
    var instructionScanComplete = false
}

extension PDFArchiveFontProgram {
    /// Binary structure and instruction token boundaries are checked from the
    /// actual program. This does not execute the TrueType hinting machine.
    func structuralAudit(maximumOperations:Int = 8_000_000,maximumComponentDepth:Int = 64) -> PDFArchiveFontProgramAudit {
        var audit = PDFArchiveFontProgramAudit()
        guard format == .sfntTrueType || format == .sfntCFF else {
            if format == .cff,let cff { return cff.programAudit(maximumOperations:maximumOperations) }
            else { audit.gaps.append("Semantica completa del programma PostScript/CharStrings Type1 non dimostrata.") }
            return audit
        }
        let bytes = self.bytes
        func fail(_ detail:String) { if audit.issues.count<64 { audit.issues.append(detail) } }
        func gap(_ detail:String) { if !audit.gaps.contains(detail) { audit.gaps.append(detail) } }
        func u16(_ offset:Int) throws -> Int { try Self.u16(bytes,offset) }
        func i16(_ offset:Int) throws -> Int { Int(Int16(bitPattern:UInt16(try u16(offset)))) }
        func u32(_ offset:Int) throws -> Int { try Self.u32(bytes,offset) }
        var remainingOperations = max(0,maximumOperations)
        func charge(_ count:Int = 1) throws {
            try Task.checkCancellation()
            guard count<=remainingOperations else { remainingOperations = 0;throw PDFStructureError.limit }
            remainingOperations -= count
        }
        func instructionTokens(_ input:Data,_ context:String) throws {
            audit.instructionPrograms += 1;audit.instructionBytes += input.count
            guard audit.instructionBytes<=16*1024*1024 else { throw PDFStructureError.limit }
            let code = Array(input);var cursor = 0
            while cursor<code.count {
                try charge()
                let op = code[cursor];cursor += 1
                var count = 0
                if op == 0x40 || op == 0x41 {
                    guard cursor<code.count else { throw PDFStructureError.malformed(context + ": NPUSH privo di conteggio") }
                    count = Int(code[cursor])*(op == 0x41 ? 2:1);cursor += 1
                } else if (0xB0...0xB7).contains(op) { count = Int(op-0xB0)+1 }
                else if (0xB8...0xBF).contains(op) { count = (Int(op-0xB8)+1)*2 }
                guard count<=code.count-cursor else { throw PDFStructureError.malformed(context + ": PUSH troncato") };cursor += count
            }
            if !code.isEmpty { gap("Bytecode TrueType: token PUSH verificati; stack, salti, FDEF/IDEF, CVT, storage e geometria di hinting non eseguiti.") }
        }
        do {
            try charge()
            let directoryEnd = 12+(try u16(4))*16
            let occupied = tables.filter{!$0.value.isEmpty}.sorted{$0.value.lowerBound<$1.value.lowerBound}
            for (index,table) in occupied.enumerated() {
                if table.value.lowerBound<directoryEnd { fail("Tabella \(table.key) sovrapposta alla directory SFNT.") }
                if index>0,occupied[index-1].value.upperBound>table.value.lowerBound { fail("Tabelle \(occupied[index-1].key)/\(table.key) sovrapposte.") }
            }
            guard let head = tables["head"],head.count>=54,let maxp = tables["maxp"],maxp.count>=6 else { throw PDFStructureError.malformed("head/maxp troncate") }
            if try u32(head.lowerBound+12) != 0x5F0F3CF5 { fail("head.magicNumber non valido.") }
            if let hhea = tables["hhea"],let hmtx = tables["hmtx"] {
                if hhea.count<36 { fail("hhea troncata.") }
                else { let count = try u16(hhea.lowerBound+34);if count == 0 || count>glyphCount || count*4+(glyphCount-count)*2>hmtx.count { fail("hmtx/numberOfHMetrics non coerenti con numGlyphs.") } }
            }
            if let vhea = tables["vhea"],let vmtx = tables["vmtx"] {
                if vhea.count<36 { fail("vhea troncata.") }
                else { let count = try u16(vhea.lowerBound+34);if count == 0 || count>glyphCount || count*4+(glyphCount-count)*2>vmtx.count { fail("vmtx/numberOfVMetrics non coerenti con numGlyphs.") } }
            }
            if format == .sfntCFF,let vorg = tables["VORG"] {
                if vorg.count<8 { fail("VORG troncata.") }
                else {
                    let version = try u32(vorg.lowerBound),count = try u16(vorg.lowerBound+6)
                    if version != 0x10000 || 8+count*4>vorg.count { fail("VORG versione/lunghezza non valida.") }
                    else { var previous = -1;for index in 0..<count { let gid = try u16(vorg.lowerBound+8+index*4);if gid<=previous || gid>=glyphCount { fail("VORG GID non ordinati/univoci o fuori numGlyphs.") };previous = gid } }
                }
            }
            if let cmap = tables["cmap"] {
                var inspected = Set<Int>()
                for record in cmapRecords {
                    do {
                        if inspected.insert(record.offset).inserted { try checkedCmap(offset:record.offset,bound:cmap.upperBound) }
                        if try Self.u16(bytes,record.offset) == 14,record.platform != 0 || record.encoding != 5 { fail("cmap14 richiede platform0/encoding5.") }
                    }
                    catch PDFStructureError.unsupported(let why) { gap(why) }
                    catch PDFStructureError.limit { gap("Budget verifica cmap superato.") }
                    catch { fail(error.localizedDescription) }
                }
            }
            if format == .sfntCFF {
                if cff?.glyphCount != glyphCount { fail("maxp.numGlyphs diverso da CFF CharStrings count.") }
                if let compact = cff?.programAudit(maximumOperations:remainingOperations) {
                    audit.checkedGlyphs = compact.checkedGlyphs;audit.instructionPrograms = compact.instructionPrograms;audit.instructionBytes = compact.instructionBytes
                    audit.issues += compact.issues
                    for detail in compact.gaps { gap(detail) }
                }
                return audit
            }
            if try u32(maxp.lowerBound) != 0x10000 || maxp.count<32 { throw PDFStructureError.malformed("TrueType glyf richiede maxp versione1.0 e32byte") }
            guard let loca = tables["loca"],let glyf = tables["glyf"] else { throw PDFStructureError.malformed("glyf/loca assenti") }
            let locaFormat = try i16(head.lowerBound+50)
            guard locaFormat == 0 || locaFormat == 1 else { throw PDFStructureError.malformed("indexToLocFormat non0/1") }
            let entrySize = locaFormat == 0 ? 2:4
            guard (glyphCount+1)*entrySize<=loca.count else { throw PDFStructureError.malformed("loca non contiene numGlyphs+1 offset") }
            var offsets:[Int] = []
            for gid in 0...glyphCount {
                let value = locaFormat == 0 ? try u16(loca.lowerBound+gid*2)*2:try u32(loca.lowerBound+gid*4)
                guard value<=glyf.count,offsets.last.map({$0<=value}) ?? true else { throw PDFStructureError.malformed("loca offset non monotoni/fuori glyf") };offsets.append(value)
            }
            struct Component { let glyph:Int;let matchingPoints:(parent:Int,child:Int)? }
            struct GlyphShape { var points = 0;var contours = 0;var components:[Component] = [];var complete = false }
            var shapes = Array(repeating:GlyphShape(),count:glyphCount)
            let maxPoints = try u16(maxp.lowerBound+6),maxContours = try u16(maxp.lowerBound+8),maxInstructions = try u16(maxp.lowerBound+26),maxComponents = try u16(maxp.lowerBound+28)
            audit.instructionScanComplete = true
            for gid in 0..<glyphCount {
                let start = glyf.lowerBound+offsets[gid],end = glyf.lowerBound+offsets[gid+1]
                do {
                    try charge();audit.checkedGlyphs += 1
                    if start == end { shapes[gid].complete = true;continue }
                    guard end-start>=10 else { throw PDFStructureError.malformed("glyph\(gid): header minore di10byte") }
                    let contours = try i16(start)
                    // Every negative count denotes a composite; -1 is only
                    // recommended by both Apple and the OpenType glyf table.
                    guard try i16(start+2)<=i16(start+6),try i16(start+4)<=i16(start+8) else { throw PDFStructureError.malformed("glyph\(gid): bounding box non valido") }
                    var cursor = start+10,instructions = Data()
                    if contours>=0 {
                        try charge(contours)
                        guard cursor+contours*2<=end else { throw PDFStructureError.malformed("glyph\(gid): endPtsOfContours troncato") }
                        var previous = -1
                        for _ in 0..<contours { let last = try u16(cursor);cursor += 2;guard last>previous else { throw PDFStructureError.malformed("glyph\(gid): endPtsOfContours non crescente") };previous = last }
                        let points = previous+1;shapes[gid].points = points;shapes[gid].contours = contours
                        if points>maxPoints || contours>maxContours { fail("glyph\(gid): punti/contorni superano maxp.") }
                        if contours == 0,cursor == end { shapes[gid].complete = true;continue }
                        guard cursor+2<=end else { throw PDFStructureError.malformed("glyph\(gid): instructionLength troncato") }
                        let length = try u16(cursor);cursor += 2
                        guard length<=end-cursor else { throw PDFStructureError.malformed("glyph\(gid): instructions troncate") }
                        instructions = Data(bytes[cursor..<(cursor+length)]);cursor += length
                        var flags:[UInt8] = []
                        try charge(points)
                        while flags.count<points {
                            guard cursor<end else { throw PDFStructureError.malformed("glyph\(gid): flags troncati") };let flag = bytes[cursor];cursor += 1;var repeatCount = 1
                            if flag&8 != 0 { guard cursor<end else { throw PDFStructureError.malformed("glyph\(gid): repeat flag troncato") };repeatCount += Int(bytes[cursor]);cursor += 1 }
                            guard repeatCount<=points-flags.count else { throw PDFStructureError.malformed("glyph\(gid): repeat flag supera i punti") };flags += Array(repeating:flag,count:repeatCount)
                            if flag&0x80 != 0 { fail("glyph\(gid): flag semplice riservato bit7 non zero.") }
                        }
                        var needed = 0
                        for flag in flags { needed += flag&2 != 0 ? 1:(flag&16 != 0 ? 0:2);needed += flag&4 != 0 ? 1:(flag&32 != 0 ? 0:2) }
                        guard needed<=end-cursor else { throw PDFStructureError.malformed("glyph\(gid): coordinate troncate") }
                        // Coordinates are deltas, not absolute positions. The
                        // two packed arrays have independent signs/short bits.
                        // Compare original control points only: no hinting or
                        // variable-font instance coordinates are invented.
                        func coordinateBounds(short:UInt8,same:UInt8) throws -> (Int,Int)? {
                            try charge(points)
                            var position = 0,minimum:Int?,maximum:Int?
                            for (index,flag) in flags.enumerated() {
                                if index&1023 == 0 { try Task.checkCancellation() }
                                if flag&short != 0 {
                                    let delta = Int(bytes[cursor]);cursor += 1
                                    position += flag&same != 0 ? delta:-delta
                                } else if flag&same == 0 { position += try i16(cursor);cursor += 2 }
                                minimum = min(minimum ?? position,position);maximum = max(maximum ?? position,position)
                            }
                            return minimum.flatMap { low in maximum.map { (low,$0) } }
                        }
                        let x = try coordinateBounds(short:2,same:16),y = try coordinateBounds(short:4,same:32)
                        if let x,let y {
                            let xMin = try i16(start+2),yMin = try i16(start+4),xMax = try i16(start+6),yMax = try i16(start+8)
                            if x.0<xMin || x.1>xMax || y.0<yMin || y.1>yMax { fail("glyph\(gid): bounding box non contiene i punti originali decodificati.") }
                        }
                    } else {
                        var more = true,hasInstructions = false
                        while more {
                            try charge()
                            guard cursor+4<=end else { throw PDFStructureError.malformed("glyph\(gid): componente troncata") }
                            let flags = try u16(cursor),child = try u16(cursor+2);cursor += 4
                            guard child<glyphCount else { throw PDFStructureError.malformed("glyph\(gid): componente GID fuori numGlyphs") }
                            let transforms = [8,64,128].filter{flags&$0 != 0}
                            guard transforms.count<=1,flags&0x1800 != 0x1800 else { throw PDFStructureError.malformed("glyph\(gid): flag trasformazione componente incompatibili") }
                            let length = (flags&1 != 0 ? 4:2)+(flags&8 != 0 ? 2:flags&64 != 0 ? 4:flags&128 != 0 ? 8:0)
                            guard length<=end-cursor else { throw PDFStructureError.malformed("glyph\(gid): argomenti/matrice componente troncati") }
                            // Point numbers are unsigned, even when XY offsets
                            // of the same physical size would be signed.
                            let matching:(parent:Int,child:Int)?
                            if flags&2 == 0 {
                                matching = flags&1 != 0 ? (try u16(cursor),try u16(cursor+2)):(Int(bytes[cursor]),Int(bytes[cursor+1]))
                                if shapes[gid].components.isEmpty { fail("glyph\(gid): primo componente richiede ARGS_ARE_XY_VALUES.") }
                                gap("Indici degli agganci punto-punto verificati; coordinate finali dopo hinting e trasformazioni non eseguite.")
                            } else { matching = nil }
                            shapes[gid].components.append(.init(glyph:child,matchingPoints:matching));cursor += length
                            if flags&0xE000 != 0 { fail("glyph\(gid): flag componente riservati non zero.") }
                            // Apple AATIntro documents a historical bit4
                            // overlap flag ignored by all scalers. Current
                            // OpenType calls it reserved; do not retroactively
                            // reject a legacy TrueType program on that basis.
                            if flags&0x10 != 0 { gap("Flag componente legacy bit4: edizione/overlap storico non attestati; bit ignorato secondo Apple AAT.") }
                            more = flags&32 != 0;hasInstructions = hasInstructions || flags&256 != 0
                            guard shapes[gid].components.count<=4096 else { throw PDFStructureError.limit }
                        }
                        if shapes[gid].components.count>maxComponents { fail("glyph\(gid): componenti superano maxp.maxComponentElements.") }
                        if hasInstructions {
                            guard cursor+2<=end else { throw PDFStructureError.malformed("glyph\(gid): composite instructionLength troncato") };let length = try u16(cursor);cursor += 2
                            guard length<=end-cursor else { throw PDFStructureError.malformed("glyph\(gid): composite instructions troncate") };instructions = Data(bytes[cursor..<(cursor+length)])
                        }
                    }
                    if instructions.count>maxInstructions { fail("glyph\(gid): instructionLength supera maxp.maxSizeOfInstructions.") }
                    try instructionTokens(instructions,"glyph\(gid)")
                    shapes[gid].complete = true
                } catch is CancellationError { throw CancellationError() }
                catch PDFStructureError.limit {
                    audit.instructionScanComplete = false;gap("Budget dati glyf/istruzioni superato; verifica incompleta.")
                    if remainingOperations == 0 { break }
                }
                catch { audit.instructionScanComplete = false;fail(error.localizedDescription) }
            }
            var summaries:[Int:(points:Int,contours:Int,depth:Int)] = [:]
            func summary(_ gid:Int,_ active:Set<Int>) throws -> (points:Int,contours:Int,depth:Int) {
                try charge()
                if let cached = summaries[gid] { return cached }
                guard !active.contains(gid) else { throw PDFStructureError.malformed("ciclo nelle componenti glyf") }
                guard active.count<max(0,maximumComponentDepth) else { throw PDFStructureError.limit }
                let shape = shapes[gid]
                guard shape.complete else { throw PDFStructureError.unsupported("contorni componente non interamente decodificati") }
                if shape.components.isEmpty { let result = (shape.points,shape.contours,0);summaries[gid] = result;return result }
                var points = 0,contours = 0,depth = 0,parentMatches:[(index:Int,priorPoints:Int)] = []
                for child in shape.components {
                    let value = try summary(child.glyph,active.union([gid]))
                    // Four phantom points follow the original contour points
                    // and may participate in both parent and child alignment.
                    // Their positions after hinting remain outside this audit.
                    if let match = child.matchingPoints {
                        parentMatches.append((match.parent,points))
                        if match.child>=value.points+4 { fail("glyph\(gid): indice punto componente fuori contorni e4phantom points.") }
                    }
                    points += value.points;contours += value.contours;depth = max(depth,value.depth+1)
                    guard points<=1_000_000,contours<=1_000_000 else { throw PDFStructureError.limit }
                }
                for match in parentMatches {
                    if match.index>=points+4 { fail("glyph\(gid): indice punto parent fuori contorni e4phantom points.") }
                    else if match.index>=match.priorPoints+4 {
                        // The spec explicitly permits parent phantom points;
                        // the numbering at an intermediate incorporation step
                        // is not independently proven by this count-only model.
                        gap("Numerazione intermedia phantom points del parent composito non provata; nessun indice viene dichiarato fuori range per ipotesi.")
                    }
                }
                let result = (points,contours,depth);summaries[gid] = result;return result
            }
            for gid in 0..<glyphCount where !shapes[gid].components.isEmpty {
                do {
                    let value = try summary(gid,[])
                    let maxCompositePoints = try u16(maxp.lowerBound+10),maxCompositeContours = try u16(maxp.lowerBound+12),maxDepth = try u16(maxp.lowerBound+30)
                    if value.points>maxCompositePoints || value.contours>maxCompositeContours || value.depth>maxDepth { fail("glyph\(gid): aggregati compositi superano maxp.") }
                } catch is CancellationError { throw CancellationError() }
                catch PDFStructureError.limit { gap("Budget componenti compositi superato; esito non verificato.") }
                catch PDFStructureError.unsupported(let why) { gap("glyph\(gid): " + why) }
                catch { fail(error.localizedDescription) }
            }
            for tag in ["fpgm","prep"] {
                if let range = tables[tag] {
                    do { try instructionTokens(Data(bytes[range]),tag) }
                    catch is CancellationError { throw CancellationError() }
                    catch PDFStructureError.limit { audit.instructionScanComplete = false;gap("Budget fpgm/prep superato; verifica incompleta.") }
                    catch { audit.instructionScanComplete = false;fail(error.localizedDescription) }
                }
            }
        } catch is CancellationError { audit.instructionScanComplete = false;audit.gaps.append("Verifica programma font annullata.") }
        catch PDFStructureError.limit { audit.instructionScanComplete = false;audit.gaps.append("Budget di verifica del programma font superato.") }
        catch { fail(error.localizedDescription) }
        return audit
    }
    private func auditCmap(offset:Int,bound:Int) throws {
        let bytes = self.bytes,format = try Self.u16(bytes,offset)
        func word(_ position:Int) throws -> Int { guard position>=offset,position+2<=bound else { throw PDFStructureError.malformed("cmap troncata") };return try Self.u16(bytes,position) }
        func dword(_ position:Int) throws -> Int { guard position>=offset,position+4<=bound else { throw PDFStructureError.malformed("cmap troncata") };return try Self.u32(bytes,position) }
        func gid(_ value:Int) throws { guard value<glyphCount else { throw PDFStructureError.malformed("cmap GID fuori numGlyphs") } }
        if format == 2 {
            let length = try word(offset+2)
            guard length>=526,length<=bound-offset else { throw PDFStructureError.malformed("cmap2 lunghezza") }
            var maximum = 0
            for code in 0..<256 { let key = try word(offset+6+code*2);guard key%8 == 0 else { throw PDFStructureError.malformed("cmap2 subHeaderKey non multiplo8") };maximum = max(maximum,key) }
            let subCount = maximum/8+1,glyphArray = offset+518+subCount*8,end = offset+length
            guard glyphArray<=end else { throw PDFStructureError.malformed("cmap2 subHeaders troncati") }
            for i in 0..<subCount {
                let p = offset+518+i*8,first = try word(p),count = try word(p+2),delta = try word(p+4),range = try word(p+6)
                guard first<=255,count<=256,first+count<=256 else { throw PDFStructureError.malformed("cmap2 firstCode/entryCount") }
                if count>0 {
                    let start = p+6+range
                    guard range%2 == 0,start>=glyphArray,start<=end,count*2<=end-start else { throw PDFStructureError.malformed("cmap2 idRangeOffset fuori glyphIdArray") }
                    for j in 0..<count { let raw = try word(start+j*2);try gid(raw == 0 ? 0:(raw+delta)&65535) }
                }
            };return
        }
        if format == 8 {
            let length = try dword(offset+4)
            guard length>=8208,length<=bound-offset,try word(offset+2) == 0 else { throw PDFStructureError.malformed("cmap8 reserved/length") }
            let count = try dword(offset+8204)
            guard count<1_000_000,count<=(length-8208)/12 else { throw PDFStructureError.malformed("cmap8 gruppi troncati") }
            func is32(_ word:Int)->Bool { bytes[offset+12+word/8] & (1 << (7-word%8)) != 0 }
            var previous = -1
            for i in 0..<count {
                let p = offset+8208+i*12,first = try dword(p),last = try dword(p+4),start = try dword(p+8)
                guard first<=last,first>previous else { throw PDFStructureError.malformed("cmap8 gruppi non ordinati") };previous = last
                try gid(start+last-first)
                if last<=65535 && !is32(0) {
                    for code in first...last where is32(code) { throw PDFStructureError.malformed("cmap8 codice16 marcato is32") }
                } else {
                    for high in (first>>16)...(last>>16) where !is32(high) { throw PDFStructureError.malformed("cmap8 codice32 senza is32") }
                }
            };return
        }
        if format == 14 {
            let length = try dword(offset+2),count = try dword(offset+6)
            guard length>=10,length<=bound-offset,count<=(length-10)/11 else { throw PDFStructureError.malformed("cmap14 header/length") }
            let recordsEnd = offset+10+count*11,end = offset+length
            func scalar(_ value:Int)->Bool { value<=0x10FFFF && !(0xD800...0xDFFF).contains(value) }
            func table(_ relative:Int,_ size:Int) throws -> (Int,Int) {
                let p = offset+relative
                guard p>=recordsEnd,p<=end-4 else { throw PDFStructureError.malformed("cmap14 offset UVS") }
                let n = try dword(p);guard n<=(end-p-4)/size else { throw PDFStructureError.malformed("cmap14 UVS troncata") };return (p,n)
            }
            var previous = -1
            for i in 0..<count {
                let p = offset+10+i*11,selector = Self.u24(bytes,p),defaultOffset = try dword(p+3),explicitOffset = try dword(p+7)
                let isSelector = (0x180B...0x180D).contains(selector) || selector == 0x180F || (0xFE00...0xFE0F).contains(selector) || (0xE0100...0xE01EF).contains(selector)
                guard isSelector,selector>previous else { throw PDFStructureError.malformed("cmap14 selector non valido/ordinato/univoco") };previous = selector
                var defaults:[ClosedRange<Int>] = []
                if defaultOffset != 0 {
                    let (base,n) = try table(defaultOffset,4);var last = -1
                    for j in 0..<n {
                        let first = Self.u24(bytes,base+4+j*4),end = first+Int(bytes[base+7+j*4])
                        guard scalar(first),scalar(end),!(first<0xD800 && end>0xDFFF),first>last else { throw PDFStructureError.malformed("cmap14 default UVS range non valido") }
                        defaults.append(first...end);last = end
                    }
                }
                if explicitOffset != 0 {
                    let (base,n) = try table(explicitOffset,5);var last = -1,rangeIndex = 0
                    for j in 0..<n {
                        let code = Self.u24(bytes,base+4+j*5)
                        guard scalar(code),code>last else { throw PDFStructureError.malformed("cmap14 non-default UVS ordine/scalare") };last = code
                        while rangeIndex<defaults.count && defaults[rangeIndex].upperBound<code { rangeIndex += 1 }
                        guard rangeIndex == defaults.count || !defaults[rangeIndex].contains(code) else { throw PDFStructureError.malformed("cmap14 UVS in default e non-default") }
                        try gid(word(base+7+j*5))
                    }
                }
            };return
        }
        if [0,4,6].contains(format) {
            let length = try word(offset+2);guard length>=6,length<=bound-offset else { throw PDFStructureError.malformed("cmap lunghezza non valida") };let end = offset+length
            if format == 0 { guard length>=262 else { throw PDFStructureError.malformed("cmap0 troncata") };for code in bytes[(offset+6)..<(offset+262)] { try gid(Int(code)) };return }
            if format == 6 { let first = try word(offset+6),count = try word(offset+8);guard 10+count*2<=length,first+count<=65536 else { throw PDFStructureError.malformed("cmap6 troncata/range") };for i in 0..<count { try gid(word(offset+10+i*2)) };return }
            let raw = try word(offset+6),count = raw/2
            guard raw%2 == 0,count>0,16+count*8<=length else { throw PDFStructureError.malformed("cmap4 segCount/length") }
            let ends = offset+14,starts = ends+count*2+2,deltas = starts+count*2,ranges = deltas+count*2,glyphArray = ranges+count*2
            guard try word(ends+count*2) == 0 else { throw PDFStructureError.malformed("cmap4 reservedPad") }
            var previous = -1
            for i in 0..<count {
                let first = try word(starts+i*2),last = try word(ends+i*2),delta = try word(deltas+i*2),range = try word(ranges+i*2)
                guard first<=last,last>previous else { throw PDFStructureError.malformed("cmap4 segmenti non ordinati") };previous = last
                for code in first...last {
                    if range == 0 { try gid((code+delta)&65535) }
                    else {
                        let position = ranges+i*2+range+(code-first)*2
                        guard position>=glyphArray,position+2<=end else { throw PDFStructureError.malformed("cmap4 idRangeOffset fuori glyphIdArray") }
                        let raw = try word(position);try gid(raw == 0 ? 0:(raw+delta)&65535)
                    }
                }
            }
            guard previous == 65535 else { throw PDFStructureError.malformed("cmap4 senza segmento sentinella FFFF") };return
        }
        if format == 10 || format == 12 || format == 13 {
            let length = try dword(offset+4);guard length<=bound-offset,length>=16 else { throw PDFStructureError.malformed("cmap10/12/13 lunghezza") }
            if format == 10 {
                let first = try dword(offset+12),count = try dword(offset+16)
                guard count<=65536,20+count*2<=length,first<=0x10FFFF,count<=0x110000-first else { throw PDFStructureError.malformed("cmap10 range") }
                for index in 0..<count { try gid(word(offset+20+index*2)) };return
            }
            let count = try dword(offset+12);guard count<=0x110000,16+count*12<=length else { throw PDFStructureError.malformed("cmap12/13 groups") }
            var previous = -1
            for i in 0..<count {
                let position = offset+16+i*12,first = try dword(position),last = try dword(position+4),start = try dword(position+8)
                guard first<=last,last<=0x10FFFF,first>previous else { throw PDFStructureError.malformed("cmap12/13 gruppi non ordinati") };previous = last
                try gid(start+(format == 12 ? last-first:0))
            };return
        }
        throw PDFStructureError.unsupported("cmap formato\(format): struttura/mapping non verificati integralmente.")
    }
}

/// Factual CFF1 tables independently transcribed from Adobe Technical Note
/// 5176 (4Dec2003), AppendicesA–C. No external font engine code is used.
private enum PDFArchiveCFFPredefined {
    static let strings = """
    .notdef space exclam quotedbl numbersign dollar percent ampersand quoteright parenleft parenright asterisk plus comma hyphen period slash zero one two three four five six seven eight nine colon semicolon less equal greater question at A B C D E F G H I J K L M N O P Q R S T U V W X Y Z bracketleft backslash bracketright asciicircum underscore quoteleft a b c d e f g h i j k l m n o p q r s t u v w x y z braceleft bar braceright asciitilde exclamdown cent sterling fraction yen florin section currency quotesingle quotedblleft guillemotleft guilsinglleft guilsinglright fi fl endash dagger daggerdbl periodcentered paragraph bullet quotesinglbase quotedblbase quotedblright guillemotright ellipsis perthousand questiondown grave acute circumflex tilde macron breve dotaccent dieresis ring cedilla hungarumlaut ogonek caron emdash AE ordfeminine Lslash Oslash OE ordmasculine ae dotlessi lslash oslash oe germandbls onesuperior logicalnot mu trademark Eth onehalf plusminus Thorn onequarter divide brokenbar degree thorn threequarters twosuperior registered minus eth multiply threesuperior copyright Aacute Acircumflex Adieresis Agrave Aring Atilde Ccedilla Eacute Ecircumflex Edieresis Egrave Iacute Icircumflex Idieresis Igrave Ntilde Oacute Ocircumflex Odieresis Ograve Otilde Scaron Uacute Ucircumflex Udieresis Ugrave Yacute Ydieresis Zcaron aacute acircumflex adieresis agrave aring atilde ccedilla eacute ecircumflex edieresis egrave iacute icircumflex idieresis igrave ntilde oacute ocircumflex odieresis ograve otilde scaron uacute ucircumflex udieresis ugrave yacute ydieresis zcaron exclamsmall Hungarumlautsmall dollaroldstyle dollarsuperior ampersandsmall Acutesmall parenleftsuperior parenrightsuperior twodotenleader onedotenleader zerooldstyle oneoldstyle twooldstyle threeoldstyle fouroldstyle fiveoldstyle sixoldstyle sevenoldstyle eightoldstyle nineoldstyle commasuperior threequartersemdash periodsuperior questionsmall asuperior bsuperior centsuperior dsuperior esuperior isuperior lsuperior msuperior nsuperior osuperior rsuperior ssuperior tsuperior ff ffi ffl parenleftinferior parenrightinferior Circumflexsmall hyphensuperior Gravesmall Asmall Bsmall Csmall Dsmall Esmall Fsmall Gsmall Hsmall Ismall Jsmall Ksmall Lsmall Msmall Nsmall Osmall Psmall Qsmall Rsmall Ssmall Tsmall Usmall Vsmall Wsmall Xsmall Ysmall Zsmall colonmonetary onefitted rupiah Tildesmall exclamdownsmall centoldstyle Lslashsmall Scaronsmall Zcaronsmall Dieresissmall Brevesmall Caronsmall Dotaccentsmall Macronsmall figuredash hypheninferior Ogoneksmall Ringsmall Cedillasmall questiondownsmall oneeighth threeeighths fiveeighths seveneighths onethird twothirds zerosuperior foursuperior fivesuperior sixsuperior sevensuperior eightsuperior ninesuperior zeroinferior oneinferior twoinferior threeinferior fourinferior fiveinferior sixinferior seveninferior eightinferior nineinferior centinferior dollarinferior periodinferior commainferior Agravesmall Aacutesmall Acircumflexsmall Atildesmall Adieresissmall Aringsmall AEsmall Ccedillasmall Egravesmall Eacutesmall Ecircumflexsmall Edieresissmall Igravesmall Iacutesmall Icircumflexsmall Idieresissmall Ethsmall Ntildesmall Ogravesmall Oacutesmall Ocircumflexsmall Otildesmall Odieresissmall OEsmall Oslashsmall Ugravesmall Uacutesmall Ucircumflexsmall Udieresissmall Yacutesmall Thornsmall Ydieresissmall 001.000 001.001 001.002 001.003 Black Bold Book Light Medium Regular Roman Semibold
    """.split(whereSeparator:{$0.isWhitespace}).map(String.init)
    static let expertCharset:[Int] = [
        0,1,229,230,231,232,233,234,235,236,237,238,13,14,15,99,239,240,241,242,
        243,244,245,246,247,248,27,28,249,250,251,252,253,254,255,256,257,258,259,260,
        261,262,263,264,265,266,109,110,267,268,269,270,271,272,273,274,275,276,277,278,
        279,280,281,282,283,284,285,286,287,288,289,290,291,292,293,294,295,296,297,298,
        299,300,301,302,303,304,305,306,307,308,309,310,311,312,313,314,315,316,317,318,
        158,155,163,319,320,321,322,323,324,325,326,150,164,169,327,328,329,330,331,332,
        333,334,335,336,337,338,339,340,341,342,343,344,345,346,347,348,349,350,351,352,
        353,354,355,356,357,358,359,360,361,362,363,364,365,366,367,368,369,370,371,372,
        373,374,375,376,377,378
    ]
    static let expertSubsetCharset:[Int] = [
        0,1,231,232,235,236,237,238,13,14,15,99,239,240,241,242,243,244,245,246,
        247,248,27,28,249,250,251,253,254,255,256,257,258,259,260,261,262,263,264,265,
        266,109,110,267,268,269,270,272,300,301,302,305,314,315,158,155,163,320,321,322,
        323,324,325,326,150,164,169,327,328,329,330,331,332,333,334,335,336,337,338,339,
        340,341,342,343,344,345,346
    ]
    static let expertEncoding:[Int] = [
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
        0,0,0,0,0,0,0,0,0,0,0,0,1,229,230,0,231,232,233,234,
        235,236,237,238,13,14,15,99,239,240,241,242,243,244,245,246,247,248,27,28,
        249,250,251,252,0,253,254,255,256,257,0,0,0,258,0,0,259,260,261,262,
        0,0,263,264,265,0,266,109,110,267,268,269,0,270,271,272,273,274,275,276,
        277,278,279,280,281,282,283,284,285,286,287,288,289,290,291,292,293,294,295,296,
        297,298,299,300,301,302,303,0,0,0,0,0,0,0,0,0,0,0,0,0,
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
        0,304,305,306,0,0,307,308,309,310,311,0,312,0,0,313,0,0,314,315,
        0,0,316,317,318,0,0,0,158,155,163,319,320,321,322,323,324,325,0,0,
        326,150,164,169,327,328,329,330,331,332,333,334,335,336,337,338,339,340,341,342,
        343,344,345,346,347,348,349,350,351,352,353,354,355,356,357,358,359,360,361,362,
        363,364,365,366,367,368,369,370,371,372,373,374,375,376,377,378
    ]
}

/// CFF1 INDEX, Top DICT, String INDEX and charset reader. It validates actual
/// glyph/CID identity; arbitrary Type2 bytecode execution remains a separate gap.
struct PDFArchiveCFF {
    let glyphCount: Int
    let charStrings: [Data]
    let cidByGlyph: [Int:Int]
    let customNames: [Int:String]
    let encoding:[UInt8:Int]
    let standardEncoding:Bool
    let expertEncoding:Bool
    private let topDictionary:[Int:[Double]]
    private let globalSubrs:[Data]
    private struct WidthContext {
        let defaultWidth:Double,nominalWidth:Double
        let localSubrs:[Data]
        let fdMatrix:[Double]?
        let privateDictionary:[Int:[Double]]
    }
    private let widthContexts:[WidthContext]
    private let fdByGlyph:[Int]
    init(data: Data) throws {
        let bytes = Array(data);guard bytes.count >= 4, bytes[0] == 1, Int(bytes[2]) >= 4, Int(bytes[2]) <= bytes.count,(1...4).contains(bytes[3]) else { throw PDFStructureError.malformed("CFF header") }
        func index(_ offset:Int) throws -> ([Data],Int) {
            let count = try PDFArchiveFontProgram.u16(bytes,offset); if count == 0 { return ([],offset+2) }
            guard offset+3 <= bytes.count else { throw PDFStructureError.malformed("CFF INDEX") }
            let size = Int(bytes[offset+2]); guard (1...4).contains(size), count <= 65535, offset+3+(count+1)*size <= bytes.count else { throw PDFStructureError.malformed("CFF offSize") }
            var positions:[Int] = []
            for i in 0...count { var value = 0; for byte in bytes[(offset+3+i*size)..<(offset+3+(i+1)*size)] { value = value<<8 | Int(byte) }; positions.append(value) }
            let start = offset+3+(count+1)*size
            guard positions.first == 1, let last = positions.last, last >= 1, last-1 <= bytes.count-start else { throw PDFStructureError.malformed("CFF INDEX offsets") }
            var values:[Data] = []
            for i in 0..<count { guard positions[i]<=positions[i+1],positions[i]>=1 else { throw PDFStructureError.malformed("CFF INDEX order") }; values.append(Data(bytes[(start+positions[i]-1)..<(start+positions[i+1]-1)])) }
            return (values,start+last-1)
        }
        let names = try index(Int(bytes[2])), tops = try index(names.1), strings = try index(tops.1)
        guard names.0.count == 1, let top = tops.0.first else { throw PDFStructureError.unsupported("CFF FontSet con più font") }
        let dictionary = try Self.dictionary(top);topDictionary = dictionary;globalSubrs = try index(strings.1).0
        guard let rawOffset = dictionary[17]?.first,rawOffset>=0,rawOffset<Double(bytes.count),rawOffset.rounded(.towardZero) == rawOffset else { throw PDFStructureError.malformed("CFF CharStrings offset") }
        let offset = Int(rawOffset)
        guard offset >= 0 else { throw PDFStructureError.malformed("CFF CharStrings") }
        let characters = try index(offset).0; guard !characters.isEmpty else { throw PDFStructureError.malformed("CFF senza glifi") }
        charStrings = characters; glyphCount = characters.count
        let isCID = dictionary[1230] != nil, rawCharset = dictionary[15]?.first ?? 0
        guard rawCharset>=0,rawCharset<Double(bytes.count),rawCharset.rounded(.towardZero) == rawCharset else { throw PDFStructureError.malformed("CFF charset offset") }
        let charset = Int(rawCharset)
        var identifiers = [0], cursor = charset
        if charset <= 2 {
            guard !isCID else { throw PDFStructureError.malformed("CID CFF con charset predefinito") }
            if charset == 0 { guard glyphCount<=229 else { throw PDFStructureError.malformed("CFF ISOAdobe charset count") };identifiers += Array(1..<glyphCount) }
            else {
                let predefined = charset == 1 ? PDFArchiveCFFPredefined.expertCharset:PDFArchiveCFFPredefined.expertSubsetCharset
                guard glyphCount<=predefined.count else { throw PDFStructureError.malformed("CFF Expert charset count") };identifiers = Array(predefined.prefix(glyphCount))
            }
        } else {
            guard cursor < bytes.count else { throw PDFStructureError.malformed("CFF charset") }
            let format = bytes[cursor]; cursor += 1
            if format == 0 {
                for _ in 1..<glyphCount { identifiers.append(try PDFArchiveFontProgram.u16(bytes,cursor)); cursor += 2 }
            } else if format == 1 || format == 2 {
                while identifiers.count < glyphCount {
                    let first = try PDFArchiveFontProgram.u16(bytes,cursor); cursor += 2
                    let extra: Int
                    if format == 1 { guard cursor<bytes.count else { throw PDFStructureError.malformed("CFF range") }; extra = Int(bytes[cursor]); cursor += 1 }
                    else { extra = try PDFArchiveFontProgram.u16(bytes,cursor); cursor += 2 }
                    guard extra+1 <= glyphCount-identifiers.count,first+extra<=65535 else { throw PDFStructureError.malformed("CFF charset range") }
                    identifiers += Array(first...(first+extra))
                }
            } else { throw PDFStructureError.unsupported("CFF charset format") }
        }
        guard Set(identifiers).count == identifiers.count else { throw PDFStructureError.malformed("CFF charset SID/CID duplicati") }
        var cids:[Int:Int] = [:], glyphNames:[Int:String] = [0:".notdef"]
        for (glyph,value) in identifiers.enumerated() {
            if isCID { cids[glyph] = value }
            else if value<PDFArchiveCFFPredefined.strings.count { glyphNames[glyph] = PDFArchiveCFFPredefined.strings[value] }
            else {
                guard value-391<strings.0.count,let name = String(data:strings.0[value-391],encoding:.ascii),!name.isEmpty else { throw PDFStructureError.malformed("CFF charset SID non definito") };glyphNames[glyph] = name
            }
        }
        cidByGlyph = cids; customNames = glyphNames
        let rawEncoding = dictionary[16]?.first ?? 0
        guard rawEncoding>=0,rawEncoding<Double(bytes.count),rawEncoding.rounded(.towardZero) == rawEncoding else { throw PDFStructureError.malformed("CFF Encoding offset") }
        let encodingOffset = Int(rawEncoding);standardEncoding = !isCID && encodingOffset == 0;expertEncoding = !isCID && encodingOffset == 1
        var encoded:[UInt8:Int] = [:]
        if !isCID,encodingOffset == 1 {
            let gids = Dictionary(uniqueKeysWithValues:identifiers.enumerated().map{($0.element,$0.offset)})
            for code in 0..<256 { let sid = PDFArchiveCFFPredefined.expertEncoding[code];if sid != 0,let gid = gids[sid] { encoded[UInt8(code)] = gid } }
        }
        if !isCID,encodingOffset>1 {
            var p = encodingOffset;let format = bytes[p];p += 1
            guard p<bytes.count else { throw PDFStructureError.malformed("CFF Encoding") }
            let count = Int(bytes[p]);p += 1;var gid = 1
            if format&127 == 0 {
                guard p+count<=bytes.count,count<glyphCount else { throw PDFStructureError.malformed("CFF Encoding0") }
                for code in bytes[p..<(p+count)] { encoded[code] = gid;gid += 1 };p += count
            } else if format&127 == 1 {
                for _ in 0..<count {
                    guard p+2<=bytes.count else { throw PDFStructureError.malformed("CFF Encoding1") }
                    let first = Int(bytes[p]),extra = Int(bytes[p+1]);p += 2
                    guard first+extra<256,gid+extra<glyphCount else { throw PDFStructureError.malformed("CFF Encoding range") }
                    for code in first...(first+extra) { encoded[UInt8(code)] = gid;gid += 1 }
                }
            } else { throw PDFStructureError.unsupported("CFF Encoding format") }
            if format&128 != 0 {
                guard p<bytes.count else { throw PDFStructureError.malformed("CFF Encoding supplement") };let supplements = Int(bytes[p]);p += 1
                for _ in 0..<supplements {
                    guard p+3<=bytes.count else { throw PDFStructureError.malformed("CFF Encoding supplement") }
                    let code = bytes[p],sid = try PDFArchiveFontProgram.u16(bytes,p+1);p += 3
                    guard let gid = identifiers.firstIndex(of:sid) else { throw PDFStructureError.malformed("CFF Encoding supplement SID") };encoded[code] = gid
                }
            }
        }
        encoding = encoded
        let inventory = try Self.widthInventory(bytes:bytes,top:dictionary,glyphCount:glyphCount,isCID:isCID)
        widthContexts = inventory.0;fdByGlyph = inventory.1
    }
    private static func index(_ bytes:[UInt8],at offset:Int) throws -> [Data] {
        let count = try PDFArchiveFontProgram.u16(bytes,offset);if count == 0 { return [] }
        guard offset+3<=bytes.count else { throw PDFStructureError.malformed("CFF subroutine INDEX") };let size = Int(bytes[offset+2])
        guard (1...4).contains(size),offset+3+(count+1)*size<=bytes.count else { throw PDFStructureError.malformed("CFF subroutine INDEX offSize") }
        var positions:[Int] = []
        for i in 0...count { var n = 0;for byte in bytes[(offset+3+i*size)..<(offset+3+(i+1)*size)] { n = n<<8|Int(byte) };positions.append(n) }
        let start = offset+3+(count+1)*size
        guard positions.first == 1,let end = positions.last,end>=1,end-1<=bytes.count-start else { throw PDFStructureError.malformed("CFF subroutine INDEX bounds") }
        var result:[Data] = []
        for i in 0..<count { guard positions[i]<=positions[i+1] else { throw PDFStructureError.malformed("CFF subroutine INDEX order") };result.append(Data(bytes[(start+positions[i]-1)..<(start+positions[i+1]-1)])) };return result
    }
    /// All FD selectors and Private/Subrs INDEXes are inventoried, including
    /// dictionaries not selected by the first requested glyph. This proves
    /// bounds/association, not execution of every subroutine's Type2 program.
    private static func widthInventory(bytes:[UInt8],top:[Int:[Double]],glyphCount:Int,isCID:Bool) throws -> ([WidthContext],[Int]) {
        func integer(_ value:Double?)->Int? { guard let value,value.isFinite,value>=0,value<=Double(bytes.count),value.rounded(.towardZero) == value else { return nil };return Int(value) }
        func matrix(_ dictionary:[Int:[Double]]) throws -> [Double]? {
            guard let value = dictionary[1207] else { return nil }
            guard value.count == 6,value.allSatisfy(\.isFinite),value[0]*value[3]-value[1]*value[2] != 0 else { throw PDFStructureError.malformed("CFF FontMatrix non valida") };return value
        }
        _ = try matrix(top)
        var dictionaries = [top],selectors = Array(repeating:0,count:glyphCount)
        if isCID {
            guard let array = top[1236],array.count == 1,let fdOffset = integer(array.first),let selection = top[1237],selection.count == 1,let select = integer(selection.first),select<bytes.count else { throw PDFStructureError.malformed("CFF CID richiede FDArray/FDSelect validi") }
            dictionaries = try index(bytes,at:fdOffset).map{try dictionary($0)}
            guard !dictionaries.isEmpty else { throw PDFStructureError.malformed("CFF FDArray vuoto") }
            if bytes[select] == 0 {
                guard select+1+glyphCount<=bytes.count else { throw PDFStructureError.malformed("CFF FDSelect0 troncato") }
                selectors = bytes[(select+1)..<(select+1+glyphCount)].map(Int.init)
            } else if bytes[select] == 3 {
                let ranges = try PDFArchiveFontProgram.u16(bytes,select+1)
                guard ranges>0,select+3+ranges*3+2<=bytes.count else { throw PDFStructureError.malformed("CFF FDSelect3 bounds") }
                var previous = -1
                for range in 0..<ranges {
                    let p = select+3+range*3,first = try PDFArchiveFontProgram.u16(bytes,p),end = try PDFArchiveFontProgram.u16(bytes,p+3),fd = Int(bytes[p+2])
                    guard first>previous,first<end,end<=glyphCount,(range != 0 || first == 0) else { throw PDFStructureError.malformed("CFF FDSelect3 ranges") };previous = first
                    for glyph in first..<end { selectors[glyph] = fd }
                }
                guard try PDFArchiveFontProgram.u16(bytes,select+3+ranges*3) == glyphCount else { throw PDFStructureError.malformed("CFF FDSelect3 sentinel") }
            } else { throw PDFStructureError.unsupported("CFF FDSelect formato non supportato") }
            guard selectors.allSatisfy({$0<dictionaries.count}) else { throw PDFStructureError.malformed("CFF FDSelect FD fuori FDArray") }
        }
        var contexts:[WidthContext] = []
        for font in dictionaries {
            var local:[Data] = [],defaultWidth = 0.0,nominalWidth = 0.0
            var privateDictionary:[Int:[Double]] = [:]
            if let entry = font[18] {
                guard entry.count == 2,let size = integer(entry.first),let offset = integer(entry.last),size<=bytes.count-offset else { throw PDFStructureError.malformed("CFF Private DICT bounds") }
                privateDictionary = try dictionary(Data(bytes[offset..<(offset+size)]))
                if let value = privateDictionary[20] { guard value.count == 1,value[0].isFinite else { throw PDFStructureError.malformed("CFF defaultWidthX") };defaultWidth = value[0] }
                if let value = privateDictionary[21] { guard value.count == 1,value[0].isFinite else { throw PDFStructureError.malformed("CFF nominalWidthX") };nominalWidth = value[0] }
                if let entry = privateDictionary[19] {
                    guard entry.count == 1,let relative = integer(entry.first),relative<bytes.count-offset else { throw PDFStructureError.malformed("CFF localSubrs offset") }
                    local = try index(bytes,at:offset+relative)
                }
            }
            contexts.append(WidthContext(defaultWidth:defaultWidth,nominalWidth:nominalWidth,localSubrs:local,fdMatrix:isCID ? try matrix(font):nil,privateDictionary:privateDictionary))
        }
        return (contexts,selectors)
    }
    var structureGaps:[String] {
        widthContexts.contains(where:{$0.fdMatrix != nil}) ? ["CFF FD FontMatrix: composizione con Top FontMatrix non verificata integralmente."]:[]
    }
    /// Executes bounded stack/control structure, never rasterizer hinting or
    /// outline geometry. Reserved/legacy and value-undefined cases stay gaps.
    func programAudit(maximumOperations:Int = 2_000_000) -> PDFArchiveFontProgramAudit {
        var audit = PDFArchiveFontProgramAudit(),operations = 0
        audit.gaps = structureGaps
        audit.gaps.append("Esecuzione completa Type2: geometria outline, sovrapposizione hint, seac e programmi non raggiunti non dimostrati.")
        func fail(_ detail:String) { if audit.issues.count<64 { audit.issues.append(detail) } }
        func gap(_ detail:String) { if !audit.gaps.contains(detail) { audit.gaps.append(detail) } }
        for (fd,context) in widthContexts.enumerated() {
            // CFF5176 Table23 and Type1§5.3–5.9: delta-array cardinalities.
            for (op,maximum) in [(6,14),(7,10),(8,14),(9,10)] {
                if let values = context.privateDictionary[op],values.count%2 != 0 || values.count>maximum { fail("CFF FD\(fd) Private: BlueValues/OtherBlues array di cardinalità non valida.") }
            }
            for op in [10,11,1209,1210,1211,1214,1217,1218,1219,19,20,21] {
                if let values = context.privateDictionary[op],values.count != 1 { fail("CFF FD\(fd) Private: operatore scalare \(op) con \(values.count) operandi.") }
            }
            for op in [1212,1213] {
                if let values = context.privateDictionary[op],values.count>12 { fail("CFF FD\(fd) Private: StemSnap oltre12 elementi.") }
            }
        }
        guard topDictionary[1206]?.first ?? 2 == 2 else { gap("Type2: CharstringType diverso da2 non eseguito.");return audit }
        enum Stop { case returned,finished }
        for glyph in 0..<glyphCount {
            let context = widthContexts[fdByGlyph[glyph]]
            var stack:[Double] = [],transient:[Int:Double] = [:],widthSeen = false,pathStarted = false,stems = 0
            func require(_ count:Int) throws { guard stack.count>=count else { throw PDFStructureError.malformed("Type2 stack insufficiente") } }
            func integer(_ number:Double,_ field:String) throws -> Int {
                guard number.isFinite,number.rounded(.towardZero) == number,number>=Double(Int32.min),number<=Double(Int32.max) else { throw PDFStructureError.unsupported("Type2 \(field) non intero/risolto") };return Int(number)
            }
            func clearPath(_ valid:Bool) throws {
                guard pathStarted else { throw PDFStructureError.malformed("Type2 path senza moveto") }
                guard valid else { throw PDFStructureError.malformed("Type2 arità operatore path non valida") };stack.removeAll(keepingCapacity:true)
            }
            func settleWidth(_ required:Int,stem:Bool = false,finish:Bool = false) {
                guard !widthSeen else { return };widthSeen = true
                if (stem && stack.count%2 == 1) || (finish && [1,5].contains(stack.count)) || (!stem && !finish && stack.count == required+1) { stack.removeFirst() }
            }
            func execute(_ input:Data,depth:Int) throws -> Stop {
                guard depth<=10 else { throw PDFStructureError.limit }
                let code = Array(input);var p = 0
                while p<code.count {
                    operations += 1;guard operations<=maximumOperations else { throw PDFStructureError.limit }
                    if operations%256 == 0 { try Task.checkCancellation() }
                    let op = code[p];p += 1
                    if op>=32 && op<=246 { stack.append(Double(Int(op)-139)) }
                    else if op>=247 && op<=254 {
                        guard p<code.count else { throw PDFStructureError.malformed("Type2 numero troncato") }
                        stack.append(Double(op<=250 ? (Int(op)-247)*256+Int(code[p])+108:-(Int(op)-251)*256-Int(code[p])-108));p += 1
                    } else if op == 28 { let n = try PDFArchiveFontProgram.u16(code,p);p += 2;stack.append(Double(Int16(bitPattern:UInt16(n)))) }
                    else if op == 255 { let n = try PDFArchiveFontProgram.u32(code,p);p += 4;stack.append(Double(Int32(bitPattern:UInt32(n)))/65536) }
                    else if op == 10 || op == 29 {
                        try require(1);let index = try integer(stack.removeLast(),"subroutine"),subrs = op == 10 ? context.localSubrs:globalSubrs
                        let bias = subrs.count<1240 ? 107:subrs.count<33900 ? 1131:32768
                        guard index>=(-bias),index<subrs.count-bias else { throw PDFStructureError.malformed("Type2 subroutine fuori INDEX") }
                        if case .finished = try execute(subrs[index+bias],depth:depth+1) { return .finished }
                    } else if op == 11 {
                        guard depth>0 else { throw PDFStructureError.malformed("Type2 return fuori subroutine") };return .returned
                    } else if [1,3,18,23,19,20].contains(op) {
                        settleWidth(0,stem:true)
                        let mask = op == 19 || op == 20
                        guard stack.count%2 == 0,(mask || stack.count>=2),(!pathStarted || stack.isEmpty) else { throw PDFStructureError.malformed("Type2 arità/posizione dichiarazione stem non valida") }
                        stems += stack.count/2;stack.removeAll(keepingCapacity:true)
                        guard stems<=96 else { throw PDFStructureError.limit }
                        if mask {
                            guard stems>0 else { throw PDFStructureError.malformed("Type2 mask senza stem") }
                            let count = (stems+7)/8
                            guard count<=code.count-p else { throw PDFStructureError.malformed("Type2 hintmask/cntrmask troncata") }
                            let unused = count*8-stems
                            guard unused == 0 || code[p+count-1] & UInt8((1<<unused)-1) == 0 else { throw PDFStructureError.malformed("Type2 mask bit inutilizzati non zero") };p += count
                        }
                    } else if [4,21,22].contains(op) {
                        let count = op == 21 ? 2:1;settleWidth(count)
                        guard stack.count == count else { throw PDFStructureError.malformed("Type2 arità moveto non valida") }
                        pathStarted = true;stack.removeAll(keepingCapacity:true)
                    } else if op == 5 { try clearPath(stack.count>=2 && stack.count%2 == 0) }
                    else if op == 6 || op == 7 { try clearPath(!stack.isEmpty) }
                    else if op == 8 { try clearPath(stack.count>=6 && stack.count%6 == 0) }
                    else if op == 24 { try clearPath(stack.count>=8 && (stack.count-2)%6 == 0) }
                    else if op == 25 { try clearPath(stack.count>=8 && (stack.count-6)%2 == 0) }
                    else if [26,27,30,31].contains(op) { try clearPath(stack.count>=4 && [0,1].contains(stack.count%4)) }
                    else if op == 14 {
                        settleWidth(0,finish:true)
                        guard [0,4].contains(stack.count) else { throw PDFStructureError.malformed("Type2 arità endchar non valida") }
                        if stack.count == 4 { throw PDFStructureError.unsupported("Type2 seac: dipendenze StandardEncoding/geometria non eseguite") }
                        return .finished
                    } else if op == 12 {
                        guard p<code.count else { throw PDFStructureError.malformed("Type2 escape troncato") };let escaped = code[p];p += 1
                        switch escaped {
                        case 0:break // deprecated dotsection is a no-op (AppendixC).
                        case 3,4,10,11,12,15,24:
                            try require(2);let b = stack.removeLast(),a = stack.removeLast()
                            if escaped == 12,b == 0 { throw PDFStructureError.unsupported("Type2 div per zero: risultato indefinito") }
                            let value:Double
                            switch escaped { case 3:value = a != 0 && b != 0 ? 1:0;case 4:value = a != 0 || b != 0 ? 1:0;case 10:value = a+b;case 11:value = a-b;case 12:value = a/b;case 15:value = a == b ? 1:0;default:value = a*b }
                            stack.append(value)
                        case 5,9,14,26:
                            try require(1);let value = stack.removeLast()
                            if escaped == 26,value<0 { throw PDFStructureError.unsupported("Type2 sqrt negativa: risultato indefinito") }
                            stack.append(escaped == 5 ? (value == 0 ? 1:0):escaped == 9 ? abs(value):escaped == 14 ? -value:sqrt(value))
                        case 18:try require(1);stack.removeLast()
                        case 20:
                            try require(2);let index = try integer(stack.removeLast(),"put"),value = stack.removeLast()
                            guard (0..<32).contains(index) else { throw PDFStructureError.unsupported("Type2 transient index non risolto") };transient[index] = value
                        case 21:
                            try require(1);let index = try integer(stack.removeLast(),"get")
                            guard let value = transient[index] else { throw PDFStructureError.unsupported("Type2 get prima di put: valore indefinito") };stack.append(value)
                        case 22:
                            try require(4);let v2 = stack.removeLast(),v1 = stack.removeLast(),s2 = stack.removeLast(),s1 = stack.removeLast();stack.append(v1<=v2 ? s1:s2)
                        case 23:throw PDFStructureError.unsupported("Type2 random: valore dipendente dal rasterizer non eseguito")
                        case 27:try require(1);stack.append(stack.last!)
                        case 28:try require(2);stack.swapAt(stack.count-1,stack.count-2)
                        case 29:
                            try require(2);let index = max(0,try integer(stack.removeLast(),"index"))
                            guard index<stack.count else { throw PDFStructureError.unsupported("Type2 index fuori stack: risultato indefinito") };stack.append(stack[stack.count-1-index])
                        case 30:
                            try require(2);let shift = try integer(stack.removeLast(),"roll"),count = try integer(stack.removeLast(),"roll")
                            guard count>=0,count<=stack.count else { throw PDFStructureError.unsupported("Type2 roll fuori stack: risultato indefinito") }
                            if count>0 { let amount = ((shift%count)+count)%count,values = Array(stack.suffix(count));stack.removeLast(count);stack += Array(values.suffix(amount))+Array(values.prefix(count-amount)) }
                        case 34,35,36,37:
                            let count = escaped == 34 ? 7:escaped == 35 ? 13:escaped == 36 ? 9:11;try clearPath(stack.count == count)
                        default:throw PDFStructureError.unsupported("Type2 operatore escape \(escaped) riservato/legacy non eseguito")
                        }
                    } else { throw PDFStructureError.unsupported("Type2 operatore \(op) riservato/legacy non eseguito") }
                    guard stack.count<=48 else { throw PDFStructureError.malformed("Type2 stack oltre48") }
                    guard stack.allSatisfy(\.isFinite) else { throw PDFStructureError.unsupported("Type2 overflow aritmetico: risultato indefinito") }
                }
                throw PDFStructureError.malformed(depth == 0 ? "Type2 endchar assente":"Type2 subroutine senza return/endchar")
            }
            do {
                try Task.checkCancellation();audit.instructionPrograms += 1;audit.instructionBytes += charStrings[glyph].count
                _ = try execute(charStrings[glyph],depth:0);audit.checkedGlyphs += 1
            } catch PDFStructureError.malformed(let why) { fail("CFF GID\(glyph): " + why) }
            catch PDFStructureError.limit { gap("Type2 budget/nesting/stem limit: verifica incompleta.");break }
            catch is CancellationError { gap("Type2 verifica annullata.");break }
            catch { gap("CFF GID\(glyph): " + error.localizedDescription) }
        }
        return audit
    }
    /// Extracts Type2 advance from actual Private DICT and the first
    /// width-defining operator, including bounded local/global subroutine calls.
    /// It does not claim that later path/hint instructions are valid.
    func declaredAdvance(glyph:Int) throws -> Double? {
        guard glyph>=0,glyph<glyphCount,topDictionary[1206]?.first ?? 2 == 2 else { return nil }
        let context = widthContexts[fdByGlyph[glyph]]
        // An explicit FD matrix has different composition rules from a Top
        // matrix; it stays unresolved rather than multiplying guessed units.
        guard context.fdMatrix == nil else { return nil }
        let local = context.localSubrs,defaultWidth = context.defaultWidth,nominalWidth = context.nominalWidth
        let matrix = topDictionary[1207] ?? [0.001,0,0,0.001,0,0]
        guard matrix.count == 6,matrix.allSatisfy(\.isFinite),matrix[1] == 0,matrix[2] == 0 else { return nil }
        var stack:[Double] = [],steps = 0
        enum Outcome { case width(Double),returned,unresolved }
        func interpret(_ input:Data,depth:Int) throws -> Outcome {
            guard depth<=10 else { throw PDFStructureError.unsupported("Type2 limite di nesting subroutine") }
            let code = Array(input);var p = 0
            func arity(_ count:Int) throws { guard stack.count>=count else { throw PDFStructureError.malformed("Type2 stack width insufficiente") } }
            while p<code.count {
                steps += 1;guard steps<=100_000 else { throw PDFStructureError.limit };let value = code[p];p += 1
                if value>=32 && value<=246 { stack.append(Double(Int(value)-139)) }
                else if value>=247 && value<=254 {
                    guard p<code.count else { throw PDFStructureError.malformed("Type2 numero troncato") }
                    let n = value<=250 ? (Int(value)-247)*256+Int(code[p])+108:-(Int(value)-251)*256-Int(code[p])-108;stack.append(Double(n));p += 1
                } else if value == 28 { let n = try PDFArchiveFontProgram.u16(code,p);p += 2;stack.append(Double(Int16(bitPattern:UInt16(n)))) }
                else if value == 255 { let n = try PDFArchiveFontProgram.u32(code,p);p += 4;stack.append(Double(Int32(bitPattern:UInt32(n)))/65536) }
                else if value == 10 || value == 29 {
                    try arity(1);let index = stack.removeLast(),subrs = value == 10 ? local:globalSubrs,bias = subrs.count<1240 ? 107:subrs.count<33900 ? 1131:32768
                    guard index.isFinite,index.rounded(.towardZero) == index,index>=Double(-bias),index<Double(subrs.count-bias) else { throw PDFStructureError.malformed("Type2 indice subroutine width non valido") }
                    let result = try interpret(subrs[Int(index)+bias],depth:depth+1)
                    switch result { case .returned:break;default:return result }
                } else if value == 11 { return .returned }
                else if [1,3,18,19,20,23].contains(value) { return .width(stack.count%2 == 1 ? nominalWidth+stack[0]:defaultWidth) }
                else if value == 4 || value == 22 {
                    guard stack.count == 1 || stack.count == 2 else { throw PDFStructureError.malformed("Type2 moveto width arity") };return .width(stack.count == 2 ? nominalWidth+stack[0]:defaultWidth)
                } else if value == 21 {
                    guard stack.count == 2 || stack.count == 3 else { throw PDFStructureError.malformed("Type2 rmoveto width arity") };return .width(stack.count == 3 ? nominalWidth+stack[0]:defaultWidth)
                } else if value == 14 {
                    guard [0,1,4,5].contains(stack.count) else { throw PDFStructureError.malformed("Type2 endchar width arity") };return .width([1,5].contains(stack.count) ? nominalWidth+stack[0]:defaultWidth)
                } else if value == 12 {
                    guard p<code.count else { throw PDFStructureError.malformed("Type2 escape width troncato") };let op = code[p];p += 1
                    switch op {
                    case 9:try arity(1);stack[stack.count-1] = abs(stack.last!)
                    case 10,11,12,24:
                        try arity(2);let b = stack.removeLast(),a = stack.removeLast()
                        if op == 12,b == 0 { return .unresolved };stack.append(op == 10 ? a+b:op == 11 ? a-b:op == 12 ? a/b:a*b)
                    case 14:try arity(1);stack[stack.count-1] = -stack.last!
                    case 18:try arity(1);stack.removeLast()
                    case 26:try arity(1);guard stack.last!>=0 else { return .unresolved };stack[stack.count-1] = sqrt(stack.last!)
                    case 27:try arity(1);stack.append(stack.last!)
                    case 28:try arity(2);stack.swapAt(stack.count-1,stack.count-2)
                    default:return .unresolved
                    }
                } else { return .unresolved }
                guard stack.count<=48,stack.allSatisfy(\.isFinite) else { throw PDFStructureError.malformed("Type2 width stack oltre48/non finito") }
            }
            return .unresolved
        }
        if case .width(let width) = try interpret(charStrings[glyph],depth:0) { return width*matrix[0]*1000 };return nil
    }
    static func dictionary(_ data: Data) throws -> [Int:[Double]] {
        let bytes = Array(data); var cursor = 0, stack:[Double] = [], result:[Int:[Double]] = [:]
        while cursor < bytes.count {
            let value = bytes[cursor]; cursor += 1
            if value <= 21 {
                let operation: Int
                if value == 12 { guard cursor<bytes.count else { throw PDFStructureError.malformed("CFF DICT escape") }; operation = 1200+Int(bytes[cursor]); cursor += 1 }
                else { operation = Int(value) }
                result[operation] = stack; stack = []
            } else if value == 28 { let raw = try PDFArchiveFontProgram.u16(bytes,cursor); cursor += 2; stack.append(Double(Int(Int16(bitPattern:UInt16(raw))))) }
            else if value == 29 { let raw = try PDFArchiveFontProgram.u32(bytes,cursor); cursor += 4; stack.append(Double(Int32(bitPattern:UInt32(raw)))) }
            else if value == 30 {
                var string = "", ended = false
                while cursor<bytes.count && !ended { let byte = bytes[cursor]; cursor += 1; for nibble in [byte>>4,byte&15] { if nibble == 15 { ended = true; break }; switch nibble { case 0...9:string += String(nibble); case 10:string += "."; case 11:string += "E"; case 12:string += "E-"; case 14:string += "-"; default:throw PDFStructureError.malformed("CFF real") } } }
                guard ended,let real = Double(string),real.isFinite else { throw PDFStructureError.malformed("CFF real") }; stack.append(real)
            } else if value >= 32 && value <= 246 { stack.append(Double(Int(value)-139)) }
            else if value >= 247 && value <= 250 { guard cursor<bytes.count else { throw PDFStructureError.malformed("CFF number") }; stack.append(Double((Int(value)-247)*256+Int(bytes[cursor])+108)); cursor += 1 }
            else if value >= 251 && value <= 254 { guard cursor<bytes.count else { throw PDFStructureError.malformed("CFF number") }; stack.append(Double(-(Int(value)-251)*256-Int(bytes[cursor])-108)); cursor += 1 }
            else { throw PDFStructureError.unsupported("CFF DICT number") }
            guard stack.count <= 96 else { throw PDFStructureError.limit }
        }
        guard stack.isEmpty else { throw PDFStructureError.malformed("CFF DICT operandi senza operatore") }
        return result
    }
}

struct PDFArchiveCMap {
    struct Space { let low:Data,high:Data }
    var codeSpaces:[Space] = []
    var unicode:[Data:Data] = [:]
    var cids:[Data:Int] = [:]
    var name:String?, registry:String?, ordering:String?, supplement:Int?, writingMode = 0
    var baseName:String?
    var identityCID = false
    var writingModeDefined = false
    var referencedNames:[String] = []
    var notdefRanges:[(low:Data,high:Data,cid:Int)] = []
    var maximalCID:Int { max(cids.values.max() ?? 0,notdefRanges.map(\.cid).max() ?? 0) }
    init(data: Data) throws {
        guard data.count <= 16*1024*1024 else { throw PDFStructureError.limit }
        var lexer = PDFSyntaxLexer(data), previous:PDFSyntaxValue?, operands:[PDFSyntaxValue] = []
        func count(_ previous:PDFSyntaxValue?) throws -> Int { guard let count = previous?.int,count >= 0,count <= 100_000 else { throw PDFStructureError.malformed("conteggio CMap") }; return count }
        while true {
            lexer.skip(); if lexer.offset == lexer.bytes.count { break }
            let value = try lexer.value()
            if case .keyword(let operation) = value {
                if operation == "begincodespacerange" {
                    for _ in 0..<(try count(previous)) { guard let low = try lexer.value().data,let high = try lexer.value().data,low.count == high.count,(1...4).contains(low.count),Self.integer(low)<=Self.integer(high) else { throw PDFStructureError.malformed("codespace") }; codeSpaces.append(.init(low:low,high:high)) }
                } else if operation == "beginnotdefrange" || operation == "beginnotdefchar" {
                    for _ in 0..<(try count(previous)) {
                        guard let low = try lexer.value().data,(1...4).contains(low.count) else { throw PDFStructureError.malformed("notdef CMap") }
                        let high:Data;if operation == "beginnotdefrange" { guard let value = try lexer.value().data,value.count == low.count else { throw PDFStructureError.malformed("notdefrange") };high = value } else { high = low }
                        guard let cid = try lexer.value().int,cid>=0,Self.integer(low)<=Self.integer(high) else { throw PDFStructureError.malformed("notdef CID") };notdefRanges.append((low,high,cid))
                    }
                } else if operation == "beginbfchar" || operation == "begincidchar" {
                    for _ in 0..<(try count(previous)) { guard let code = try lexer.value().data,(1...4).contains(code.count) else { throw PDFStructureError.malformed("CMap source") }; let target = try lexer.value(); if operation == "beginbfchar" { guard let bytes = target.data else { throw PDFStructureError.malformed("bfchar") }; unicode[code] = bytes } else { guard let cid = target.int,cid>=0 else { throw PDFStructureError.malformed("cidchar") }; cids[code] = cid } }
                } else if operation == "beginbfrange" || operation == "begincidrange" {
                    for _ in 0..<(try count(previous)) {
                        guard let low = try lexer.value().data,let high = try lexer.value().data,low.count == high.count,(1...4).contains(low.count) else { throw PDFStructureError.malformed("CMap range") }
                        let first = Self.integer(low),last = Self.integer(high),target = try lexer.value()
                        guard last>=first,last-first<100_000 else { throw PDFStructureError.limit }
                        for offset in 0...(last-first) {
                            let source = Self.bytes(first+offset,count:low.count)
                            if operation == "begincidrange" { guard let cid = target.int,cid>=0,cid<=Int.max-offset else { throw PDFStructureError.malformed("cidrange") }; cids[source] = cid+offset }
                            else if let array = target.array { guard offset<array.count,let value = array[offset].data else { throw PDFStructureError.malformed("bfrange array") }; unicode[source] = value }
                            else if let start = target.data { guard start.count <= 32 else { throw PDFStructureError.limit }; var result = Array(start),carry = offset; for i in result.indices.reversed() { let sum = Int(result[i])+(carry&255); result[i] = UInt8(sum&255); carry = (carry>>8)+(sum>>8) }; guard carry == 0 else { throw PDFStructureError.malformed("bfrange overflow") }; unicode[source] = Data(result) }
                            else { throw PDFStructureError.malformed("bfrange target") }
                        }
                    }
                } else if operation == "usecmap" { baseName = previous?.name;if let baseName { referencedNames.append(baseName) } }
                else if operation == "def",operands.count >= 2,let key = operands[operands.count-2].name {
                    let value = operands.last!
                    if key == "WMode" { guard let mode = value.int,[0,1].contains(mode) else { throw PDFStructureError.malformed("WMode CMap") };writingMode = mode;writingModeDefined = true }
                    if key == "CMapName" { name = value.name }
                    if key == "CIDSystemInfo",let dictionary = value.dictionary { registry = dictionary["Registry"]?.text; ordering = dictionary["Ordering"]?.text; supplement = dictionary["Supplement"]?.int }
                    if key == "Registry" { registry = value.text };if key == "Ordering" { ordering = value.text };if key == "Supplement" { supplement = value.int }
                }
                operands.removeAll(keepingCapacity:true)
            } else { operands.append(value); guard operands.count<100_000 else { throw PDFStructureError.limit } }
            previous = value
            guard unicode.count+cids.count <= 1_000_000 else { throw PDFStructureError.limit }
        }
    }
    static func identity(vertical: Bool) -> Self {
        var map = try! Self(data:Data()); map.name = vertical ? "Identity-V":"Identity-H"; map.identityCID = true; map.writingModeDefined = true; map.writingMode = vertical ? 1:0
        map.codeSpaces = [.init(low:Data([0,0]),high:Data([255,255]))]; return map
    }
    func codes(in data:Data) throws -> [Data] {
        let bytes = Array(data); var cursor = 0,result:[Data] = []
        let spaces = codeSpaces.sorted { $0.low.count<$1.low.count }
        guard !spaces.isEmpty else { throw PDFStructureError.unsupported("CMap senza codespace risolto") }
        while cursor<bytes.count {
            var found:Data?
            for space in spaces where cursor+space.low.count<=bytes.count {
                let code = Data(bytes[cursor..<(cursor+space.low.count)]),number = Self.integer(code)
                if number>=Self.integer(space.low),number<=Self.integer(space.high) { found = code;break }
            }
            guard let code = found else { throw PDFStructureError.malformed("codice fuori codespace CMap") }; result.append(code);cursor += code.count
        }
        return result
    }
    func cid(_ code:Data)->Int? {
        if let value = cids[code] { return value };if identityCID { return Self.integer(code) }
        let value = Self.integer(code)
        return notdefRanges.first { $0.low.count == code.count && value>=Self.integer($0.low) && value<=Self.integer($0.high) }?.cid ?? 0
    }
    func inheriting(_ base:Self)->Self {
        var result = self
        result.unicode = base.unicode.merging(unicode){_,new in new};result.cids = base.cids.merging(cids){_,new in new}
        result.codeSpaces = base.codeSpaces + codeSpaces.filter { item in !base.codeSpaces.contains{$0.low == item.low && $0.high == item.high} }
        result.notdefRanges = notdefRanges+base.notdefRanges;result.identityCID = identityCID || base.identityCID
        if !writingModeDefined { result.writingMode = base.writingMode }
        if registry == nil { result.registry = base.registry };if ordering == nil { result.ordering = base.ordering };if supplement == nil { result.supplement = base.supplement }
        result.referencedNames = referencedNames+base.referencedNames;return result
    }
    static func integer(_ data:Data)->Int { data.reduce(0) { ($0<<8)|Int($1) } }
    static func bytes(_ value:Int,count:Int)->Data { Data((0..<count).reversed().map { UInt8((value>>($0*8))&255) }) }
    static func unicodeString(_ data:Data)->String? {
        guard !data.isEmpty,data.count%2 == 0 else { return nil }
        var scalars = String.UnicodeScalarView(),units:[UInt16] = []
        for pair in stride(from:0,to:data.count,by:2) { units.append(UInt16(data[pair])<<8|UInt16(data[pair+1])) }
        var index = 0
        while index<units.count {
            let value = units[index]; index += 1
            if (0xD800...0xDBFF).contains(value) { guard index<units.count,(0xDC00...0xDFFF).contains(units[index]) else { return nil }; let scalar = 0x10000+(UInt32(value)-0xD800)*1024+UInt32(units[index])-0xDC00; index += 1; guard let unicode = UnicodeScalar(scalar) else { return nil }; scalars.append(unicode) }
            else { guard !(0xDC00...0xDFFF).contains(value),let scalar = UnicodeScalar(value) else { return nil }; scalars.append(scalar) }
        }
        return String(scalars)
    }
}

/// Supported standard encodings and Adobe-style uniXXXX/uXXXXX names. Unknown
/// names remain unknown instead of being interpreted as arbitrary Unicode.
enum PDFArchiveFontEncoding {
    static func resolvedFontHeader(_ dictionary:[String:PDFSyntaxValue],reader:PDFStructureDocument) throws -> [String:PDFSyntaxValue] {
        var result = dictionary
        for field in ["Type","Subtype","BaseFont"] { if let value = dictionary[field] { result[field] = try reader.resolve(value) } };return result
    }
    // ISO 32000-1 Annex D character names, kept separate from the much
    // larger AGL: membership in AGL alone is not an approved PDF encoding.
    static let latinNames = Set("""
    space exclam quotedbl numbersign dollar percent ampersand quoteright parenleft parenright asterisk plus comma hyphen period slash zero one two three four five six seven eight nine colon semicolon less equal greater question at A B C D E F G H I J K L M N O P Q R S T U V W X Y Z bracketleft backslash bracketright asciicircum underscore quoteleft a b c d e f g h i j k l m n o p q r s t u v w x y z braceleft bar braceright asciitilde exclamdown cent sterling fraction yen florin section currency quotesingle quotedblleft guillemotleft guilsinglleft guilsinglright fi fl endash dagger daggerdbl periodcentered paragraph bullet quotesinglbase quotedblbase quotedblright guillemotright ellipsis perthousand questiondown grave acute circumflex tilde macron breve dotaccent dieresis ring cedilla hungarumlaut ogonek caron emdash AE ordfeminine Lslash Oslash OE ordmasculine ae dotlessi lslash oslash oe germandbls onesuperior logicalnot mu trademark Eth onehalf plusminus Thorn onequarter divide brokenbar degree thorn threequarters twosuperior registered minus eth multiply threesuperior copyright Aacute Acircumflex Adieresis Agrave Aring Atilde Ccedilla Eacute Ecircumflex Edieresis Egrave Iacute Icircumflex Idieresis Igrave Ntilde Oacute Ocircumflex Odieresis Ograve Otilde Scaron Uacute Ucircumflex Udieresis Ugrave Yacute Ydieresis Zcaron aacute acircumflex adieresis agrave aring atilde ccedilla eacute ecircumflex edieresis egrave iacute icircumflex idieresis igrave ntilde oacute ocircumflex odieresis ograve otilde scaron uacute ucircumflex udieresis ugrave yacute ydieresis zcaron Euro
    """.split(whereSeparator:{$0.isWhitespace}).map(String.init))
    static let symbolNames = Set("""
    space exclam universal numbersign existential percent ampersand suchthat parenleft parenright asteriskmath plus comma minus period slash zero one two three four five six seven eight nine colon semicolon less equal greater question congruent Alpha Beta Chi Delta Epsilon Phi Gamma Eta Iota theta1 Kappa Lambda Mu Nu Omicron Pi Theta Rho Sigma Tau Upsilon sigma1 Omega Xi Psi Zeta bracketleft therefore bracketright perpendicular underscore radicalex alpha beta chi delta epsilon phi gamma eta iota phi1 kappa lambda mu nu omicron pi theta rho sigma tau upsilon omega1 omega xi psi zeta braceleft bar braceright similar Euro Upsilon1 minute lessequal fraction infinity florin club diamond heart spade arrowboth arrowleft arrowup arrowright arrowdown degree plusminus second greaterequal multiply proportional partialdiff bullet divide notequal equivalence approxequal ellipsis arrowvertex arrowhorizex carriagereturn aleph Ifraktur Rfraktur weierstrass circlemultiply circleplus emptyset intersection union propersuperset reflexsuperset notsubset propersubset reflexsubset element notelement angle gradient registerserif copyrightserif trademarkserif product radical dotmath logicalnot logicaland logicalor arrowdblboth arrowdblleft arrowdblup arrowdblright arrowdbldown lozenge angleleft registersans copyrightsans trademarksans summation parenlefttp parenleftex parenleftbt bracketlefttp bracketleftex bracketleftbt bracelefttp braceleftmid braceleftbt braceex angleright integral integraltp integralex integralbt parenrighttp parenrightex parenrightbt bracketrighttp bracketrightex bracketrightbt bracerighttp bracerightmid bracerightbt
    """.split(whereSeparator:{$0.isWhitespace}).map(String.init))
    static let standardNames:[UInt8:String] = {
        var result = punctuation;result[39] = "quoteright";result[96] = "quoteleft"
        for code in UInt8(65)...90 { result[code] = String(UnicodeScalar(code)) };for code in UInt8(97)...122 { result[code] = String(UnicodeScalar(code)) }
        for (i,name) in ["zero","one","two","three","four","five","six","seven","eight","nine"].enumerated() { result[UInt8(i+48)] = name }
        let extra:[Int:String] = [161:"exclamdown",162:"cent",163:"sterling",164:"fraction",165:"yen",166:"florin",167:"section",168:"currency",169:"quotesingle",170:"quotedblleft",171:"guillemotleft",172:"guilsinglleft",173:"guilsinglright",174:"fi",175:"fl",177:"endash",178:"dagger",179:"daggerdbl",180:"periodcentered",182:"paragraph",183:"bullet",184:"quotesinglbase",185:"quotedblbase",186:"quotedblright",187:"guillemotright",188:"ellipsis",189:"perthousand",191:"questiondown",193:"grave",194:"acute",195:"circumflex",196:"tilde",197:"macron",198:"breve",199:"dotaccent",200:"dieresis",202:"ring",203:"cedilla",205:"hungarumlaut",206:"ogonek",207:"caron",208:"emdash",225:"AE",227:"ordfeminine",232:"Lslash",233:"Oslash",234:"OE",235:"ordmasculine",241:"ae",245:"dotlessi",248:"lslash",249:"oslash",250:"oe",251:"germandbls"]
        for (code,name) in extra { result[UInt8(code)] = name };return result
    }()
    static let punctuation:[UInt8:String] = [32:"space",33:"exclam",34:"quotedbl",35:"numbersign",36:"dollar",37:"percent",38:"ampersand",39:"quotesingle",40:"parenleft",41:"parenright",42:"asterisk",43:"plus",44:"comma",45:"hyphen",46:"period",47:"slash",58:"colon",59:"semicolon",60:"less",61:"equal",62:"greater",63:"question",64:"at",91:"bracketleft",92:"backslash",93:"bracketright",94:"asciicircum",95:"underscore",96:"grave",123:"braceleft",124:"bar",125:"braceright",126:"asciitilde"]
    private static let standardGlyphByUnicode:[String:String] = {
        var result:[String:String] = [:]
        for (name,text) in (PDFArchiveFontReferenceData.shared?.glyphs ?? [:]).sorted(by:{$0.key<$1.key}) where latinNames.contains(name) { if result[text] == nil { result[text] = name } };return result
    }()
    static func differences(font:[String:PDFSyntaxValue],reader:PDFStructureDocument) throws -> [UInt8:String] {
        let encoding = try reader.dictionary(font["Encoding"]); var result:[UInt8:String] = [:],index = 0
        for item in try reader.resolve(encoding["Differences"])?.array ?? [] {
            if let value = item.int { guard (0...255).contains(value) else { throw PDFStructureError.malformed("Differences code") };index = value }
            else if let name = item.name { guard index<256 else { throw PDFStructureError.malformed("Differences overflow") };result[UInt8(index)] = name;index += 1 }
            else { throw PDFStructureError.malformed("Differences entry") }
        }
        return result
    }
    static func baseEncoding(font:[String:PDFSyntaxValue],reader:PDFStructureDocument) throws -> String? {
        let value = try reader.resolve(font["Encoding"]); if let name = value?.name { return name }; return try reader.dictionary(value)["BaseEncoding"]?.name
    }
    static func glyphName(code:UInt8,font:[String:PDFSyntaxValue],reader:PDFStructureDocument) throws -> String? {
        if let name = try differences(font:font,reader:reader)[code] { return name }
        let encoding = try baseEncoding(font:font,reader:reader)
        if encoding == "StandardEncoding" { return standardNames[code] ?? ".notdef" }
        guard encoding == "WinAnsiEncoding" || encoding == "MacRomanEncoding" else { return nil }
        if code<32 { return ".notdef" }
        if encoding == "StandardEncoding",code == 39 { return "quoteright" }
        if encoding == "StandardEncoding",code == 96 { return "quoteleft" }
        if let punctuation = punctuation[code] { return punctuation }
        if (65...90).contains(code) || (97...122).contains(code) { return String(UnicodeScalar(code)) }
        if (48...57).contains(code) { return ["zero","one","two","three","four","five","six","seven","eight","nine"][Int(code)-48] }
        if encoding == "WinAnsiEncoding" {
            if [127,129,141,143,144,149,157].contains(code) { return "bullet" }
            if code == 160 { return "space" };if code == 173 { return "hyphen" }
        }
        if let unicode = try unicode(code:code,font:font,reader:reader) { return standardGlyphByUnicode[unicode] }
        return nil
    }
    static func unicode(code:UInt8,font:[String:PDFSyntaxValue],reader:PDFStructureDocument) throws -> String? {
        if let name = try differences(font:font,reader:reader)[code] { return unicode(name:name) }
        let encoding = try baseEncoding(font:font,reader:reader)
        if encoding == "WinAnsiEncoding" {
            if [127,129,141,143,144,149,157].contains(code) { return "•" }
            if code == 160 { return " " };if code == 173 { return "-" }
            guard code>=32 else { return nil };return String(data:Data([code]),encoding:.windowsCP1252)
        }
        if encoding == "MacRomanEncoding" { return code>=32 ? String(data:Data([code]),encoding:.macOSRoman) : nil }
        if encoding == "StandardEncoding",let name = standardNames[code] { return unicode(name:name) }
        return nil
    }
    static func unicode(name:String)->String? {
        let stem = String(name.split(separator:".",maxSplits:1,omittingEmptySubsequences:false)[0])
        if stem.contains("_") { let parts = stem.split(separator:"_").map { unicode(name:String($0)) };guard parts.allSatisfy({$0 != nil}) else { return nil };return parts.compactMap{$0}.joined() }
        if stem.count == 1,let scalar = stem.unicodeScalars.first,scalar.isASCII { return stem }
        if let pair = punctuation.first(where:{$0.value == stem}) { return String(UnicodeScalar(pair.key)) }
        if let index = ["zero","one","two","three","four","five","six","seven","eight","nine"].firstIndex(of:stem) { return String(index) }
        let known = ["bullet":"•","Euro":"€","fi":"ﬁ","fl":"ﬂ","ff":"ﬀ","ffi":"ﬃ","ffl":"ﬄ","quotesingle":"'","quoteright":"’","quoteleft":"‘","quotedblleft":"“","quotedblright":"”","endash":"–","emdash":"—","ellipsis":"…","nonbreakingspace":" ",".notdef":""]
        if let value = known[stem] { return value.isEmpty ? nil:value }
        if let value = PDFArchiveFontReferenceData.shared?.glyphs[stem] { return value }
        if stem.hasPrefix("uni"),stem.count>3,(stem.count-3)%4 == 0 {
            let text = String(stem.dropFirst(3));var data = Data();var index = text.startIndex
            while index<text.endIndex { let end = text.index(index,offsetBy:4);guard let unit = UInt16(text[index..<end],radix:16) else { return nil };data += Data([UInt8(unit>>8),UInt8(unit&255)]);index = end };return PDFArchiveCMap.unicodeString(data)
        }
        if stem.hasPrefix("u"),(5...7).contains(stem.count),let value = UInt32(stem.dropFirst(),radix:16),let scalar = UnicodeScalar(value) { return String(scalar) }
        return nil
    }
}

/// Type1 eexec/CharStrings reader. No PostScript is executed. Standard RD/-|
/// binary records and lenIV are interpreted; dynamic PostScript stays unknown.
struct PDFArchiveType1Program {
    let charStrings:[String:Data]
    let subroutines:[Int:Data]
    let names:[String]
    let matrixScale:Double?
    let encoding:[UInt8:String]
    init(data:Data,length1:Int? = nil,length2:Int? = nil) throws {
        var bytes = Array(data),binary:Data?,clear:Data?
        if bytes.starts(with:[0x80,1]) {
            var cursor = 0,ascii = Data(),encrypted = Data()
            while cursor<bytes.count {
                guard cursor+2<=bytes.count,bytes[cursor] == 0x80 else { throw PDFStructureError.malformed("PFB segment") }
                let type = bytes[cursor+1];cursor += 2;if type == 3 { break }
                guard cursor+4<=bytes.count,type == 1 || type == 2 else { throw PDFStructureError.unsupported("PFB segment type") }
                let count = Int(bytes[cursor])|Int(bytes[cursor+1])<<8|Int(bytes[cursor+2])<<16|Int(bytes[cursor+3])<<24;cursor += 4
                guard count<=bytes.count-cursor else { throw PDFStructureError.malformed("PFB length") }
                if type == 1 && encrypted.isEmpty { ascii += Data(bytes[cursor..<(cursor+count)]) };if type == 2 { encrypted += Data(bytes[cursor..<(cursor+count)]) };cursor += count
            }
            clear = ascii;binary = encrypted
        }
        if clear == nil {
            var tokens = Type1Tokens(bytes:bytes),previous = "",found:Int?
            while let token = try tokens.next() {
                if token == "eexec",previous == "currentfile" { found = tokens.cursor;break };previous = token
            }
            if let length1,length1>0,length1<=bytes.count { found = length1 }
            guard var start = found else { throw PDFStructureError.unsupported("Type1 senza eexec standard") }
            clear = Data(bytes.prefix(start))
            if length1 == nil {
                if start<bytes.count,bytes[start] == 13 { start += 1;if start<bytes.count,bytes[start] == 10 { start += 1 } }
                else if start<bytes.count,bytes[start] == 10 || bytes[start] == 32 { start += 1 }
            }
            let count = length2 ?? (bytes.count-start)
            guard count>=4,count<=bytes.count-start else { throw PDFStructureError.malformed("Type1 Length2") }
            binary = Data(bytes[start..<(start+count)])
        }
        // Read declarative header tokens only. Never execute arbitrary PS.
        var header = Type1Tokens(bytes:Array(clear!)),headerTokens:[String] = []
        while let token = try header.next() { headerTokens.append(token);guard headerTokens.count<=100_000 else { throw PDFStructureError.limit } }
        var scale:Double?,encoded:[UInt8:String] = [:]
        if let i = headerTokens.lastIndex(of:"/FontMatrix"),i+8<headerTokens.count,headerTokens[i+1] == "[",headerTokens[i+8] == "]" {
            let values = headerTokens[(i+2)..<(i+8)].compactMap(Double.init)
            if values.count == 6,values[1] == 0,values[2] == 0,values[0].isFinite,values[0]>0 { scale = values[0]*1000 }
        }
        if let i = headerTokens.lastIndex(of:"/Encoding"),i+1<headerTokens.count {
            if headerTokens[i+1] == "StandardEncoding" { encoded = PDFArchiveFontEncoding.standardNames }
            else {
                var p = i+1,brace = 0
                while p<headerTokens.count {
                    let token = headerTokens[p]
                    if token == "{" { brace += 1 };if token == "}" { brace -= 1 }
                    if brace == 0,token == "dup",p+3<headerTokens.count,let code = UInt8(headerTokens[p+1]),headerTokens[p+2].hasPrefix("/"),headerTokens[p+3] == "put" { encoded[code] = String(headerTokens[p+2].dropFirst()) }
                    if brace == 0,token == "def" { break };p += 1
                }
            }
        }
        matrixScale = scale;encoding = encoded
        func decrypted(_ input:Data,seed:UInt16,discard:Int) throws -> Data {
            var state = UInt32(seed),output = Data()
            for byte in input { output.append(byte ^ UInt8(state>>8));state = ((UInt32(byte)+state)*52845+22719)&65535 }
            guard discard>=0,discard<=output.count else { throw PDFStructureError.malformed("Type1 lenIV") };return output.dropFirst(discard)
        }
        var cipher = binary!
        let nonspace = cipher.filter{![9,10,13,32].contains($0)}
        if nonspace.prefix(8).count == 8,nonspace.prefix(8).allSatisfy({(48...57).contains($0)||(65...70).contains($0)||(97...102).contains($0)}) {
            var hex = Data();let chars = Array(nonspace);var cursor = 0
            while cursor+1<chars.count,let value = UInt8(String(decoding:chars[cursor...cursor+1],as:UTF8.self),radix:16) { hex.append(value);cursor += 2 };cipher = hex
        }
        bytes = Array(try decrypted(cipher,seed:55665,discard:4))
        var parser = Type1Tokens(bytes:bytes),history:[String] = [],insideChars = false,lenIV = 4,rawChars:[String:Data] = [:],rawSubrs:[Int:Data] = [:]
        while let token = try parser.next() {
            if token == "/CharStrings" { insideChars = true }
            if history.last == "/lenIV",let number = Int(token),(-1...32).contains(number) { lenIV = number }
            if token == "RD" || token == "-|" {
                guard history.count>=2,let count = Int(history.last!),count>=0,count<=16*1024*1024 else { throw PDFStructureError.unsupported("Type1 RD dinamico") }
                let bytes = try parser.binary(count)
                if insideChars,history[history.count-2].hasPrefix("/") { rawChars[String(history[history.count-2].dropFirst())] = bytes }
                else if history.count>=3,history[history.count-3] == "dup",let index = Int(history[history.count-2]) { rawSubrs[index] = bytes }
            }
            history.append(token);if history.count>8 { history.removeFirst() }
            if token == "closefile" { break }
        }
        guard !rawChars.isEmpty,rawChars.count<=65535 else { throw PDFStructureError.unsupported("CharStrings Type1 non individuabili") }
        func decode(_ bytes:Data) throws -> Data { lenIV == -1 ? bytes:try decrypted(bytes,seed:4330,discard:lenIV) }
        charStrings = try rawChars.mapValues(decode);subroutines = try rawSubrs.mapValues(decode)
        names = [".notdef"]+rawChars.keys.filter{$0 != ".notdef"}.sorted()
    }
    func advance(name:String) throws -> Double? {
        guard let data = charStrings[name],let scale = matrixScale else { return nil }
        var stack:[Double] = [],budget = 0
        func width(_ data:Data,depth:Int) throws -> Double? {
            guard depth<20 else { throw PDFStructureError.limit };let bytes = Array(data);var cursor = 0
            while cursor<bytes.count {
                budget += 1;guard budget<100_000 else { throw PDFStructureError.limit };let value = bytes[cursor];cursor += 1
                if value >= 32 && value <= 246 { stack.append(Double(Int(value)-139)) }
                else if value >= 247 && value <= 250 { guard cursor<bytes.count else { throw PDFStructureError.malformed("Type1 number") };stack.append(Double((Int(value)-247)*256+Int(bytes[cursor])+108));cursor += 1 }
                else if value >= 251 && value <= 254 { guard cursor<bytes.count else { throw PDFStructureError.malformed("Type1 number") };stack.append(Double(-(Int(value)-251)*256-Int(bytes[cursor])-108));cursor += 1 }
                else if value == 255 { let raw = try PDFArchiveFontProgram.u32(bytes,cursor);cursor += 4;stack.append(Double(Int32(bitPattern:UInt32(raw)))) }
                else if value == 13 { guard stack.count>=2 else { throw PDFStructureError.malformed("hsbw") };return stack[stack.count-1]*scale }
                else if value == 10 { guard let index = stack.popLast(),index>=0,index<=65535,let subroutine = subroutines[Int(index)] else { return nil };if let value = try width(subroutine,depth:depth+1) { return value } }
                else if value == 11 { return nil }
                else if value == 12 {
                    guard cursor<bytes.count else { throw PDFStructureError.malformed("Type1 escape") };let operation = bytes[cursor];cursor += 1
                    if operation == 7 { guard stack.count>=4 else { throw PDFStructureError.malformed("sbw") };return stack[stack.count-2]*scale }
                    if operation == 12 { guard stack.count>=2 else { return nil };let denominator = stack.removeLast(),numerator = stack.removeLast();guard denominator != 0 else { return nil };stack.append(numerator/denominator) }
                    else { return nil }
                } else { return nil }
                guard stack.count<=96 else { throw PDFStructureError.limit }
            }
            return nil
        }
        return try width(data,depth:0)
    }
    private struct Type1Tokens {
        let bytes:[UInt8];var cursor = 0
        mutating func next() throws -> String? {
            while cursor<bytes.count {
                if [0,9,10,12,13,32].contains(bytes[cursor]) { cursor += 1;continue }
                if bytes[cursor] == 37 { while cursor<bytes.count && bytes[cursor] != 10 && bytes[cursor] != 13 { cursor += 1 };continue };break
            }
            guard cursor<bytes.count else { return nil };let start = cursor;cursor += 1
            if [91,93,123,125].contains(bytes[start]) { return String(UnicodeScalar(bytes[start])) }
            if bytes[start] == 40 {
                var depth = 1
                while cursor<bytes.count && depth>0 { let value = bytes[cursor];cursor += 1;if value == 92 && cursor<bytes.count { cursor += 1 } else if value == 40 { depth += 1 } else if value == 41 { depth -= 1 } }
                guard depth == 0 else { throw PDFStructureError.malformed("Type1 string") };return "(string)"
            }
            while cursor<bytes.count && ![0,9,10,12,13,32,37,40,41,91,93,123,125,47].contains(bytes[cursor]) { cursor += 1 }
            return String(decoding:bytes[start..<cursor],as:UTF8.self)
        }
        mutating func binary(_ count:Int) throws -> Data {
            guard cursor<bytes.count,[9,10,13,32].contains(bytes[cursor]) else { throw PDFStructureError.malformed("Type1 RD delimiter") };cursor += 1
            guard count<=bytes.count-cursor else { throw PDFStructureError.malformed("Type1 RD length") };let result = Data(bytes[cursor..<(cursor+count)]);cursor += count;return result
        }
    }
}

/// Original Adobe BSD reference DATA, never an external engine. Every resource
/// and its inventory are SHA-256 pinned; missing/changed data yields unknown.
final class PDFArchiveFontReferenceData {
    private struct Manifest:Decodable {
        struct Item:Decodable { let name:String,file:String,sha256:String }
        let items:[Item]
    }
    private final class MapBox:NSObject { let map:PDFArchiveCMap;init(_ map:PDFArchiveCMap) { self.map = map } }
    static let manifestSHA256 = "0f2ac1ecd208995e164298d3eca70d2db9b6cc3322363317b419161c435a7f31"
    static let shared:PDFArchiveFontReferenceData? = try? PDFArchiveFontReferenceData()
    private let directory:URL
    private let items:[String:Manifest.Item]
    private let maps = NSCache<NSString,MapBox>()
    private(set) var glyphs:[String:String] = [:]
    init(directory:URL? = nil) throws {
        guard let directory = directory ?? PDFArchiveValidator.resourceDirectory()?.deletingLastPathComponent().appendingPathComponent("PDFFontData",isDirectory:true) else { throw PDFStructureError.unsupported("dati font Adobe offline mancanti") }
        self.directory = directory
        let data = try Data(contentsOf:directory.appendingPathComponent("MANIFEST.json"))
        guard Self.hash(data) == Self.manifestSHA256 else { throw PDFStructureError.malformed("inventario dati font Adobe modificato") }
        let manifest = try JSONDecoder().decode(Manifest.self,from:data)
        var unique:[String:Manifest.Item] = [:]
        for item in manifest.items where item.file.hasPrefix("CMaps/") || item.file.hasPrefix("AGL/") { if unique[item.name] == nil { unique[item.name] = item } }
        items = unique;maps.countLimit = 16;maps.totalCostLimit = 32*1024*1024
        for file in ["glyphlist.txt","zapfdingbats.txt"] {
            let text = String(decoding:try bytes(file),as:UTF8.self)
            for line in text.split(whereSeparator:{$0.isNewline}) where !line.hasPrefix("#") {
                let columns = line.split(separator:";",omittingEmptySubsequences:false)
                guard columns.count == 2 else { continue };var values = String.UnicodeScalarView(),valid = true
                for field in columns[1].split(whereSeparator:{$0.isWhitespace}) { guard let code = UInt32(field,radix:16),let scalar = UnicodeScalar(code) else { valid = false;break };values.append(scalar) }
                if valid,!values.isEmpty { glyphs[String(columns[0])] = String(values) }
            }
        }
    }
    private static func hash(_ data:Data)->String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
    func bytes(_ name:String) throws -> Data {
        guard let item = items[name] else { throw PDFStructureError.unsupported("dato Adobe non catalogato: " + name) }
        let data = try Data(contentsOf:directory.appendingPathComponent(item.file));guard data.count<=16*1024*1024,Self.hash(data) == item.sha256 else { throw PDFStructureError.malformed("hash dato Adobe: " + name) };return data
    }
    func cmap(_ name:String,active:Set<String> = []) throws -> PDFArchiveCMap {
        if name == "Identity-H" || name == "Identity-V" { return .identity(vertical:name == "Identity-V") }
        if let cached = maps.object(forKey:name as NSString) { return cached.map }
        guard !active.contains(name),active.count<30 else { throw PDFStructureError.unsupported("UseCMap Adobe ricorsivo") }
        var map = try PDFArchiveCMap(data:bytes(name))
        if let baseName = map.baseName {
            let base = try cmap(baseName,active:active.union([name]))
            map = map.inheriting(base);map.baseName = nil
        }
        maps.setObject(MapBox(map),forKey:name as NSString,cost:map.cids.count*64+map.unicode.count*96)
        return map
    }
    func unicode(cid:Int,registry:String,ordering:String,supplement:Int? = nil) throws -> String? {
        guard registry == "Adobe",cid>=0,cid<=65535,["Japan1","GB1","CNS1","Korea1","KR"].contains(ordering) else { return nil }
        let map = try cmap(registry + "-" + ordering + "-UCS2")
        if let supplement,let available = map.supplement,supplement>available { throw PDFStructureError.unsupported("Supplement CID più recente dei dati Adobe offline") }
        return map.unicode[PDFArchiveCMap.bytes(cid,count:2)].flatMap(PDFArchiveCMap.unicodeString)
    }
}
