import CoreGraphics
import Foundation
import XCTest
@testable import CartaPDF

final class PDFArchiveGraphicsSyntaxTests: XCTestCase {
    private func rule(_ object:String,_ expression:String) -> PDFArchiveCatalogueRule {
        .init(specification:"test",clause:"test",testNumber:"1",objectType:object,requirement:expression,expression:expression)
    }
    private func stream(_ data:Data,_ dictionary:String = "") -> Data {
        Data("<< \(dictionary) /Length \(data.count) >>\nstream\n".utf8) + data + Data("\nendstream".utf8)
    }
    private func fixture(content:String = "",resources:String = "<< >>",catalog:String = "",page:String = "",extras:[Int:Data] = [:],version:String = "1.7") -> Data {
        var objects:[Int:Data] = [
            1:Data("<< /Type /Catalog /Pages 2 0 R \(catalog) >>".utf8),
            2:Data("<< /Type /Pages /Count 1 /Kids [3 0 R] >>".utf8),
            3:Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources \(resources) /Contents 4 0 R \(page) >>".utf8),
            4:stream(Data(content.utf8))
        ]
        objects.merge(extras) { _,new in new }
        var data = Data("%PDF-\(version)\n%".utf8) + Data([0xE2,0xE3,0xCF,0xD3,10]), offsets:[Int:Int] = [:]
        for i in objects.keys.sorted() { offsets[i] = data.count; data += Data("\(i) 0 obj\n".utf8) + objects[i]! + Data("\nendobj\n".utf8) }
        let xref = data.count, count = objects.keys.max()! + 1
        data += Data("xref\n0 \(count)\n0000000000 65535 f \n".utf8)
        for i in 1..<count { data += Data(String(format:"%010lld 00000 %@ \n",Int64(offsets[i] ?? 0),offsets[i] == nil ? "f" : "n").utf8) }
        data += Data("trailer\n<< /Root 1 0 R /Size \(count) /ID [<1234><5678>] >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        return data
    }
    private func graphic(_ data:Data,_ object:String,_ expression:String,profile:PDFArchiveProfile = .pdfa2u) throws -> PDFArchiveRuleEvaluation {
        try XCTUnwrap(PDFArchiveGraphicsChecks(reader:PDFStructureDocument(data:data),profile:profile).evaluate(rule(object,expression)))
    }
    func testSpecifiedDeviceColorsAreUsedInPartsOneThroughThreeAndUnusedResourcesAreExempt() throws {
        let expression = #"gOutputCS != null && gOutputCS == "RGB ""#
        XCTAssertEqual(try graphic(fixture(content:"1 0 0 rg"),"PDDeviceRGB",expression).status,.failed)
        XCTAssertEqual(try graphic(fixture(content:"1 0 0 rg",version:"2.0"),"PDDeviceRGB",expression,profile:.pdfa4).status,.notApplicable)
        XCTAssertEqual(try graphic(fixture(content:"1 0 0 rg 0 0 10 10 re f"),"PDDeviceRGB",expression).status,.failed)
        XCTAssertEqual(try graphic(fixture(resources:"<< /ColorSpace << /Unused /DeviceRGB >> >>"),"PDDeviceRGB",expression).status,.notApplicable)
        XCTAssertEqual(try graphic(fixture(content:"0 0 10 10 re f"),"PDDeviceGray","gOutputCS != null").status,.failed)
    }
    func testDefaultRGBAndActualOutputICCResolveTheColorRequirement() throws {
        let expression = #"gOutputCS != null && gOutputCS == "RGB ""#
        let content = "1 0 0 rg 0 0 10 10 re f"
        let defaults = "<< /ColorSpace << /DefaultRGB [/CalRGB << /WhitePoint [0.9505 1 1.089] >>] >> >>"
        XCTAssertEqual(try graphic(fixture(content:content,resources:defaults),"PDDeviceRGB",expression).status,.notApplicable)
        let icc = try XCTUnwrap(CGColorSpace(name:CGColorSpace.displayP3)?.copyICCData()) as Data
        let data = fixture(content:content,catalog:"/OutputIntents [<< /S /GTS_PDFA1 /DestOutputProfile 5 0 R >>]",extras:[5:stream(icc)])
        XCTAssertEqual(try graphic(data,"PDDeviceRGB",expression).status,.passed)
        XCTAssertEqual(try graphic(data,"ICCOutputProfile",#"deviceClass == "mntr" && version < 5.0"#).status,.passed)
        XCTAssertEqual(try graphic(data,"ICCOutputProfile",#"deviceClass == "mntr" && version < 3.0"#,profile:.pdfa1b).status,.failed)
    }
    func testICCComponentsAndCorruptTagBoundsUseTheEmbeddedBytes() throws {
        let icc = try XCTUnwrap(CGColorSpace(name:CGColorSpace.displayP3)?.copyICCData()) as Data
        let resources = "<< /ColorSpace << /CS1 [/ICCBased 5 0 R] >> >>", content = "/CS1 cs 1 0 0 sc 0 0 10 10 re f"
        let good = fixture(content:content,resources:resources,extras:[5:stream(icc,"/N 3")])
        XCTAssertEqual(try graphic(good,"ICCProfile","N != null").status,.passed)
        let bad = fixture(content:content,resources:resources,extras:[5:stream(icc,"/N 4")])
        XCTAssertEqual(try graphic(bad,"ICCProfile","N != null").status,.failed)
        var corrupted = icc
        corrupted.replaceSubrange(136..<140,with:[255,255,255,255])
        let corrupt = fixture(content:content,resources:resources,extras:[5:stream(corrupted,"/N 3")])
        XCTAssertEqual(try graphic(corrupt,"ICCProfile","N != null").status,.failed)
    }
    func testResourceResolutionAndQDepthHaveActualNegativeCases() throws {
        let missing = fixture(content:"/Missing Do")
        XCTAssertEqual(try graphic(missing,"PDContentStream","undefinedResourceNames == ''").status,.failed)
        let nested = String(repeating:"q ",count:29) + String(repeating:"Q ",count:29)
        XCTAssertEqual(try graphic(fixture(content:nested),"Op_q_gsave","nestingLevel <= 28").status,.failed)
        XCTAssertEqual(try graphic(fixture(content:"q Q"),"Op_q_gsave","nestingLevel <= 28").status,.passed)
        let form = stream(Data("/A gs".utf8),"/Type /XObject /Subtype /Form /BBox [0 0 20 20]")
        let resources = "<< /XObject << /F1 5 0 R >> /ExtGState << /A << /CA 1 >> >> >>"
        XCTAssertEqual(try graphic(fixture(content:"/F1 Do",resources:resources,extras:[5:form]),"PDContentStream","inheritedResourceNames == ''",profile:.pdfa4).status,.failed)
    }
    func testTransparencyRequiresOutputOrExplicitPageBlendingSpace() throws {
        let expression = "gOutputCS != null || containsGroupCS == true || containsTransparency == false"
        let resources = "<< /ExtGState << /Half << /ca 0.5 >> >> >>"
        let data = fixture(content:"/Half gs 0 0 10 10 re f",resources:resources)
        XCTAssertEqual(try graphic(data,"PDPage",expression).status,.failed)
        let group = "/Group << /S /Transparency /CS [/CalRGB << /WhitePoint [0.9505 1 1.089] >>] >>"
        XCTAssertEqual(try graphic(fixture(content:"/Half gs 0 0 10 10 re f",resources:resources,page:group),"PDPage",expression).status,.passed)
    }
    func testShadingPatternExtGStateContributesTransparencyOnlyWhenUsed() throws {
        let pattern = "<< /Pattern << /P << /PatternType 2 /Shading << /ShadingType 2 /ColorSpace [/CalRGB << /WhitePoint [0.9505 1 1.089] >>] /Coords [0 0 10 10] /Function << /FunctionType 2 /Domain [0 1] /C0 [0 0 0] /C1 [1 1 1] /N 1 >> >> /ExtGState << /ca 0.5 >> >> >> >>"
        let expression = "gOutputCS != null || containsGroupCS == true || containsTransparency == false"
        XCTAssertEqual(try graphic(fixture(resources:pattern),"PDPage",expression).status,.passed)
        XCTAssertEqual(try graphic(fixture(content:"/Pattern cs /P scn 0 0 10 10 re f",resources:pattern),"PDPage",expression).status,.failed)
        let group = "/Group << /S /Transparency /CS [/CalRGB << /WhitePoint [0.9505 1 1.089] >>] >>"
        XCTAssertEqual(try graphic(fixture(content:"/Pattern cs /P scn 0 0 10 10 re f",resources:pattern,page:group),"PDPage",expression).status,.passed)
    }
    func testInlinePixelsContainingEIAreSkippedByExactSampleLength() throws {
        let pixels = Data([32,69,73,32,0,255])
        var lexer = PDFSyntaxLexer(Data("/W 2 /H 1 /BPC 8 /CS /RGB ID ".utf8) + pixels + Data(" EI q Q".utf8))
        let image = try PDFArchiveInlineImage.read(from:&lexer)
        XCTAssertEqual(image.bytes,pixels); XCTAssertTrue(image.lengthReliable)
        XCTAssertEqual(try lexer.word(),"q")
        var unknown = PDFSyntaxLexer(Data("/W 1 /H 1 /BPC 8 /CS /RGB /F /DCT ID abc EI q".utf8))
        XCTAssertFalse(try PDFArchiveInlineImage.read(from:&unknown).lengthReliable)
        var declared = PDFSyntaxLexer(Data("/W 1 /H 1 /BPC 8 /CS /RGB /F /DCT /L 3 ID abc EI".utf8))
        XCTAssertFalse(try PDFArchiveInlineImage.read(from:&declared).lengthReliable)
        var wrongL = PDFSyntaxLexer(Data("/W 1 /H 1 /BPC 8 /CS /RGB /L 1 ID abc EI".utf8))
        let independent = try PDFArchiveInlineImage.read(from:&wrongL)
        XCTAssertEqual(independent.bytes.count,3);XCTAssertTrue(independent.lengthReliable)
    }
    func testPaintedPatternsAndSoftMasksContributeActualDeviceColors() throws {
        let expression = #"gOutputCS != null && gOutputCS == "RGB ""#
        let cell = stream(Data("1 0 0 rg 0 0 10 10 re f".utf8),"/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources << >>")
        let resources = "<< /Pattern << /P1 5 0 R >> >>"
        XCTAssertEqual(try graphic(fixture(resources:resources,extras:[5:cell]),"PDDeviceRGB",expression).status,.notApplicable)
        XCTAssertEqual(try graphic(fixture(content:"/Pattern cs /P1 scn 0 0 10 10 re f",resources:resources,extras:[5:cell]),"PDDeviceRGB",expression).status,.failed)
        let mask = stream(Data("1 0 0 rg 0 0 10 10 re f".utf8),"/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources << >> /Group << /S /Transparency >>")
        let states = "<< /ExtGState << /Mask << /SMask << /S /Luminosity /G 5 0 R >> >> >> >>"
        XCTAssertEqual(try graphic(fixture(content:"/Mask gs 0 0 10 10 re f",resources:states,extras:[5:mask]),"PDDeviceRGB",expression).status,.failed)
    }
    func testOptionalGroupTypeAndICCBasedPageBlendingAreRecognized() throws {
        let icc = try XCTUnwrap(CGColorSpace(name:CGColorSpace.displayP3)?.copyICCData()) as Data
        let page = "/Group << /S /Transparency /CS [/ICCBased 5 0 R] >>"
        let pdf = fixture(content:"1 0 0 rg 0 0 10 10 re f",page:page,extras:[5:stream(icc,"/N 3")],version:"2.0")
        XCTAssertEqual(try graphic(pdf,"PDDeviceRGB",#"gOutputCS == "RGB " || blendingCS == "RGB ""#,profile:.pdfa4).status,.passed)
        XCTAssertEqual(try graphic(pdf,"PDGroup",#"S != "Transparency""#,profile:.pdfa1b).status,.failed)
    }
    func testLexicalChecksIncludeUnusedContainersWithoutInventingPaintUse() throws {
        let cell = stream(Data((String(repeating:"q ",count:29) + "<F> pop " + String(repeating:"Q ",count:29)).utf8),"/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources << >>")
        let pdf = fixture(resources:"<< /Pattern << /Unused 5 0 R >> >>",extras:[5:cell])
        XCTAssertEqual(try graphic(pdf,"Op_q_gsave","nestingLevel <= 28").status,.failed)
        XCTAssertEqual(try graphic(pdf,"Op_q_gsave","nestingLevel <= 28",profile:.pdfa1b).status,.notApplicable)
        let referenced = fixture(content:"/Pattern cs /Unused scn 0 0 10 10 re f",resources:"<< /Pattern << /Unused 5 0 R >> >>",extras:[5:cell])
        XCTAssertEqual(try graphic(referenced,"Op_q_gsave","nestingLevel <= 28",profile:.pdfa1b).status,.failed)
        let syntax = PDFArchiveSyntaxChecks(reader:try PDFStructureDocument(data:pdf))
        XCTAssertEqual(try syntax.evaluate(rule("CosString","hexCount % 2 == 0"))?.status,.failed)
        let long = fixture(content:"(" + String(repeating:"a",count:32768) + ") Tj")
        let context = try PDFArchiveRuleContext(data:long,profile:.pdfa2b)
        XCTAssertEqual(try context.evaluate(rule("CosString","value.length() < 32768")).status,.failed)
        let integer = try PDFArchiveRuleContext(data:fixture(content:"2147483648 0 m"),profile:.pdfa1b)
        XCTAssertEqual(try integer.evaluate(rule("CosInteger","value <= 2147483647")).status,.failed)
    }
    func testCrossReferenceRowFormatIsCheckedWithoutChangingObjectResolution() throws {
        var pdf = fixture()
        let marker = Data("0000000000 65535 f \n".utf8)
        let range = try XCTUnwrap(pdf.range(of:marker))
        pdf.replaceSubrange((range.lowerBound + 10)..<(range.lowerBound + 11),with:[9])
        let syntax = PDFArchiveSyntaxChecks(reader:try PDFStructureDocument(data:pdf))
        XCTAssertEqual(syntax.modelResult().status,.failed)
    }
    func testPageBoundaryLimitsUseInheritanceDefaultsAndIgnorePrivateBBoxKeys() throws {
        let expression = "Math.abs(top - bottom) >= 3 && Math.abs(top - bottom) <= 14400"
        func check(_ data:Data) throws -> PDFArchiveRuleStatus { try PDFArchiveRuleContext(data:data,profile:.pdfa2b).evaluate(rule("CosBBox",expression)).status }
        XCTAssertEqual(try check(fixture(catalog:"/Private << /BBox [0 0 1 1] >>")),.passed)
        XCTAssertEqual(try check(fixture(page:"/TrimBox [0 0 2 200]")),.failed)
        XCTAssertEqual(try check(fixture(page:"/ArtBox [0 0 3 14400]")),.passed)
        let inherited = fixture(extras:[
            2:Data("<< /Type /Pages /Count 1 /Kids [3 0 R] /MediaBox [0 0 200 200] /CropBox 5 0 R >>".utf8),
            3:Data("<< /Type /Page /Parent 2 0 R /Resources << >> /Contents 4 0 R >>".utf8),
            5:Data("[0 0 200 2]".utf8)
        ])
        XCTAssertEqual(try check(inherited),.failed)
    }
    func testDictionaryKeyNamesAreIncludedInLexicalLimits() throws {
        let data = fixture(catalog:"/" + String(repeating:"K",count:128) + " true")
        let context = try PDFArchiveRuleContext(data:data,profile:.pdfa1b)
        XCTAssertEqual(try context.evaluate(rule("CosName","value.length() <= 127")).status,.failed)
    }
    func testInitialDeviceGrayUsesDefaultGrayAndUnsupportedGroupsCannotProveRGB() throws {
        let defaults = "<< /ColorSpace << /DefaultGray [/CalGray << /WhitePoint [0.9505 1 1.089] >>] >> >>"
        XCTAssertEqual(try graphic(fixture(content:"0 0 10 10 re f",resources:defaults),"PDDeviceGray","gOutputCS != null").status,.notApplicable)
        let invalid = fixture(content:"1 0 0 rg 0 0 10 10 re f",page:"/Group << /S /Unsupported /CS [/CalRGB << /WhitePoint [0.9505 1 1.089] >>] >>",version:"2.0")
        XCTAssertNotEqual(try graphic(invalid,"PDDeviceRGB","gTransparencyCS == 'CalRGB'",profile:.pdfa4).status,.passed)
    }
    func testDeviceRGBFormGroupRetainsCharacterizationOfEnclosingPageGroup() throws {
        let icc = try XCTUnwrap(CGColorSpace(name:CGColorSpace.displayP3)?.copyICCData()) as Data
        let form = stream(Data("1 0 0 rg 0 0 10 10 re f".utf8),"/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources << >> /Group << /S /Transparency /CS /DeviceRGB >>")
        let pdf = fixture(content:"/F1 Do",resources:"<< /XObject << /F1 6 0 R >> >>",page:"/Group << /S /Transparency /CS [/ICCBased 5 0 R] >>",extras:[5:stream(icc,"/N 3"),6:form],version:"2.0")
        XCTAssertEqual(try graphic(pdf,"PDDeviceRGB","gTransparencyCS == 'RGB '",profile:.pdfa4).status,.passed)
        let isolated = stream(Data("1 0 0 rg 0 0 10 10 re f".utf8),"/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources << >> /Group << /S /Transparency /I true /CS /DeviceRGB >>")
        let separate = fixture(content:"/F1 Do",resources:"<< /XObject << /F1 6 0 R >> >>",page:"/Group << /S /Transparency /CS [/ICCBased 5 0 R] >>",extras:[5:stream(icc,"/N 3"),6:isolated],version:"2.0")
        XCTAssertEqual(try graphic(separate,"PDDeviceRGB","gTransparencyCS == 'RGB '",profile:.pdfa4).status,.failed)
    }
    func testICCProfileFingerprintNormalizesAllThreeHeaderFields() throws {
        let icc = try XCTUnwrap(CGColorSpace(name:CGColorSpace.displayP3)?.copyICCData()) as Data
        var altered = icc
        altered.replaceSubrange(44..<48,with:[0,0,0,1])
        altered.replaceSubrange(64..<68,with:[0,0,0,3])
        altered.replaceSubrange(84..<100,with:repeatElement(UInt8(42),count:16))
        XCTAssertEqual(try PDFArchiveICCProfile(data:icc).fingerprint,try PDFArchiveICCProfile(data:altered).fingerprint)
        XCTAssertNil(try PDFArchiveICCProfile(data:altered).verifiedFingerprint)
        altered[80] ^= 1
        XCTAssertNotEqual(try PDFArchiveICCProfile(data:icc).fingerprint,try PDFArchiveICCProfile(data:altered).fingerprint)
    }
    func testActualType3GlyphProgramsAreIncludedInPaintedColors() throws {
        let font = Data("<< /Type /Font /Subtype /Type3 /FontBBox [0 0 10 10] /FontMatrix [0.001 0 0 0.001 0 0] /FirstChar 65 /LastChar 65 /Widths [1000] /Encoding << /Type /Encoding /Differences [65 /A] >> /CharProcs << /A 6 0 R >> /Resources << >> >>".utf8)
        let procedure = stream(Data("1000 0 d0 1 0 0 rg 0 0 10 10 re f".utf8))
        let pdf = fixture(content:"BT /F1 12 Tf (A) Tj ET",resources:"<< /Font << /F1 5 0 R >> >>",extras:[5:font,6:procedure])
        XCTAssertEqual(try graphic(pdf,"PDDeviceRGB","gOutputCS == 'RGB '").status,.failed)
        let unused = fixture(resources:"<< /Font << /F1 5 0 R >> >>",extras:[5:font,6:procedure])
        XCTAssertEqual(try graphic(unused,"PDDeviceRGB","gOutputCS == 'RGB '").status,.notApplicable)
    }
    func testLengthDoesNotSilentlySkipUncountedWhitespaceBeforeEndstream() throws {
        let invalid = Data("<< /Length 3 >>\nstream\nq Q \nendstream".utf8)
        let syntax = PDFArchiveSyntaxChecks(reader:try PDFStructureDocument(data:fixture(extras:[4:invalid])))
        XCTAssertEqual(try syntax.evaluate(rule("CosStream","Length == realLength"))?.status,.failed)
        XCTAssertEqual(syntax.modelResult().status,.failed)
    }
    func testInlineLengthRequirementIncludesImagesInUnpaintedForms() throws {
        let samples = Data("BI /W 1 /H 1 /BPC 8 /CS /RGB ID abc EI".utf8)
        let form = stream(samples,"/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources << >>")
        let pdf = fixture(resources:"<< /XObject << /Unused 5 0 R >> >>",extras:[5:form],version:"2.0")
        XCTAssertEqual(try graphic(pdf,"PDInlineImage","L != null && L == realLength",profile:.pdfa4).status,.failed)
    }
    func testFilteredInlineLengthUsesEncodedEODInsteadOfItsOwnHint() throws {
        let bytes = Data([3,32,69,73,32,254,65,128])
        func image(_ hint:Int) -> Data {
            let content = Data("BI /W 7 /H 1 /BPC 8 /CS /G /F /RL /L \(hint) ID ".utf8) + bytes + Data(" EI".utf8)
            return fixture(extras:[4:stream(content)],version:"2.0")
        }
        XCTAssertEqual(try graphic(image(bytes.count),"PDInlineImage","L != null && L == realLength",profile:.pdfa4).status,.passed)
        XCTAssertEqual(try graphic(image(1),"PDInlineImage","L != null && L == realLength",profile:.pdfa4).status,.failed)
    }
    func testMalformedContentAndStreamFiltersProduceSeparateModelViolations() throws {
        for pdf in [
            fixture(content:"1e3 0 m"),
            fixture(content:"2 0 R Do"),
            fixture(extras:[5:stream(Data("not zlib".utf8),"/Filter /FlateDecode")]),
            fixture(content:"BI /W 1 /H 1 /BPC 8 /CS /G /F /Fl ID x EI")
        ] {
            XCTAssertEqual(PDFArchiveSyntaxChecks(reader:try PDFStructureDocument(data:pdf)).modelResult().status,.failed)
        }
        XCTAssertEqual(PDFArchiveSyntaxChecks(reader:try PDFStructureDocument(data:fixture(content:".3 +2. m"))).modelResult().status,.passed)
    }
    func testLongValidDecimalIsNotConfusedWithMalformedSyntaxOrMachineUnderflow() throws {
        let token = "50." + String(repeating:"1",count:65600)
        let pdf = fixture(content:token + " 0 m")
        XCTAssertEqual(PDFArchiveSyntaxChecks(reader:try PDFStructureDocument(data:pdf)).modelResult().status,.passed)
        let context = try PDFArchiveRuleContext(data:pdf,profile:.pdfa1b)
        XCTAssertEqual(try context.evaluate(rule("CosReal","Math.abs(value) <= 32767.0")).status,.passed)
        let tiny = try PDFArchiveRuleContext(data:fixture(content:"0." + String(repeating:"0",count:500) + "1 0 m"),profile:.pdfa2b)
        XCTAssertEqual(try tiny.evaluate(rule("CosReal","value == 0 || Math.abs(value) >= 1.175e-38")).status,.failed)
    }
    func testUnreadableOutputProfileDoesNotProveMissingCMYKCharacterization() throws {
        let pdf = fixture(content:"0 0 0 1 k 0 0 10 10 re f",catalog:"/OutputIntents [<< /S /GTS_PDFA1 /DestOutputProfile 5 0 R >>]",extras:[5:stream(Data("not a profile".utf8))])
        XCTAssertEqual(try graphic(pdf,"PDDeviceCMYK","gOutputCS == 'CMYK'").status,.notVerified)
    }
    func testAmbiguousInlineBoundaryCannotInventOperatorsInsideBinarySamples() throws {
        let pdf = fixture(content:"BI /W 1 /H 1 /BPC 8 /CS /RGB /F /Fl ID bytes EI madeup EI")
        XCTAssertEqual(try graphic(pdf,"Op_Undefined","false").status,.notVerified)
    }
    func testJPEG2000BoxFactsAndForbiddenEnumeratedColorSpace() throws {
        func u32(_ n:Int) -> Data { Data([UInt8(n >> 24 & 255),UInt8(n >> 16 & 255),UInt8(n >> 8 & 255),UInt8(n & 255)]) }
        func box(_ name:String,_ payload:Data) -> Data { u32(payload.count + 8) + Data(name.utf8) + payload }
        let header = u32(1) + u32(1) + Data([0,3,7,7,0,0])
        let data = Data([0,0,0,12,0x6A,0x50,0x20,0x20,13,10,0x87,10]) + box("jp2h",box("ihdr",header) + box("colr",Data([1,0,0]) + u32(19)))
        let facts = try PDFArchiveJPEG2000(data:data)
        XCTAssertEqual(facts.components,3); XCTAssertEqual(facts.bitDepth,8)
        let pdf = fixture(content:"/Im Do",resources:"<< /XObject << /Im 5 0 R >> >>",extras:[5:stream(data,"/Type /XObject /Subtype /Image /Width 1 /Height 1 /Filter /JPXDecode")])
        XCTAssertEqual(try graphic(pdf,"JPEG2000","nrColorChannels == 1 || nrColorChannels == 3 || nrColorChannels == 4").status,.passed)
        XCTAssertEqual(try graphic(pdf,"JPEG2000","hasColorSpace == true || colrEnumCS == null || colrEnumCS != 19").status,.failed)
        XCTAssertThrowsError(try PDFArchiveJPEG2000(data:Data(data.prefix(15))))
        let truncatedColor = Data([0,0,0,12,0x6A,0x50,0x20,0x20,13,10,0x87,10]) + box("jp2h",box("ihdr",header) + box("colr",Data([1,0,0])) + box("free",Data([0,0,0,19])))
        XCTAssertThrowsError(try PDFArchiveJPEG2000(data:truncatedColor))
    }
    func testHexAndObjectSyntaxAreVerifiedBeforeNormalization() throws {
        let pdf = fixture(catalog:"/Private <F>")
        let reader = try PDFStructureDocument(data:pdf), checks = PDFArchiveSyntaxChecks(reader:reader)
        XCTAssertEqual(try checks.evaluate(rule("CosString","(isHex != true) || hexCount % 2 == 0"))?.status,.failed)
        XCTAssertEqual(try checks.evaluate(rule("CosString","(isHex != true) || containsOnlyHex == true"))?.status,.passed)
        XCTAssertEqual(checks.modelResult().status,.passed)
        let exponent = PDFArchiveSyntaxChecks(reader:try PDFStructureDocument(data:fixture(catalog:"/Private 1e3")))
        XCTAssertEqual(exponent.modelResult().status,.failed)
        let duplicate = PDFArchiveSyntaxChecks(reader:try PDFStructureDocument(data:fixture(catalog:"/Private 1 /Private 2")))
        XCTAssertEqual(duplicate.modelResult().status,.failed)
    }
    func testPhysicalStreamsAndStandardObjectSpacingPass() throws {
        let reader = try PDFStructureDocument(data:fixture(content:"q Q")), checks = PDFArchiveSyntaxChecks(reader:reader)
        XCTAssertEqual(try checks.evaluate(rule("CosIndirect","spacingCompliesPDFA"))?.status,.passed)
        XCTAssertEqual(try checks.evaluate(rule("CosStream","Length == realLength"))?.status,.passed)
        XCTAssertEqual(try checks.evaluate(rule("CosStream","streamKeywordCRLFCompliant == true && endstreamKeywordEOLCompliant == true"))?.status,.passed)
        let malformed = stream(Data("q Q".utf8)) + Data()
        let spaced = Data(String(decoding:malformed,as:UTF8.self).replacingOccurrences(of:"\nendstream",with:"\n endstream").utf8)
        let bad = PDFArchiveSyntaxChecks(reader:try PDFStructureDocument(data:fixture(extras:[4:spaced])))
        XCTAssertEqual(try bad.evaluate(rule("CosStream","streamKeywordCRLFCompliant == true && endstreamKeywordEOLCompliant == true"))?.status,.failed)
    }
    func testHybridCrossReferenceResolvesCompressedRootAndKeepsBothSections() throws {
        var data = Data("%PDF-1.7\n%".utf8) + Data([0xE2,0xE3,0xCF,0xD3,10]), positions:[Int:Int] = [:]
        let objects:[Int:Data] = [
            2:Data("<< /Type /Pages /Count 1 /Kids [3 0 R] >>".utf8),
            3:Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 10 10] /Contents 4 0 R >>".utf8),
            4:stream(Data()),
            5:stream(Data("1 0 << /Type /Catalog /Pages 2 0 R >>".utf8),"/Type /ObjStm /N 1 /First 4")
        ]
        for i in objects.keys.sorted() { positions[i] = data.count; data += Data("\(i) 0 obj\n".utf8) + objects[i]! + Data("\nendobj\n".utf8) }
        positions[6] = data.count
        var records = Data()
        for i in 0...6 {
            let kind = i == 0 ? 0 : i == 1 ? 2 : 1, one = i == 1 ? 5 : positions[i] ?? 0, two = i == 0 ? 65535 : 0
            records += Data([UInt8(kind),UInt8(one >> 24 & 255),UInt8(one >> 16 & 255),UInt8(one >> 8 & 255),UInt8(one & 255),UInt8(two >> 8),UInt8(two & 255)])
        }
        data += Data("6 0 obj\n".utf8) + stream(records,"/Type /XRef /Size 7 /W [1 4 2]") + Data("\nendobj\n".utf8)
        let classic = data.count
        data += Data("xref\n0 7\n0000000000 65535 f \n0000000000 00000 f \n".utf8)
        for i in 2...6 { data += Data(String(format:"%010lld 00000 n \n",Int64(positions[i]!)).utf8) }
        data += Data("trailer\n<< /Size 7 /Root 1 0 R /XRefStm \(positions[6]!) /ID [<1234><5678>] >>\nstartxref\n\(classic)\n%%EOF\n".utf8)
        let reader = try PDFStructureDocument(data:data)
        XCTAssertEqual(try reader.pageIDs().count,1); XCTAssertEqual(reader.revisions.count,2)
        XCTAssertEqual(PDFArchiveSyntaxChecks(reader:reader).modelResult().status,.passed)
    }
}
