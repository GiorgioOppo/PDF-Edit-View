import AppKit
import CoreGraphics
import PDFKit
import XCTest
@testable import CartaPDF

final class PDFArchiveValidatorTests: XCTestCase {
    func testAllElevenPinnedCataloguesHaveEveryOfficialRuleAndUniqueIdentifiers() throws {
        var total = 0
        for profile in PDFArchiveProfile.allCases {
            let rules = try PDFArchiveValidator.catalogue(profile: profile)
            XCTAssertEqual(rules.count, profile.expectedRuleCount, profile.title)
            XCTAssertEqual(Set(rules.map(\.id)).count, rules.count)
            XCTAssertTrue(rules.allSatisfy { !$0.expression.isEmpty && !$0.requirement.isEmpty && !$0.specification.isEmpty })
            total += rules.count
        }
        XCTAssertEqual(total, 1489)
    }
    func testResourceDiscoverySupportsFlatAndContentsBundlesWithAuthenticatedCatalogues() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let project = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = project.appendingPathComponent("Resources/PDFAProfiles",isDirectory:true)
        for (index,relative) in ["PDFAProfiles","Contents/Resources/PDFAProfiles","CartaPDF_CartaPDF.bundle/PDFAProfiles","CartaPDF_CartaPDF.bundle/Contents/Resources/PDFAProfiles"].enumerated() {
            let root = temporary.appendingPathComponent("layout\(index)",isDirectory:true),directory = root.appendingPathComponent(relative,isDirectory:true)
            try FileManager.default.createDirectory(at:directory.deletingLastPathComponent(),withIntermediateDirectories:true)
            try FileManager.default.copyItem(at:source,to:directory)
            XCTAssertEqual(PDFArchiveValidator.resourceDirectory(searchRoots:[root]),directory)
            XCTAssertEqual(try PDFArchiveValidator.catalogue(profile:.pdfa4f,directory:directory).count,111)
        }
    }
    func testXCTestProductsAreSearchableWithoutEscapingAnInstalledApp() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let directory = temporary.appendingPathComponent("CartaPDF_CartaPDF.bundle/PDFAProfiles",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try Data("{}".utf8).write(to:directory.appendingPathComponent("MANIFEST.json"))
        let test = temporary.appendingPathComponent("CartaPDFPackageTests.xctest",isDirectory:true),app = temporary.appendingPathComponent("CartaPDF.app",isDirectory:true)
        let testRoots = PDFArchiveValidator.resourceSearchRoots(bundleURLs:[test],resourceURLs:[])
        XCTAssertTrue(testRoots.contains(temporary));XCTAssertEqual(PDFArchiveValidator.resourceDirectory(searchRoots:testRoots),directory)
        let appRoots = PDFArchiveValidator.resourceSearchRoots(bundleURLs:[app],resourceURLs:[])
        XCTAssertFalse(appRoots.contains(temporary));XCTAssertNil(PDFArchiveValidator.resourceDirectory(searchRoots:appRoots))
        XCTAssertNil(PDFArchiveValidator.resourceDirectory(searchRoots:[temporary.appendingPathComponent("missing")]))
    }
    func testProfileAwareHeaderAndIdentificationDoNotTreatFourAsTwo() throws {
        let two = PDFArchiveValidator.validate(data: fixture(version: "1.0", part: 2, conformance: "U"), profile: .pdfa2u)
        XCTAssertEqual(try result(two, clause: "6.1.2", number: "1").status, .passed)
        XCTAssertEqual(try result(two, clause: "6.6.4", number: "2").status, .passed)
        let four = PDFArchiveValidator.validate(data: fixture(version: "2.0", part: 4, conformance: nil, revision: "2020"), profile: .pdfa4)
        XCTAssertEqual(try result(four, clause: "6.1.2", number: "1").status, .passed)
        XCTAssertEqual(try result(four, clause: "6.7.3", number: "3").status, .passed)
        XCTAssertEqual(try result(four, clause: "6.7.3", number: "5").status, .passed)
        let wrong = PDFArchiveValidator.validate(data: fixture(version: "1.7", part: 2, conformance: "U"), profile: .pdfa4)
        XCTAssertEqual(try result(wrong, clause: "6.1.2", number: "1").status, .failed)
        XCTAssertEqual(try result(wrong, clause: "6.7.3", number: "2").status, .failed)
        XCTAssertEqual(wrong.verdict, .nonconforming)
    }
    func testEveryProfileRemainsIndeterminateWhenNormativeModelIsIncomplete() throws {
        for profile in PDFArchiveProfile.allCases {
            let report = PDFArchiveValidator.validate(data: fixture(version: profile.part == 4 ? "2.0" : "1.7", part: profile.part,
                conformance: profile == .pdfa4 ? nil : String(profile.rawValue.suffix(1)).uppercased(), revision: profile.part == 4 ? "2020" : nil), profile: profile)
            XCTAssertFalse(report.coverageComplete)
            XCTAssertNotEqual(report.verdict, .conforming)
            XCTAssertTrue(report.unverifiedCount > 0 || !report.scopeGaps.isEmpty)
            if report.failedCount == 0 { XCTAssertEqual(report.verdict,.indeterminate,"Passing catalogue predicates cannot discharge unmodeled normative obligations") }
            XCTAssertEqual(report.rules.count, profile.expectedRuleCount)
            XCTAssertFalse(report.scopeGaps.isEmpty)
        }
    }
    @MainActor
    func testAppleGeneratedPDFA2uHasPassingActualChecksButNeverFalseFullConformity() throws {
        let source = try XCTUnwrap(PDFDocument(data: fixture(version: "1.7", part: 2, conformance: "U")))
        let generated = try PDFNativeProfileConverter.redraw(source, archival: true)
        let declared = try XCTUnwrap(PDFArchiveValidator.declaredProfile(data:generated))
        XCTAssertEqual(declared.part,2)
        let actualReport = PDFArchiveValidator.validate(data:generated,profile:declared)
        XCTAssertNotEqual(actualReport.verdict,.conforming)
        XCTAssertEqual(try result(actualReport,clause:"6.6.4",number:"3").status,.passed)
        let report = PDFArchiveValidator.validate(data: generated, profile: .pdfa2u)
        XCTAssertEqual(try result(report, clause: "6.1.2", number: "1").status, .passed)
        XCTAssertEqual(try result(report, clause: "6.1.2", number: "2").status, .passed)
        XCTAssertEqual(try result(report, clause: "6.6.4", number: "2").status, .passed)
        XCTAssertGreaterThan(report.passedCount, 20)
        XCTAssertNotEqual(report.verdict, .conforming)
        let identification = try result(report, clause: "6.6.4", number: "3")
        if identification.status == .failed {
            XCTAssertEqual(report.verdict, .nonconforming, "Some native outputs identify themselves as 2b; the requested 2u level must not be assumed")
        } else { XCTAssertEqual(report.verdict, .indeterminate) }
    }
    func testTrailerIDsBinaryMarkerAndTrailingBytesAreActuallyChecked() throws {
        var missing = fixture(version: "1.7", part: 2, conformance: "U", id: false)
        let before = PDFArchiveValidator.validate(data: missing, profile: .pdfa2u)
        XCTAssertEqual(try result(before, clause: "6.1.3", number: "1").status, .failed)
        missing += Data("garbage".utf8)
        let after = PDFArchiveValidator.validate(data: missing, profile: .pdfa2u)
        XCTAssertEqual(try result(after, clause: "6.1.3", number: "3").status, .failed)
        var badBinary = fixture(version: "1.7", part: 2, conformance: "U")
        badBinary[badBinary.firstIndex(of: 0xE2)!] = 65
        XCTAssertEqual(try result(PDFArchiveValidator.validate(data: badBinary, profile: .pdfa2u), clause: "6.1.2", number: "2").status, .failed)
    }
    func testActualXMPNamespacesAttributesAndPacketEncodingAreChecked() throws {
        let attribute = "<rdf:Description rdf:about=\"\" xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\" pdfaid:part=\"2\" pdfaid:conformance=\"U\"/>"
        let report = PDFArchiveValidator.validate(data: fixture(version: "1.7", part: 2, conformance: "U", customDescription: attribute), profile: .pdfa2u)
        XCTAssertEqual(try result(report, clause: "6.6.4", number: "2").status, .passed)
        let wrongNamespace = attribute.replacingOccurrences(of: "http://www.aiim.org/pdfa/ns/id/", with: "https://example.invalid/spoof")
        let spoof = PDFArchiveValidator.validate(data: fixture(version: "1.7", part: 2, conformance: "U", customDescription: wrongNamespace), profile: .pdfa2u)
        XCTAssertEqual(try result(spoof, clause: "6.6.4", number: "1").status, .failed)
        let packet = PDFArchiveValidator.validate(data: fixture(version: "1.7", part: 2, conformance: "U", packet: "<?xpacket begin=\"\" bytes=\"2000\" encoding=\"UTF-8\"?>"), profile: .pdfa2u)
        XCTAssertEqual(try result(packet, clause: "6.6.2.1", number: "2").status, .failed)
        XCTAssertEqual(try result(packet, clause: "6.6.2.1", number: "3").status, .failed)
    }
    func testActualActionsHaveDifferentAllowedSetsFor2And4e() throws {
        let data = fixture(version: "2.0", part: 4, conformance: "E", revision: "2020", extraCatalog: "/OpenAction 7 0 R", extras: [7:Data("<< /Type /Action /S /GoTo3DView >>".utf8)])
        let engineering = PDFArchiveValidator.validate(data: data, profile: .pdfa4e)
        XCTAssertEqual(try result(engineering, clause: "6.6.1", number: "1").status, .passed)
        let base = PDFArchiveValidator.validate(data: data, profile: .pdfa4)
        XCTAssertEqual(try result(base, clause: "6.6.1", number: "1").status, .failed)
        let two = PDFArchiveValidator.validate(data: data, profile: .pdfa2u)
        XCTAssertEqual(try result(two, clause: "6.5.1", number: "1").status, .failed)
    }
    func testPDFa4InfoAndFileRequirementsAreDistinct() throws {
        let four = PDFArchiveValidator.validate(data: fixture(version: "2.0", part: 4, conformance: nil, revision: "2020", info: true), profile: .pdfa4)
        XCTAssertEqual(try result(four, clause: "6.1.3", number: "4").status, .failed)
        XCTAssertEqual(try result(four, clause: "6.1.3", number: "5").status, .failed)
        let noFile = PDFArchiveValidator.validate(data: fixture(version: "2.0", part: 4, conformance: "F", revision: "2020"), profile: .pdfa4f)
        XCTAssertEqual(try result(noFile, clause: "6.9", number: "5").status, .failed)
        let attached = try PDFStructureDocument(data: fixture(version: "1.7", part: 2, conformance: "U")).addingAttachments([(name:"data.txt",data:Data("abc".utf8))])
        let two = PDFArchiveValidator.validate(data: attached, profile: .pdfa2u)
        XCTAssertEqual(try result(two, clause: "6.8", number: "5").status, .failed, "These non-PDF bytes prove that the attachment is not a conforming PDF/A document")
        let one = PDFArchiveValidator.validate(data: attached, profile: .pdfa1b)
        XCTAssertEqual(try result(one, clause: "6.1.11", number: "1").status, .failed)
    }
    func testFontEmbeddingUsesActualRenderingModeAndNeverMistakesToUnicodePresenceForUnicodeProof() throws {
        for mode in [0,3] {
            let content = Data("BT /F1 12 Tf \(mode) Tr 10 10 Td (test) Tj ET".utf8)
            let data = fixture(version: "1.7", part: 2, conformance: "U", content: content)
            let report = PDFArchiveValidator.validate(data: data, profile: .pdfa2u)
            XCTAssertEqual(try result(report, clause: "6.2.11.4.1", number: "1").status, mode == 3 ? .passed : .failed)
            XCTAssertNotEqual(report.verdict, .conforming)
            XCTAssertEqual(try result(report, clause:"6.2.11.7.2", number:"1").status, .passed,
                           "WinAnsi has a standard Unicode mapping, independently of embedding and font-program validity")
        }
    }
    func testUnsupportedContentAndCatalogTamperingFailClosedAndReportsRoundTrip() throws {
        let data = fixture(version: "1.7", part: 2, conformance: "U", content: Data("BI /W 1 /H 1 /BPC 8 ID x EI".utf8))
        let report = PDFArchiveValidator.validate(data: data, profile: .pdfa2u)
        XCTAssertEqual(try result(report, clause: "6.2.2", number: "1").status, .notVerified)
        XCTAssertNotEqual(report.verdict, .conforming)
        let restored = try JSONDecoder().decode(PDFArchiveValidationReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(restored.sha256, report.sha256); XCTAssertEqual(restored.rules.count, report.rules.count)
        let missing = PDFArchiveValidator.validate(data: data, profile: .pdfa2u, catalogueDirectory: URL(fileURLWithPath: "/private/tmp/no-such-profile-" + UUID().uuidString))
        XCTAssertEqual(missing.verdict, .indeterminate); XCTAssertTrue(missing.rules.isEmpty)
        XCTAssertTrue(missing.diagnostics.contains { diagnosticContains($0, "Catalogo") })
    }
    func testMalformedPdfNeverBecomesConformingAndStillReportsAllCatalogueRules() throws {
        let report = PDFArchiveValidator.validate(data: Data("%PDF-1.7\n%notbinary\ninvalid".utf8), profile: .pdfa2u)
        XCTAssertEqual(report.rules.count, 146)
        XCTAssertFalse(report.coverageComplete); XCTAssertNotEqual(report.verdict, .conforming)
        XCTAssertGreaterThan(report.unverifiedCount, 100)
        XCTAssertFalse(report.diagnostics.isEmpty)
    }
    func testCatalogBytesCannotBeForgedByChangingTheManifestHash() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = "PDFA-2U.xml", forged = Data("<profile/>".utf8)
        try forged.write(to: directory.appendingPathComponent(file))
        let manifest: [String:Any] = ["upstream_commit":PDFArchiveValidator.catalogueCommit,"profiles":[["file":file,"sha256":"forged","rule_count":146]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("MANIFEST.json"))
        let report = PDFArchiveValidator.validate(data: fixture(version:"1.7",part:2,conformance:"U"), profile:.pdfa2u, catalogueDirectory:directory)
        XCTAssertEqual(report.verdict,.indeterminate); XCTAssertTrue(report.rules.isEmpty)
        XCTAssertTrue(report.diagnostics.contains { diagnosticContains($0, "hash") })
        XCTAssertNil(PDFArchiveValidator.resourceDirectory(searchRoots:[directory.appendingPathComponent("missing-installation")]))
    }
    func testDeclaredProfileUsesUnambiguousActualRDFAndDoesNotValidateOrUpgrade() throws {
        XCTAssertEqual(PDFArchiveValidator.declaredProfile(data:fixture(version:"1.7",part:2,conformance:"B")),.pdfa2b)
        XCTAssertEqual(PDFArchiveValidator.declaredProfile(data:fixture(version:"2.0",part:4,conformance:nil,revision:"2020")),.pdfa4)
        XCTAssertEqual(PDFArchiveValidator.declaredProfile(data:fixture(version:"2.0",part:4,conformance:"F",revision:"2020")),.pdfa4f)
        let spoof = "<rdf:Description xmlns:pdfaid=\"https://example.invalid/\" pdfaid:part=\"2\" pdfaid:conformance=\"U\"/>"
        XCTAssertNil(PDFArchiveValidator.declaredProfile(data:fixture(version:"1.7",part:2,conformance:"U",customDescription:spoof)))
        let duplicate = "<rdf:Description xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\" pdfaid:part=\"2\" pdfaid:conformance=\"U\"><pdfaid:part>3</pdfaid:part></rdf:Description>"
        XCTAssertNil(PDFArchiveValidator.declaredProfile(data:fixture(version:"1.7",part:2,conformance:"U",customDescription:duplicate)))
        XCTAssertNil(PDFArchiveValidator.declaredProfile(data:fixture(version:"1.7",part:1,conformance:"U")))
        let integer = "<rdf:Description xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\" pdfaid:part=\"02\" pdfaid:conformance=\"U\"/>"
        let leadingZero = fixture(version:"1.7",part:2,conformance:"U",customDescription:integer)
        XCTAssertEqual(PDFArchiveValidator.declaredProfile(data:leadingZero),.pdfa2u)
        XCTAssertEqual(try result(PDFArchiveValidator.validate(data:leadingZero,profile:.pdfa2u),clause:"6.6.4",number:"2").status,.passed)
    }
    func testExternalStreamsForbiddenFiltersAndIndirectInterpolateAreDetected() throws {
        let raw = Data([255,0,0])
        let image = Data("<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceRGB /Interpolate 8 0 R /F (external.bin) /Filter /LZWDecode /Length 3 >>\nstream\n".utf8) + raw + Data("\nendstream".utf8)
        let report = PDFArchiveValidator.validate(data: fixture(version:"1.7",part:2,conformance:"U",extras:[7:image,8:Data("true".utf8)]),profile:.pdfa2u)
        XCTAssertEqual(try result(report,clause:"6.1.7.1",number:"3").status,.failed)
        XCTAssertEqual(try result(report,clause:"6.1.7.2",number:"1").status,.failed)
        XCTAssertEqual(try result(report,clause:"6.2.8",number:"3").status,.failed)
    }
    func testActualICCOutputHeaderAndMalformedXMPHaveRealNegativeEvidence() throws {
        let space = try XCTUnwrap(CGColorSpace(name:CGColorSpace.displayP3)), profileData = try XCTUnwrap(space.copyICCData()) as Data
        let stream = Data("<< /N 3 /Length \(profileData.count) >>\nstream\n".utf8) + profileData + Data("\nendstream".utf8)
        let data = fixture(version:"1.7",part:2,conformance:"U",extraCatalog:"/OutputIntents [<< /S /GTS_PDFA1 /DestOutputProfile 7 0 R >>]",extras:[7:stream])
        XCTAssertEqual(try result(PDFArchiveValidator.validate(data:data,profile:.pdfa2u),clause:"6.2.3",number:"1").status,.passed)
        let one = PDFArchiveValidator.validate(data:data,profile:.pdfa1b)
        XCTAssertEqual(try result(one,clause:"6.2.2",number:"1").status,profileData[8] >= 3 ? .failed : .passed)
        let malformed = PDFArchiveValidator.validate(data:fixture(version:"1.7",part:2,conformance:"U",customDescription:"<rdf:Description>"),profile:.pdfa2u)
        XCTAssertEqual(try result(malformed,clause:"6.6.2.1",number:"4").status,.failed)
        XCTAssertEqual(malformed.verdict,.nonconforming)
    }
    func testUndefinedOperatorInsideCompatibilitySectionIsForbiddenAndOpenActionDestinationIsLegal() throws {
        let unknown = PDFArchiveValidator.validate(data:fixture(version:"1.7",part:2,conformance:"U",content:Data("BX BogusOperator EX".utf8)),profile:.pdfa2u)
        XCTAssertEqual(try result(unknown,clause:"6.2.2",number:"1").status,.failed)
        let destination = PDFArchiveValidator.validate(data:fixture(version:"1.7",part:2,conformance:"U",extraCatalog:"/OpenAction [3 0 R /Fit] /Private << /A << /Custom true >> >>"),profile:.pdfa2u)
        XCTAssertEqual(try result(destination,clause:"6.5.1",number:"1").status,.notApplicable)
        XCTAssertEqual(destination.verdict,.indeterminate)
    }
    func testUnusedPatternDoesNotImplyFontUseAndSecondaryMetadataIsChecked() throws {
        let pattern = Data("<< /Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Length 0 >>\nstream\n\nendstream".utf8)
        let patterned = PDFArchiveValidator.validate(data:fixture(version:"1.7",part:2,conformance:"U",extras:[7:pattern]),profile:.pdfa2u)
        XCTAssertEqual(try result(patterned,clause:"6.2.11.4.1",number:"1").status,.notApplicable)
        let xml = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"/></x:xmpmeta>"
        let bytes = Data([0xFF,0xFE]) + (xml.data(using:.utf16LittleEndian) ?? Data())
        let metadata = Data("<< /Type /Metadata /Subtype /XML /Length \(bytes.count) >>\nstream\n".utf8) + bytes + Data("\nendstream".utf8)
        let secondary = PDFArchiveValidator.validate(data:fixture(version:"2.0",part:4,conformance:nil,revision:"2020",extras:[7:metadata]),profile:.pdfa4)
        XCTAssertEqual(try result(secondary,clause:"6.7.2.1",number:"5").status,.failed)
    }
    func testPDFa4fAssociatedFileWithoutEmbeddedFilesNameTreeDoesNotMeetRequirement() throws {
        let file = Data("<< /Type /Filespec /F (data.txt) /UF (data.txt) /AFRelationship /Data /EF << /F 8 0 R >> >>".utf8)
        let bytes = Data("<< /Type /EmbeddedFile /Subtype /text#2Fplain /Length 3 >>\nstream\nabc\nendstream".utf8)
        let data = fixture(version:"2.0",part:4,conformance:"F",revision:"2020",extraCatalog:"/AF [7 0 R]",extras:[7:file,8:bytes])
        XCTAssertEqual(try result(PDFArchiveValidator.validate(data:data,profile:.pdfa4f),clause:"6.9",number:"5").status,.failed)
    }
    func testPrivateApplicationDataNamedFontIsNotAPdfFontResource() throws {
        let data = fixture(version:"1.7",part:2,conformance:"U",extraCatalog:"/PieceInfo << /CartaPDF << /Private << /Font << /NotAFont << /Answer 42 >> >> >> >> >>",content:Data("BT /F1 12 Tf 3 Tr (A) Tj ET".utf8))
        let report = PDFArchiveValidator.validate(data:data,profile:.pdfa2u)
        XCTAssertEqual(try result(report,clause:"6.2.11.2",number:"1").status,.passed)
        XCTAssertEqual(try result(report,clause:"6.2.11.2",number:"2").status,.passed)
        XCTAssertEqual(try result(report,clause:"6.2.11.2",number:"3").status,.passed)
        XCTAssertEqual(report.verdict,.indeterminate)
    }
    private func result(_ report: PDFArchiveValidationReport, clause: String, number: String) throws -> PDFArchiveRuleResult {
        try XCTUnwrap(report.rules.first { $0.clause == clause && $0.testNumber == number }, "Missing \(clause)-\(number) in \(report.profile.title)")
    }
    private func fixture(version: String, part: Int, conformance: String?, revision: String? = nil, id: Bool = true, info: Bool = false, extraCatalog: String = "", extras: [Int:Data] = [:], content: Data = Data(), customDescription: String? = nil, packet: String = "") -> Data {
        let description = customDescription ?? "<rdf:Description rdf:about=\"\" xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\"><pdfaid:part>\(part)</pdfaid:part>\(conformance.map { "<pdfaid:conformance>\($0)</pdfaid:conformance>" } ?? "")\(revision.map { "<pdfaid:rev>\($0)</pdfaid:rev>" } ?? "")</rdf:Description>"
        let xmp = Data((packet + "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">" + description + "</rdf:RDF></x:xmpmeta>").utf8)
        func stream(_ dictionary: String, _ bytes: Data) -> Data { Data("<< \(dictionary) /Length \(bytes.count) >>\nstream\n".utf8) + bytes + Data("\nendstream".utf8) }
        var objects: [Int:Data] = [1:Data("<< /Type /Catalog /Pages 2 0 R /Metadata 4 0 R \(extraCatalog) >>".utf8),
            2:Data("<< /Type /Pages /Count 1 /Kids [3 0 R] >>".utf8), 3:Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 6 0 R >> >> /Contents 5 0 R >>".utf8),
            4:stream("/Type /Metadata /Subtype /XML",xmp), 5:stream("",content), 6:Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".utf8)]
        objects.merge(extras) { _, new in new }
        if info { objects[8] = Data("<< /Producer (Test) >>".utf8) }
        var data = Data(("%PDF-" + version + "\n%").utf8) + Data([0xE2,0xE3,0xCF,0xD3,10]), positions:[Int:Int] = [:]
        for i in objects.keys.sorted() { positions[i] = data.count; data += Data("\(i) 0 obj\n".utf8) + objects[i]! + Data("\nendobj\n".utf8) }
        let start = data.count, size = (objects.keys.max() ?? 0) + 1
        data += Data("xref\n0 \(size)\n0000000000 65535 f \n".utf8)
        for i in 1..<size { data += Data(String(format:"%010lld 00000 %@ \n",Int64(positions[i] ?? 0),positions[i] == nil ? "f" : "n").utf8) }
        data += Data("trailer\n<< /Size \(size) /Root 1 0 R \(id ? "/ID [<1234567890ABCDEF><FEDCBA0987654321>]" : "") \(info ? "/Info 8 0 R" : "") >>\nstartxref\n\(start)\n%%EOF\n".utf8)
        return data
    }
}
