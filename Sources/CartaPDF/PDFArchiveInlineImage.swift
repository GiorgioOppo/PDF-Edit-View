import Foundation

/// Consumes BI's dictionary and data without tokenizing binary pixels as PDF
/// operators. An independently calculated unfiltered sample count establishes
/// reliable boundaries. L can guide traversal but cannot prove its own validity.
struct PDFArchiveInlineImage {
    let dictionary: [String: PDFSyntaxValue]
    let bytes: Data
    let lengthReliable: Bool
    var decodingIssue: String? = nil
    static func read(from lexer: inout PDFSyntaxLexer) throws -> Self {
        let aliases = ["W":"Width", "H":"Height", "BPC":"BitsPerComponent", "CS":"ColorSpace",
                       "F":"Filter", "DP":"DecodeParms", "IM":"ImageMask", "I":"Interpolate", "D":"Decode"]
        var dictionary: [String: PDFSyntaxValue] = [:]
        func firstFilter() -> String? { dictionary["Filter"]?.name ?? dictionary["Filter"]?.array?.first?.name }
        func asciiFilter() -> Bool { ["ASCIIHexDecode","AHx","ASCII85Decode","A85"].contains(firstFilter() ?? "") }
        while true {
            lexer.skip()
            // §8.9.7 permits no separator after ID for ASCII filters; the
            // encoded first character may itself be a regular token byte.
            if lexer.offset+1 < lexer.bytes.count,lexer.bytes[lexer.offset] == 73,lexer.bytes[lexer.offset+1] == 68,
               asciiFilter() || lexer.offset+2 == lexer.bytes.count || PDFSyntaxLexer.delimiter(lexer.bytes[lexer.offset+2]) {
                lexer.offset += 2;break
            }
            let token = try lexer.value()
            if case .keyword("ID") = token { break }
            guard let key = token.name, dictionary.count < 1000 else { throw PDFStructureError.malformed(L10n.tr("dizionario immagine inline")) }
            let normalized = aliases[key] ?? key
            guard dictionary[normalized] == nil else { throw PDFStructureError.malformed(L10n.tr("chiave inline duplicata")) }
            dictionary[normalized] = try lexer.value()
        }
        guard lexer.offset < lexer.bytes.count else { throw PDFStructureError.malformed(L10n.tr("dati immagine inline assenti")) }
        if !PDFSyntaxLexer.space(lexer.bytes[lexer.offset]) && !asciiFilter() {
            throw PDFStructureError.malformed(L10n.tr("ID deve essere seguito da uno spazio"))
        }
        if PDFSyntaxLexer.space(lexer.bytes[lexer.offset]) {
            if lexer.bytes[lexer.offset] == 13, lexer.offset + 1 < lexer.bytes.count, lexer.bytes[lexer.offset + 1] == 10 { lexer.offset += 2 }
            else { lexer.offset += 1 }
        }
        let start = lexer.offset
        var length:Int?,sampleCount:Int?,reliable = false,decodingIssue:String?
        if let width = dictionary["Width"]?.int, let height = dictionary["Height"]?.int,
           width > 0, height > 0, width <= 1_000_000, height <= 1_000_000 {
            let mask = dictionary["ImageMask"]?.bool == true
            let bits = mask ? 1 : dictionary["BitsPerComponent"]?.int
            let name = dictionary["ColorSpace"]?.name
            let components = mask ? 1 : ["G":1,"DeviceGray":1,"RGB":3,"DeviceRGB":3,"CMYK":4,"DeviceCMYK":4][name ?? ""]
            if let bits, let components, [1,2,4,8,16].contains(bits) {
                let row = (width * components * bits + 7) / 8
                if row <= 256 * 1024 * 1024 / height { sampleCount = row * height }
            }
        }
        if dictionary["Filter"] == nil,let sampleCount { length = sampleCount;reliable = true }
        // General filters define an EOD independent of L. The outermost
        // encoded filter alone determines the physical extent of the payload.
        if length == nil {
            let first = firstFilter()
            if let first,PDFStreamFilters.supported.contains(first) {
                let parameters = dictionary["DecodeParms"]?.dictionary ?? dictionary["DecodeParms"]?.array?.first?.dictionary ?? [:]
                do {
                    let prefix = try PDFStreamFilters.prefix(Data(lexer.bytes[start...]),filter:first,parameters:parameters)
                    length = prefix.consumed;reliable = true
                    let filters = PDFStructureDocument.filters(dictionary)
                    if filters.allSatisfy({ PDFStreamFilters.supported.contains($0) }) {
                        let samples = try PDFStructureDocument.decode(Data(lexer.bytes[start..<(start+prefix.consumed)]),dictionary:dictionary)
                        if let sampleCount,samples.count != sampleCount {
                            throw PDFStructureError.malformed(L10n.tr("campioni inline: \(samples.count) byte decodificati, attesi \(sampleCount) dalle righe/dimensioni"))
                        }
                    }
                } catch {
                    guard let error = error as? PDFStructureError else { throw error }
                    // The dictionary is still proved even when its encoded
                    // payload is invalid. Preserve independent violations.
                    switch error {
                    case .malformed:decodingIssue = error.localizedDescription
                    case .unsupported:break
                    default:throw error
                    }
                }
            }
        }
        if length == nil,let declared = dictionary["L"]?.int,declared >= 0,declared <= 256 * 1024 * 1024 { length = declared }
        if let length {
            guard length >= 0, length <= 256 * 1024 * 1024, start <= lexer.bytes.count - length else { throw PDFStructureError.malformed(L10n.tr("lunghezza immagine inline")) }
            lexer.offset = start + length
            guard lexer.offset < lexer.bytes.count, PDFSyntaxLexer.space(lexer.bytes[lexer.offset]) else { throw PDFStructureError.malformed(L10n.tr("delimitatore prima di EI")) }
            guard try lexer.word() == "EI" else { throw PDFStructureError.malformed(L10n.tr("fine immagine inline")) }
            return .init(dictionary: dictionary, bytes: Data(lexer.bytes[start..<(start + length)]), lengthReliable: reliable,decodingIssue:decodingIssue)
        }
        var cursor = start
        while cursor + 3 <= lexer.bytes.count {
            try Task.checkCancellation()
            if PDFSyntaxLexer.space(lexer.bytes[cursor]), lexer.bytes[cursor + 1] == 69, lexer.bytes[cursor + 2] == 73,
               cursor + 3 == lexer.bytes.count || PDFSyntaxLexer.delimiter(lexer.bytes[cursor + 3]) {
                lexer.offset = cursor + 3
                return .init(dictionary: dictionary, bytes: Data(lexer.bytes[start..<cursor]), lengthReliable: false,decodingIssue:decodingIssue)
            }
            cursor += 1
        }
        throw PDFStructureError.malformed(L10n.tr("EI non trovato nell’immagine inline"))
    }
}
