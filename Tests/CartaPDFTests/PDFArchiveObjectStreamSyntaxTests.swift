import Foundation
import XCTest
@testable import CartaPDF

final class PDFArchiveObjectStreamSyntaxTests:XCTestCase {
    private func stream(_ data:Data,_ dictionary:String = "")->Data {
        Data("<< \(dictionary) /Length \(data.count) >>\nstream\n".utf8)+data+Data("\nendstream".utf8)
    }
    private func objectStream(header:String = "9 0 ",values:String = "true",n:String = "1",first:String? = nil,filter:String = "")->Data {
        stream(Data((header+values).utf8),"/Type /ObjStm /N \(n) /First \(first ?? String(header.utf8.count)) \(filter)")
    }
    private func fixture(_ objectStream:Data,extras:[Int:Data] = [:])->(Data,Int) {
        var objects:[Int:Data] = [
            1:Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            2:Data("<< /Type /Pages /Count 1 /Kids [3 0 R] >>".utf8),
            3:Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 10 10] /Resources << >> /Contents 4 0 R >>".utf8),
            4:stream(Data()),5:objectStream
        ]
        objects.merge(extras){_,new in new}
        var data = Data("%PDF-1.7\n%".utf8)+Data([0xE2,0xE3,0xCF,0xD3,10]),positions:[Int:Int] = [:]
        for number in objects.keys.sorted() { positions[number] = data.count;data += Data("\(number) 0 obj\n".utf8)+objects[number]!+Data("\nendobj\n".utf8) }
        let xref = data.count,count = (objects.keys.max() ?? 0)+1
        data += Data("xref\n0 \(count)\n0000000000 65535 f \n".utf8)
        for number in 1..<count { data += Data(String(format:"%010lld 00000 %@ \n",Int64(positions[number] ?? 0),positions[number] == nil ? "f":"n").utf8) }
        data += Data("trailer\n<< /Root 1 0 R /Size \(count) /ID [<1234><5678>] >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        return (data,xref)
    }
    private func append(_ original:Data,previous:Int,objects:[Int:Data],republished:[Int:Int] = [:])->Data {
        var data = original,positions:[Int:Int] = [:]
        for number in objects.keys.sorted() { positions[number] = data.count;data += Data("\(number) 0 obj\n".utf8)+objects[number]!+Data("\nendobj\n".utf8) }
        positions.merge(republished){_,new in new}
        let xref = data.count;data += Data("xref\n".utf8)
        for number in positions.keys.sorted() { data += Data("\(number) 1\n".utf8)+Data(String(format:"%010lld 00000 n \n",Int64(positions[number]!)).utf8) }
        data += Data("trailer\n<< /Root 1 0 R /Size 20 /Prev \(previous) /ID [<1234><5678>] >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        return data
    }
    private func checks(_ stream:Data,extras:[Int:Data] = [:]) throws -> PDFArchiveSyntaxChecks {
        try PDFArchiveSyntaxChecks(reader:PDFStructureDocument(data:fixture(stream,extras:extras).0))
    }
    private func hexRule(_ expression:String)->PDFArchiveCatalogueRule {
        .init(specification:"test",clause:"7.3.4.3",testNumber:"1",objectType:"CosString",requirement:expression,expression:expression)
    }
    func testConsecutiveBoundedValuesAllowInternalReferencesCommentsAndUnorderedObjectNumbers() throws {
        let first = "[1 0 R] %slice comment\n",second = "<< /Private <ABCD> >> %tail\n"
        let header = "10 0 9 \(first.utf8.count) %header comment\n"
        XCTAssertEqual(try checks(objectStream(header:header,values:first+second,n:"2")).modelResult().status,.passed)
        XCTAssertEqual(try checks(objectStream(header:"+9 +0 ",values:"true")).modelResult().status,.passed)
        XCTAssertEqual(try checks(objectStream(header:"",values:"%empty\n",n:"0",first:"0")).modelResult().status,.passed)
    }
    func testObjectNumbersMustBePositiveUniqueIntegerTokens() throws {
        for header in ["0 0 ","-9 0 ","9.0 0 ","9e0 0 ","0x9 0 "] {
            XCTAssertEqual(try checks(objectStream(header:header)).modelResult().status,.failed,header)
        }
        XCTAssertEqual(try checks(objectStream(header:"9 0 9 2 ",values:"1 true",n:"2")).modelResult().status,.failed)
    }
    func testOffsetsMustBeIncreasingInBoundsAndCannotSplitAValueOrToken() throws {
        for (header,values) in [("9 0 10 0 ","1 true"),("9 2 10 0 ","1 true"),("9 0 10 100 ","1 true"),("9 0 10 2 ","(a) 42"),("9 0 10 1 ","12")] {
            XCTAssertEqual(try checks(objectStream(header:header,values:values,n:"2")).modelResult().status,.failed,header)
        }
        for offset in ["-1","0.0","0e0","0x0","1"] {
            XCTAssertEqual(try checks(objectStream(header:"9 \(offset) ")).modelResult().status,.failed,offset)
        }
    }
    func testOneValuePerSliceAndStandaloneReferenceProhibitionAreIndependent() throws {
        for value in ["1 0 R","1 true","<< >> stream\nendstream","1 endobj",""] {
            XCTAssertEqual(try checks(objectStream(values:value)).modelResult().status,.failed,value)
        }
        XCTAssertEqual(try checks(objectStream(values:"[1 0 R]")).modelResult().status,.passed)
        XCTAssertEqual(try checks(objectStream(values:"<< /Nested 1 0 R >>")).modelResult().status,.passed)
        XCTAssertEqual(try checks(objectStream(header:"",values:"true",n:"0",first:"0")).modelResult().status,.failed)
    }
    func testFirstMustEncloseExactlyTheHeaderAndNotTruncateAnIntegerOrComment() throws {
        for first in ["-1","2","7","100","4.0"] {
            XCTAssertEqual(try checks(objectStream(first:first)).modelResult().status,.failed,first)
        }
        XCTAssertEqual(try checks(objectStream(header:"9 0 17 ",first:"7")).modelResult().status,.failed)
        let header = "9 0 %cut"
        XCTAssertEqual(try checks(objectStream(header:header,values:"<< /A 1 >>")).modelResult().status,.failed)
        XCTAssertEqual(try checks(objectStream(header:"9 0 %closed\n",values:"<< /A 1 >>")).modelResult().status,.passed)
        XCTAssertEqual(try checks(objectStream(header:"9 0",values:"12",first:"3")).modelResult().status,.failed)
    }
    func testIndirectNAndFirstUseTheirHistoricalRevisionInsteadOfLatestDefinitions() throws {
        let original = fixture(objectStream(n:"6 0 R",first:"7 0 R"),extras:[6:Data("1".utf8),7:Data("4".utf8)])
        let newHeader = "11 0 12 2 ",replacement = objectStream(header:newHeader,values:"1 false",n:"6 0 R",first:"7 0 R")
        let updated = append(original.0,previous:original.1,objects:[5:replacement,6:Data("2".utf8),7:Data(String(newHeader.utf8.count).utf8)])
        let reader = try PDFStructureDocument(data:updated)
        XCTAssertEqual(reader.revisions.count,2)
        XCTAssertEqual(PDFArchiveSyntaxChecks(reader:reader).modelResult().status,.passed)
    }
    func testInvalidHistoricalObjectStreamIsNotRepairedByAnActiveReplacement() throws {
        let original = fixture(objectStream(values:"1 0 R"))
        let updated = append(original.0,previous:original.1,objects:[5:objectStream(values:"true")])
        let result = PDFArchiveSyntaxChecks(reader:try PDFStructureDocument(data:updated)).modelResult()
        XCTAssertEqual(result.status,.failed)
        XCTAssertTrue(diagnosticContains(result.detail, "soltanto un riferimento"))
    }
    func testRepublishedPhysicalOffsetValidatesBothOldAndNewIndirectNInterpretations() throws {
        let header = "9 0 10 2 "
        for oldN in [1,2] {
            let original = fixture(objectStream(header:header,values:"1 true",n:"6 0 R",first:"7 0 R"),extras:[6:Data(String(oldN).utf8),7:Data(String(header.utf8.count).utf8)])
            let physical = try XCTUnwrap(original.0.range(of:Data("5 0 obj\n".utf8))).lowerBound
            let updated = append(original.0,previous:original.1,objects:[6:Data(String(3-oldN).utf8)],republished:[5:physical])
            XCTAssertEqual(PDFArchiveSyntaxChecks(reader:try PDFStructureDocument(data:updated)).modelResult().status,.failed)
        }
    }
    func testRepublishedOffsetFirstIsRevisionSpecificButBenignIndirectUpdatesRemainValidAndPhysicalFactsUnique() throws {
        for (oldFirst,newFirst,failed) in [("5","4",true),("4","5",true),("4","+4",false)] {
            let original = fixture(objectStream(n:"6 0 R",first:"7 0 R"),extras:[6:Data("1".utf8),7:Data(oldFirst.utf8)])
            let physical = try XCTUnwrap(original.0.range(of:Data("5 0 obj\n".utf8))).lowerBound
            let updated = append(original.0,previous:original.1,objects:[6:Data("+1".utf8),7:Data(newFirst.utf8)],republished:[5:physical])
            let result = PDFArchiveSyntaxChecks(reader:try PDFStructureDocument(data:updated)).modelResult()
            XCTAssertEqual(result.status,failed ? .failed:.passed)
            if !failed { XCTAssertTrue(result.detail.contains(L10n.tr("Controllati \(9) oggetti e \(2) stream, incluse revisioni xref ibride.")),result.detail) }
        }
    }
    func testTrailingSliceCommentCannotExposeAnotherValueBeforeItsActualLineEnding() throws {
        let first = "true %tail",header = "9 0 10 \(first.utf8.count) "
        let bad = objectStream(header:header,values:first+"<< /A 1 >>",n:"2")
        let result = try checks(bad).modelResult()
        XCTAssertEqual(result.status,.failed)
        XCTAssertTrue(diagnosticContains(result.detail, "interrompe un commento"))
        for separator in ["\n","\r\n"] {
            XCTAssertEqual(try checks(objectStream(header:header,values:first+separator+"<< /A 1 >>",n:"2")).modelResult().status,.passed)
        }
    }
    func testHistoricalOddAndInvalidHexFactsSurviveStrictParseFailureAndObjectReplacement() throws {
        let first = "<F> ",second = "[<AG>]",header = "9 0 10 \(first.utf8.count) "
        let original = fixture(objectStream(header:header,values:first+second,n:"2"))
        let updated = append(original.0,previous:original.1,objects:[5:objectStream(values:"<AB>")])
        let checks = PDFArchiveSyntaxChecks(reader:try PDFStructureDocument(data:updated))
        XCTAssertEqual(try checks.evaluate(hexRule("hexCount % 2 == 0"))?.status,.failed)
        XCTAssertEqual(try checks.evaluate(hexRule("containsOnlyHex == true"))?.status,.failed)
        XCTAssertEqual(checks.modelResult().status,.failed)
    }
    func testUnsupportedFilterAndCountBudgetAreUnknownRatherThanSyntaxViolations() throws {
        XCTAssertEqual(try checks(objectStream(filter:"/Filter /DCTDecode")).modelResult().status,.notVerified)
        XCTAssertEqual(try checks(objectStream(n:"100001")).modelResult().status,.notVerified)
        XCTAssertEqual(try checks(objectStream(n:"999999999999999999999999999999")).modelResult().status,.notVerified)
        XCTAssertEqual(try checks(objectStream(n:"1.0")).modelResult().status,.failed)
    }
    func testCancellationIsNeverReportedAsMalformedObjectStreamSyntax() async throws {
        let reader = try PDFStructureDocument(data:fixture(objectStream()).0)
        let task = Task {
            withUnsafeCurrentTask{$0?.cancel()}
            return PDFArchiveSyntaxChecks(reader:reader).modelResult().status
        }
        let status = await task.value
        XCTAssertEqual(status,.notVerified)
    }
}
