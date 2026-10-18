import AppKit
import Compression
import CoreGraphics
import CryptoKit
import PDFKit
import Security

// Native, bounded PDF syntax reader and incremental writer. Existing revisions
// remain byte-for-byte intact; this is deliberately NOT a redaction engine.
enum PDFStructureError: LocalizedError {
    // This payload is also a parser classification key. Keep it independent
    // of translated diagnostics so language cannot change validation behavior.
    static let cmapCodeOutsideCodespace = "codice fuori codespace CMap"
    case unsupported(String), malformed(String), encrypted, limit, security(OSStatus)
    var errorDescription: String? {
        switch self {
        case .unsupported(let value): return L10n.tr("Operazione non supportata per questo PDF: \(value).")
        case .malformed(let value):
            let detail = value == Self.cmapCodeOutsideCodespace ? L10n.string(value) : value
            return L10n.tr("Struttura PDF non valida: \(detail).")
        case .encrypted: return L10n.tr("Le modifiche strutturali non sono disponibili sui PDF cifrati: non viene generata una copia priva di protezione.")
        case .limit: return L10n.tr("Il PDF supera i limiti di sicurezza del lettore strutturale.")
        case .security(let status): return L10n.tr("Security: \((SecCopyErrorMessageString(status, nil) as String?) ?? String(status)).")
        }
    }
}

struct PDFObjectID: Hashable, Comparable, Identifiable {
    let number: Int
    let generation: Int
    var id: String { "\(number) \(generation)" }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.number == rhs.number ? lhs.generation < rhs.generation : lhs.number < rhs.number }
    var syntax: String { "\(number) \(generation) R" }
}

indirect enum PDFSyntaxValue {
    case name(String), number(String), bytes(Data), array([PDFSyntaxValue]), dictionary([String: PDFSyntaxValue])
    case reference(PDFObjectID), boolean(Bool), null, keyword(String)
    var dictionary: [String: PDFSyntaxValue]? { if case .dictionary(let value) = self { return value }; return nil }
    var array: [PDFSyntaxValue]? { if case .array(let value) = self { return value }; return nil }
    var int: Int? { if case .number(let value) = self { return Int(value) }; return nil }
    var real: Double? {
        guard case .number(let value) = self else { return nil }
        if let number = Double(value) { return number }
        // Long decimals may exceed Swift's conversion buffer, not PDF grammar.
        guard PDFSyntaxLexer.numberToken(value) else { return nil }
        let negative = value.hasPrefix("-"),unsigned = value.drop(while:{ $0 == "+" || $0 == "-" })
        let parts = unsigned.split(separator:".",omittingEmptySubsequences:false)
        let integer = parts[0].drop(while:{ $0 == "0" }),fraction = parts.count > 1 ? parts[1]:Substring()
        let digits:String,exponent:Int
        if !integer.isEmpty { digits = String((String(integer)+String(fraction)).prefix(18));exponent = integer.count-1 }
        else {
            let significant = fraction.drop(while:{ $0 == "0" })
            if significant.isEmpty { return negative ? -0.0:0.0 }
            digits = String(significant.prefix(18));exponent = -(fraction.count-significant.count)-1
        }
        return Double((negative ? "-":"") + String(digits.prefix(1)) + "." + String(digits.dropFirst()) + "e" + String(exponent))
    }
    var name: String? { if case .name(let value) = self { return value }; return nil }
    var bool: Bool? { if case .boolean(let value) = self { return value }; return nil }
    var reference: PDFObjectID? { if case .reference(let value) = self { return value }; return nil }
    var data: Data? { if case .bytes(let value) = self { return value }; return nil }
    var text: String? {
        guard let data else { return nil }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        let special: [UInt8: UInt32] = [0x18:0x02D8,0x19:0x02C7,0x1A:0x02C6,0x1B:0x02D9,0x1C:0x02DD,0x1D:0x02DB,0x1E:0x02DA,0x1F:0x02DC,
            0x80:0x2022,0x81:0x2020,0x82:0x2021,0x83:0x2026,0x84:0x2014,0x85:0x2013,0x86:0x0192,0x87:0x2044,0x88:0x2039,0x89:0x203A,
            0x8A:0x2212,0x8B:0x2030,0x8C:0x201E,0x8D:0x201C,0x8E:0x201D,0x8F:0x2018,0x90:0x2019,0x91:0x201A,0x92:0x2122,0x93:0xFB01,0x94:0xFB02,
            0x95:0x0141,0x96:0x0152,0x97:0x0160,0x98:0x0178,0x99:0x017D,0x9A:0x0131,0x9B:0x0142,0x9C:0x0153,0x9D:0x0161,0x9E:0x017E,0xA0:0x20AC]
        return String(String.UnicodeScalarView(data.map { UnicodeScalar(special[$0] ?? UInt32($0))! }))
    }
    static func string(_ text: String) -> Self {
        .bytes(Data([0xFE, 0xFF]) + (text.data(using: .utf16BigEndian) ?? Data()))
    }
    var encoded: Data {
        switch self {
        case .name(let name):
            let raw = name.unicodeScalars.allSatisfy({ $0.value <= 255 }) ? name.unicodeScalars.map { UInt8($0.value) } : Array(name.utf8)
            let value = raw.map { byte -> String in
                if byte >= 33 && byte <= 126 && ![35, 37, 40, 41, 47, 60, 62, 91, 93, 123, 125].contains(byte) { return String(UnicodeScalar(byte)) }
                return String(format: "#%02X", byte)
            }.joined()
            return Data(("/" + value).utf8)
        case .number(let value), .keyword(let value): return Data(value.utf8)
        case .bytes(let value): return Data(("<" + value.map { String(format: "%02X", $0) }.joined() + ">").utf8)
        case .array(let values): return Data("[ ".utf8) + values.reduce(into: Data()) { $0 += $1.encoded + Data(" ".utf8) } + Data("]".utf8)
        case .dictionary(let values):
            return Data("<<\n".utf8) + values.keys.sorted().reduce(into: Data()) {
                $0 += PDFSyntaxValue.name($1).encoded + Data(" ".utf8) + values[$1]!.encoded + Data("\n".utf8)
            } + Data(">>".utf8)
        case .reference(let value): return Data(value.syntax.utf8)
        case .boolean(let value): return Data((value ? "true" : "false").utf8)
        case .null: return Data("null".utf8)
        }
    }
}

struct PDFSyntaxLexer {
    let bytes: [UInt8]
    var offset: Int
    var strict = false
    var allowContentOperators = false
    var collectLexicalFacts = false
    var hexLexemes: [(offset: Int, digits: Int, valid: Bool)] = []
    var duplicateKeys: [String] = []
    var memberRanges: [String: Range<Int>] = [:]
    init(_ data: Data, offset: Int = 0) { bytes = Array(data); self.offset = offset }
    init(bytes: [UInt8], offset: Int = 0) { self.bytes = bytes; self.offset = offset }
    mutating func skip() {
        while offset < bytes.count {
            if Self.space(bytes[offset]) { offset += 1 }
            else if bytes[offset] == 37 { while offset < bytes.count && bytes[offset] != 10 && bytes[offset] != 13 { offset += 1 } }
            else { break }
        }
    }
    static func space(_ value: UInt8) -> Bool { [0, 9, 10, 12, 13, 32].contains(value) }
    static func delimiter(_ value: UInt8) -> Bool { space(value) || [37, 40, 41, 47, 60, 62, 91, 93, 123, 125].contains(value) }
    static func numberToken(_ token:String) -> Bool {
        var digits = 0,dot = false
        for (index,byte) in token.utf8.enumerated() {
            if index == 0 && [43,45].contains(byte) { continue }
            if (48...57).contains(byte) { digits += 1 }
            else if byte == 46 && !dot { dot = true }
            else { return false }
        }
        return digits > 0
    }
    mutating func word() throws -> String {
        skip(); let start = offset
        while offset < bytes.count && !Self.delimiter(bytes[offset]) { offset += 1 }
        guard offset > start else { throw PDFStructureError.malformed(L10n.tr("token a \(offset)")) }
        return String(decoding: bytes[start..<offset], as: UTF8.self)
    }
    mutating func value(depth: Int = 0) throws -> PDFSyntaxValue {
        guard depth < 100 else { throw PDFStructureError.limit }
        skip(); guard offset < bytes.count else { throw PDFStructureError.malformed(L10n.tr("fine prematura")) }
        let current = bytes[offset]
        if current == 47 {
            offset += 1; var result: [UInt8] = []
            while offset < bytes.count && !Self.delimiter(bytes[offset]) {
                if bytes[offset] == 35, offset + 2 < bytes.count,
                   let byte = UInt8(String(decoding: bytes[(offset + 1)...(offset + 2)], as: UTF8.self), radix: 16) {
                    result.append(byte); offset += 3
                } else {
                    if strict && bytes[offset] == 35 { throw PDFStructureError.malformed(L10n.tr("escape esadecimale nel nome")) }
                    result.append(bytes[offset]); offset += 1
                }
            }
            return .name(String(bytes: result, encoding: .isoLatin1)!)
        }
        if current == 40 {
            offset += 1; var nesting = 1; var result = Data()
            while offset < bytes.count && nesting > 0 {
                let byte = bytes[offset]; offset += 1
                if byte == 92 {
                    guard offset < bytes.count else { break }
                    let escaped = bytes[offset]; offset += 1
                    if escaped >= 48 && escaped <= 55 {
                        var digits = [escaped]
                        for _ in 0..<2 where offset < bytes.count && bytes[offset] >= 48 && bytes[offset] <= 55 { digits.append(bytes[offset]); offset += 1 }
                        result.append(UInt8(Int(String(decoding: digits, as: UTF8.self), radix: 8)! & 255))
                    } else if escaped == 13 { if offset < bytes.count && bytes[offset] == 10 { offset += 1 } }
                    else if escaped != 10 {
                        let replacements: [UInt8: UInt8] = [110: 10, 114: 13, 116: 9, 98: 8, 102: 12]
                        result.append(replacements[escaped] ?? escaped)
                    }
                } else if byte == 40 { nesting += 1; result.append(byte) }
                else if byte == 41 { nesting -= 1; if nesting > 0 { result.append(byte) } }
                else if byte == 13 { result.append(10); if offset < bytes.count && bytes[offset] == 10 { offset += 1 } }
                else { result.append(byte) }
            }
            guard nesting == 0 else { throw PDFStructureError.malformed(L10n.tr("stringa non chiusa")) }
            return .bytes(result)
        }
        if current == 60 {
            if offset + 1 < bytes.count && bytes[offset + 1] == 60 {
                offset += 2; var result: [String: PDFSyntaxValue] = [:]; var ranges: [String: Range<Int>] = [:]
                while true {
                    skip(); guard offset + 1 < bytes.count else { throw PDFStructureError.malformed(L10n.tr("dizionario non chiuso")) }
                    if bytes[offset] == 62 && bytes[offset + 1] == 62 { offset += 2; break }
                    guard case .name(let name) = try value(depth: depth + 1) else { throw PDFStructureError.malformed(L10n.tr("chiave del dizionario")) }
                    skip(); let start = offset
                    if result[name] != nil {
                        if collectLexicalFacts { duplicateKeys.append(name) }
                        if strict { throw PDFStructureError.malformed(L10n.tr("chiave duplicata: ") + name) }
                    }
                    result[name] = try value(depth: depth + 1); ranges[name] = start..<offset
                    guard result.count < 100_000 else { throw PDFStructureError.limit }
                }
                memberRanges = ranges
                return .dictionary(result)
            }
            let hexStart = offset
            offset += 1; var hex: [UInt8] = []
            while offset < bytes.count && bytes[offset] != 62 {
                if !Self.space(bytes[offset]) { hex.append(bytes[offset]) }; offset += 1
            }
            guard offset < bytes.count else { throw PDFStructureError.malformed(L10n.tr("stringa esadecimale")) }
            if collectLexicalFacts {
                hexLexemes.append((hexStart,hex.count,hex.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }))
            }
            offset += 1; if hex.count % 2 != 0 { hex.append(48) }
            var result = Data()
            for index in stride(from: 0, to: hex.count, by: 2) {
                guard let byte = UInt8(String(decoding: hex[index..<(index + 2)], as: UTF8.self), radix: 16) else { throw PDFStructureError.malformed(L10n.tr("cifra esadecimale")) }
                result.append(byte)
            }
            return .bytes(result)
        }
        if current == 91 {
            offset += 1; var result: [PDFSyntaxValue] = []
            while true {
                skip(); guard offset < bytes.count else { throw PDFStructureError.malformed(L10n.tr("array non chiuso")) }
                if bytes[offset] == 93 { offset += 1; return .array(result) }
                result.append(try value(depth: depth + 1)); guard result.count < 1_000_000 else { throw PDFStructureError.limit }
            }
        }
        let token = try word()
        if token == "true" { return .boolean(true) }; if token == "false" { return .boolean(false) }; if token == "null" { return .null }
        let numeric = Self.numberToken(token)
        if numeric || Double(token) != nil {
            if strict && !numeric {
                throw PDFStructureError.malformed(L10n.tr("numero PDF non valido: ") + token)
            }
            let end = offset
            if let first = Int(token), first >= 0 {
                if let second = try? word(), let generation = Int(second), generation >= 0,
                   (try? word()) == "R" {
                    if strict && allowContentOperators { throw PDFStructureError.malformed(L10n.tr("riferimento indiretto nel content stream")) }
                    return .reference(PDFObjectID(number: first, generation: generation))
                }
                offset = end
            }
            return .number(token)
        }
        if strict, let first = token.utf8.first, (48...57).contains(first) || [43,45,46].contains(first) {
            throw PDFStructureError.malformed(L10n.tr("token numerico PDF non valido: ") + token)
        }
        if strict && !(allowContentOperators && depth == 0) { throw PDFStructureError.malformed(L10n.tr("parola chiave fuori da uno stream: ") + token) }
        return .keyword(token)
    }
}

struct PDFIndirectObject {
    let id: PDFObjectID
    var value: PDFSyntaxValue
    var stream: Data?
    var memberRanges: [String: Range<Int>] = [:]
    var encoded: Data {
        var value = self.value
        if let stream, var dictionary = value.dictionary { dictionary["Length"] = .number(String(stream.count)); value = .dictionary(dictionary) }
        var result = Data("\(id.number) \(id.generation) obj\n".utf8) + value.encoded
        if let stream { result += Data("\nstream\n".utf8) + stream + Data("\nendstream".utf8) }
        return result + Data("\nendobj\n".utf8)
    }
}

struct PDFEmbeddedImage: Identifiable {
    let id: PDFObjectID
    let width: Int
    let height: Int
    let bits: Int
    let filters: [String]
    let colorSpace: String
    var description: String { L10n.tr("Oggetto \(id.number) · \(width) × \(height) px · \(bits) bit · \(filters.isEmpty ? L10n.tr("non compresso") : filters.joined(separator: ", "))") }
}
struct PDFEmbeddedFile: Identifiable {
    let id: PDFObjectID
    let name: String
    let streamID: PDFObjectID
    let size: Int
}
struct PDFOptionalLayer: Identifiable {
    let id: PDFObjectID
    let name: String
    let visible: Bool
}
struct PDFOriginalTextRun: Identifiable {
    var id: String { "\(pageIndex):\(streamID.id):\(range.lowerBound)" }
    let pageIndex: Int
    let streamID: PDFObjectID
    let range: Range<Int>
    let bytes: Data
    let text: String
    let font: String
}
struct PDFPreflightItem: Identifiable {
    let id = UUID()
    let severity: String
    let title: String
    let detail: String
}

final class PDFStructureDocument {
    enum XrefEntry { case free, direct(Int, Int), compressed(Int, Int) }
    let source: Data
    let sourceBytes: [UInt8]
    private(set) var trailer: [String: PDFSyntaxValue] = [:]
    private(set) var lastXref = 0
    private var entries: [Int: XrefEntry] = [:]
    private(set) var revisions: [(offset: Int, dictionary: [String: PDFSyntaxValue], entries: [Int: XrefEntry])] = []
    private var cache: [PDFObjectID: PDFIndirectObject] = [:]
    private var decodedCache: [PDFObjectID:Data] = [:]
    private var decodedCacheSize = 0
    private var updates: [PDFObjectID: PDFIndirectObject] = [:]
    private var nextNumber = 1
    private var reading = Set<PDFObjectID>()
    var encrypted: Bool { trailer["Encrypt"] != nil }
    var rootID: PDFObjectID { get throws { guard trailer["Root"]?.reference != nil,let id = try resolvedObjectID(trailer["Root"]) else { throw PDFStructureError.malformed(L10n.tr("catalogo mancante")) }; return id } }

    init(data: Data) throws {
        guard data.count <= 512 * 1024 * 1024 else { throw PDFStructureError.limit }
        guard data.starts(with: Data("%PDF-".utf8)) else { throw PDFStructureError.malformed("intestazione") }
        source = data; sourceBytes = Array(data)
        guard let marker = data.range(of: Data("startxref".utf8), options: .backwards) else { throw PDFStructureError.malformed(L10n.tr("startxref mancante")) }
        var lexer = PDFSyntaxLexer(bytes: sourceBytes, offset: marker.upperBound)
        guard let offset = Int(try lexer.word()), offset >= 0, offset < data.count else { throw PDFStructureError.malformed(L10n.tr("offset xref")) }
        lastXref = offset
        try readXref(at: offset, visited: [])
        nextNumber = max((entries.keys.max() ?? 0) + 1, trailer["Size"]?.int ?? 1)
        guard nextNumber < 1_000_000 else { throw PDFStructureError.limit }
        _ = try object(rootID)
    }
    private init(source:Data,bytes:[UInt8],revisions:[(offset:Int,dictionary:[String:PDFSyntaxValue],entries:[Int:XrefEntry])],at offset:Int) throws {
        self.source = source;sourceBytes = bytes;self.revisions = revisions;lastXref = offset
        var count = 0
        for revision in revisions {
            try Task.checkCancellation();count += revision.entries.count
            guard count <= 2_000_000 else { throw PDFStructureError.limit }
            for (number,entry) in revision.entries where entries[number] == nil { entries[number] = entry }
            for (key,value) in revision.dictionary where trailer[key] == nil { trailer[key] = value }
        }
        nextNumber = max((entries.keys.max() ?? 0)+1,trailer["Size"]?.int ?? 1)
    }
    /// Immutable xref state at a recorded revision. Free entries and generation
    /// changes shadow older entries; later updates cannot supply an old Length.
    func revisionReader(at offset:Int) throws -> PDFStructureDocument {
        if offset == lastXref { return self }
        guard let index = revisions.firstIndex(where:{ $0.offset == offset }) else { throw PDFStructureError.malformed(L10n.tr("revisione xref non indicizzata")) }
        return try PDFStructureDocument(source:source,bytes:sourceBytes,revisions:Array(revisions[index...]),at:offset)
    }

    private func readXref(at offset: Int, visited: Set<Int>) throws {
        guard !visited.contains(offset), visited.count < 1000, offset >= 0, offset < source.count else { throw PDFStructureError.malformed(L10n.tr("catena xref")) }
        var visited = visited; visited.insert(offset)
        var lexer = PDFSyntaxLexer(bytes: sourceBytes, offset: offset)
        let token = try lexer.word()
        var local: [Int: XrefEntry] = [:]
        let dictionary: [String: PDFSyntaxValue]
        if token == "xref" {
            while true {
                let first = try lexer.word()
                if first == "trailer" { break }
                guard let start = Int(first), let count = Int(try lexer.word()), start >= 0, start < 1_000_000,
                      count >= 0, count < 1_000_000 - start else { throw PDFStructureError.limit }
                for number in start..<(start + count) {
                    guard let position = Int(try lexer.word()), let generation = Int(try lexer.word()) else { throw PDFStructureError.malformed(L10n.tr("riga xref")) }
                    let state = try lexer.word()
                    local[number] = state == "n" ? .direct(position, generation) : .free
                }
            }
            guard let value = try lexer.value().dictionary else { throw PDFStructureError.malformed("trailer") }
            dictionary = value
            if let hybrid = value["XRefStm"]?.int {
                guard hybrid >= 0, hybrid < source.count, hybrid != offset else { throw PDFStructureError.malformed(L10n.tr("offset xref ibrida")) }
                let supplement = try readXrefStream(at: hybrid)
                local.merge(supplement.entries) { _, streamEntry in streamEntry }
                revisions.append((hybrid,supplement.dictionary,supplement.entries))
            }
        } else {
            let stream = try readXrefStream(at: offset)
            dictionary = stream.dictionary; local = stream.entries
        }
        revisions.append((offset,dictionary,local))
        for (number, entry) in local where entries[number] == nil { entries[number] = entry }
        for (key, value) in dictionary where trailer[key] == nil { trailer[key] = value }
        if let previous = dictionary["Prev"]?.int { try readXref(at: previous, visited: visited) }
    }

    private func readXrefStream(at offset: Int) throws -> (dictionary: [String: PDFSyntaxValue], entries: [Int: XrefEntry]) {
        var local: [Int: XrefEntry] = [:]
        let object = try readDirectObject(at: offset)
        guard let value = object.value.dictionary, value["Type"]?.name == "XRef", let stream = object.stream,
              let widths = value["W"]?.array?.compactMap(\.int), widths.count == 3,
              widths.allSatisfy({ $0 >= 0 && $0 <= 8 }), widths.reduce(0, +) > 0 else { throw PDFStructureError.malformed(L10n.tr("stream xref")) }
        let data = try Self.decode(stream, dictionary: value)
        let index = value["Index"]?.array?.compactMap(\.int) ?? [0, value["Size"]?.int ?? 0]
        guard index.count % 2 == 0 else { throw PDFStructureError.malformed(L10n.tr("indice xref")) }
        let bytes = Array(data); var cursor = 0
        func field(_ count: Int) throws -> Int {
            guard cursor + count <= bytes.count else { throw PDFStructureError.malformed(L10n.tr("stream xref troncato")) }
            var result = 0
            for _ in 0..<count { guard result <= Int.max >> 8 else { throw PDFStructureError.limit }; result = (result << 8) | Int(bytes[cursor]); cursor += 1 }
            return result
        }
        for pair in stride(from: 0, to: index.count, by: 2) {
            let start = index[pair], count = index[pair + 1]
            guard start >= 0, start < 1_000_000, count >= 0, count < 1_000_000 - start else { throw PDFStructureError.limit }
            for number in start..<(start + count) {
                let type = widths[0] == 0 ? 1 : try field(widths[0])
                let one = try field(widths[1]), two = try field(widths[2])
                local[number] = type == 1 ? .direct(one, two) : type == 2 ? .compressed(one, two) : .free
            }
        }
        return (value, local)
    }

    private func readDirectObject(at offset: Int) throws -> PDFIndirectObject {
        guard offset >= 0, offset < sourceBytes.count else { throw PDFStructureError.malformed(L10n.tr("offset oggetto fuori dal file")) }
        var lexer = PDFSyntaxLexer(bytes: sourceBytes, offset: offset)
        guard let number = Int(try lexer.word()), let generation = Int(try lexer.word()),
              number >= 0, number < 1_000_000, (0..<65536).contains(generation),
              try lexer.word() == "obj" else { throw PDFStructureError.malformed("oggetto a \(offset)") }
        let value = try lexer.value(); let memberRanges = lexer.memberRanges
        lexer.skip(); var stream: Data?
        if value.dictionary != nil, (try? lexer.word()) == "stream" {
            if lexer.offset < sourceBytes.count && sourceBytes[lexer.offset] == 13 { lexer.offset += 1 }
            if lexer.offset < sourceBytes.count && sourceBytes[lexer.offset] == 10 { lexer.offset += 1 }
            var length = value.dictionary?["Length"]?.int
            if length == nil { length = try resolve(value.dictionary?["Length"])?.int }
            guard let length, length >= 0, length <= 256 * 1024 * 1024,
                  lexer.offset <= source.count - length else { throw PDFStructureError.malformed(L10n.tr("lunghezza stream")) }
            stream = Data(sourceBytes[lexer.offset..<(lexer.offset + length)])
            lexer.offset += length
            guard (try? lexer.word()) == "endstream" else { throw PDFStructureError.malformed(L10n.tr("fine stream")) }
        }
        return PDFIndirectObject(id: PDFObjectID(number: number, generation: generation), value: value, stream: stream, memberRanges: memberRanges)
    }

    func object(_ id: PDFObjectID) throws -> PDFIndirectObject {
        if let value = updates[id] ?? cache[id] { return value }
        guard !reading.contains(id) else { throw PDFStructureError.malformed(L10n.tr("riferimento circolare")) }
        reading.insert(id); defer { reading.remove(id) }
        guard let entry = entries[id.number] else { throw PDFStructureError.malformed("oggetto \(id.syntax) mancante") }
        let result: PDFIndirectObject
        switch entry {
        case .free: throw PDFStructureError.malformed("oggetto libero")
        case .direct(let offset, let generation):
            guard generation == id.generation else { throw PDFStructureError.malformed(L10n.tr("generazione oggetto")) }
            result = try readDirectObject(at: offset)
            guard result.id == id else { throw PDFStructureError.malformed(L10n.tr("identità oggetto")) }
        case .compressed(let container, let index):
            guard id.generation == 0 else { throw PDFStructureError.malformed(L10n.tr("generazione stream oggetto")) }
            let owner = try object(PDFObjectID(number: container, generation: 0))
            guard let dictionary = owner.value.dictionary,try resolve(dictionary["Type"])?.name == "ObjStm",let stream = owner.stream,
                  let count = try resolve(dictionary["N"])?.int,let first = try resolve(dictionary["First"])?.int,
                  count >= 0,first >= 0,index >= 0,index < count else { throw PDFStructureError.malformed(L10n.tr("stream di oggetti")) }
            guard count < 100_000 else { throw PDFStructureError.limit }
            let data = try Self.decode(stream, dictionary: streamDecodingDictionary(dictionary))
            var header = PDFSyntaxLexer(data)
            var positions: [(Int, Int)] = []
            for _ in 0..<count {
                guard let number = Int(try header.word()), let offset = Int(try header.word()) else { throw PDFStructureError.malformed(L10n.tr("indice oggetti compressi")) }
                positions.append((number, offset))
            }
            guard positions[index].0 == id.number, first >= 0, positions[index].1 >= 0,
                  positions[index].1 < data.count, first < data.count - positions[index].1 else { throw PDFStructureError.malformed(L10n.tr("posizione oggetto compresso")) }
            var lexer = PDFSyntaxLexer(data, offset: first + positions[index].1)
            result = PDFIndirectObject(id: id, value: try lexer.value(), stream: nil)
        }
        cache[id] = result
        return result
    }

    func resolve(_ value: PDFSyntaxValue?) throws -> PDFSyntaxValue? { try resolution(value).value }
    /// Identity of the terminal indirect object, distinct from a reference alias.
    /// Physical object(id) continues exposing the original indexed body.
    func resolvedObjectID(_ value:PDFSyntaxValue?) throws -> PDFObjectID? { try resolution(value).id }
    private func resolution(_ input:PDFSyntaxValue?) throws -> (id:PDFObjectID?,value:PDFSyntaxValue?) {
        guard var value = input else { return (nil,nil) }
        var visited = Set<PDFObjectID>(),terminal:PDFObjectID?
        while let id = value.reference {
            try Task.checkCancellation()
            guard visited.insert(id).inserted else { throw PDFStructureError.unsupported(L10n.tr("catena di alias indiretti circolare")) }
            guard visited.count <= 1000 else { throw PDFStructureError.limit }
            // §7.3.10: undefined indirect objects have null semantics. A broken
            // body at an existing xref entry still raises its parsing error.
            if updates[id] == nil,cache[id] == nil {
                guard let entry = entries[id.number] else { return (nil,.null) }
                switch entry {
                case .free:return (nil,.null)
                case .direct(_,let generation):if generation != id.generation { return (nil,.null) }
                case .compressed:if id.generation != 0 { return (nil,.null) }
                }
            }
            value = try object(id).value;terminal = id
        };return (terminal,value)
    }
    func dictionary(_ value: PDFSyntaxValue?) throws -> [String: PDFSyntaxValue] { try resolve(value)?.dictionary ?? [:] }
    func requireWritable() throws {
        guard !encrypted else { throw PDFStructureError.encrypted }
        let root = try dictionary(.reference(rootID))
        if root["Perms"] != nil { throw PDFStructureError.unsupported(L10n.tr("documento certificato: permessi DocMDP")) }
    }
    @discardableResult func add(_ value: PDFSyntaxValue, stream: Data? = nil) -> PDFObjectID {
        let id = PDFObjectID(number: nextNumber, generation: 0); nextNumber += 1
        updates[id] = PDFIndirectObject(id: id, value: value, stream: stream)
        return id
    }
    func replace(_ id: PDFObjectID, dictionary: [String: PDFSyntaxValue], stream: Data? = nil) {
        // A replacement can also change an indirectly referenced filter value.
        decodedCache.removeAll();decodedCacheSize = 0
        updates[id] = PDFIndirectObject(id: id, value: .dictionary(dictionary), stream: stream)
    }
    func writeIncremental() throws -> Data {
        try requireWritable(); guard !updates.isEmpty else { return source }
        var result = source + Data("\n".utf8); var positions: [PDFObjectID: Int] = [:]
        for id in updates.keys.sorted() { positions[id] = result.count; result += updates[id]!.encoded }
        let xrefOffset = result.count; result += Data("xref\n".utf8)
        if trailer["Type"]?.name == "XRef" {
            // Keep stream-based xrefs stream-based. Some native readers reject a
            // classic incremental table whose Prev points into an xref stream.
            result.removeSubrange(xrefOffset..<result.count)
            let xrefID = PDFObjectID(number: nextNumber, generation: 0)
            positions[xrefID] = xrefOffset
            var rows = Data(), index: [PDFSyntaxValue] = []
            for id in positions.keys.sorted() {
                guard let offset = positions[id], offset <= Int(UInt32.max), id.generation < 65536 else { throw PDFStructureError.limit }
                rows += Data([1, UInt8((offset >> 24) & 255), UInt8((offset >> 16) & 255), UInt8((offset >> 8) & 255), UInt8(offset & 255), UInt8((id.generation >> 8) & 255), UInt8(id.generation & 255)])
                index += [.number(String(id.number)), .number("1")]
            }
            var xref: [String: PDFSyntaxValue] = ["Type": .name("XRef"), "Root": .reference(try rootID),
                "Size": .number(String(nextNumber + 1)), "Prev": .number(String(lastXref)),
                "W": .array([.number("1"), .number("4"), .number("2")]), "Index": .array(index)]
            for key in ["Info", "ID"] { xref[key] = trailer[key] }
            result += PDFIndirectObject(id: xrefID, value: .dictionary(xref), stream: rows).encoded
            result += Data("startxref\n\(xrefOffset)\n%%EOF\n".utf8)
            guard let provider = CGDataProvider(data: result as CFData), CGPDFDocument(provider) != nil else { throw PDFStructureError.malformed(L10n.tr("risultato incrementale xref-stream")) }
            return result
        }
        for id in positions.keys.sorted() {
            guard let offset = positions[id], offset < 10_000_000_000, id.generation < 65536 else { throw PDFStructureError.limit }
            result += Data("\(id.number) 1\n".utf8)
            result += Data(String(format: "%010lld %05d n \n", Int64(offset), id.generation).utf8)
        }
        var newTrailer: [String: PDFSyntaxValue] = ["Root": .reference(try rootID), "Size": .number(String(nextNumber)), "Prev": .number(String(lastXref))]
        for key in ["Info", "ID"] { newTrailer[key] = trailer[key] }
        result += Data("trailer\n".utf8) + PDFSyntaxValue.dictionary(newTrailer).encoded
        result += Data("\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8)
        guard CGPDFDocument(CGDataProvider(data: result as CFData)!) != nil else { throw PDFStructureError.malformed(L10n.tr("risultato incrementale")) }
        return result
    }
    func allObjectIDs() -> [PDFObjectID] {
        Array(Set(entries.compactMap { number, entry -> PDFObjectID? in
            switch entry { case .direct(_, let generation): return PDFObjectID(number: number, generation: generation)
            case .compressed: return PDFObjectID(number: number, generation: 0)
            case .free: return nil }
        } + updates.keys)).sorted()
    }
    func pageIDs() throws -> [PDFObjectID] {
        let root = try object(rootID).value.dictionary ?? [:]
        guard let pages = root["Pages"]?.reference else { throw PDFStructureError.malformed(L10n.tr("albero pagine")) }
        var result: [PDFObjectID] = [], visited = Set<PDFObjectID>()
        func walk(_ id: PDFObjectID, depth: Int) throws {
            guard depth < 100,visited.count < 100_000 else { throw PDFStructureError.limit }
            guard let canonical = try resolvedObjectID(.reference(id)) else { throw PDFStructureError.malformed("pagina indiretta nulla") }
            guard visited.insert(canonical).inserted else { throw PDFStructureError.malformed(L10n.tr("albero pagine circolare/condiviso")) }
            let d = try dictionary(.reference(canonical))
            if try resolve(d["Type"])?.name == "Page" { result.append(canonical) }
            else { for child in try resolve(d["Kids"])?.array ?? [] { if let id = child.reference { try walk(id, depth: depth + 1) } } }
        }
        try walk(pages, depth: 0); return result
    }
    func inherited(_ key: String, pageID: PDFObjectID) throws -> PDFSyntaxValue? {
        var next: PDFObjectID? = pageID; var visited = Set<PDFObjectID>()
        while let id = next {
            guard visited.count < 1000 else { throw PDFStructureError.limit }
            guard let canonical = try resolvedObjectID(.reference(id)) else { return nil }
            guard visited.insert(canonical).inserted else { throw PDFStructureError.malformed(L10n.tr("parent circolare")) }
            let d = try dictionary(.reference(canonical))
            if let raw = d[key],let value = try resolve(raw) {
                // A null dictionary entry is omission (§7.3.9), including
                // undefined/free indirect references. Continue inheritance.
                if case .null = value { } else { return value }
            }
            next = d["Parent"]?.reference
        }
        return nil
    }

    static func filters(_ dictionary: [String: PDFSyntaxValue]) -> [String] {
        dictionary["Filter"]?.name.map { [$0] } ?? dictionary["Filter"]?.array?.compactMap(\.name) ?? []
    }
    static func decode(_ data: Data, dictionary: [String: PDFSyntaxValue]) throws -> Data {
        let names:[String]
        switch dictionary["Filter"] {
        case nil,.null?: names = []
        case .name(let name)?: names = [name]
        case .array(let array)?:
            guard array.allSatisfy({ $0.name != nil }) else { throw PDFStructureError.malformed(L10n.tr("elenco Filter")) }
            names = array.compactMap(\.name)
        case .reference?: throw PDFStructureError.unsupported(L10n.tr("Filter indiretto non risolto"))
        default: throw PDFStructureError.malformed(L10n.tr("tipo Filter"))
        }
        guard names.count <= 100 else { throw PDFStructureError.limit }
        let parameters:[PDFSyntaxValue]
        switch dictionary["DecodeParms"] {
        case nil,.null?: parameters = Array(repeating:.null,count:names.count)
        case .dictionary(let value)?:
            guard names.count == 1 else { throw PDFStructureError.malformed(L10n.tr("DecodeParms non corrisponde a Filter")) }
            parameters = [.dictionary(value)]
        case .array(let values)?:
            guard values.count == names.count,values.allSatisfy({ if case .null = $0 { return true };return $0.dictionary != nil }) else { throw PDFStructureError.malformed(L10n.tr("elenco DecodeParms")) }
            parameters = values
        case .reference?: throw PDFStructureError.unsupported(L10n.tr("DecodeParms indiretto non risolto"))
        default: throw PDFStructureError.malformed(L10n.tr("tipo DecodeParms"))
        }
        var result = data
        for (index,name) in names.enumerated() {
            let parameter = parameters[index].dictionary ?? [:]
            result = try PDFStreamFilters.prefix(result,filter:name,parameters:parameter).data
            if ["FlateDecode","Fl","LZWDecode","LZW"].contains(name) { result = try PDFStreamFilters.unpredict(result,parameters:parameter) }
        }
        return result
    }
    /// Except where specifically forbidden, filter names, parameter dictionaries
    /// and their values may be indirect (§7.3.10). Resolve only this bounded tree.
    func streamDecodingDictionary(_ dictionary:[String:PDFSyntaxValue]) throws -> [String:PDFSyntaxValue] {
        func expand(_ value:PDFSyntaxValue,active:Set<PDFObjectID>,depth:Int) throws -> PDFSyntaxValue {
            guard depth < 60 else { throw PDFStructureError.limit }
            if let id = value.reference {
                guard !active.contains(id) else { throw PDFStructureError.malformed(L10n.tr("parametri filtro circolari")) }
                return try expand(resolve(value) ?? .null,active:active.union([id]),depth:depth+1)
            }
            if let array = value.array { return .array(try array.map { try expand($0,active:active,depth:depth+1) }) }
            if let dictionary = value.dictionary { return .dictionary(try dictionary.mapValues { try expand($0,active:active,depth:depth+1) }) }
            return value
        }
        var result = dictionary
        for key in ["Filter","DecodeParms"] { if let value = dictionary[key] { result[key] = try expand(value,active:[],depth:0) } }
        return result
    }

}

extension PDFStructureDocument {
    enum PageLabelStyle: String, CaseIterable, Identifiable {
        case decimal = "D", romanLower = "r", romanUpper = "R", alphabeticLower = "a", alphabeticUpper = "A", prefixOnly = ""
        var id: String { rawValue }
        var title: String {
            switch self { case .decimal: return "1, 2, 3"; case .romanLower: return L10n.tr("i, ii, iii"); case .romanUpper: return L10n.tr("I, II, III")
            case .alphabeticLower: return "a, b, c"; case .alphabeticUpper: return "A, B, C"; case .prefixOnly: return L10n.tr("Solo prefisso") }
        }
    }
    func setPageLabels(startPage: Int, firstNumber: Int, prefix: String, style: PageLabelStyle) throws -> Data {
        try requireWritable(); let count = try pageIDs().count
        guard (0..<count).contains(startPage), firstNumber >= 1 else { throw PDFStructureError.malformed(L10n.tr("intervallo numerazione logica")) }
        let id = try rootID; var root = try dictionary(.reference(id))
        var pairs: [Int: PDFSyntaxValue] = [:]
        func collect(_ value: PDFSyntaxValue?, visited: inout Set<PDFObjectID>) throws {
            if let reference = value?.reference { guard visited.insert(reference).inserted else { throw PDFStructureError.malformed(L10n.tr("PageLabels circolare")) } }
            let node = try dictionary(value)
            let nums = try resolve(node["Nums"])?.array ?? []
            guard nums.count % 2 == 0 else { throw PDFStructureError.malformed(L10n.tr("PageLabels Nums")) }
            for index in stride(from: 0, to: nums.count, by: 2) { if let number = nums[index].int { pairs[number] = nums[index + 1] } }
            for kid in try resolve(node["Kids"])?.array ?? [] { try collect(kid, visited: &visited) }
        }
        var visited = Set<PDFObjectID>(); try collect(root["PageLabels"], visited: &visited)
        var label: [String: PDFSyntaxValue] = ["St": .number(String(firstNumber))]
        if !prefix.isEmpty { label["P"] = .string(prefix) }; if !style.rawValue.isEmpty { label["S"] = .name(style.rawValue) }
        pairs[startPage] = .dictionary(label)
        if pairs[0] == nil { pairs[0] = .dictionary(["S": .name("D")]) }
        root["PageLabels"] = .dictionary(["Nums": .array(pairs.keys.sorted().flatMap { [.number(String($0)), pairs[$0]!] })])
        replace(id, dictionary: root); return try writeIncremental()
    }

    func embeddedImages() throws -> [PDFEmbeddedImage] {
        guard !encrypted else { throw PDFStructureError.encrypted }
        return try allObjectIDs().compactMap { id in
            let object = try object(id); guard let dictionary = object.value.dictionary,
                dictionary["Subtype"]?.name == "Image", object.stream != nil else { return nil }
            let color = try resolve(dictionary["ColorSpace"])
            return PDFEmbeddedImage(id: id, width: dictionary["Width"]?.int ?? 0, height: dictionary["Height"]?.int ?? 0,
                                    bits: dictionary["BitsPerComponent"]?.int ?? 1, filters: Self.filters(dictionary),
                                    colorSpace: color?.name ?? color?.array?.first?.name ?? "maschera")
        }
    }
    func extractImage(_ image: PDFEmbeddedImage) throws -> (data: Data, fileExtension: String) {
        guard !encrypted else { throw PDFStructureError.encrypted }
        let object = try object(image.id); guard let dictionary = object.value.dictionary, let stream = object.stream else { throw PDFStructureError.malformed("immagine") }
        let filters = Self.filters(dictionary)
        if filters.last == "DCTDecode" || filters.last == "JPXDecode" {
            var prefix = dictionary
            prefix["Filter"] = .array(filters.dropLast().map { .name($0) }); prefix.removeValue(forKey: "DecodeParms")
            return (try Self.decode(stream, dictionary: prefix), filters.last == "DCTDecode" ? "jpg" : "jp2")
        }
        guard image.bits == 8, ["DeviceRGB", "DeviceGray"].contains(image.colorSpace),
              dictionary["SMask"] == nil, dictionary["Mask"] == nil, dictionary["Decode"] == nil else {
            throw PDFStructureError.unsupported(L10n.tr("estrazione lossless solo JPEG/JPX o bitmap RGB/grigie a 8 bit senza maschere"))
        }
        let pixels = try Self.decode(stream, dictionary: dictionary), components = image.colorSpace == "DeviceRGB" ? 3 : 1
        guard image.width > 0, image.height > 0, image.width <= 50_000, image.height <= 50_000,
              image.width * image.height <= 40_000_000, pixels.count == image.width * image.height * components,
              let provider = CGDataProvider(data: pixels as CFData),
              let cgImage = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 8 * components,
                                    bytesPerRow: image.width * components, space: components == 3 ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                                    shouldInterpolate: false, intent: .defaultIntent),
              let encoded = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            throw PDFStructureError.malformed(L10n.tr("dimensioni bitmap"))
        }
        return (encoded, "png")
    }
    func replaceImage(_ id: PDFObjectID, with image: CGImage) throws -> Data {
        try requireWritable(); let object = try object(id)
        guard var dictionary = object.value.dictionary, dictionary["Subtype"]?.name == "Image",
              image.width > 0, image.height > 0, image.width * image.height <= 40_000_000 else { throw PDFStructureError.malformed(L10n.tr("immagine da sostituire")) }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let memory = context.data else { throw PDFStructureError.limit }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let rgba = memory.assumingMemoryBound(to: UInt8.self); var rgb = Data(capacity: image.width * image.height * 3)
        for pixel in 0..<(image.width * image.height) { rgb.append(contentsOf: [rgba[pixel * 4], rgba[pixel * 4 + 1], rgba[pixel * 4 + 2]]) }
        for key in ["Filter", "DecodeParms", "Decode", "SMask", "Mask", "ImageMask", "SMaskInData", "Alternates", "OPI", "Metadata"] { dictionary.removeValue(forKey: key) }
        dictionary["Width"] = .number(String(image.width)); dictionary["Height"] = .number(String(image.height))
        dictionary["BitsPerComponent"] = .number("8"); dictionary["ColorSpace"] = .name("DeviceRGB")
        replace(id, dictionary: dictionary, stream: rgb); return try writeIncremental()
    }

    private func nameTree(_ value: PDFSyntaxValue?, visited: inout Set<PDFObjectID>) throws -> [(String, PDFSyntaxValue)] {
        if let id = value?.reference { guard visited.insert(id).inserted else { throw PDFStructureError.malformed(L10n.tr("name tree circolare")) } }
        let dictionary = try dictionary(value), names = try resolve(dictionary["Names"])?.array ?? []
        guard names.count % 2 == 0 else { throw PDFStructureError.malformed(L10n.tr("name tree")) }
        var result: [(String, PDFSyntaxValue)] = []
        for index in stride(from: 0, to: names.count, by: 2) { if let name = names[index].text { result.append((name, names[index + 1])) } }
        for child in try resolve(dictionary["Kids"])?.array ?? [] { result += try nameTree(child, visited: &visited) }
        return result
    }
    func embeddedFiles() throws -> [PDFEmbeddedFile] {
        guard !encrypted else { throw PDFStructureError.encrypted }
        let root = try dictionary(.reference(rootID)), names = try dictionary(root["Names"])
        var visited = Set<PDFObjectID>()
        return try nameTree(names["EmbeddedFiles"], visited: &visited).compactMap { fallback, value in
            guard let id = value.reference else { throw PDFStructureError.unsupported(L10n.tr("Filespec diretto")) }
            let file = try dictionary(value), ef = try dictionary(file["EF"])
            guard let streamID = (ef["UF"] ?? ef["F"])?.reference else { return nil }
            let stream = try object(streamID)
            let name = file["UF"]?.text ?? file["F"]?.text ?? fallback
            return PDFEmbeddedFile(id: id, name: name, streamID: streamID, size: stream.value.dictionary?["Params"]?.dictionary?["Size"]?.int ?? stream.stream?.count ?? 0)
        }
    }
    func extractAttachment(_ file: PDFEmbeddedFile) throws -> Data {
        guard !encrypted else { throw PDFStructureError.encrypted }
        let object = try object(file.streamID)
        guard let stream = object.stream, let dictionary = object.value.dictionary else { throw PDFStructureError.malformed("allegato") }
        return try Self.decode(stream, dictionary: streamDecodingDictionary(dictionary))
    }
    func addingAttachments(_ files: [(name: String, data: Data)], portfolio: Bool = false) throws -> Data {
        try requireWritable(); let id = try rootID; var root = try dictionary(.reference(id)); var names = try dictionary(root["Names"])
        var visited = Set<PDFObjectID>(); var pairs = try nameTree(names["EmbeddedFiles"], visited: &visited)
        var existing = Set(pairs.map(\.0))
        for file in files {
            guard !file.name.isEmpty, file.data.count <= 256 * 1024 * 1024 else { throw PDFStructureError.limit }
            guard existing.insert(file.name).inserted else { throw PDFStructureError.unsupported(L10n.tr("un allegato si chiama già “\(file.name)”")) }
            let stream = add(.dictionary(["Type": .name("EmbeddedFile"), "Params": .dictionary(["Size": .number(String(file.data.count))])]), stream: file.data)
            let spec = add(.dictionary(["Type": .name("Filespec"), "F": .string(file.name), "UF": .string(file.name),
                                        "EF": .dictionary(["F": .reference(stream), "UF": .reference(stream)]),
                                        "AFRelationship": .name("Unspecified"), "CI": .dictionary(["Nome": .string(file.name)])]))
            pairs.append((file.name, .reference(spec)))
        }
        pairs.sort { PDFSyntaxValue.string($0.0).data!.lexicographicallyPrecedes(PDFSyntaxValue.string($1.0).data!) }
        names["EmbeddedFiles"] = .dictionary(["Names": .array(pairs.flatMap { [.string($0.0), $0.1] })])
        root["Names"] = .dictionary(names)
        var associated = try resolve(root["AF"])?.array ?? []
        for (_, value) in pairs where !associated.contains(where: { $0.reference == value.reference }) { associated.append(value) }
        root["AF"] = .array(associated)
        if portfolio {
            root["Collection"] = .dictionary(["Type": .name("Collection"), "View": .name("D"),
                "Schema": .dictionary(["Nome": .dictionary(["Type": .name("CollectionField"), "Subtype": .name("F"), "N": .string("Nome file"), "O": .number("0")])])])
        }
        replace(id, dictionary: root); return try writeIncremental()
    }
    func removingAttachment(_ file: PDFEmbeddedFile) throws -> Data {
        try requireWritable(); let id = try rootID; var root = try dictionary(.reference(id)); var names = try dictionary(root["Names"])
        var visited = Set<PDFObjectID>(); let pairs = try nameTree(names["EmbeddedFiles"], visited: &visited).filter { $0.1.reference != file.id }
        names["EmbeddedFiles"] = .dictionary(["Names": .array(pairs.flatMap { [.string($0.0), $0.1] })]); root["Names"] = .dictionary(names)
        if let af = try resolve(root["AF"])?.array { root["AF"] = .array(af.filter { $0.reference != file.id }) }
        replace(id, dictionary: root); return try writeIncremental()
    }

    func optionalLayers() throws -> [PDFOptionalLayer] {
        guard !encrypted else { throw PDFStructureError.encrypted }
        let root = try dictionary(.reference(rootID)), properties = try dictionary(root["OCProperties"]), configuration = try dictionary(properties["D"])
        let on = Set((try resolve(configuration["ON"])?.array ?? []).compactMap(\.reference))
        let off = Set((try resolve(configuration["OFF"])?.array ?? []).compactMap(\.reference))
        let base = configuration["BaseState"]?.name != "OFF"
        return try (resolve(properties["OCGs"])?.array ?? []).compactMap { value in
            guard let id = value.reference else { return nil }; let layer = try dictionary(value)
            return PDFOptionalLayer(id: id, name: layer["Name"]?.text ?? "Livello \(id.number)", visible: on.contains(id) || (!off.contains(id) && base))
        }
    }
    func setLayerVisibility(_ id: PDFObjectID, visible: Bool) throws -> Data {
        try requireWritable(); guard try optionalLayers().contains(where: { $0.id == id }) else { throw PDFStructureError.malformed("livello") }
        let rootID = try rootID; var root = try dictionary(.reference(rootID)); var properties = try dictionary(root["OCProperties"]); var config = try dictionary(properties["D"])
        for (key, include) in [("ON", visible), ("OFF", !visible)] {
            var ids = (try resolve(config[key])?.array ?? []).filter { $0.reference != id }
            if include { ids.append(.reference(id)) }; config[key] = .array(ids)
        }
        properties["D"] = .dictionary(config); root["OCProperties"] = .dictionary(properties); replace(rootID, dictionary: root)
        return try writeIncremental()
    }

    func contentStreamIDs(on page: PDFObjectID) throws -> [PDFObjectID] {
        let dictionary = try dictionary(.reference(page))
        guard let contents = try resolve(dictionary["Contents"]) else { return [] }
        if case .null = contents { return [] }
        if let id = try resolvedObjectID(dictionary["Contents"]), try object(id).stream != nil { return [id] }
        guard let values = contents.array else { throw PDFStructureError.malformed(L10n.tr("Contents non è uno stream o un array di stream")) }
        guard values.count <= 100_000 else { throw PDFStructureError.limit }
        return try values.map { value in
            try Task.checkCancellation()
            guard let id = try resolvedObjectID(value), try object(id).stream != nil else {
                throw PDFStructureError.malformed(L10n.tr("elemento Contents non è uno stream indiretto"))
            };return id
        }
    }
    func decodedStream(_ id: PDFObjectID) throws -> Data {
        guard !encrypted else { throw PDFStructureError.encrypted }
        guard let terminal = try resolvedObjectID(.reference(id)) else { throw PDFStructureError.malformed(L10n.tr("stream indiretto assente")) }
        if let cached = decodedCache[terminal] { return cached }
        let object = try object(terminal); guard let stream = object.stream, let dictionary = object.value.dictionary else { throw PDFStructureError.malformed("stream") }
        let decoded = try Self.decode(stream, dictionary: streamDecodingDictionary(dictionary))
        // Alias identities share one decoded entry and one cache allocation.
        if decoded.count <= 64 * 1024 * 1024-decodedCacheSize { decodedCache[terminal] = decoded;decodedCacheSize += decoded.count }
        return decoded
    }
    func originalTextRuns() throws -> [PDFOriginalTextRun] {
        guard !encrypted else { throw PDFStructureError.encrypted }
        let standard = Set(["Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique", "Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic", "Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique"])
        var result: [PDFOriginalTextRun] = []
        for (pageIndex, page) in try pageIDs().enumerated() {
            let resources = try dictionary(inherited("Resources", pageID: page)), fonts = try dictionary(resources["Font"])
            var supported: [String: String] = [:]
            for (key, value) in fonts {
                let font = try dictionary(value), base = font["BaseFont"]?.name ?? ""
                let encoding = try resolve(font["Encoding"])
                if font["Subtype"]?.name == "Type1", standard.contains(base), font["ToUnicode"] == nil,
                   font["FontDescriptor"] == nil, encoding?.name == "WinAnsiEncoding" { supported[key] = base }
            }
            var activeFont: String?
            for streamID in try contentStreamIDs(on: page) {
                let data = try decodedStream(streamID); var lexer = PDFSyntaxLexer(data); var operands: [(PDFSyntaxValue, Range<Int>)] = []
                while true {
                    lexer.skip(); if lexer.offset >= lexer.bytes.count { break }
                    let start = lexer.offset, value = try lexer.value(), range = start..<lexer.offset
                    if case .keyword(let keyword) = value {
                        if keyword == "BI" { throw PDFStructureError.unsupported(L10n.tr("immagini inline nel content stream")) }
                        if keyword == "Tf", operands.count >= 2 { activeFont = operands[operands.count - 2].0.name }
                        if ["Tj", "'", "\""].contains(keyword), let last = operands.last,
                           let font = activeFont.flatMap({ supported[$0] }), let bytes = last.0.data,
                           let text = String(data: bytes, encoding: .windowsCP1252), !text.isEmpty {
                            result.append(PDFOriginalTextRun(pageIndex: pageIndex, streamID: streamID, range: last.1, bytes: bytes, text: text, font: font))
                        }
                        // TJ is intentionally not edited: kerning arrays have several strings
                        // and changing one run can change subsequent glyph positions.
                        operands.removeAll(keepingCapacity: true)
                    } else { operands.append((value, range)) }
                }
            }
        }
        return result
    }
    func replaceOriginalText(_ run: PDFOriginalTextRun, with text: String) throws -> Data {
        try requireWritable()
        guard try originalTextRuns().contains(where: { $0.id == run.id && $0.bytes == run.bytes }),
              let replacement = text.data(using: .windowsCP1252, allowLossyConversion: false),
              replacement.allSatisfy({ $0 >= 32 && $0 != 127 }) else { throw PDFStructureError.unsupported(L10n.tr("testo o font non rappresentabile in WinAnsi")) }
        let object = try object(run.streamID); var dictionary = object.value.dictionary ?? [:]
        var stream = try decodedStream(run.streamID)
        guard run.range.upperBound <= stream.count else { throw PDFStructureError.malformed(L10n.tr("testo modificato")) }
        stream.replaceSubrange(run.range, with: PDFSyntaxValue.bytes(replacement).encoded)
        dictionary.removeValue(forKey: "Filter"); dictionary.removeValue(forKey: "DecodeParms")
        replace(run.streamID, dictionary: dictionary, stream: stream); return try writeIncremental()
    }

    struct PageTag {
        let role: String
        let description: String
    }
    func tagPages(language: String, tags: [PageTag]) throws -> Data {
        try requireWritable(); let pages = try pageIDs(); let catalogID = try rootID; var root = try dictionary(.reference(catalogID))
        guard root["StructTreeRoot"] == nil else { throw PDFStructureError.unsupported(L10n.tr("esiste già una struttura di accessibilità; non viene sovrascritta")) }
        guard tags.count == pages.count, !language.isEmpty else { throw PDFStructureError.malformed(L10n.tr("descrizioni accessibili")) }
        let treeID = add(.dictionary([:]))
        var elements: [PDFSyntaxValue] = [], parentEntries: [PDFSyntaxValue] = []
        for (index, pageID) in pages.enumerated() {
            let tag = tags[index]
            guard ["Figure", "P", "H1", "H2"].contains(tag.role), !tag.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PDFStructureError.malformed(L10n.tr("ruolo o descrizione pagina \(index + 1)")) }
            let element = add(.dictionary(["Type": .name("StructElem"), "S": .name(tag.role), "P": .reference(treeID), "Pg": .reference(pageID),
                                           "K": .number("0"), "Alt": .string(tag.description), "Lang": .string(language)]))
            elements.append(.reference(element)); parentEntries += [.number(String(index)), .array([.reference(element)])]
            let begin = add(.dictionary([:]), stream: Data("/\(tag.role) << /MCID 0 >> BDC\n".utf8))
            let end = add(.dictionary([:]), stream: Data("\nEMC\n".utf8))
            var page = try dictionary(.reference(pageID))
            page["Contents"] = .array([.reference(begin)] + (try contentStreamIDs(on: pageID)).map { .reference($0) } + [.reference(end)])
            page["StructParents"] = .number(String(index)); page["Tabs"] = .name("S")
            replace(pageID, dictionary: page)
        }
        let parentTree = add(.dictionary(["Nums": .array(parentEntries)]))
        replace(treeID, dictionary: ["Type": .name("StructTreeRoot"), "K": .array(elements), "ParentTree": .reference(parentTree), "ParentTreeNextKey": .number(String(pages.count))])
        root["StructTreeRoot"] = .reference(treeID); root["MarkInfo"] = .dictionary(["Marked": .boolean(true)]); root["Lang"] = .string(language)
        replace(catalogID, dictionary: root); return try writeIncremental()
    }
}

extension PDFStructureDocument {
    func preflight() throws -> [PDFPreflightItem] {
        var result: [PDFPreflightItem] = []
        let pages = try pageIDs()
        result.append(.init(severity: "info", title: L10n.tr("Documento"), detail: L10n.tr("\(pages.count) pagine; \(source.count) byte; \(allObjectIDs().count) oggetti attivi nella xref.")))
        if encrypted {
            result.append(.init(severity: "avviso", title: L10n.tr("PDF cifrato"), detail: L10n.tr("I contenuti non vengono decifrati da questo lettore. Analisi di font, immagini e conformità non eseguibile.")))
            return result
        }
        var fontIDs = Set<PDFObjectID>()
        for (index, id) in pages.enumerated() {
            let media = try inherited("MediaBox", pageID: id)?.array?.compactMap(\.real) ?? []
            let crop = try inherited("CropBox", pageID: id)?.array?.compactMap(\.real) ?? media
            if media.count != 4 || crop.count != 4 || media[2] <= media[0] || media[3] <= media[1] || crop[2] <= crop[0] || crop[3] <= crop[1] {
                result.append(.init(severity: "errore", title: L10n.tr("Pagina \(index + 1)"), detail: L10n.tr("MediaBox/CropBox assente o dimensioni non valide.")))
            } else {
                result.append(.init(severity: "info", title: L10n.tr("Pagina \(index + 1)"), detail: String(format: L10n.string("MediaBox %.2f × %.2f pt; CropBox %.2f × %.2f pt."), media[2] - media[0], media[3] - media[1], crop[2] - crop[0], crop[3] - crop[1])))
            }
            let resources = try dictionary(inherited("Resources", pageID: id)), fonts = try dictionary(resources["Font"])
            for (_, fontValue) in fonts {
                if let fontID = fontValue.reference, !fontIDs.insert(fontID).inserted { continue }
                let font = try dictionary(fontValue), subtype = font["Subtype"]?.name ?? "?", base = font["BaseFont"]?.name ?? L10n.tr("senza nome")
                var descriptor = try dictionary(font["FontDescriptor"])
                if subtype == "Type0", let descendant = try resolve(font["DescendantFonts"])?.array?.first { descriptor = try dictionary(dictionary(descendant)["FontDescriptor"]) }
                let embedded = subtype == "Type3" || ["FontFile", "FontFile2", "FontFile3"].contains { descriptor[$0] != nil }
                result.append(.init(severity: embedded ? "info" : "avviso", title: L10n.tr("Font \(base)"), detail: L10n.tr("\(subtype); \(embedded ? L10n.tr("programma del font incorporato") : L10n.tr("programma del font non incorporato")). Controllo riferimenti del dizionario, non licenza o qualità dei glifi.")))
            }
            do {
                for placement in try imagePlacements(on: id) {
                    result.append(.init(severity: placement.dpi < 150 ? "avviso" : "info", title: L10n.tr("Immagine \(placement.id.number), pagina \(index + 1)"), detail: String(format: L10n.string("Risoluzione minima nella matrice di posizionamento: %.1f dpi."), placement.dpi)))
                }
            } catch {
                result.append(.init(severity: "avviso", title: L10n.tr("Analisi immagini pagina \(index + 1) incompleta"), detail: error.localizedDescription))
            }
        }
        let root = try dictionary(.reference(rootID))
        let intents = try resolve(root["OutputIntents"])?.array ?? []
        for intent in intents {
            let item = try dictionary(intent)
            result.append(.init(severity: item["DestOutputProfile"] != nil ? "info" : "avviso", title: L10n.tr("Output intent \(item["S"]?.name ?? "?")"), detail: L10n.tr("Profilo ICC \(item["DestOutputProfile"] != nil ? "referenziato" : "assente"); \(item["OutputConditionIdentifier"]?.text ?? L10n.tr("condizione non specificata")).")))
        }
        if intents.isEmpty { result.append(.init(severity: "avviso", title: L10n.tr("Output intent"), detail: L10n.tr("Nessun intento di output ICC dichiarato."))) }
        if root["StructTreeRoot"] == nil {
            result.append(.init(severity: "avviso", title: L10n.tr("Accessibilità"), detail: L10n.tr("StructTreeRoot assente. Non è un documento PDF con struttura logica dichiarata.")))
        } else {
            result.append(.init(severity: "info", title: L10n.tr("Accessibilità"), detail: L10n.tr("StructTreeRoot presente; lingua \(root["Lang"]?.text ?? L10n.tr("non dichiarata")). La presenza dei tag non certifica PDF/UA o la correttezza dell’ordine di lettura.")))
        }
        let names = try dictionary(root["Names"])
        if names["JavaScript"] != nil || root["OpenAction"] != nil || root["AA"] != nil {
            result.append(.init(severity: "avviso", title: L10n.tr("Azioni documento"), detail: L10n.tr("Il catalogo contiene azioni o script. Questo controllo non esegue codice e non è una bonifica completa.")))
        }
        result += try archivalChecks()
        return result
    }

    func imagePlacements(on pageID: PDFObjectID) throws -> [(id: PDFObjectID, dpi: Double)] {
        var output: [(id: PDFObjectID, dpi: Double)] = []
        func scan(_ ids: [PDFObjectID], resources: [String: PDFSyntaxValue], matrix: CGAffineTransform, visited: Set<PDFObjectID>) throws {
            var current = matrix, stack: [CGAffineTransform] = [], operands: [PDFSyntaxValue] = []
            for stream in ids {
                var lexer = PDFSyntaxLexer(try decodedStream(stream))
                while true {
                    lexer.skip(); if lexer.offset >= lexer.bytes.count { break }
                    let value = try lexer.value()
                    guard case .keyword(let operation) = value else { operands.append(value); continue }
                    switch operation {
                    case "BI": throw PDFStructureError.unsupported(L10n.tr("immagini inline"))
                    case "q": stack.append(current)
                    case "Q": guard let restored = stack.popLast() else { throw PDFStructureError.malformed(L10n.tr("stack grafico")) }; current = restored
                    case "cm":
                        let values = operands.suffix(6).compactMap(\.real)
                        if values.count == 6 { current = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5]).concatenating(current) }
                    case "Do":
                        if let name = operands.last?.name, let id = try dictionary(resources["XObject"])[name]?.reference {
                            let object = try object(id), dictionary = object.value.dictionary ?? [:]
                            if dictionary["Subtype"]?.name == "Image" {
                                let width = dictionary["Width"]?.real ?? 0, height = dictionary["Height"]?.real ?? 0
                                let pointsX = hypot(current.a, current.b), pointsY = hypot(current.c, current.d)
                                if pointsX > 0, pointsY > 0 { output.append((id, min(width * 72 / pointsX, height * 72 / pointsY))) }
                            } else if dictionary["Subtype"]?.name == "Form" {
                                guard !visited.contains(id), visited.count < 100 else { throw PDFStructureError.malformed(L10n.tr("XObject Form circolare")) }
                                let numbers = try resolve(dictionary["Matrix"])?.array?.compactMap(\.real) ?? [1, 0, 0, 1, 0, 0]
                                guard numbers.count == 6 else { throw PDFStructureError.malformed(L10n.tr("matrice Form")) }
                                let formMatrix = CGAffineTransform(a: numbers[0], b: numbers[1], c: numbers[2], d: numbers[3], tx: numbers[4], ty: numbers[5])
                                let nested = dictionary["Resources"] == nil ? resources : try self.dictionary(dictionary["Resources"])
                                try scan([id], resources: nested, matrix: formMatrix.concatenating(current), visited: visited.union([id]))
                            }
                        }
                    default: break
                    }
                    operands.removeAll(keepingCapacity: true)
                }
            }
        }
        try scan(contentStreamIDs(on: pageID), resources: dictionary(inherited("Resources", pageID: pageID)), matrix: .identity, visited: [])
        return output
    }

    func archivalChecks() throws -> [PDFPreflightItem] {
        let root = try dictionary(.reference(rootID))
        var result: [PDFPreflightItem] = []
        if let metadata = root["Metadata"]?.reference {
            let xmp = String(data: try decodedStream(metadata), encoding: .utf8) ?? ""
            if xmp.contains("pdfaid:") || xmp.contains("http://www.aiim.org/pdfa/ns/id/") {
                result.append(.init(severity: "info", title: L10n.tr("Dichiarazione PDF/A in XMP"), detail: L10n.tr("Identificatore PDF/A presente nei metadati. Questo non dimostra che tutti gli oggetti rispettino ISO 19005.")))
            }
        }
        result.append(.init(severity: "avviso", title: L10n.tr("Limite della validazione"), detail: L10n.tr("Controlli strutturali locali su cifratura, font, pagine, immagini, tag, metadati e intenti ICC. Non è un validatore completo ISO PDF/A, PDF/X o PDF/UA; non viene emesso un certificato di conformità.")))
        return result
    }
}

@MainActor
enum PDFNativeProfileConverter {
    static func redraw(_ source: PDFDocument, archival: Bool = false, outputProfile: CGColorSpace? = nil, condition: String = "Profilo locale") throws -> Data {
        guard !source.isLocked, !source.isEncrypted, source.allowsPrinting, source.allowsCopying else { throw PDFStructureError.encrypted }
        let output = NSMutableData(); guard let consumer = CGDataConsumer(data: output as CFMutableData) else { throw PDFStructureError.limit }
        var options: [String: Any] = [kCGPDFContextCreator as String: "CartaPDF"]
        if archival { options[kCGPDFContextCreatePDFA as String] = true }
        if let outputProfile {
            options[kCGPDFContextOutputIntent as String] = [
                kCGPDFXOutputIntentSubtype as String: "GTS_PDFX", kCGPDFXOutputConditionIdentifier as String: condition,
                kCGPDFXInfo as String: L10n.tr("Preparazione ICC locale; conformità PDF/X non certificata"),
                kCGPDFXDestinationOutputProfile as String: outputProfile
            ]
        }
        guard let context = CGContext(consumer: consumer, mediaBox: nil, options as CFDictionary) else { throw PDFStructureError.malformed(L10n.tr("creazione contesto PDF")) }
        for index in 0..<source.pageCount {
            guard let page = source.page(at: index) else { throw PDFStructureError.malformed("pagina") }
            let crop = page.bounds(for: .cropBox), transform = page.transform(for: .cropBox), display = crop.applying(transform)
            guard display.width > 0, display.height > 0 else { throw PDFStructureError.malformed(L10n.tr("dimensioni pagina")) }
            var box = CGRect(origin: .zero, size: display.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)] as CFDictionary)
            context.saveGState(); context.translateBy(x: -display.minX, y: -display.minY)
            page.draw(with: .cropBox, to: context)
            context.restoreGState(); context.endPDFPage()
        }
        context.closePDF(); let data = output as Data
        guard PDFDocument(data: data)?.pageCount == source.pageCount else { throw PDFStructureError.malformed(L10n.tr("conversione PDF")) }
        return data
    }
    static func portfolioIndex(files: [(name: String, data: Data)]) throws -> Data {
        let output = NSMutableData(); guard let consumer = CGDataConsumer(data: output as CFMutableData) else { throw PDFStructureError.limit }
        var box = CGRect(x: 0, y: 0, width: 595.276, height: 841.89)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw PDFStructureError.limit }
        let count = max(1, Int(ceil(Double(files.count) / 24)))
        for page in 0..<count {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            ("Raccolta documenti" as NSString).draw(at: CGPoint(x: 42, y: 766), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 24), .foregroundColor: NSColor.black])
            ("Indice degli allegati incorporati · \(files.count) file" as NSString).draw(at: CGPoint(x: 42, y: 737), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.darkGray])
            let slice = files.dropFirst(page * 24).prefix(24)
            for (offset, file) in slice.enumerated() {
                let line = "\(page * 24 + offset + 1). \(file.name) — \(ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file))"
                (line as NSString).draw(in: CGRect(x: 42, y: 684 - offset * 25, width: 512, height: 22), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
            }
            NSGraphicsContext.restoreGraphicsState(); context.endPDFPage()
        }
        context.closePDF()
        return try PDFStructureDocument(data: output as Data).addingAttachments(files, portfolio: true)
    }
}

struct PDFLocalIdentity: Identifiable {
    let id: String
    let name: String
    let identity: SecIdentity
}
struct PDFSignatureVerification: Identifiable {
    let id: PDFObjectID
    let signer: String
    let integrityValid: Bool
    let locallyTrusted: Bool
    let signedRevisionBytes: Int
    let bytesAfterSignature: Int
    let digest: String
    let detail: String
}

@MainActor
enum PDFLocalCertificateEngine {
    static func identities() throws -> [PDFLocalIdentity] {
        var output: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassIdentity, kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitAll] as CFDictionary, &output)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw PDFStructureError.security(status) }
        let identities = (output as? [SecIdentity]) ?? []
        return identities.compactMap { identity in
            var certificate: SecCertificate?; guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
            let bytes = SecCertificateCopyData(certificate) as Data
            let name = SecCertificateCopySubjectSummary(certificate) as String? ?? L10n.tr("Certificato senza nome")
            return PDFLocalIdentity(id: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), name: name, identity: identity)
        }
    }

    static func sign(_ source: Data, identity: SecIdentity, reason: String) throws -> Data {
        let document = try PDFStructureDocument(data: source); try document.requireWritable()
        let rootID = try document.rootID; var root = try document.dictionary(.reference(rootID))
        let pages = try document.pageIDs(); guard let firstPage = pages.first else { throw PDFStructureError.malformed("pagina della firma") }
        let placeholderSize = 32_768
        let zero = String(repeating: "0", count: 20)
        let byteRange = PDFSyntaxValue.array(Array(repeating: .number(zero), count: 4))
        var certificate: SecCertificate?; try check(SecIdentityCopyCertificate(identity, &certificate))
        let signer = certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "Firmatario locale"
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmmss"
        let sig = document.add(.dictionary(["Type": .name("Sig"), "Filter": .name("Adobe.PPKLite"), "SubFilter": .name("adbe.pkcs7.detached"),
            "ByteRange": byteRange, "Contents": .bytes(Data(repeating: 0, count: placeholderSize)), "M": .string("D:" + formatter.string(from: Date()) + "Z"),
            "Name": .string(signer), "Reason": .string(reason)]))
        let field = document.add(.dictionary(["Type": .name("Annot"), "Subtype": .name("Widget"), "FT": .name("Sig"),
            "T": .string("Firma CartaPDF " + UUID().uuidString), "V": .reference(sig), "P": .reference(firstPage),
            "Rect": .array([.number("0"), .number("0"), .number("0"), .number("0")]), "F": .number("132")]))
        var form = try document.dictionary(root["AcroForm"])
        var fields = try document.resolve(form["Fields"])?.array ?? []; fields.append(.reference(field))
        form["Fields"] = .array(fields); form["SigFlags"] = .number("3"); root["AcroForm"] = .dictionary(form)
        var page = try document.dictionary(.reference(firstPage)); var annotations = try document.resolve(page["Annots"])?.array ?? []
        annotations.append(.reference(field)); page["Annots"] = .array(annotations)
        document.replace(firstPage, dictionary: page); document.replace(rootID, dictionary: root)
        var result = try document.writeIncremental()
        let contentsMarker = PDFSyntaxValue.bytes(Data(repeating: 0, count: placeholderSize)).encoded
        guard let contents = result.range(of: contentsMarker, options: .backwards),
              let range = result.range(of: byteRange.encoded, options: .backwards) else { throw PDFStructureError.malformed(L10n.tr("segnaposto firma")) }
        let values = [0, contents.lowerBound, contents.upperBound, result.count - contents.upperBound]
        let actualRange = PDFSyntaxValue.array(values.map { .number(String(format: "%020lld", Int64($0))) }).encoded
        guard actualRange.count == range.count else { throw PDFStructureError.limit }
        result.replaceSubrange(range, with: actualRange)
        let signed = result.subdata(in: 0..<contents.lowerBound) + result.subdata(in: contents.upperBound..<result.count)
        let cms = try detachedCMS(signed, identity: identity)
        guard cms.count <= placeholderSize else { throw PDFStructureError.limit }
        let hex = cms.map { String(format: "%02X", $0) }.joined() + String(repeating: "0", count: (placeholderSize - cms.count) * 2)
        result.replaceSubrange((contents.lowerBound + 1)..<(contents.upperBound - 1), with: Data(hex.utf8))
        let verified = try verify(result)
        guard verified.contains(where: { $0.id == sig && $0.integrityValid && $0.bytesAfterSignature == 0 }) else {
            let details = verified.map { "oggetto \($0.id.number): \($0.detail)" }.joined(separator: "; ")
            throw PDFStructureError.malformed(L10n.tr("verifica immediata della firma non riuscita. ") + (details.isEmpty ? L10n.tr("Nessuna firma rilevata.") : details))
        }
        return result
    }

    static func detachedCMS(_ content: Data, identity: SecIdentity) throws -> Data {
        guard !content.isEmpty else { throw PDFStructureError.malformed(L10n.tr("contenuto CMS vuoto")) }
        var key: SecKey?; try check(SecIdentityCopyPrivateKey(identity, &key))
        guard let key else { throw PDFStructureError.security(errSecParam) }
        let attributes = SecKeyCopyAttributes(key) as? [String: Any] ?? [:]
        if attributes[kSecAttrKeyType as String] as? String == kSecAttrKeyTypeECSECPrimeRandom as String {
            // The legacy encoder inconsistently accepts in-memory EC identities.
            // Use Security's native ECDSA implementation with a deterministic
            // CMS container; Apple's separate decoder verifies the result.
            return try securityDetachedCMS(content, identity: identity)
        }
        do { return try nativeDetachedCMS(content, identity: identity) }
        catch PDFStructureError.security(let status) where status == errSecParam || status == errSecUnimplemented {
            // The legacy CMS encoder rejects some in-memory EC identities.
            // Build standard detached SignedData using Security's actual private
            // key signature, then verify through Apple's CMS decoder as usual.
            return try securityDetachedCMS(content, identity: identity)
        }
    }
    private static func nativeDetachedCMS(_ content: Data, identity: SecIdentity) throws -> Data {
        var output: CMSEncoder?; try check(CMSEncoderCreate(&output)); guard let encoder = output else { throw PDFStructureError.security(errSecInternalComponent) }
        try check(CMSEncoderSetSignerAlgorithm(encoder, kCMSEncoderDigestAlgorithmSHA256))
        // Signer-only prevents chain discovery/network access while signing.
        try check(CMSEncoderSetCertificateChainMode(encoder, .signerOnly))
        try check(CMSEncoderSetHasDetachedContent(encoder, true))
        try check(CMSEncoderAddSigners(encoder, identity))
        try content.withUnsafeBytes { bytes in try check(CMSEncoderUpdateContent(encoder, bytes.baseAddress!, bytes.count)) }
        var encoded: CFData?; try check(CMSEncoderCopyEncodedContent(encoder, &encoded))
        guard let encoded else { throw PDFStructureError.security(errSecInternalComponent) }; return encoded as Data
    }

    private static func securityDetachedCMS(_ content: Data, identity: SecIdentity) throws -> Data {
        var certificate: SecCertificate?, key: SecKey?
        try check(SecIdentityCopyCertificate(identity, &certificate)); try check(SecIdentityCopyPrivateKey(identity, &key))
        guard let certificate, let key else { throw PDFStructureError.security(errSecParam) }
        let certificateDER = SecCertificateCopyData(certificate) as Data
        let certificateParts = try PDFDER.children(certificateDER)
        guard let tbs = certificateParts.first else { throw PDFStructureError.malformed(L10n.tr("certificato ASN.1")) }
        var parts = try PDFDER.children(tbs)
        if parts.first?.first == 0xA0 { parts.removeFirst() }
        guard parts.count >= 3 else { throw PDFStructureError.malformed(L10n.tr("issuer/serial certificato")) }
        let serial = parts[0], issuer = parts[2]
        let attributes = SecKeyCopyAttributes(key) as? [String: Any] ?? [:]
        let type = attributes[kSecAttrKeyType as String] as? String
        let algorithm: SecKeyAlgorithm
        let signatureAlgorithm: Data
        if type == kSecAttrKeyTypeRSA as String {
            algorithm = .rsaSignatureMessagePKCS1v15SHA256
            signatureAlgorithm = PDFDER.sequence(Data([6,9,42,134,72,134,247,13,1,1,1,5,0]))
        } else if type == kSecAttrKeyTypeECSECPrimeRandom as String {
            algorithm = .ecdsaSignatureMessageX962SHA256
            signatureAlgorithm = PDFDER.sequence(Data([6,8,42,134,72,206,61,4,3,2]))
        } else { throw PDFStructureError.unsupported(L10n.tr("algoritmo della chiave privata")) }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, algorithm, content as CFData, &error) else {
            if let underlying = error?.takeRetainedValue() { throw underlying }
            throw PDFStructureError.security(errSecInternalComponent)
        }
        let sha256 = PDFDER.sequence(Data([6,9,96,134,72,1,101,3,4,2,1,5,0]))
        let issuerAndSerial = PDFDER.sequence(issuer + serial)
        let signer = PDFDER.sequence(Data([2,1,1]) + issuerAndSerial + sha256 + signatureAlgorithm + PDFDER.tlv(4, signature as Data))
        let dataOID = Data([6,9,42,134,72,134,247,13,1,7,1])
        let signed = PDFDER.sequence(Data([2,1,1]) + PDFDER.tlv(49, sha256) + PDFDER.sequence(dataOID)
                                    + PDFDER.tlv(0xA0, certificateDER) + PDFDER.tlv(49, signer))
        return PDFDER.sequence(Data([6,9,42,134,72,134,247,13,1,7,2]) + PDFDER.tlv(0xA0, signed))
    }

    static func verify(_ data: Data) throws -> [PDFSignatureVerification] {
        let document = try PDFStructureDocument(data: data)
        guard !document.encrypted else { throw PDFStructureError.encrypted }
        var result: [PDFSignatureVerification] = []
        for id in document.allObjectIDs() {
            let object = try document.object(id)
            guard let dictionary = object.value.dictionary, dictionary["ByteRange"] != nil,
                  let paddedCMS = dictionary["Contents"]?.data else { continue }
            let subFilter = dictionary["SubFilter"]?.name ?? ""
            guard ["adbe.pkcs7.detached", "ETSI.CAdES.detached"].contains(subFilter) else {
                result.append(.init(id: id, signer: dictionary["Name"]?.text ?? "?", integrityValid: false, locallyTrusted: false,
                    signedRevisionBytes: 0, bytesAfterSignature: data.count, digest: "", detail: L10n.tr("SubFilter \(subFilter) non verificabile da questo motore."))); continue
            }
            let ranges = dictionary["ByteRange"]?.array?.compactMap(\.int) ?? []
            guard ranges.count == 4, ranges[0] == 0, ranges[1] > 0, ranges[2] > ranges[1], ranges[3] >= 0,
                  ranges[2] <= data.count, ranges[3] <= data.count - ranges[2],
                  let contentsRange = object.memberRanges["Contents"], contentsRange.lowerBound == ranges[1], contentsRange.upperBound == ranges[2],
                  data[ranges[1]] == 60, data[ranges[2] - 1] == 62 else {
                result.append(.init(id: id, signer: dictionary["Name"]?.text ?? "?", integrityValid: false, locallyTrusted: false,
                    signedRevisionBytes: 0, bytesAfterSignature: data.count, digest: "", detail: L10n.tr("ByteRange non canonico o area esclusa diversa dal solo Contents."))); continue
            }
            let signed = data.subdata(in: 0..<ranges[1]) + data.subdata(in: ranges[2]..<(ranges[2] + ranges[3]))
            let digest = SHA256.hash(data: signed).map { String(format: "%02x", $0) }.joined()
            do {
                let cms = try derEnvelope(paddedCMS)
                var decoder: CMSDecoder?; try check(CMSDecoderCreate(&decoder)); guard let decoder else { throw PDFStructureError.security(errSecInternalComponent) }
                try cms.withUnsafeBytes { try check(CMSDecoderUpdateMessage(decoder, $0.baseAddress!, $0.count)) }
                try check(CMSDecoderFinalizeMessage(decoder)); try check(CMSDecoderSetDetachedContent(decoder, signed as CFData))
                var count = 0; try check(CMSDecoderGetNumSigners(decoder, &count))
                guard count > 0 else { throw PDFStructureError.malformed(L10n.tr("CMS privo di firmatari")) }
                for signerIndex in 0..<count {
                    var status = CMSSignerStatus.unsigned; var trust: SecTrust?; var trustStatus: OSStatus = 0
                    let policy = SecPolicyCreateBasicX509()
                    try check(CMSDecoderCopySignerStatus(decoder, signerIndex, policy, false, &status, &trust, &trustStatus))
                    var trusted = false
                    if let trust {
                        try check(SecTrustSetNetworkFetchAllowed(trust, false))
                        var error: CFError?; trusted = SecTrustEvaluateWithError(trust, &error)
                    }
                    var certificate: SecCertificate?; _ = CMSDecoderCopySignerCert(decoder, signerIndex, &certificate)
                    let signer = certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? dictionary["Name"]?.text ?? "Firmatario"
                    let integrity = status == .valid
                    result.append(.init(id: id, signer: signer, integrityValid: integrity, locallyTrusted: trusted,
                        signedRevisionBytes: ranges[2] + ranges[3], bytesAfterSignature: data.count - ranges[2] - ranges[3], digest: digest,
                        detail: L10n.tr("Integrità CMS \(integrity ? L10n.tr("verificata") : L10n.tr("NON valida")) (stato decoder \(status.rawValue)); catena/date \(trusted ? L10n.tr("accettate dal Portachiavi locale") : L10n.tr("non convalidate localmente")). Rete disabilitata: nessuna verifica aggiornata di revoca OCSP/CRL, timestamp qualificato o conformità PAdES.")))
                }
            } catch {
                result.append(.init(id: id, signer: dictionary["Name"]?.text ?? "?", integrityValid: false, locallyTrusted: false,
                    signedRevisionBytes: ranges[2] + ranges[3], bytesAfterSignature: data.count - ranges[2] - ranges[3], digest: digest, detail: error.localizedDescription))
            }
        }
        return result
    }

    static func derEnvelope(_ data: Data) throws -> Data {
        let bytes = Array(data); guard bytes.count >= 2, bytes[0] == 48 else { throw PDFStructureError.malformed(L10n.tr("CMS ASN.1")) }
        let initial = Int(bytes[1]); var length = 0, start = 2
        if initial < 128 { length = initial }
        else {
            let count = initial & 127
            guard count > 0, count <= 4, bytes.count >= 2 + count else { throw PDFStructureError.unsupported(L10n.tr("CMS BER a lunghezza indefinita")) }
            start += count
            for byte in bytes[2..<start] { length = length * 256 + Int(byte) }
        }
        guard length <= bytes.count - start else { throw PDFStructureError.malformed(L10n.tr("CMS troncato")) }
        return Data(bytes.prefix(start + length))
    }
    private static func check(_ status: OSStatus) throws { guard status == errSecSuccess else { throw PDFStructureError.security(status) } }
}

private enum PDFDER {
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var length = Data()
        if content.count < 128 { length.append(UInt8(content.count)) }
        else {
            var count = content.count, bytes: [UInt8] = []
            while count > 0 { bytes.insert(UInt8(count & 255), at: 0); count >>= 8 }
            length.append(0x80 | UInt8(bytes.count)); length += Data(bytes)
        }
        return Data([tag]) + length + content
    }
    static func sequence(_ content: Data) -> Data { tlv(48, content) }
    static func children(_ data: Data) throws -> [Data] {
        let bytes = Array(data)
        func node(_ start: Int) throws -> (Range<Int>, Range<Int>) {
            guard start >= 0, start + 2 <= bytes.count else { throw PDFStructureError.malformed(L10n.tr("ASN.1 troncato")) }
            let first = Int(bytes[start + 1]); var cursor = start + 2, length = first
            if first >= 128 {
                let count = first & 127; guard count > 0, count <= 4, cursor + count <= bytes.count else { throw PDFStructureError.unsupported(L10n.tr("ASN.1 BER")) }
                length = 0; for byte in bytes[cursor..<(cursor + count)] { length = length * 256 + Int(byte) }; cursor += count
            }
            guard length <= bytes.count - cursor else { throw PDFStructureError.malformed(L10n.tr("lunghezza ASN.1")) }
            return (start..<(cursor + length), cursor..<(cursor + length))
        }
        let (_, content) = try node(0); var cursor = content.lowerBound, result: [Data] = []
        while cursor < content.upperBound {
            let (total, _) = try node(cursor); guard total.upperBound <= content.upperBound else { throw PDFStructureError.malformed(L10n.tr("figlio ASN.1")) }
            result.append(Data(bytes[total])); cursor = total.upperBound
        }
        return result
    }
}
