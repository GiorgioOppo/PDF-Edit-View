import Foundation
import CoreGraphics
import CryptoKit

/// Binary facts from an ICC profile. A native ColorSpace accepting bytes is
/// deliberately not used as proof of the whole ICC conformance specification.
struct PDFArchiveICCProfile {
    static func channels(_ signature:String) -> Int? {
        if let count = ["GRAY":1,"RGB ":3,"CMYK":4,"CMY ":3,"Lab ":3,"XYZ ":3,
                        "Luv ":3,"YCbr":3,"Yxy ":3,"HSV ":3,"HLS ":3][signature] { return count }
        let bytes = Array(signature.utf8)
        guard bytes.count == 4,Array(bytes[1...]) == Array("CLR".utf8) else { return nil }
        if (50...57).contains(bytes[0]) { return Int(bytes[0]-48) }
        if (65...70).contains(bytes[0]) { return Int(bytes[0]-65)+10 }
        return nil
    }
    let bytes: Data
    let deviceClass: String
    let colorSpace: String
    let majorVersion: Int
    let components: Int?
    let structuralIssues: [String]
    /// ICC.1 §7.2.18 profile fingerprint, independent of embedded flags,
    /// rendering intent and the optional previously calculated Profile ID.
    var fingerprint: Data {
        var normalized = bytes
        for range in [44..<48,64..<68,84..<100] { normalized.replaceSubrange(range,with:repeatElement(UInt8(0),count:range.count)) }
        return Data(Insecure.MD5.hash(data:normalized))
    }
    var verifiedFingerprint: Data? {
        let declared = bytes.subdata(in:84..<100), calculated = fingerprint
        // An inconsistent declared ID cannot establish either equality or
        // inequality. It is never trusted as a shortcut to a passing result.
        return declared.allSatisfy { $0 == 0 } || declared == calculated ? calculated : nil
    }
    init(data: Data) throws {
        let b = Array(data)
        guard b.count >= 132 else { throw PDFStructureError.malformed(L10n.tr("header ICC troncato")) }
        func u32(_ p: Int) -> Int { b[p..<(p + 4)].reduce(0) { ($0 << 8) | Int($1) } }
        func text(_ p: Int) -> String { String(decoding: b[p..<(p + 4)], as: UTF8.self) }
        bytes = data; deviceClass = text(12); colorSpace = text(16); majorVersion = Int(b[8])
        components = Self.channels(colorSpace)
        var issues: [String] = []
        let size = u32(0), count = u32(128)
        if text(36) != "acsp" { issues.append(L10n.tr("firma acsp assente")) }
        if size != b.count { issues.append(L10n.tr("dimensione dichiarata ICC diversa dai byte incorporati")) }
        if u32(64) > 3 { issues.append(L10n.tr("rendering intent ICC fuori intervallo")) }
        guard count <= (b.count - 132) / 12 else { throw PDFStructureError.malformed(L10n.tr("tabella tag ICC troncata")) }
        guard count <= 4096 else { throw PDFStructureError.limit }
        var signatures = Set<String>(), ranges: [Range<Int>] = []
        for i in 0..<count {
            let p = 132 + 12 * i, signature = text(p), offset = u32(p + 4), length = u32(p + 8)
            if !signatures.insert(signature).inserted { issues.append(L10n.tr("tag ICC duplicato: ") + signature) }
            guard length >= 8, offset >= 132 + 12 * count, offset <= b.count, length <= b.count - offset else {
                issues.append(L10n.tr("limiti tag ICC: ") + signature); continue
            }
            if offset % 4 != 0 { issues.append(L10n.tr("tag ICC non allineato: ") + signature) }
            if b[(offset + 4)..<(offset + 8)].contains(where: { $0 != 0 }) { issues.append(L10n.tr("byte riservati tag ICC non nulli: ") + signature) }
            let range = offset..<(offset + length)
            if ranges.contains(where: { $0.overlaps(range) && $0 != range }) { issues.append(L10n.tr("sovrapposizione parziale tag ICC: ") + signature) }
            ranges.append(range)
        }
        structuralIssues = issues
    }
}

/// JP2 box/SIZ facts for the explicit PDF/A JPEG2000 predicates. Compression
/// integrity, palette semantics and colour transform validity remain separate.
struct PDFArchiveJPEG2000 {
    struct ColorSpec { let method: Int, precedence: Int, approximation: Int, enumerated: Int? }
    var colorSpecs: [ColorSpec] = []
    var components = 0
    var bitDepth = 0
    var bpccPresent = false
    var channelCountKnown = true
    private var alphaChannels = Set<Int>()
    private var mappedChannels: Int?
    init(data: Data) throws {
        let b = Array(data)
        func be(_ start: Int, _ length: Int) throws -> Int {
            guard start >= 0, length <= 8, start <= b.count - length else { throw PDFStructureError.malformed(L10n.tr("campo JPEG2000 troncato")) }
            var n = 0
            for byte in b[start..<(start + length)] { guard n <= Int.max >> 8 else { throw PDFStructureError.limit }; n = n << 8 | Int(byte) }
            return n
        }
        if b.starts(with: [0xFF,0x4F]) {
            guard b.count >= 42, b[2] == 0xFF, b[3] == 0x51 else { throw PDFStructureError.malformed(L10n.tr("SIZ JPEG2000 mancante")) }
            components = try be(40, 2)
            // SIZ starts at byte2, Csiz is at marker+38, component facts at+40.
            let length = try be(4, 2)
            guard components > 0, components <= 16384, length == 38 + 3 * components, b.count >= 42 + 3 * components else {
                throw PDFStructureError.malformed(L10n.tr("SIZ JPEG2000 troncato"))
            }
            let depths = (0..<components).map { Int(b[42 + 3 * $0] & 0x7F) + 1 }
            bitDepth = depths.first ?? 0; bpccPresent = Set(depths).count != 1
            return
        }
        guard b.starts(with: [0,0,0,12,0x6A,0x50,0x20,0x20,13,10,0x87,10]) else { throw PDFStructureError.malformed(L10n.tr("firma JP2")) }
        func boxes(_ range: Range<Int>, depth: Int) throws {
            guard depth < 16 else { throw PDFStructureError.limit }
            var cursor = range.lowerBound, count = 0
            while cursor < range.upperBound {
                count += 1; guard count < 100_000, cursor <= range.upperBound - 8 else { throw PDFStructureError.malformed(L10n.tr("box JP2 troncato")) }
                var length = try be(cursor, 4), header = 8
                let name = String(decoding: b[(cursor + 4)..<(cursor + 8)], as: UTF8.self)
                if length == 1 { guard range.upperBound - cursor >= 16 else { throw PDFStructureError.malformed(L10n.tr("XLBox JP2 troncato")) };length = try be(cursor + 8, 8); header = 16 }
                else if length == 0 { length = range.upperBound - cursor }
                guard length >= header, length <= range.upperBound - cursor else { throw PDFStructureError.malformed(L10n.tr("lunghezza box JP2")) }
                let p = cursor + header, end = cursor + length
                if name == "jp2h" { try boxes(p..<end, depth: depth + 1) }
                else if name == "ihdr" {
                    guard end - p == 14 else { throw PDFStructureError.malformed(L10n.tr("ihdr JP2")) }
                    components = try be(p + 8, 2); bitDepth = Int(b[p + 10] & 0x7F) + 1
                    if b[p + 10] == 255 { bpccPresent = true }
                } else if name == "bpcc" { bpccPresent = true }
                else if name == "colr" {
                    guard end - p >= 3 else { throw PDFStructureError.malformed(L10n.tr("colr JP2")) }
                    guard b[p] != 1 || end - p >= 7 else { throw PDFStructureError.malformed(L10n.tr("colr JP2 enumerato troncato")) }
                    colorSpecs.append(.init(method: Int(b[p]), precedence: Int(b[p + 1]), approximation: Int(b[p + 2]), enumerated: b[p] == 1 ? try be(p + 3, 4) : nil))
                } else if name == "cdef" {
                    guard end - p >= 2 else { throw PDFStructureError.malformed(L10n.tr("cdef JP2 troncato")) }
                    let n = try be(p, 2)
                    guard end - p >= 2 + n * 6 else { throw PDFStructureError.malformed(L10n.tr("cdef JP2")) }
                    for i in 0..<n {
                        let channel = try be(p + 2 + 6 * i, 2), type = try be(p + 4 + 6 * i, 2)
                        if type == 1 || type == 2 { alphaChannels.insert(channel) }
                        else if type != 0 && type != 65535 { channelCountKnown = false }
                    }
                } else if name == "cmap" {
                    guard (end - p) % 4 == 0 else { throw PDFStructureError.malformed(L10n.tr("cmap JP2")) }
                    mappedChannels = (end - p) / 4
                }
                cursor = end
            }
        }
        try boxes(0..<b.count, depth: 0)
        guard components > 0 else { throw PDFStructureError.malformed(L10n.tr("ihdr JP2 mancante")) }
        let count = mappedChannels ?? components
        if alphaChannels.contains(where: { $0 >= count }) { throw PDFStructureError.malformed(L10n.tr("canale cdef JP2 fuori intervallo")) }
        components = count - alphaChannels.count
    }
}
