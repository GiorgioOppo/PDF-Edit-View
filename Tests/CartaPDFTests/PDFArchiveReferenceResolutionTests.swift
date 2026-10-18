import Foundation
import XCTest
@testable import CartaPDF

final class PDFArchiveReferenceResolutionTests:XCTestCase {
    private func fixture(_ extras:[Int:Data] = [:],root:String = "1 0 R")->Data {
        var objects:[Int:Data] = [1:Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),2:Data("<< /Type /Pages /Count 1 /Kids [3 0 R] /MediaBox [0 0 200 200] >>".utf8),3:Data("<< /Type /Page /Parent 2 0 R /Resources << >> >>".utf8)]
        objects.merge(extras){_,new in new}
        var data = Data("%PDF-1.7\n%".utf8)+Data([0xE2,0xE3,0xCF,0xD3,10]),offsets:[Int:Int] = [:]
        for number in objects.keys.sorted() { offsets[number] = data.count;data += Data("\(number) 0 obj\n".utf8)+objects[number]!+Data("\nendobj\n".utf8) }
        let xref = data.count,count = objects.keys.max()!+1
        data += Data("xref\n0 \(count)\n0000000000 65535 f \n".utf8)
        for number in 1..<count { data += Data(String(format:"%010lld 00000 %@ \n",Int64(offsets[number] ?? 0),offsets[number] == nil ? "f":"n").utf8) }
        data += Data("trailer\n<< /Root \(root) /Size \(count) /ID [<1234><5678>] >>\nstartxref\n\(xref)\n%%EOF\n".utf8);return data
    }
    private func ref(_ number:Int,_ generation:Int = 0)->PDFSyntaxValue { .reference(.init(number:number,generation:generation)) }
    func testReferenceAliasesResolveValuesAndCanonicalIdentityWithoutChangingPhysicalBodies() throws {
        let reader = try PDFStructureDocument(data:fixture([5:Data("6 0 R".utf8),6:Data("7 0 R".utf8),7:Data("42".utf8)]))
        XCTAssertEqual(try reader.resolve(ref(5))?.int,42)
        XCTAssertEqual(try reader.resolvedObjectID(ref(5)),PDFObjectID(number:7,generation:0))
        XCTAssertEqual(try reader.object(.init(number:5,generation:0)).value.reference,PDFObjectID(number:6,generation:0))
    }
    func testAliasChainsRetainUndefinedFreeAndWrongGenerationNullSemantics() throws {
        let reader = try PDFStructureDocument(data:fixture([5:Data("6 0 R".utf8),7:Data("42".utf8),8:Data("7 1 R".utf8),9:Data("999 0 R".utf8)]))
        for id in [5,8,9] { guard case .null? = try reader.resolve(ref(id)) else { return XCTFail("Riferimento indefinito non null") };XCTAssertNil(try reader.resolvedObjectID(ref(id))) }
    }
    func testAliasCyclesAreIncompleteWhileOrdinaryDictionaryCyclesRemainValues() throws {
        let reader = try PDFStructureDocument(data:fixture([5:Data("6 0 R".utf8),6:Data("5 0 R".utf8),7:Data("<< /Self 7 0 R >>".utf8)]))
        XCTAssertThrowsError(try reader.resolve(ref(5))) { error in guard case PDFStructureError.unsupported = error else { return XCTFail("Ciclo alias deve restare unsupported") } }
        XCTAssertNotNil(try reader.resolve(ref(7))?.dictionary)
    }
    func testAliasDepthBudgetIsNotAProvenMalformedFile() throws {
        var objects:[Int:Data] = [:]
        for number in 5...1005 { objects[number] = Data("\(number+1) 0 R".utf8) };objects[1006] = Data("42".utf8)
        let reader = try PDFStructureDocument(data:fixture(objects))
        XCTAssertThrowsError(try reader.resolve(ref(5))) { error in guard case PDFStructureError.limit = error else { return XCTFail("Budget alias deve essere limit") } }
    }
    func testAliasedCatalogPagesKidsTypesAndParentsHaveCanonicalPageIdentities() throws {
        let reader = try PDFStructureDocument(data:fixture([
            1:Data("<< /Type /Catalog /Pages 12 0 R >>".utf8),2:Data("<< /Type /Pages /Count 1 /Kids 13 0 R /MediaBox [0 0 200 200] >>".utf8),
            3:Data("<< /Type 15 0 R /Parent 16 0 R /Resources null >>".utf8),10:Data("11 0 R".utf8),11:Data("1 0 R".utf8),12:Data("2 0 R".utf8),13:Data("[14 0 R]".utf8),14:Data("3 0 R".utf8),15:Data("/Page".utf8),16:Data("2 0 R".utf8)
        ],root:"10 0 R"))
        XCTAssertEqual(try reader.rootID,PDFObjectID(number:1,generation:0))
        XCTAssertEqual(try reader.pageIDs(),[PDFObjectID(number:3,generation:0)])
        XCTAssertEqual(try reader.inherited("MediaBox",pageID:.init(number:14,generation:0))?.array?.compactMap(\.int),[0,0,200,200])
    }
    func testAliasedStreamLengthAndFilterAreResolvedBeforeDecoding() throws {
        let body = Data("<< /Length 6 0 R /Filter 8 0 R >>\nstream\n4142>\nendstream".utf8)
        let reader = try PDFStructureDocument(data:fixture([5:body,6:Data("7 0 R".utf8),7:Data("5".utf8),8:Data("9 0 R".utf8),9:Data("/ASCIIHexDecode".utf8)]))
        XCTAssertEqual(try reader.decodedStream(.init(number:5,generation:0)),Data("AB".utf8))
    }
    func testCompressedObjectHeaderMayUseExternalIndirectIntegerAliases() throws {
        var data = Data("%PDF-1.7\n%".utf8)+Data([0xE2,0xE3,0xCF,0xD3,10]),offsets:[Int:Int] = [:]
        let catalog = Data("1 0 << /Type /Catalog /Pages 2 0 R >>".utf8)
        let objects:[Int:Data] = [2:Data("<< /Type /Pages /Count 1 /Kids [3 0 R] >>".utf8),3:Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>".utf8),4:Data("<< /Type /ObjStm /N 5 0 R /First 7 0 R /Length \(catalog.count) >>\nstream\n".utf8)+catalog+Data("\nendstream".utf8),5:Data("6 0 R".utf8),6:Data("1".utf8),7:Data("8 0 R".utf8),8:Data("4".utf8)]
        for n in objects.keys.sorted() { offsets[n] = data.count;data += Data("\(n) 0 obj\n".utf8)+objects[n]!+Data("\nendobj\n".utf8) }
        let xref = data.count;offsets[9] = xref
        func entry(_ type:UInt8,_ a:Int,_ b:Int)->Data { Data([type,UInt8(a>>24 & 255),UInt8(a>>16 & 255),UInt8(a>>8 & 255),UInt8(a & 255),UInt8(b>>8 & 255),UInt8(b & 255)]) }
        var table = entry(0,0,65535)+entry(2,4,0)
        for n in 2...9 { table += entry(1,offsets[n]!,0) }
        data += Data("9 0 obj\n<< /Type /XRef /Size 10 /W [1 4 2] /Root 1 0 R /Length \(table.count) >>\nstream\n".utf8)+table+Data("\nendstream\nendobj\nstartxref\n\(xref)\n%%EOF\n".utf8)
        let reader = try PDFStructureDocument(data:data)
        XCTAssertEqual(try reader.dictionary(ref(1))["Type"]?.name,"Catalog")
        XCTAssertEqual(try reader.pageIDs().count,1)
    }
    func testAliasedContentsStreamsAndArraysUseTerminalIdentities() throws {
        let body = Data("<< /Length 3 >>\nstream\nq Q\nendstream".utf8)
        for contents in ["5 0 R","7 0 R"] {
            let reader = try PDFStructureDocument(data:fixture([3:Data("<< /Type /Page /Parent 2 0 R /Contents \(contents) >>".utf8),5:Data("6 0 R".utf8),6:body,7:Data("8 0 R".utf8),8:Data("[5 0 R 6 0 R]".utf8)]))
            XCTAssertEqual(try reader.contentStreamIDs(on:.init(number:3,generation:0)),contents == "5 0 R" ? [.init(number:6,generation:0)]:[.init(number:6,generation:0),.init(number:6,generation:0)])
            XCTAssertEqual(try reader.decodedStream(.init(number:5,generation:0)),Data("q Q".utf8))
            XCTAssertEqual(try reader.decodedStream(.init(number:6,generation:0)),Data("q Q".utf8))
        }
    }
    func testNullContentsIsOmissionButNonStreamArrayMembersAreInvalid() throws {
        for contents in ["null","99 0 R","5 0 R"] {
            let reader = try PDFStructureDocument(data:fixture([3:Data("<< /Type /Page /Parent 2 0 R /Contents \(contents) >>".utf8),5:Data("null".utf8)]))
            XCTAssertEqual(try reader.contentStreamIDs(on:.init(number:3,generation:0)),[])
        }
        for contents in ["[null]","[99 0 R]","[42]","(text)"] {
            let reader = try PDFStructureDocument(data:fixture([3:Data("<< /Type /Page /Parent 2 0 R /Contents \(contents) >>".utf8)]))
            XCTAssertThrowsError(try reader.contentStreamIDs(on:.init(number:3,generation:0))) { error in guard case PDFStructureError.malformed = error else { return XCTFail("Tipo Contents provatamente errato") } }
        }
    }
    func testAliasedMetadataKeepsDeclarationAndStreamRequirement() throws {
        let xml = Data("<x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'><rdf:Description rdf:about='' xmlns:pdfaid='http://www.aiim.org/pdfa/ns/id/' pdfaid:part='4' pdfaid:conformance='F'/></rdf:RDF></x:xmpmeta>".utf8)
        let data = fixture([1:Data("<< /Type /Catalog /Pages 2 0 R /Metadata 5 0 R >>".utf8),5:Data("6 0 R".utf8),6:Data("<< /Type /Metadata /Subtype /XML /Length \(xml.count) >>\nstream\n".utf8)+xml+Data("\nendstream".utf8)])
        XCTAssertEqual(PDFArchiveValidator.declaredProfile(data:data),.pdfa4f)
        let report = PDFArchiveValidator.validate(data:data,profile:.pdfa4f)
        let contains = report.rules.filter{$0.objectType == "PDDocument" && $0.requirement.contains("metadata")}
        XCTAssertFalse(contains.contains{$0.status == .failed})
        XCTAssertFalse(report.modelChecks.contains{$0.objectType == "ISO32000Syntax" && $0.status == .failed})
    }
    func testAliasStreamCycleRetainsUnsupportedEvidence() throws {
        let reader = try PDFStructureDocument(data:fixture([5:Data("6 0 R".utf8),6:Data("5 0 R".utf8)]))
        XCTAssertThrowsError(try reader.decodedStream(.init(number:5,generation:0))) { error in guard case PDFStructureError.unsupported = error else { return XCTFail("Ciclo stream non è prova malformed") } }
    }
    func testCancellationInterruptsReferenceResolution() async throws {
        let reader = try PDFStructureDocument(data:fixture([5:Data("42".utf8)]))
        let task = Task { try? await Task.sleep(nanoseconds:1_000_000_000);return try reader.resolve(self.ref(5)) }
        task.cancel()
        do { _ = try await task.value;XCTFail("Cancellazione ignorata") } catch is CancellationError { }
    }
}
