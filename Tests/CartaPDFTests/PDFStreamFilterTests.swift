import Foundation
import XCTest
@testable import CartaPDF

final class PDFStreamFilterTests: XCTestCase {
    private func decode(_ data:Data,_ name:String,_ parameters:[String:PDFSyntaxValue] = [:]) throws -> Data {
        try PDFStructureDocument.decode(data,dictionary:["Filter":.name(name),"DecodeParms":.dictionary(parameters)])
    }
    private func hex(_ string:String) -> Data {
        let bytes = Array(string.utf8)
        return Data(stride(from:0,to:bytes.count,by:2).map { UInt8(String(decoding:bytes[$0..<($0+2)],as:UTF8.self),radix:16)! })
    }
    func testASCIIHexStopsAtEODAndRejectsInvalidOrUnterminatedData() throws {
        let prefix = try PDFStreamFilters.prefix(Data("61 62 6> ignored".utf8),filter:"AHx")
        XCTAssertEqual(prefix.data,Data([97,98,96]));XCTAssertEqual(prefix.consumed,8)
        XCTAssertThrowsError(try decode(Data("6162".utf8),"AHx"))
        do { _ = try decode(Data("6162".utf8),"AHx");XCTFail("must remain unverified") }
        catch PDFStructureError.unsupported {} catch { XCTFail("Missing > alone is not a proved normative violation") }
        XCTAssertThrowsError(try decode(Data("61x>".utf8),"AHx"))
    }
    func testASCII85MarkersOverflowAndPartialGroups() throws {
        XCTAssertEqual(try decode(Data("87cURD_*#TDfTZ)+T~>".utf8),"A85"),Data("Hello, world!".utf8))
        XCTAssertEqual(try decode(Data("z!!~>".utf8),"A85"),Data(repeating:0,count:5))
        for text in ["z","!~>","!z~>","uuuuu~>","~x","<~z~>"] { XCTAssertThrowsError(try decode(Data(text.utf8),"A85"),text) }
    }
    func testRunLengthEODIsIndependentOfInlineBinaryEITokens() throws {
        let encoded = Data([3,32,69,73,32,254,65,128])
        let prefix = try PDFStreamFilters.prefix(encoded + Data(" EI q".utf8),filter:"RL")
        XCTAssertEqual(prefix.data,Data(" EI AAA".utf8));XCTAssertEqual(prefix.consumed,encoded.count)
        XCTAssertThrowsError(try decode(Data([2,65]),"RL"))
        XCTAssertThrowsError(try decode(Data([0,65]),"RL"))
        var lexer = PDFSyntaxLexer(Data("/W 7 /H 1 /CS /G /BPC 8 /F /RL /L 1 ID ".utf8) + encoded + Data(" EI q".utf8))
        let image = try PDFArchiveInlineImage.read(from:&lexer)
        XCTAssertTrue(image.lengthReliable);XCTAssertEqual(image.bytes,encoded);XCTAssertEqual(try lexer.word(),"q")
    }
    func testASCIIInlineFiltersDoNotRequireWhitespaceAfterIDAndValidateAllFilters() throws {
        for source in ["/W 1 /H 1 /CS /G /BPC 8 /F /AHx ID16> EI","/W 1 /H 1 /CS /G /BPC 8 /F /A85 ID('~> EI"] {
            var lexer = PDFSyntaxLexer(Data(source.utf8));let image = try PDFArchiveInlineImage.read(from:&lexer)
            XCTAssertTrue(image.lengthReliable);XCTAssertNil(image.decodingIssue)
            XCTAssertEqual(try PDFStructureDocument.decode(image.bytes,dictionary:image.dictionary),Data([22]))
        }
        var bad = PDFSyntaxLexer(Data("/W 1 /H 1 /CS /G /BPC 8 /F [/AHx /Fl] ID67617262616765> EI".utf8))
        let image = try PDFArchiveInlineImage.read(from:&bad)
        XCTAssertTrue(image.lengthReliable);XCTAssertNotNil(image.decodingIssue)
        var raw = PDFSyntaxLexer(Data("/W 1 /H 1 /CS /G /BPC 8 ID(x) EI".utf8))
        XCTAssertThrowsError(try PDFArchiveInlineImage.read(from:&raw))
    }
    func testFilteredInlineSamplesMustMatchRowsAfterTheWholeFilterChain() throws {
        var valid = PDFSyntaxLexer(Data("/W 3 /H 1 /CS /G /BPC 8 /F /AHx ID616263> EI".utf8))
        XCTAssertNil(try PDFArchiveInlineImage.read(from:&valid).decodingIssue)
        var short = PDFSyntaxLexer(Data("/W 4 /H 1 /CS /G /BPC 8 /F /AHx ID616263> EI".utf8))
        let truncated = try PDFArchiveInlineImage.read(from:&short)
        XCTAssertTrue(truncated.lengthReliable);XCTAssertNotNil(truncated.decodingIssue)
        var long = PDFSyntaxLexer(Data("/W 1 /H 1 /CS /G /BPC 8 /F /A85 IDz~> EI".utf8))
        let excess = try PDFArchiveInlineImage.read(from:&long)
        XCTAssertTrue(excess.lengthReliable);XCTAssertNotNil(excess.decodingIssue)
    }
    func testFlateVerifiesChecksumAndReportsEncodedBoundary() throws {
        // RFC 1950 wrapper around a deflate representation of the bytes abc.
        let encoded = hex("789C4B4C4A0600024D0127")
        let prefix = try PDFStreamFilters.prefix(encoded + Data(" EI q".utf8),filter:"Fl")
        XCTAssertEqual(prefix.data,Data("abc".utf8));XCTAssertEqual(prefix.consumed,encoded.count)
        XCTAssertEqual(try decode(hex("789C030000000001"),"Fl"),Data())
        var bad = encoded;bad[bad.count-1] ^= 1
        XCTAssertThrowsError(try decode(bad,"Fl"))
        XCTAssertThrowsError(try decode(Data(encoded.dropLast(5)),"Fl"))
        var lexer = PDFSyntaxLexer(Data("/W 3 /H 1 /BPC 8 /CS /G /F /Fl /L 1 ID ".utf8) + encoded + Data(" EI q".utf8))
        let image = try PDFArchiveInlineImage.read(from:&lexer)
        XCTAssertEqual(image.bytes,encoded);XCTAssertTrue(image.lengthReliable)
    }
    func testFlateChecksStoredBlocksAndRejectsReservedBlockTypes() throws {
        XCTAssertEqual(try decode(hex("7801010300FCFF616263024D0127"),"Fl"),Data("abc".utf8))
        XCTAssertThrowsError(try decode(hex("7801010300FDFF616263024D0127"),"Fl"))
        XCTAssertThrowsError(try decode(hex("78010700000001"),"Fl"))
        XCTAssertThrowsError(try decode(hex("78010300000000"),"Fl"))
        // Independent review counterexample: EOB-only dynamic tree with a
        // two-bit code leaves unused branches and is not a valid singleton.
        XCTAssertThrowsError(try decode(hex("789c058001040000004000000000000000000000000000000000000000000000000000000000000000000200000001"),"Fl"))
    }
    func testLZWDecodesPublishedISO32000ExampleAndRejectsInvalidCodes() throws {
        // ISO 32000-1:2008 §7.4.4.2 example 2, not generated by this decoder.
        XCTAssertEqual(try decode(hex("800B6050220C0C8501"),"LZWDecode"),Data([45,45,45,45,45,65,45,45,45,66]))
        XCTAssertThrowsError(try decode(hex("800B6050220C0C8500"),"LZWDecode"))
        XCTAssertThrowsError(try decode(hex("0000"),"LZWDecode"))
        XCTAssertThrowsError(try decode(hex("800B6050220C0C8501"),"LZWDecode",["EarlyChange":.number("2")]))
    }
    private func packed(_ codes:[(Int,Int)]) -> Data {
        var result = Data(),accumulator:UInt8 = 0,used = 0
        for (code,width) in codes { for shift in (0..<width).reversed() {
            accumulator = accumulator<<1 | UInt8(code>>shift & 1);used += 1
            if used == 8 { result.append(accumulator);accumulator = 0;used = 0 }
        } }
        if used > 0 { result.append(accumulator << (8-used)) };return result
    }
    func testLZWEarlyChangeZeroAndOneAcrossAllCodeWidths() throws {
        for early in [0,1] {
            // A literal-only stream has fixed transition positions; no LZW
            // encoder or copy of the decoder's table construction is involved.
            let first = early == 1 ? 254:255
            var codes = [(256,9)],expected = Data(),index = 0
            for (count,width) in [(first,9),(512,10),(1024,11),(500,12)] {
                for _ in 0..<count { codes.append((index%256,width));expected.append(UInt8(index%256));index += 1 }
            }
            codes.append((257,12))
            XCTAssertEqual(try decode(packed(codes),"LZWDecode",["EarlyChange":.number(String(early))]),expected)
        }
    }
    func testTIFFPredictorWorksOnPackedSamplesAndSixteenBitComponents() throws {
        for (bits,columns,encoded,expected) in [
            (1,5,Data([0xE0]),Data([0xB8])), // 1,0,1,1,1 after modulo differencing
            (2,4,Data([0x55]),Data([0x6C])),
            (4,3,Data([0x12,0xF0]),Data([0x13,0x20])),
            (16,3,Data([0,255,0,2,255,255]),Data([0,255,1,1,1,0]))
        ] {
            XCTAssertEqual(try PDFStreamFilters.unpredict(encoded,parameters:["Predictor":.number("2"),"Columns":.number(String(columns)),"BitsPerComponent":.number(String(bits))]),expected)
        }
        let color = try PDFStreamFilters.unpredict(Data([1,2,3,4,5,6]),parameters:["Predictor":.number("2"),"Colors":.number("3"),"Columns":.number("2")])
        XCTAssertEqual(color,Data([1,2,3,5,7,9]))
    }
    func testPNGPredictorsUseBytesPerPixelAndRowTagsForAllBitDepths() throws {
        XCTAssertEqual(try PDFStreamFilters.unpredict(Data([1,0x12,0x22,0x22]),parameters:["Predictor":.number("10"),"Columns":.number("6"),"BitsPerComponent":.number("4")]),Data([0x12,0x34,0x56]))
        XCTAssertEqual(try PDFStreamFilters.unpredict(Data([1,1,2,2,2]),parameters:["Predictor":.number("15"),"Columns":.number("2"),"BitsPerComponent":.number("16")]),Data([1,2,3,4]))
        XCTAssertThrowsError(try PDFStreamFilters.unpredict(Data([5,0]),parameters:["Predictor":.number("12")]))
        XCTAssertThrowsError(try PDFStreamFilters.unpredict(Data([0]),parameters:["Predictor":.number("2"),"Columns":.number("2")]))
        XCTAssertThrowsError(try PDFStreamFilters.unpredict(Data(),parameters:["Predictor":.number("3")]))
    }
    func testFilterChainsRequireMatchingParameterArrays() throws {
        let encoded = Data("373839433442344334413036303030323444303132373E>".utf8)
        XCTAssertEqual(try PDFStructureDocument.decode(encoded,dictionary:["Filter":.array([.name("AHx"),.name("AHx"),.name("Fl")])]),Data("abc".utf8))
        XCTAssertThrowsError(try PDFStructureDocument.decode(encoded,dictionary:["Filter":.array([.name("AHx"),.number("1")])]))
        XCTAssertThrowsError(try PDFStructureDocument.decode(encoded,dictionary:["Filter":.array([.name("AHx"),.name("Fl")]),"DecodeParms":.dictionary([:])]))
    }
    private func document(_ objects:[Int:Data]) throws -> PDFStructureDocument {
        var data = Data("%PDF-1.7\n".utf8),offsets:[Int:Int] = [:]
        for id in objects.keys.sorted() { offsets[id] = data.count;data += Data("\(id) 0 obj\n".utf8)+objects[id]!+Data("\nendobj\n".utf8) }
        let xref = data.count,count = objects.keys.max()!+1
        data += Data("xref\n0 \(count)\n0000000000 65535 f \n".utf8)
        for i in 1..<count { data += Data(String(format:"%010lld 00000 %@ \n",Int64(offsets[i] ?? 0),offsets[i] == nil ? "f":"n").utf8) }
        data += Data("trailer\n<< /Root 1 0 R /Size \(count) >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        return try PDFStructureDocument(data:data)
    }
    func testIndirectFiltersAndParameterValuesAreResolvedAndCyclesRejected() throws {
        let reader = try document([1:Data("<< /Type /Catalog >>".utf8),2:Data("<< /Length 7 /Filter 3 0 R /DecodeParms 4 0 R >>\nstream\n616263>\nendstream".utf8),3:Data("/ASCIIHexDecode".utf8),4:Data("<< /Predictor 5 0 R >>".utf8),5:Data("1".utf8),6:Data("<< /Filter 6 0 R >>".utf8)])
        XCTAssertEqual(try reader.decodedStream(.init(number:2,generation:0)),Data("abc".utf8))
        XCTAssertThrowsError(try reader.streamDecodingDictionary(["Filter":.reference(.init(number:6,generation:0))]))
    }
    func testUndefinedAndFreeReferencesHaveNullSemanticsWithoutHidingBrokenObjects() throws {
        let reader = try document([1:Data("<< /Type /Catalog >>".utf8),3:Data("<< /X 999 0 R >>".utf8)])
        for id in [PDFObjectID(number:2,generation:0),.init(number:999,generation:0),.init(number:3,generation:7)] {
            if case .null? = try reader.resolve(.reference(id)) {} else { XCTFail("undefined reference must resolve to null") }
        }
        XCTAssertThrowsError(try reader.object(.init(number:999,generation:0)))
    }
    func testContentNumbersAndIndirectReferencesAreCheckedBeforeNormalization() throws {
        for content in ["1e3 0 m","+ 0 m","0 0 R m","<< /X operator >> BDC"] {
            var lexer = PDFSyntaxLexer(Data(content.utf8));lexer.strict = true;lexer.allowContentOperators = true
            XCTAssertThrowsError(try { while lexer.offset < lexer.bytes.count { _ = try lexer.value();lexer.skip() } }(),content)
        }
        var valid = PDFSyntaxLexer(Data("+.3 -2. 0 m q Q".utf8));valid.strict = true;valid.allowContentOperators = true
        XCTAssertNoThrow(try { while valid.offset < valid.bytes.count { _ = try valid.value();valid.skip() } }())
    }
}
