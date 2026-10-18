import Compression
import Foundation

/// Original bounded implementations of ISO 32000-1 §7.4 general stream filters.
/// Consumed byte count comes from the encoded EOD, never from an inline L hint.
enum PDFStreamFilters {
    static let maximum = 256 * 1024 * 1024
    struct Prefix { let data: Data; let consumed: Int }
    static let supported: Set<String> = ["FlateDecode","Fl","LZWDecode","LZW","ASCIIHexDecode","AHx","ASCII85Decode","A85","RunLengthDecode","RL"]
    static func prefix(_ data: Data, filter: String, parameters: [String:PDFSyntaxValue] = [:]) throws -> Prefix {
        switch filter {
        case "FlateDecode","Fl": return try flate(data)
        case "ASCIIHexDecode","AHx": return try hex(data)
        case "ASCII85Decode","A85": return try base85(data)
        case "RunLengthDecode","RL": return try runLength(data)
        case "LZWDecode","LZW": return try lzw(data,earlyChange:integer(parameters,"EarlyChange",default:1))
        default: throw PDFStructureError.unsupported("filtro \(filter)")
        }
    }
    static func integer(_ dictionary:[String:PDFSyntaxValue],_ key:String,default value:Int) throws -> Int {
        guard let item = dictionary[key] else { return value }
        if case .null = item { return value }
        guard let number = item.int else { throw PDFStructureError.malformed("parametro \(key) non intero") }
        return number
    }
    private static func hex(_ data:Data) throws -> Prefix {
        var result = Data(), high:Int?
        for (index,byte) in data.enumerated() {
            if index%65536 == 0 { try Task.checkCancellation() }
            if byte == 62 { if let high { guard result.count < maximum else { throw PDFStructureError.limit };result.append(UInt8(high << 4)) }; return .init(data:result,consumed:index+1) }
            if PDFSyntaxLexer.space(byte) { continue }
            let digit:Int
            switch byte { case 48...57:digit = Int(byte-48);case 65...70:digit = Int(byte-55);case 97...102:digit = Int(byte-87)
            default:throw PDFStructureError.malformed("ASCIIHex: cifra non valida") }
            if let first = high { result.append(UInt8(first << 4 | digit));high = nil } else { high = digit }
            guard result.count <= maximum else { throw PDFStructureError.limit }
        }
        // The public PDF editions do not explicitly settle whether an ordinary
        // stream's Length-delimited EOF substitutes for >. It proves neither
        // a valid inline boundary nor a normative violation on its own.
        throw PDFStructureError.unsupported("ASCIIHex: EOD assente; semantica EOF delimitato da Length non dimostrata")
    }
    private static func base85(_ data:Data) throws -> Prefix {
        let bytes = Array(data);var offset = 0, group:[UInt8] = [], result = Data()
        func emit(_ values:[UInt8],count:Int) throws -> Data {
            let value = values.reduce(UInt64(0)) { $0 * 85 + UInt64($1-33) }
            guard value <= UInt32.max else { throw PDFStructureError.malformed("ASCII85: overflow") }
            return Data([UInt8(value>>24 & 255),UInt8(value>>16 & 255),UInt8(value>>8 & 255),UInt8(value & 255)].prefix(count))
        }
        while offset < bytes.count {
            if offset%65536 == 0 { try Task.checkCancellation() }
            let byte = bytes[offset];offset += 1
            if PDFSyntaxLexer.space(byte) { continue }
            if byte == 126 {
                guard offset < bytes.count,bytes[offset] == 62 else { throw PDFStructureError.malformed("ASCII85: EOD ~> non valido") };offset += 1
                if !group.isEmpty { guard group.count > 1 else { throw PDFStructureError.malformed("ASCII85: gruppo finale singolo") };let count = group.count-1
                    while group.count < 5 { group.append(117) };guard result.count <= maximum-count else { throw PDFStructureError.limit };result += try emit(group,count:count) }
                return .init(data:result,consumed:offset)
            }
            if byte == 122 { guard group.isEmpty else { throw PDFStructureError.malformed("ASCII85: z nel gruppo") };result += Data(repeating:0,count:4) }
            else { guard (33...117).contains(byte) else { throw PDFStructureError.malformed("ASCII85: carattere non valido") }
                group.append(byte);if group.count == 5 { result += try emit(group,count:4);group.removeAll(keepingCapacity:true) } }
            guard result.count <= maximum else { throw PDFStructureError.limit }
        }
        throw PDFStructureError.malformed("ASCII85: EOD assente")
    }
    private static func runLength(_ data:Data) throws -> Prefix {
        let bytes = Array(data);var offset = 0,result = Data(),commands = 0
        while offset < bytes.count {
            commands += 1;if commands%4096 == 0 { try Task.checkCancellation() }
            let count = Int(bytes[offset]);offset += 1
            if count == 128 { return .init(data:result,consumed:offset) }
            if count < 128 {
                guard offset <= bytes.count-count-1 else { throw PDFStructureError.malformed("RunLength: run troncato") }
                result.append(contentsOf:bytes[offset..<(offset+count+1)]);offset += count+1
            } else { guard offset < bytes.count else { throw PDFStructureError.malformed("RunLength: run troncato") }
                result.append(Data(repeating:bytes[offset],count:257-count));offset += 1 }
            guard result.count <= maximum else { throw PDFStructureError.limit }
        }
        throw PDFStructureError.malformed("RunLength: EOD assente")
    }
    private static func lzw(_ data:Data,earlyChange:Int) throws -> Prefix {
        guard [0,1].contains(earlyChange) else { throw PDFStructureError.malformed("LZW: EarlyChange") }
        let bytes = Array(data);var bit = 0,width = 9,next = 258,previous:[UInt8]?,table = [[UInt8]](repeating:[],count:4096),result = Data()
        func code() throws -> Int {
            guard bit <= bytes.count*8-width else { throw PDFStructureError.malformed("LZW: EOD assente") }
            var value = 0
            for _ in 0..<width { value = value<<1 | Int(bytes[bit/8] >> (7-bit%8) & 1);bit += 1 };return value
        }
        func reset() { width = 9;next = 258;previous = nil;for i in 0..<256 { table[i] = [UInt8(i)] } }
        reset()
        guard try code() == 256 else { throw PDFStructureError.malformed("LZW: clear iniziale assente") }
        while true {
            try Task.checkCancellation()
            let value = try code()
            if value == 256 { reset();continue }
            if value == 257 {
                if bit%8 != 0 { let unused = 8-bit%8;guard bytes[bit/8] & UInt8((1<<unused)-1) == 0 else { throw PDFStructureError.malformed("LZW: padding non nullo") } }
                return .init(data:result,consumed:(bit+7)/8)
            }
            let sequence:[UInt8]
            if value < next,!table[value].isEmpty { sequence = table[value] }
            else if value == next,let previous,let first = previous.first { sequence = previous + [first] }
            else { throw PDFStructureError.malformed("LZW: codice non definito") }
            guard result.count <= maximum-sequence.count else { throw PDFStructureError.limit };result.append(contentsOf:sequence)
            if let previous,let first = sequence.first {
                guard next < 4096 else { throw PDFStructureError.malformed("LZW: tabella piena senza clear") }
                table[next] = previous + [first];next += 1
                if width < 12,next+earlyChange == 1<<width { width += 1 }
            }
            previous = sequence
        }
    }
    private static func flate(_ data:Data) throws -> Prefix {
        let bytes = Array(data)
        guard bytes.count >= 6 else { throw PDFStructureError.malformed("Flate: dati troncati") }
        guard bytes[0] & 15 == 8,bytes[0] >> 4 <= 7,(Int(bytes[0])*256+Int(bytes[1]))%31 == 0,bytes[1] & 32 == 0 else { throw PDFStructureError.malformed("Flate: intestazione zlib") }
        // Compression may read ahead beyond the final deflate block. Its source
        // pointer is therefore not evidence for an inline boundary. First parse
        // the RFC 1951 bit structure, then let Apple's decoder expand the bytes.
        var deflate = PDFDeflateBounds(bytes:bytes,bit:16)
        let count = try deflate.scan(window:1 << (Int(bytes[0]>>4)+8)),end = (deflate.bit+7)/8
        guard end <= bytes.count-4 else { throw PDFStructureError.malformed("Flate: Adler32 assente") }
        var result = Data()
        if count > 0 {
            var output = [UInt8](repeating:0,count:count+1)
            let compressed = Array(bytes[2..<end])
            let written = compression_decode_buffer(&output,output.count,compressed,compressed.count,nil,COMPRESSION_ZLIB)
            guard written == count else { throw PDFStructureError.malformed("Flate: decompressione discordante") }
            result = Data(output.prefix(written))
        }
        var a:UInt32 = 1,b:UInt32 = 0
        for (index,byte) in result.enumerated() { if index%65536 == 0 { try Task.checkCancellation() };a = (a+UInt32(byte))%65521;b = (b+a)%65521 }
        let expected = bytes[end..<(end+4)].reduce(UInt32(0)) { $0<<8 | UInt32($1) }
        guard b<<16 | a == expected else { throw PDFStructureError.malformed("Flate: checksum Adler32") }
        return .init(data:result,consumed:end+4)
    }
    static func unpredict(_ data:Data,parameters:[String:PDFSyntaxValue]) throws -> Data {
        let predictor = try integer(parameters,"Predictor",default:1)
        if predictor == 1 { return data }
        let colors = try integer(parameters,"Colors",default:1),columns = try integer(parameters,"Columns",default:1),bits = try integer(parameters,"BitsPerComponent",default:8)
        guard colors > 0,colors <= 32,columns > 0,columns <= 1_000_000 else { throw PDFStructureError.limit }
        guard [1,2,4,8,16].contains(bits),[2,10,11,12,13,14,15].contains(predictor) else { throw PDFStructureError.malformed("parametri predittore bitmap") }
        let samples = colors*columns,row = (samples*bits+7)/8,bytes = Array(data)
        guard row <= maximum else { throw PDFStructureError.limit }
        var result = Data()
        if predictor == 2 {
            guard bytes.count%row == 0 else { throw PDFStructureError.malformed("predittore TIFF: riga troncata") }
            for offset in stride(from:0,to:bytes.count,by:row) {
                try Task.checkCancellation();var line = Array(bytes[offset..<(offset+row)]),prior = [Int](repeating:0,count:colors)
                for sample in 0..<samples {
                    var value = 0
                    for b in 0..<bits { let p = sample*bits+b;value = value<<1 | Int(line[p/8] >> (7-p%8) & 1) }
                    value = (value+prior[sample%colors]) & ((1<<bits)-1);prior[sample%colors] = value
                    for b in 0..<bits { let p = sample*bits+b,mask = UInt8(1 << (7-p%8));line[p/8] = (line[p/8] & ~mask) | (((value >> (bits-1-b)) & 1) == 0 ? 0:mask) }
                };result.append(contentsOf:line)
            };return result
        }
        guard bytes.count%(row+1) == 0 else { throw PDFStructureError.malformed("predittore PNG: riga troncata") }
        let bpp = (colors*bits+7)/8;var prior = [UInt8](repeating:0,count:row)
        for offset in stride(from:0,to:bytes.count,by:row+1) {
            try Task.checkCancellation();let type = bytes[offset];var line = Array(bytes[(offset+1)..<(offset+row+1)])
            for i in 0..<row {
                let left = i >= bpp ? Int(line[i-bpp]):0,up = Int(prior[i]),upperLeft = i >= bpp ? Int(prior[i-bpp]):0,value:Int
                switch type { case 0:value = 0;case 1:value = left;case 2:value = up;case 3:value = (left+up)/2
                case 4:let p = left+up-upperLeft,a = abs(p-left),b = abs(p-up),c = abs(p-upperLeft);value = a <= b && a <= c ? left:b <= c ? up:upperLeft
                default:throw PDFStructureError.malformed("predittore PNG: tipo riga") }
                line[i] = line[i] &+ UInt8(value)
            };result.append(contentsOf:line);prior = line
        };return result
    }
}

/// RFC 1951 syntax and extent checker. It does not duplicate Apple's inflater.
private struct PDFDeflateBounds {
    let bytes:[UInt8]
    var bit:Int
    mutating func read(_ count:Int) throws -> Int {
        guard bit <= bytes.count*8-count else { throw PDFStructureError.malformed("deflate troncato") }
        var result = 0
        for shift in 0..<count { result |= Int(bytes[bit/8] >> (bit%8) & 1)<<shift;bit += 1 }
        return result
    }
    struct Huffman {
        let codes:[Int:Int],maximum:Int
        init(_ lengths:[Int],allowEmpty:Bool = false,allowSingle:Bool = true) throws {
            let maximum = lengths.max() ?? 0
            guard maximum <= 15,allowEmpty || maximum > 0 else { throw PDFStructureError.malformed("deflate: albero vuoto") }
            var counts = [Int](repeating:0,count:16),next = counts,code = 0,result:[Int:Int] = [:],space = 1
            for length in lengths where length > 0 { counts[length] += 1 }
            for length in 1...15 {
                space = (space<<1)-counts[length]
                guard space >= 0 else { throw PDFStructureError.malformed("deflate: albero sovrascritto") }
                code = (code+counts[length-1])<<1;next[length] = code
            }
            guard space == 0 || (allowEmpty && maximum == 0) || (allowSingle && maximum == 1 && counts[1] == 1) else {
                throw PDFStructureError.malformed("deflate: albero Huffman incompleto")
            }
            // RFC 1951 permits a single distance code, or no distance codes
            // when all data are literals. A partially populated larger tree
            // cannot establish a valid code for the missing bit sequences.
            for (symbol,length) in lengths.enumerated() where length > 0 {
                result[(1<<length)|next[length]] = symbol;next[length] += 1
            }
            self.codes = result;self.maximum = maximum
        }
    }
    mutating func symbol(_ table:Huffman) throws -> Int {
        var code = 0
        guard table.maximum > 0 else { throw PDFStructureError.malformed("deflate: distanza senza albero") }
        for width in 1...table.maximum {
            code = code<<1 | (try read(1))
            if let symbol = table.codes[(1<<width)|code] { return symbol }
        }
        throw PDFStructureError.malformed("deflate: codice Huffman non definito")
    }
    mutating func scan(window:Int) throws -> Int {
        var count = 0,final = 0,commands = 0
        let lengthBase = [3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258]
        let lengthExtra = [0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0]
        let distanceBase = [1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577]
        let distanceExtra = [0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13]
        repeat {
            try Task.checkCancellation();final = try read(1)
            let type = try read(2)
            if type == 0 {
                bit = (bit+7)/8*8
                let length = try read(16),inverse = try read(16)
                guard length ^ inverse == 65535,bit <= bytes.count*8-length*8 else { throw PDFStructureError.malformed("deflate: blocco stored") }
                bit += length*8;count += length
            } else {
                let literal:Huffman,distance:Huffman
                if type == 1 {
                    literal = try Huffman(Array(repeating:8,count:144)+Array(repeating:9,count:112)+Array(repeating:7,count:24)+Array(repeating:8,count:8))
                    distance = try Huffman(Array(repeating:5,count:32))
                } else if type == 2 {
                    let literalCount = try read(5)+257,distanceCount = try read(5)+1,codeCount = try read(4)+4
                    guard literalCount <= 286 else { throw PDFStructureError.malformed("deflate: HLIT") }
                    let codeOrder = [16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15]
                    var codeLengths = [Int](repeating:0,count:19)
                    for index in 0..<codeCount { codeLengths[codeOrder[index]] = try read(3) }
                    let codeTree = try Huffman(codeLengths,allowSingle:false);var lengths:[Int] = []
                    while lengths.count < literalCount+distanceCount {
                        let value = try symbol(codeTree),repeated:Int,repetitions:Int
                        if value <= 15 { repeated = value;repetitions = 1 }
                        else if value == 16 { guard let previous = lengths.last else { throw PDFStructureError.malformed("deflate: repeat iniziale") };repeated = previous;repetitions = try read(2)+3 }
                        else if value == 17 { repeated = 0;repetitions = try read(3)+3 }
                        else { repeated = 0;repetitions = try read(7)+11 }
                        guard repetitions <= literalCount+distanceCount-lengths.count else { throw PDFStructureError.malformed("deflate: repeat fuori tabella") }
                        lengths += Array(repeating:repeated,count:repetitions)
                    }
                    guard lengths[256] > 0 else { throw PDFStructureError.malformed("deflate: EOB senza codice") }
                    literal = try Huffman(Array(lengths.prefix(literalCount)))
                    distance = try Huffman(Array(lengths.dropFirst(literalCount)),allowEmpty:true)
                } else { throw PDFStructureError.malformed("deflate: tipo blocco riservato") }
                while true {
                    commands += 1;if commands%4096 == 0 { try Task.checkCancellation() }
                    let value = try symbol(literal)
                    if value < 256 { count += 1 }
                    else if value == 256 { break }
                    else {
                        guard value <= 285 else { throw PDFStructureError.malformed("deflate: lunghezza riservata") }
                        let index = value-257,length = lengthBase[index] + (try read(lengthExtra[index]))
                        let d = try symbol(distance)
                        guard d < 30 else { throw PDFStructureError.malformed("deflate: distanza riservata") }
                        let offset = distanceBase[d] + (try read(distanceExtra[d]))
                        guard offset <= count,offset <= window else { throw PDFStructureError.malformed("deflate: distanza fuori finestra") }
                        count += length
                    }
                    guard count <= PDFStreamFilters.maximum else { throw PDFStructureError.limit }
                }
            }
            guard count <= PDFStreamFilters.maximum else { throw PDFStructureError.limit }
        } while final == 0
        return count
    }
}
