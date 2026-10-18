import Foundation

/// Original Swift reader of the common U3D envelope, from ECMA-363 (3rd
/// edition) §§5.2,8.10,9.1–9.4,10.4.2. No geometry codec or script executes.
/// A successful envelope check does not prove the encoded 3D model correct.
enum PDFArchiveEngineeringChecks {
    struct Audit {
        let structure: PDFArchiveRuleEvaluation
        let payload: PDFArchiveRuleEvaluation
    }
    private struct Block {
        let type: UInt32, start: Int, end: Int
        let data: Range<Int>, metadata: Range<Int>
    }
    private struct Invalid: Error { let reason: String }
    private static let header: UInt32 = 0x00443355
    private static let priority: UInt32 = 0xffffff15
    private static let baseTypes: Set<UInt32> = [
        header, 0xffffff12, 0xffffff14, priority, 0xffffff16,
        0xffffff21, 0xffffff22, 0xffffff23, 0xffffff24,
        0xffffff31, 0xffffff36, 0xffffff37, 0xffffff3b, 0xffffff3c,
        0xffffff3e, 0xffffff3f, 0xffffff41, 0xffffff42, 0xffffff43,
        0xffffff44, 0xffffff45, 0xffffff46, 0xffffff51, 0xffffff52,
        0xffffff53, 0xffffff54, 0xffffff55, 0xffffff56, 0xffffff5c
    ]
    private static let continuations: Set<UInt32> = [priority, 0xffffff3b, 0xffffff3c, 0xffffff3e, 0xffffff3f, 0xffffff5c]

    static func audit(_ data: Data, subtype: String) -> Audit {
        guard subtype == "U3D" else {
            return .init(structure: .unknown("PRC: struttura ISO14739 non ancora provata da un parser normativo locale."),
                         payload: .unknown("Geometria PRC non validata integralmente."))
        }
        guard data.count <= 64 * 1024 * 1024 else {
            return .init(structure: .unknown("U3D oltre il limite locale di 64MiB; visita non eseguita."),
                         payload: .unknown("Payload U3D non visitato."))
        }
        let bytes = Array(data)
        var issues: [String] = [], gaps: [String] = [], blocks: [Block] = []
        do {
            var offset = 0
            while offset < bytes.count {
                guard blocks.count < 100_000 else { throw PDFStructureError.limit }
                let block = try readBlock(bytes, start: offset, end: bytes.count)
                blocks.append(block); offset = block.end
            }
        } catch let error as Invalid { issues.append(error.reason) }
        catch { gaps.append("Limite della visita dei blocchi U3D") }
        guard let first = blocks.first, first.type == header else {
            return .init(structure: .check(false, "U3D: File Header Block iniziale assente o troncato.", locations: issues),
                         payload: .unknown("Payload U3D non interpretato."))
        }
        var declaration = 0, profile: UInt32 = 0
        do {
            guard first.data.count >= 4 else { throw Invalid(reason: "Header U3D senza versione") }
            let major = Int16(bitPattern: try u16(bytes, first.data.lowerBound, first.data.upperBound))
            if major > 0 {
                return .init(structure: issues.isEmpty ? .unknown("Versione maggiore U3D \(major) non supportata; nessuna semantica futura dedotta.") : .check(false, "Framing U3D non valido.", locations: issues),
                             payload: .unknown("Versione U3D non interpretata."))
            }
            guard first.data.count >= 24 else { throw Invalid(reason: "File Header U3D troncato") }
            profile = try u32(bytes, first.data.lowerBound + 4, first.data.upperBound)
            guard profile & ~UInt32(14) == 0 else { throw Invalid(reason: "Profile Identifier U3D contiene bit riservati") }
            let headerLength = profile & 8 == 0 ? 24 : 32
            guard first.data.count == headerLength else { throw Invalid(reason: "Header U3D: presenza/dimensione Units Scaling Factor incoerente") }
            declaration = Int(try u32(bytes, first.data.lowerBound + 8, first.data.upperBound))
            let fileSize = try u64(bytes, first.data.lowerBound + 12, first.data.upperBound)
            guard fileSize == UInt64(bytes.count) else { throw Invalid(reason: "File Size U3D diverso dai byte disponibili") }
            guard declaration >= first.end, declaration <= bytes.count, declaration % 4 == 0,
                  declaration == bytes.count || blocks.contains(where: { $0.start == declaration }) else {
                throw Invalid(reason: "Declaration Size U3D non coincide con un confine di blocco")
            }
            guard try u32(bytes, first.data.lowerBound + 20, first.data.upperBound) == 106 else {
                throw Invalid(reason: "Character Encoding U3D diverso da UTF-8/MIB106")
            }
        } catch let error as Invalid { issues.append(error.reason) }
        catch { gaps.append("Header U3D non completamente interpretato") }

        var previousPriority: UInt32 = 0, opaque = 0
        for (index, block) in blocks.enumerated() {
            do {
                try metadata(bytes, range: block.metadata)
                if index > 0, block.type == header { throw Invalid(reason: "File Header U3D ripetuto al byte \(block.start)") }
                if block.type == 0xffffff16, profile & 2 == 0 { throw Invalid(reason: "New Object Type senza profilo Extensible") }
                if !baseTypes.contains(block.type) {
                    if profile & 2 != 0, (0x100...0x00ffffff).contains(block.type) {
                        gaps.append("Tipo esteso U3D non risolto al byte \(block.start)")
                    } else { throw Invalid(reason: "Block Type U3D non definito: \(String(block.type, radix: 16))") }
                }
                if continuations.contains(block.type), block.start < declaration {
                    throw Invalid(reason: "Blocco continuation nella sezione declaration al byte \(block.start)")
                }
                if block.type == priority {
                    guard block.data.count == 4 else { throw Invalid(reason: "Priority Update U3D non contiene un U32") }
                    let value = try u32(bytes, block.data.lowerBound, block.data.upperBound)
                    guard value > 0, value <= 0x7fffffff, value >= previousPriority else {
                        throw Invalid(reason: "Priority Update U3D nullo, decrescente o fuori intervallo")
                    }
                    previousPriority = value
                } else if index > 0 { opaque += 1 }
            } catch let error as Invalid { issues.append(error.reason) }
            catch { gaps.append("Metadati U3D oltre i limiti locali") }
        }
        let detail = "U3D: \(blocks.count) blocchi top-level; header, confini, padding, metadati e Priority Update secondo ECMA363 ed3. Geometria e blocchi annidati sono verifiche separate."
        let structure: PDFArchiveRuleEvaluation
        if !issues.isEmpty { structure = .check(false, detail, locations: Array(issues.prefix(64))) }
        else if !gaps.isEmpty { structure = .unknown(detail + " " + Array(Set(gaps)).sorted().joined(separator: "; ")) }
        else { structure = .check(true, detail) }
        return .init(structure: structure, payload: opaque == 0 && issues.isEmpty && gaps.isEmpty
                     ? .absent("Nessun blocco geometrico: solo File Header ed eventuali Priority Update.")
                     : .unknown("Payload geometrico, blocchi annidati, riferimenti esterni e semantica delle estensioni U3D non validati integralmente."))
    }

    private static func readBlock(_ bytes: [UInt8], start: Int, end: Int) throws -> Block {
        guard start % 4 == 0, end - start >= 12 else { throw Invalid(reason: "Header di blocco U3D troncato/non allineato al byte \(start)") }
        let type = try u32(bytes, start, end)
        let dataSize = Int(try u32(bytes, start + 4, end)), metaSize = Int(try u32(bytes, start + 8, end))
        let begin = start + 12
        guard dataSize <= end - begin else { throw Invalid(reason: "Data Size U3D eccede il flusso al byte \(start)") }
        let dataEnd = begin + dataSize, metaBegin = (dataEnd + 3) & ~3
        guard metaBegin <= end, metaSize <= end - metaBegin else { throw Invalid(reason: "Meta Data Size/padding U3D eccede il flusso al byte \(start)") }
        let metaEnd = metaBegin + metaSize, blockEnd = (metaEnd + 3) & ~3
        guard blockEnd <= end else { throw Invalid(reason: "Meta Data Padding U3D troncato al byte \(start)") }
        guard bytes[dataEnd..<metaBegin].allSatisfy({ $0 == 0 }), bytes[metaEnd..<blockEnd].allSatisfy({ $0 == 0 }) else {
            throw Invalid(reason: "Padding U3D non nullo al byte \(start)")
        }
        return .init(type: type, start: start, end: blockEnd, data: begin..<dataEnd, metadata: metaBegin..<metaEnd)
    }

    private static func metadata(_ bytes: [UInt8], range: Range<Int>) throws {
        guard !range.isEmpty else { return }
        var offset = range.lowerBound
        let count = Int(try u32(bytes, offset, range.upperBound)); offset += 4
        guard count <= (range.count - 4) / 8 else { throw Invalid(reason: "Conteggio coppie metadati U3D impossibile") }
        for _ in 0..<count {
            let attributes = try u32(bytes, offset, range.upperBound); offset += 4
            guard attributes & ~UInt32(0x773) == 0 else { throw Invalid(reason: "Attributi metadati U3D riservati") }
            try string(bytes, offset: &offset, end: range.upperBound)
            if attributes & 1 == 0 { try string(bytes, offset: &offset, end: range.upperBound) }
            else {
                let length = Int(try u32(bytes, offset, range.upperBound)); offset += 4
                guard length <= range.upperBound - offset else { throw Invalid(reason: "Valore binario metadati U3D troncato") }
                offset += length
            }
        }
        guard offset == range.upperBound else { throw Invalid(reason: "Byte residui nei metadati U3D") }
    }
    private static func string(_ bytes: [UInt8], offset: inout Int, end: Int) throws {
        let length = Int(try u16(bytes, offset, end)); offset += 2
        guard length <= end - offset else { throw Invalid(reason: "Stringa U3D troncata") }
        guard String(bytes: bytes[offset..<(offset + length)], encoding: .utf8) != nil else { throw Invalid(reason: "Stringa metadati U3D non UTF-8") }
        offset += length
    }
    private static func u16(_ bytes: [UInt8], _ offset: Int, _ end: Int) throws -> UInt16 {
        guard offset >= 0, offset <= end, end - offset >= 2 else { throw Invalid(reason: "U16 U3D troncato") }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
    private static func u32(_ bytes: [UInt8], _ offset: Int, _ end: Int) throws -> UInt32 {
        guard offset >= 0, offset <= end, end - offset >= 4 else { throw Invalid(reason: "U32 U3D troncato") }
        return (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }
    private static func u64(_ bytes: [UInt8], _ offset: Int, _ end: Int) throws -> UInt64 {
        guard offset >= 0, offset <= end, end - offset >= 8 else { throw Invalid(reason: "U64 U3D troncato") }
        return (0..<8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
    }
}
