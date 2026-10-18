import Foundation
import XCTest
@testable import CartaPDF

final class PDFArchiveRevisionTests:XCTestCase {
    private func stream(_ text:String,length:String = "5 0 R")->Data {
        Data("<< /Length \(length) >>\nstream\n\(text)\nendstream".utf8)
    }
    private func base()->(Data,Int) {
        let objects:[Int:Data] = [
            1:Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            2:Data("<< /Type /Pages /Count 1 /Kids [3 0 R] >>".utf8),
            3:Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Contents 4 0 R >>".utf8),
            4:stream("q Q"),5:Data("3".utf8)]
        var result = Data("%PDF-1.7\n".utf8),offsets:[Int:Int] = [:]
        for number in objects.keys.sorted() { offsets[number] = result.count;result += Data("\(number) 0 obj\n".utf8)+objects[number]!+Data("\nendobj\n".utf8) }
        let xref = result.count
        result += Data("xref\n0 6\n0000000000 65535 f \n".utf8)
        for number in 1...5 { result += Data(String(format:"%010lld 00000 n \n",Int64(offsets[number]!)).utf8) }
        result += Data("trailer\n<< /Root 1 0 R /Size 6 /ID [<1234><5678>] >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        return (result,xref)
    }
    private func append(_ data:Data,previous:Int,objects:[PDFObjectID:Data],free:[Int]=[])->(Data,Int) {
        var result = data,offsets:[PDFObjectID:Int] = [:]
        for id in objects.keys.sorted() { offsets[id] = result.count;result += Data("\(id.number) \(id.generation) obj\n".utf8)+objects[id]!+Data("\nendobj\n".utf8) }
        let xref = result.count;result += Data("xref\n".utf8)
        for id in objects.keys.sorted() { result += Data("\(id.number) 1\n".utf8)+Data(String(format:"%010lld %05d n \n",Int64(offsets[id]!),id.generation).utf8) }
        for number in free { result += Data("\(number) 1\n0000000000 00001 f \n".utf8) }
        result += Data("trailer\n<< /Root 1 0 R /Size 6 /Prev \(previous) /ID [<1234><5678>] >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        return (result,xref)
    }
    func testHistoricalIndirectLengthUsesItsOwnRevisionNotLatestValue() throws {
        let (original,first) = base()
        let (updated,last) = append(original,previous:first,objects:[.init(number:4,generation:0):stream("q Q q Q"),.init(number:5,generation:0):Data("7".utf8)])
        let reader = try PDFStructureDocument(data:updated),old = try reader.revisionReader(at:first)
        XCTAssertEqual(try reader.decodedStream(.init(number:4,generation:0)),Data("q Q q Q".utf8))
        XCTAssertEqual(try old.decodedStream(.init(number:4,generation:0)),Data("q Q".utf8))
        XCTAssertEqual(try old.resolve(.reference(.init(number:5,generation:0)))?.int,3)
        XCTAssertEqual(try reader.revisionReader(at:last).resolve(.reference(.init(number:5,generation:0)))?.int,7)
        XCTAssertEqual(PDFArchiveSyntaxChecks(reader:reader).modelResult().status,.passed)
    }
    func testHistoricalGenerationIsNotReplacedByTheReusedObjectNumber() throws {
        let (original,first) = base()
        let (updated,_) = append(original,previous:first,objects:[.init(number:4,generation:0):stream("q Q q Q",length:"5 1 R"),.init(number:5,generation:1):Data("7".utf8)])
        let reader = try PDFStructureDocument(data:updated),old = try reader.revisionReader(at:first)
        XCTAssertEqual(try old.resolve(.reference(.init(number:5,generation:0)))?.int,3)
        if case .null? = try reader.resolve(.reference(.init(number:5,generation:0))) {} else { XCTFail("old generation must be undefined in latest view") }
        XCTAssertEqual(PDFArchiveSyntaxChecks(reader:reader).modelResult().status,.passed)
    }
    func testHistoricalLengthSurvivesLaterFreeEntryWithoutResurrectingItInLatestView() throws {
        let (original,first) = base()
        let (updated,_) = append(original,previous:first,objects:[.init(number:4,generation:0):stream("q Q q Q",length:"7")],free:[5])
        let reader = try PDFStructureDocument(data:updated)
        if case .null? = try reader.resolve(.reference(.init(number:5,generation:0))) {} else { XCTFail("free object must resolve to null") }
        XCTAssertEqual(try reader.revisionReader(at:first).resolve(.reference(.init(number:5,generation:0)))?.int,3)
        XCTAssertEqual(PDFArchiveSyntaxChecks(reader:reader).modelResult().status,.passed)
    }
    func testInvalidHistoricalLengthCannotBeRepairedByLaterUpdate() throws {
        let (source,first) = base()
        var original = source
        let marker = try XCTUnwrap(original.range(of:Data("5 0 obj\n3\nendobj".utf8)))
        original[marker.lowerBound+8] = 49
        let (updated,_) = append(original,previous:first,objects:[.init(number:4,generation:0):stream("q Q q Q"),.init(number:5,generation:0):Data("7".utf8)])
        XCTAssertEqual(PDFArchiveSyntaxChecks(reader:try PDFStructureDocument(data:updated)).modelResult().status,.failed)
    }
}
