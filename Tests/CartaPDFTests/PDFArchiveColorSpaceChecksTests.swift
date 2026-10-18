import Foundation
import XCTest
@testable import CartaPDF

final class PDFArchiveColorSpaceChecksTests:XCTestCase {
    private func fixture(_ color:String,extra:[Int:Data] = [:],content:String = "",resources:String = "",colors:String = "")->Data {
        var objects:[Int:Data] = [1:Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),2:Data("<< /Type /Pages /Count 1 /Kids [3 0 R] >>".utf8),3:Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /ColorSpace << /C \(color) \(colors) >> \(resources) >> /Contents 4 0 R >>".utf8),4:stream("",Data(content.utf8))]
        objects.merge(extra){_,new in new};var data = Data("%PDF-1.7\n%".utf8)+Data([0xE2,0xE3,0xCF,0xD3,10]),offsets:[Int:Int] = [:]
        for number in objects.keys.sorted() { offsets[number] = data.count;data += Data("\(number) 0 obj\n".utf8)+objects[number]!+Data("\nendobj\n".utf8) }
        let start = data.count,count = objects.keys.max()!+1;data += Data("xref\n0 \(count)\n0000000000 65535 f \n".utf8)
        for number in 1..<count { data += Data(String(format:"%010lld 00000 %@ \n",Int64(offsets[number] ?? 0),offsets[number] == nil ? "f":"n").utf8) }
        data += Data("trailer\n<< /Root 1 0 R /Size \(count) /ID [<1234><5678>] >>\nstartxref\n\(start)\n%%EOF\n".utf8);return data
    }
    private func stream(_ dictionary:String,_ bytes:Data)->Data { Data("<< /Length \(bytes.count) \(dictionary) >>\nstream\n".utf8)+bytes+Data("\nendstream".utf8) }
    private func checks(_ color:String,extra:[Int:Data] = [:],profile:PDFArchiveProfile = .pdfa2u,content:String = "",resources:String = "",colors:String = "") throws -> [PDFArchiveRuleResult] {
        let reader = try PDFStructureDocument(data:fixture(color,extra:extra,content:content,resources:resources,colors:colors))
        return PDFArchiveObjectChecks(reader:reader,profile:profile).modelChecks.filter{$0.objectType == "ColorSpaceModel"}
    }
    private func state(_ color:String,extra:[Int:Data] = [:],profile:PDFArchiveProfile = .pdfa2u) throws -> PDFArchiveRuleStatus? { try checks(color,extra:extra,profile:profile).first?.status }
    private let function = "<< /FunctionType 2 /Domain [0 1] /N 1 >>"
    func testCalibratedWhiteBlackGammaAndMatrixPositiveDefaults() throws {
        XCTAssertEqual(try state("[/CalGray << /WhitePoint [.95 1 1.09] /Gamma 2.2 >>]"),.passed)
        XCTAssertEqual(try state("[/CalRGB << /WhitePoint [1 1 1] /BlackPoint [0 .1 0] /Gamma [1 2 3] /Matrix [1 0 0 0 1 0 0 0 1] >>]"),.passed)
        XCTAssertEqual(try state("[/Lab << /WhitePoint [1 1 1] /Range [-128 127 -128 127] >>]"),.passed)
    }
    func testWhitePointRequiredAndExactlyNormalizedWithNoDoubleRounding() throws {
        for value in ["[]","[0 1 1]","[1 .99999999999999999999999999999999999999999999999 1]","[1 1 -1]"] { XCTAssertEqual(try state("[/CalGray << /WhitePoint \(value) >>]"),.failed) }
        XCTAssertEqual(try state("[/CalRGB << >>]"),.failed)
        XCTAssertEqual(try state("[/CalGray << /WhitePoint [.00000000000000000000000000000000000000000000001 1 1] >>]"),.passed)
    }
    func testOptionalNullCalibrationParametersAndAliasedNumbers() throws {
        XCTAssertEqual(try state("[/CalGray << /WhitePoint [5 0 R 6 0 R 1] /BlackPoint null /Gamma 7 0 R >>]",extra:[5:Data(".95".utf8),6:Data("1.000".utf8),7:Data("null".utf8)]),.passed)
        XCTAssertEqual(try state("[/Lab << /WhitePoint null >>]"),.failed)
    }
    func testCalibrationVectorTypesDimensionsAndProvenRestrictions() throws {
        for parameters in ["/BlackPoint [-1 0 0]","/BlackPoint [0 0]","/Gamma 0","/Gamma /One"] { XCTAssertEqual(try state("[/CalGray << /WhitePoint [1 1 1] \(parameters) >>]"),.failed) }
        XCTAssertEqual(try state("[/CalRGB << /WhitePoint [1 1 1] /Matrix [1 0 0] >>]"),.failed)
        XCTAssertEqual(try state("[/CalRGB << /WhitePoint [1 1 1] /Gamma [1 2] >>]"),.failed)
        XCTAssertEqual(try state("[/CalRGB << /WhitePoint [1 1 1] /Gamma [0 1 1] >>]"),.notVerified)
    }
    func testLabRangeOrderingAllowsDegenerateBounds() throws {
        XCTAssertEqual(try state("[/Lab << /WhitePoint [1 1 1] /Range [0 0 -1 -1] >>]"),.passed)
        XCTAssertEqual(try state("[/Lab << /WhitePoint [1 1 1] /Range [1 0 0 1] >>]"),.failed)
    }
    func testIndexedLookupStringsExactExtentAndHighValueInteger() throws {
        XCTAssertEqual(try state("[/Indexed /DeviceRGB 1 <000000ffffff>]"),.passed)
        for color in ["[/Indexed /DeviceRGB 1 <000000>]","[/Indexed /DeviceRGB 0 <00000000>]","[/Indexed /DeviceGray 1.0 <0000>]","[/Indexed /DeviceGray 256 <00>]","[/Indexed /DeviceGray -1 <>]"] { XCTAssertEqual(try state(color),.failed,color) }
    }
    func testIndexedLookupFilteredStreamAliasesAndNamedBase() throws {
        let extra = [5:Data("6 0 R".utf8),6:stream("/Filter /ASCIIHexDecode",Data("000000ffffff>".utf8))]
        let rows = try checks("[/Indexed /Base 1 5 0 R]",extra:extra,colors:"/Base /DeviceRGB")
        XCTAssertEqual(rows.first?.status,.passed)
    }
    func testIndexedForbiddenBasesAndUnresolvedCodecRemainDistinct() throws {
        XCTAssertEqual(try state("[/Indexed /Pattern 0 <>]"),.failed)
        XCTAssertEqual(try state("[/Indexed [/Indexed /DeviceGray 0 <00>] 0 <00>]"),.failed)
        XCTAssertEqual(try state("[/Indexed /DeviceGray 0 5 0 R]",extra:[5:stream("/Filter /FutureCodec",Data([0]))]),.notVerified)
    }
    func testSeparationAllNoneAndAlternateRestrictions() throws {
        for name in ["Spot","All","None"] { XCTAssertEqual(try state("[/Separation /\(name) /DeviceGray \(function)]"),.passed) }
        XCTAssertEqual(try state("[/Separation /Spot /Pattern \(function)]"),.failed)
        XCTAssertEqual(try state("[/Separation (Spot) /DeviceGray \(function)]"),.failed)
    }
    func testTintInputAndOutputDimensionsMatchColorSpaces() throws {
        XCTAssertEqual(try state("[/DeviceN [/A /B] /DeviceGray \(function)]"),.failed)
        XCTAssertEqual(try state("[/Separation /A /DeviceRGB \(function)]"),.failed)
        XCTAssertEqual(try state("[/Separation /A /DeviceRGB << /FunctionType 2 /Domain [0 1] /C0 [0 0 0] /C1 [1 1 1] /N 1 >>]"),.passed)
    }
    func testDeviceNDistinctNamesAllAndRepeatedNone() throws {
        let f = "<< /FunctionType 2 /Domain [0 1 0 1] /Range [0 1] /N 1 >>"
        XCTAssertEqual(try state("[/DeviceN [/A /A] /DeviceGray \(f)]"),.failed)
        XCTAssertEqual(try state("[/DeviceN [/All /B] /DeviceGray \(f)]"),.failed)
        XCTAssertEqual(try state("[/DeviceN [/None /None] /DeviceGray \(f)]"),.passed)
    }
    func testNChannelForbidsNoneAndKeepsUnmodeledRelationshipsUnknown() throws {
        XCTAssertEqual(try state("[/DeviceN [/None] /DeviceGray \(function) << /Subtype /NChannel >>]"),.failed)
        XCTAssertEqual(try state("[/DeviceN [/Spot] /DeviceGray \(function) << /Subtype /NChannel >>]"),.notVerified)
        XCTAssertEqual(try state("[/DeviceN [/Spot] /DeviceGray \(function) << /Subtype /Other >>]"),.failed)
    }
    func testColorantsRequireMatchingSeparationNames() throws {
        XCTAssertEqual(try state("[/DeviceN [/Spot] /DeviceGray \(function) << /Colorants << /Spot [/Separation /Other /DeviceGray \(function)] >> >>]"),.failed)
        XCTAssertEqual(try state("[/DeviceN [/Spot] /DeviceGray \(function) << /Colorants << /Spot [/Separation /Spot /DeviceGray \(function)] >> >>]"),.passed)
    }
    func testICCBasedStreamCountRangeAndAlternateDimensions() throws {
        func profile(_ entries:String)->[Int:Data] { [5:Data("6 0 R".utf8),6:stream(entries,Data("ICC checked separately".utf8))] }
        XCTAssertEqual(try state("[/ICCBased 5 0 R]",extra:profile("/N 3 /Range [0 1 0 1 0 1] /Alternate /DeviceRGB")),.passed)
        XCTAssertEqual(try state("[/ICCBased 5 0 R]",extra:profile("/N 3 /Alternate /DeviceGray")),.failed)
        XCTAssertEqual(try state("[/ICCBased 5 0 R]",extra:profile("/N 2")),.failed)
        XCTAssertEqual(try state("[/ICCBased 5 0 R]",extra:profile("/N 1 /Range [1 0]")),.failed)
    }
    func testPrivateColorLookingDictionariesAreNeverInventoried() throws {
        let data = fixture("/DeviceGray",extra:[7:Data("<< /WhitePoint [0 0 0] /ColorSpace [/Indexed /Pattern 0 <>] >>".utf8)])
        XCTAssertTrue(PDFArchiveObjectChecks(reader:try PDFStructureDocument(data:data),profile:.pdfa4).modelChecks.isEmpty)
    }
    func testAllElevenProfilesRetainGlobalScopeGaps() throws {
        for profile in PDFArchiveProfile.allCases {
            XCTAssertEqual(try state("[/CalGray << /WhitePoint [1 1 1] >>]",profile:profile),.passed)
            let report = PDFArchiveValidator.validate(data:fixture("[/CalGray << /WhitePoint [0 1 1] >>]"),profile:profile)
            XCTAssertTrue(report.modelChecks.contains{$0.objectType == "ColorSpaceModel" && $0.status == .failed})
            XCTAssertNotEqual(report.verdict,.conforming)
        }
    }
    func testAliasCyclesAndUnknownFamiliesRemainIncomplete() throws {
        XCTAssertEqual(try state("5 0 R",extra:[5:Data("6 0 R".utf8),6:Data("5 0 R".utf8)]),.notVerified)
        XCTAssertEqual(try state("[/FutureColour 1 2]"),.notVerified)
    }
    func testImageAndInlineColorSpacesAreReachedThroughRoles() throws {
        let image = stream("/Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace [/CalGray << /WhitePoint [0 1 1] >>]",Data([0]))
        let rows = try checks("/DeviceGray",extra:[5:image],content:"/I Do",resources:"/XObject << /I 5 0 R >>")
        XCTAssertTrue(rows.contains{$0.status == .failed && $0.locations.first?.contains("ColorSpace") == true})
        let inline = try checks("/DeviceGray",content:"BI /W 1 /H 1 /BPC 8 /CS [/CalGray << /WhitePoint [0 1 1] >>] ID x EI")
        XCTAssertTrue(inline.contains{$0.status == .failed})
    }
    func testNullAndUndefinedColorantsDictionaryEntriesAreOmitted() throws {
        let color = "[/DeviceN [/Spot] /DeviceGray \(function) << /Colorants << /Unused null /Also 99 0 R /Alias 5 0 R >> >>]"
        XCTAssertEqual(try state(color,extra:[5:Data("null".utf8)]),.passed)
    }
    func testReportRowLimitPreservesLateProvenFailureAndUnknownSummary() throws {
        let reader = try PDFStructureDocument(data:fixture("/DeviceGray")),checks = PDFArchiveColorSpaceChecks(reader:reader,part:4)
        var good = PDFSyntaxLexer(Data("[/CalGray << /WhitePoint [1 1 1] >>]".utf8)),bad = PDFSyntaxLexer(Data("[/CalGray << /WhitePoint [0 1 1] >>]".utf8))
        let value = try good.value()
        for i in 0..<1025 { checks.record(value,resources:[:],location:"space\(i)") }
        checks.record(try bad.value(),resources:[:],location:"late-failure")
        XCTAssertEqual(checks.modelChecks.count,1026)
        XCTAssertTrue(checks.modelChecks.contains{$0.status == .failed && $0.locations == ["late-failure"]})
        XCTAssertTrue(checks.modelChecks.contains{$0.status == .notVerified})
    }
    func testAbbreviationsArePassedOnlyWithinExplicitInlineContext() throws {
        XCTAssertEqual(try state("[/I /RGB 0 <000000>]"),.notVerified)
        let reader = try PDFStructureDocument(data:fixture("/DeviceGray")),checks = PDFArchiveColorSpaceChecks(reader:reader,part:4)
        var lexer = PDFSyntaxLexer(Data("[/I /RGB 0 <000000>]".utf8))
        checks.record(try lexer.value(),resources:[:],location:"inline",inline:true)
        XCTAssertEqual(checks.modelChecks.first?.status,.passed)
    }
    func testCancellationNeverTurnsIntoProvenColorViolation() async throws {
        let reader = try PDFStructureDocument(data:fixture("[/CalGray << /WhitePoint [1 1 1] >>]"))
        let task = Task { try? await Task.sleep(nanoseconds:1_000_000_000);return PDFArchiveObjectChecks(reader:reader,profile:.pdfa4).modelChecks }
        task.cancel();let rows = await task.value
        XCTAssertFalse(rows.contains{$0.status == .failed});XCTAssertTrue(rows.contains{$0.status == .notVerified})
    }
}
