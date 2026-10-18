import Foundation
import XCTest
@testable import CartaPDF

final class PDFArchiveFunctionChecksTests:XCTestCase {
    private func stream(_ data:Data,_ d:String)->Data { Data("<< \(d) /Length \(data.count) >>\nstream\n".utf8)+data+Data("\nendstream".utf8) }
    private func fixture(_ function:Data,resources:String = "<< /ColorSpace << /CS [/Separation /Spot /DeviceGray 5 0 R] >> >>",extras:[Int:Data] = [:],catalog:String = "",page:String = "")->Data {
        var objects:[Int:Data] = [1:Data("<< /Type /Catalog /Pages 2 0 R \(catalog) >>".utf8),2:Data("<< /Type /Pages /Count 1 /Kids [3 0 R] >>".utf8),3:Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources \(resources) \(page) >>".utf8),5:function]
        objects.merge(extras){_,new in new}
        var data = Data("%PDF-2.0\n%".utf8)+Data([0xE2,0xE3,0xCF,0xD3,10]),offsets:[Int:Int] = [:]
        for number in objects.keys.sorted() { offsets[number] = data.count;data += Data("\(number) 0 obj\n".utf8)+objects[number]!+Data("\nendobj\n".utf8) }
        let xref = data.count,count = objects.keys.max()!+1
        data += Data("xref\n0 \(count)\n0000000000 65535 f \n".utf8)
        for number in 1..<count { data += Data(String(format:"%010lld 00000 %@ \n",Int64(offsets[number] ?? 0),offsets[number] == nil ? "f":"n").utf8) }
        data += Data("trailer\n<< /Root 1 0 R /Size \(count) /ID [<1234><5678>] >>\nstartxref\n\(xref)\n%%EOF\n".utf8);return data
    }
    private let linear = "<< /FunctionType 2 /Domain [0 1] /N 1 >>"
    private func rows(_ function:String,resources:String = "<< /ColorSpace << /CS [/Separation /Spot /DeviceGray 5 0 R] >> >>",extras:[Int:Data] = [:]) throws -> [PDFArchiveRuleResult] { try check(fixture(Data(function.utf8),resources:resources,extras:extras)) }
    private func check(_ data:Data) throws -> [PDFArchiveRuleResult] { PDFArchiveFunctionChecks(reader:try PDFStructureDocument(data:data)).modelChecks }
    private func allPass(_ rows:[PDFArchiveRuleResult],file:StaticString = #filePath,line:UInt = #line) { XCTAssertFalse(rows.isEmpty,file:file,line:line);XCTAssertTrue(rows.allSatisfy{$0.status == .passed},rows.map(\.detail).joined(separator:"; "),file:file,line:line) }
    func testExponentialDefaultsNullOmissionAndIndirectValues() throws {
        allPass(try rows(linear))
        allPass(try rows("<< /FunctionType 6 0 R /Domain 7 0 R /Range null /C0 null /C1 8 0 R /N 9 0 R >>",extras:[6:Data("2".utf8),7:Data("[0 1]".utf8),8:Data("null".utf8),9:Data("1".utf8)]))
    }
    func testExponentialDomainConstraintsDistinguishIntegerAndFractionalExponents() throws {
        for body in ["/Domain [-1 1] /N .5","/Domain [0 1] /N -1","/Domain [-1 1] /N -2"] {
            XCTAssertTrue(try rows("<< /FunctionType 2 \(body) >>").contains{$0.status == .failed})
        }
        allPass(try rows("<< /FunctionType 2 /Domain [-2 -1] /N -1 >>"))
        allPass(try rows("<< /FunctionType 2 /Domain [-1 1] /N 2.0000 >>"))
    }
    func testDimensionsOfExponentialCoefficientsRangeAndInputsAreIndependent() throws {
        for body in ["/Domain [0 1 0 1] /N 1","/Domain [0 1] /C0 [0 0] /N 1","/Domain [0 1] /Range [0 1 0 1] /N 1"] {
            XCTAssertTrue(try rows("<< /FunctionType 2 \(body) >>").contains{$0.status == .failed})
        }
    }
    func testExactDecimalOrderingAndExponentIntegralityDoNotUseDouble() throws {
        XCTAssertTrue(try rows("<< /FunctionType 2 /Domain [0.10000000000000000000000001 .1] /N 1 >>").contains{$0.status == .failed})
        XCTAssertTrue(try rows("<< /FunctionType 2 /Domain [-1 1] /N 1.00000000000000000000000001 >>").contains{$0.status == .failed})
        let huge = String(repeating:"9",count:8000)
        allPass(try rows("<< /FunctionType 2 /Domain [0 \(huge)] /N 1 >>"))
        allPass(try rows("<< /FunctionType 2 /Domain [-0002.000 -01.0] /N -1 >>"))
    }
    func testSampledPackedBitsRequireEnoughBytesButAllowExtraBytes() throws {
        let dictionary = "/FunctionType 0 /Domain [-1 1 -1 1] /Range [-1 1] /Size [21 31] /BitsPerSample 4"
        let resources = "<< /Shading << /S << /ShadingType 1 /ColorSpace /DeviceGray /Function 5 0 R >> >> >>"
        for count in [326,327] { allPass(try check(fixture(stream(Data(repeating:0,count:count),dictionary),resources:resources))) }
        XCTAssertTrue(try check(fixture(stream(Data(repeating:0,count:325),dictionary),resources:resources)).contains{$0.status == .failed && diagnosticContains($0.detail, "corto")})
    }
    func testSampledIntegerWidthsOrderAndArrayDimensions() throws {
        for bits in [1,2,4,8,12,16,24,32] {
            allPass(try check(fixture(stream(Data(repeating:0,count:(bits+7)/8),"/FunctionType 0 /Domain [0 1] /Range [0 1] /Size [1] /BitsPerSample \(bits) /Order 3"))))
        }
        for extra in ["/Size [1] /BitsPerSample 3","/Size [0] /BitsPerSample 8","/Size [1] /BitsPerSample 8 /Order 2","/Size [1] /BitsPerSample 8 /Encode [0]","/Size [1] /BitsPerSample 8 /Decode [0]"] {
            XCTAssertTrue(try check(fixture(stream(Data([0]),"/FunctionType 0 /Domain [0 1] /Range [0 1] "+extra))).contains{$0.status == .failed})
        }
    }
    func testSampledStreamRequirementUnknownFilterAndApplicationBudget() throws {
        XCTAssertTrue(try rows("<< /FunctionType 0 /Domain [0 1] /Range [0 1] /Size [1] /BitsPerSample 8 >>").contains{$0.status == .failed})
        let unsupported = stream(Data([0]),"/FunctionType 0 /Domain [0 1] /Range [0 1] /Size [1] /BitsPerSample 8 /Filter /UnknownFilter")
        let unknown = try check(fixture(unsupported));XCTAssertTrue(unknown.contains{$0.status == .notVerified});XCTAssertFalse(unknown.contains{$0.status == .failed})
        let budget = stream(Data([0]),"/FunctionType 0 /Domain [0 1] /Range [0 1] /Size [99999999999999999999999999999] /BitsPerSample 8")
        XCTAssertTrue(try check(fixture(budget)).contains{$0.status == .notVerified})
    }
    func testStitchingAllowsReverseEncodeAndSingleDegenerateDomain() throws {
        allPass(try rows("<< /FunctionType 3 /Domain [0 0] /Functions [6 0 R] /Bounds [] /Encode [1 0] >>",extras:[6:Data(linear.utf8)]))
        allPass(try rows("<< /FunctionType 3 /Domain [0 1] /Functions [6 0 R 6 0 R] /Bounds [1] /Encode [0 1 0 1] >>",extras:[6:Data(linear.utf8)]))
    }
    func testStitchingRejectsUnorderedBoundsAndDifferentOutputDimensions() throws {
        XCTAssertTrue(try rows("<< /FunctionType 3 /Domain [0 1] /Functions [6 0 R 6 0 R] /Bounds [0] /Encode [0 1 0 1] >>",extras:[6:Data(linear.utf8)]).contains{$0.status == .failed})
        XCTAssertTrue(try rows("<< /FunctionType 3 /Domain [0 1] /Functions [6 0 R 6 0 R 6 0 R] /Bounds [.5 .5] /Encode [0 1 0 1 0 1] >>",extras:[6:Data(linear.utf8)]).contains{$0.status == .failed})
        let two = "<< /FunctionType 2 /Domain [0 1] /N 1 /C0 [0 0] /C1 [1 1] >>"
        XCTAssertTrue(try rows("<< /FunctionType 3 /Domain [0 1] /Functions [6 0 R 7 0 R] /Bounds [.5] /Encode [0 1 0 1] >>",extras:[6:Data(linear.utf8),7:Data(two.utf8)]).contains{$0.status == .failed})
    }
    func testFunctionCyclesCannotBecomeAnAbsentSubfunction() throws {
        let result = try rows("<< /FunctionType 3 /Domain [0 1] /Functions [5 0 R] /Bounds [] /Encode [0 1] >>")
        XCTAssertTrue(result.contains{$0.status == .failed && diagnosticContains($0.detail, "ricorsivo")})
    }
    private func calculator(_ program:String) throws -> [PDFArchiveRuleResult] { try check(fixture(stream(Data(program.utf8),"/FunctionType 4 /Domain [0 1] /Range [0 1]"))) }
    func testCalculatorGrammarAndKnownConditionalPathsStayDistinctFromFullExecution() throws {
        for program in ["{ dup mul }","{ % comment\n true {1 add} if }","{false {pop 2} {pop 3} ifelse}"] {
            let result = try calculator(program);XCTAssertFalse(result.contains{$0.status == .failed},result.map(\.detail).joined(separator:"; "));XCTAssertTrue(result.contains{$0.status == .notVerified})
        }
    }
    func testCalculatorRejectsForbiddenTokensAndMalformedConditionalSyntax() throws {
        for program in ["dup","{ /Name }","{ (text) }","{ [1] }","{ 1e3 }","{ true if }","{ {1} }","{true {1} {2} if}","{dup} 1","{dup"] {
            XCTAssertTrue(try calculator(program).contains{$0.status == .failed},program)
        }
    }
    func testCalculatorProvesStackTypeAndConstantArithmeticErrors() throws {
        for program in ["{pop pop}","{true add}","{pop true}","{dup}","{pop 1 0 div}","{pop -1 sqrt}","{pop 0 log}","{pop 1 -1 index}"] {
            XCTAssertTrue(try calculator(program).contains{$0.status == .failed},program)
        }
    }
    func testObservedThreeOutputCalculatorActuallyLeavesFourValues() throws {
        let resources = "<< /ColorSpace << /CS [/Separation /Spot /DeviceRGB 5 0 R] >> >>"
        let d = "/FunctionType 4 /Domain [0 1] /Range [0 1 0 1 0 1]"
        let original = "{0 exch 0 exch 0}",repaired = "{0 exch 0       }"
        XCTAssertEqual(original.utf8.count,repaired.utf8.count)
        XCTAssertTrue(try check(fixture(stream(Data(original.utf8),d),resources:resources)).contains{$0.status == .failed && diagnosticContains($0.detail, "risultati")})
        let fixed = try check(fixture(stream(Data(repaired.utf8),d),resources:resources))
        XCTAssertFalse(fixed.contains{$0.status == .failed});XCTAssertTrue(fixed.contains{$0.status == .notVerified})
    }
    func testCalculatorDynamicBranchesAndIndicesNeverManufactureFailureWitnesses() throws {
        for program in ["{dup 0 gt {pop 1} {pop 2} ifelse}","{dup index}","{.0 not}","{pop 2147483647 1 add 0 gt {pop} if}"] {
            let result = try calculator(program);XCTAssertFalse(result.contains{$0.status == .failed},program);XCTAssertTrue(result.contains{$0.status == .notVerified})
        }
    }
    func testPrivateFunctionTypeKeysAreNotGuessedToBeFunctions() throws {
        let data = fixture(Data(linear.utf8),resources:"<< >>",catalog:"/Private << /FunctionType 999 /Domain [1 0] >>")
        XCTAssertTrue(try check(data).isEmpty)
    }
    func testSharedFunctionIsCheckedAgainstEachTintContext() throws {
        let resources = "<< /ColorSpace << /A [/Separation /A /DeviceGray 5 0 R] /B [/DeviceN [/One /Two] /DeviceRGB 5 0 R] >> >>"
        let result = try rows(linear,resources:resources)
        XCTAssertTrue(result.contains{$0.status == .passed});XCTAssertTrue(result.contains{$0.status == .failed && diagnosticContains($0.detail, "contesto")})
    }
    func testUnusedFormAndAppearanceResourceFunctionsAreInventoried() throws {
        let bad = Data("<< /FunctionType 2 /Domain [1 0] /N 1 >>".utf8)
        let form = stream(Data(),"/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources << /ColorSpace << /CS [/Separation /Spot /DeviceGray 5 0 R] >> >>")
        let data = fixture(bad,resources:"<< /XObject << /Unused 6 0 R >> >>",extras:[6:form])
        XCTAssertTrue(try check(data).contains{$0.status == .failed})
        let appearance = fixture(bad,resources:"<< >>",extras:[6:form,7:Data("<< /Subtype /Widget /AP << /N 6 0 R >> >>".utf8)],page:"/Annots [7 0 R]")
        XCTAssertTrue(try check(appearance).contains{$0.status == .failed})
    }
    func testTransferArraysAndNullEntriesUseTheirSemanticContext() throws {
        allPass(try rows(linear,resources:"<< /ExtGState << /G << /TR [5 0 R 5 0 R 5 0 R 5 0 R] /TR2 null >> >> >>"))
        XCTAssertTrue(try rows(linear,resources:"<< /ExtGState << /G << /TR [5 0 R] >> >> >>").contains{$0.status == .failed})
    }
    func testNullInheritedPageEntriesDoNotHideParentResourcesOrBounds() throws {
        let parent = "<< /Type /Pages /Count 1 /Kids [3 0 R] /Resources << /ColorSpace << /CS [/Separation /Spot /DeviceGray 5 0 R] >> >> /MediaBox [0 0 200 200] /Rotate 90 >>"
        let page = "<< /Type /Page /Parent 2 0 R /Resources null /MediaBox 6 0 R /Rotate 99 0 R >>"
        let data = fixture(Data("<< /FunctionType 2 /Domain [1 0] /N 1 >>".utf8),extras:[2:Data(parent.utf8),3:Data(page.utf8),6:Data("null".utf8)])
        let reader = try PDFStructureDocument(data:data)
        XCTAssertEqual(try reader.inherited("MediaBox",pageID:.init(number:3,generation:0))?.array?.compactMap(\.int),[0,0,200,200])
        XCTAssertEqual(try reader.inherited("Rotate",pageID:.init(number:3,generation:0))?.int,90)
        XCTAssertTrue(PDFArchiveFunctionChecks(reader:reader).modelChecks.contains{$0.status == .failed})
    }
    func testAliasedFunctionStreamsAndParametersUseTheTerminalObjects() throws {
        let data = fixture(Data("6 0 R".utf8),extras:[6:stream(Data([0]),"/FunctionType 7 0 R /Domain 9 0 R /Range [0 1] /Size [1] /BitsPerSample 8"),7:Data("8 0 R".utf8),8:Data("0".utf8),9:Data("10 0 R".utf8),10:Data("[0 1]".utf8)])
        allPass(try check(data))
    }
    func testAllElevenProfileReportsIncludeTheIndependentFunctionModel() throws {
        for profile in PDFArchiveProfile.allCases {
            let context = try PDFArchiveRuleContext(data:fixture(Data(linear.utf8)),profile:profile)
            XCTAssertTrue(context.modelChecks.contains{$0.objectType == "FunctionModel" && $0.status == .passed},profile.rawValue)
        }
    }
    func testReportBudgetPreservesAnExplicitIncompleteResult() throws {
        let spaces = (0..<1025).map{"/C\($0) [/Separation /S /DeviceGray 5 0 R]"}.joined(separator:" ")
        let result = try rows(linear,resources:"<< /ColorSpace << \(spaces) >> >>")
        XCTAssertTrue(result.contains{$0.status == .notVerified && diagnosticContains($0.detail, "Limite")})
        let withFailure = try rows(linear,resources:"<< /ColorSpace << \(spaces) /ZZZ [/Separation /Bad /DeviceGray 6 0 R] >> >>",extras:[6:Data("<< /FunctionType 2 /Domain [1 0] /N 1 >>".utf8)])
        XCTAssertTrue(withFailure.contains{$0.status == .failed})
    }
}
