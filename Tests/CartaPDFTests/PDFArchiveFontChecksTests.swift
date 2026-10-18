import Foundation
import CoreGraphics
import CryptoKit
import XCTest
@testable import CartaPDF

final class PDFArchiveFontChecksTests:XCTestCase {
    func testRealSfntCmapGlyphAndAdvanceReadFromEmbeddedProgram() throws {
        let data = try nativeTrueType(),program = try PDFArchiveFontProgram(data:data)
        XCTAssertEqual(program.format,.sfntTrueType)
        let gid = try XCTUnwrap(program.glyph(unicode:65))
        XCTAssertGreaterThan(gid,0);XCTAssertTrue(try program.glyphDataIsPresent(gid))
        XCTAssertGreaterThan(try XCTUnwrap(program.advance(glyph:gid)),0)
        XCTAssertTrue(program.cmapRecords.contains{$0.platform == 3})
        var broken = data
        // A real directory entry outside the font must be rejected, not repaired.
        broken.replaceSubrange(20..<24,with:Data([255,255,255,255]))
        XCTAssertThrowsError(try PDFArchiveFontProgram(data:broken))
    }
    func testTrueTypeActualWidthMatchesAndChangedWidthIsDetected() throws {
        let data = try nativeTrueType(),program = try PDFArchiveFontProgram(data:data),gid = try XCTUnwrap(program.glyph(unicode:65)),width = try XCTUnwrap(program.advance(glyph:gid))
        for delta in [0.0,20.0] {
            let pdf = fixture(font:"<< /Type /Font /Subtype /TrueType /BaseFont /ArialMT /Encoding /WinAnsiEncoding /FirstChar 65 /LastChar 65 /Widths [\(width+delta)] /FontDescriptor 5 0 R >>",extras:[5:descriptor(file:6),6:stream("",data)])
            let result = try evaluate(pdf,object:"Glyph",matching:"widthFromFontProgram")
            XCTAssertEqual(result.status,delta == 0 ? .passed:.failed,result.detail)
            XCTAssertEqual(try evaluate(pdf,object:"Glyph",matching:"isGlyphPresent").status,.passed)
        }
    }
    func testUnicodeMappingForEveryUsedCodeAndForbiddenScalars() throws {
        for (target,expected) in [("0041",PDFArchiveRuleStatus.passed),("0000",.failed),("FFFE",.failed),("D83DDE00",.passed)] {
            let cmap = toUnicode("1 beginbfchar <41> <\(target)> endbfchar")
            let pdf = fixture(font:"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 5 0 R >>",extras:[5:stream("",cmap)])
            XCTAssertEqual(try evaluate(pdf,object:"Glyph",matching:"toUnicode != null").status,.passed)
            XCTAssertEqual(try evaluate(pdf,object:"Glyph",matching:"toUnicode.indexOf").status,expected)
        }
        let missing = fixture(font:"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 5 0 R >>",extras:[5:stream("",toUnicode("1 beginbfchar <42> <0042> endbfchar"))])
        XCTAssertEqual(try evaluate(missing,object:"Glyph",matching:"toUnicode != null").status,.failed)
        // Standard encoding is a real alternative to ToUnicode.
        XCTAssertEqual(try evaluate(fixture(),object:"Glyph",matching:"toUnicode != null").status,.passed)
    }
    func testCmapRangesSurrogateSequencesAndMalformedRangesAreBounded() throws {
        let map = try PDFArchiveCMap(data:toUnicode("2 beginbfrange <41> <43> <0041> <50> <51> [<0066 0069> <D83DDE00>] endbfrange"))
        XCTAssertEqual(PDFArchiveCMap.unicodeString(try XCTUnwrap(map.unicode[Data([67])])),"C")
        XCTAssertEqual(PDFArchiveCMap.unicodeString(try XCTUnwrap(map.unicode[Data([80])])),"fi")
        XCTAssertEqual(PDFArchiveCMap.unicodeString(try XCTUnwrap(map.unicode[Data([81])])),"😀")
        XCTAssertNil(PDFArchiveCMap.unicodeString(Data([0xD8,0x3D])))
        XCTAssertEqual(map.cid(Data([0x20])),0) // Undefined codes resolve to CID0.
        XCTAssertThrowsError(try PDFArchiveCMap(data:toUnicode("1 beginbfrange <00000000> <FFFFFFFF> <0041> endbfrange")))
    }
    func testCIDToGidMapAndWidthsUseActualCidNotUnicodeAssumptions() throws {
        let data = try nativeTrueType(),program = try PDFArchiveFontProgram(data:data),gid = try XCTUnwrap(program.glyph(unicode:65)),width = try XCTUnwrap(program.advance(glyph:gid))
        let parent = "<< /Type /Font /Subtype /Type0 /BaseFont /ArialMT /Encoding /Identity-H /DescendantFonts [5 0 R] /ToUnicode 9 0 R >>"
        for bad in [false,true] {
            let map = Data([0,0,UInt8((bad ? 65535:gid)>>8),UInt8((bad ? 65535:gid)&255)])
            let child = Data("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /ArialMT /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 6 0 R /CIDToGIDMap 8 0 R /W [1 [\(width)]] >>".utf8)
            let pdf = fixture(font:parent,content:Data("BT /F1 12 Tf <0001> Tj ET".utf8),extras:[5:child,6:descriptor(file:7),7:stream("",data),8:stream("",map),9:stream("",Data("1 begincodespacerange <0000> <FFFF> endcodespacerange 1 beginbfchar <0001> <0041> endbfchar".utf8))])
            XCTAssertEqual(try evaluate(pdf,object:"Glyph",matching:"isGlyphPresent").status,bad ? .failed:.passed)
            XCTAssertEqual(try evaluate(pdf,object:"Glyph",matching:"toUnicode != null").status,.passed)
            if !bad { XCTAssertEqual(try evaluate(pdf,object:"Glyph",matching:"widthFromFontProgram").status,.passed) }
        }
    }
    func testPatternAppearanceAndSoftMaskFontsAreActuallyVisited() throws {
        let text = Data("BT /F1 12 Tf (A) Tj ET".utf8),font = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
        let resources = "/Resources << /Font << /F1 4 0 R >> >>"
        let contexts:[(String,String,[Int:Data])] = [
            ("/Pattern << /P1 5 0 R >>", "/Pattern cs /P1 scn 0 0 20 20 re f",[5:stream("/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 20 20] /XStep 20 /YStep 20 \(resources)",text)]),
            ("/ExtGState << /G1 << /SMask << /S /Luminosity /G 5 0 R >> >> >>","/G1 gs 0 0 20 20 re f",[5:stream("/Type /XObject /Subtype /Form /BBox [0 0 20 20] \(resources)",text)])]
        for (resource,content,extras) in contexts {
            let pdf = fixture(font:font,content:Data(content.utf8),extraResources:resource,extras:extras)
            let evidence = try PDFArchiveContentScanner(reader:PDFStructureDocument(data:pdf)).scan()
            XCTAssertEqual(evidence.fonts.count,1)
            XCTAssertEqual(try evaluate(pdf,object:"PDFont",matching:"renderingMode == 3").status,.failed)
        }
        let ap = fixture(font:font,content:Data(),pageExtra:"/Annots [5 0 R]",extras:[5:Data("<< /Type /Annot /Subtype /Stamp /Rect [0 0 20 20] /AP << /N << /A 6 0 R >> >> >>".utf8),6:stream("/Type /XObject /Subtype /Form /BBox [0 0 20 20] \(resources)",text)])
        XCTAssertEqual(try PDFArchiveContentScanner(reader:PDFStructureDocument(data:ap)).scan().fonts.count,1)
        XCTAssertEqual(try evaluate(ap,object:"PDFont",matching:"renderingMode == 3").status,.failed)
    }
    func testType3CharacterProcedureVisitsNestedFontAndActualTextOverridesUnicode() throws {
        let type3 = "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix [0.001 0 0 0.001 0 0] /FirstChar 65 /LastChar 65 /Widths [500] /Encoding << /Differences [65 /A] >> /CharProcs << /A 5 0 R >> /Resources << /Font << /Inner 6 0 R >> >> >>"
        let pdf = fixture(font:type3,extras:[5:stream("",Data("500 0 d0 BT /Inner 12 Tf (A) Tj ET".utf8)),6:Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".utf8)])
        let evidence = try PDFArchiveContentScanner(reader:PDFStructureDocument(data:pdf)).scan()
        XCTAssertEqual(evidence.fonts.count,2)
        XCTAssertEqual(try evaluate(pdf,object:"PDFont",matching:"renderingMode == 3").status,.failed)
        let actual = fixture(font:"<< /Type /Font /Subtype /Type1 /BaseFont /Custom /Encoding << /Differences [65 /UnknownGlyph] >> >>",content:Data("/Span << /ActualText <FEFF0041> >> BDC BT /F1 12 Tf (A) Tj ET EMC".utf8))
        XCTAssertEqual(try evaluate(actual,object:"Glyph",matching:"toUnicode != null").status,.passed)
    }
    func testReliableInlineBytesAreNotParsedAsOperatorsAndAmbiguousDataBlocksPasses() throws {
        let data = fixture(content:Data("BI /W 1 /H 1 /BPC 8 /CS /RGB ID ".utf8)+Data([65,66,67])+Data(" EI BT /F1 12 Tf (A) Tj ET".utf8))
        let evidence = try PDFArchiveContentScanner(reader:PDFStructureDocument(data:data)).scan()
        XCTAssertEqual(evidence.fonts.count,1);XCTAssertTrue(evidence.undefinedOperators.isEmpty)
        XCTAssertEqual(evidence.inlineImages.first?.length,3);XCTAssertEqual(evidence.inlineImages.first?.reliable,true)
        let bad = fixture(content:Data("BI /W 1 /H 1 /BPC 8 /CS /Unknown ID abc EI".utf8))
        XCTAssertEqual(try evaluate(bad,object:"Glyph",matching:"toUnicode != null").status,.notVerified)
    }
    func testTr3ExemptsEmbeddingButDoesNotExemptUnicodeAndActualTextPrivateUseIsRejected() throws {
        let pdf = fixture(font:"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 5 0 R >>",content:Data("BT /F1 12 Tf 3 Tr (A) Tj ET".utf8),extras:[5:stream("",toUnicode("1 beginbfchar <42> <0042> endbfchar"))])
        XCTAssertEqual(try evaluate(pdf,object:"PDFont",matching:"renderingMode == 3").status,.passed)
        XCTAssertEqual(try evaluate(pdf,object:"Glyph",matching:"toUnicode != null").status,.failed)
        let privateText = fixture(content:Data("/Span << /ActualText <FEFFE001> >> BDC BT /F1 12 Tf (A) Tj ET EMC".utf8))
        XCTAssertEqual(try evaluate(privateText,profile:.pdfa4,object:"CosActualText",matching:"containsPUA").status,.failed)
    }
    func testType1EexecCharstringsNamesAndRealHsbwWidthsWithoutExecutingPostScript() throws {
        let fixture = type1()
        let parsed = try PDFArchiveType1Program(data:fixture.data,length1:fixture.length1,length2:fixture.length2)
        XCTAssertEqual(parsed.names,[".notdef","A"])
        XCTAssertEqual(try parsed.advance(name:"A"),500)
        let program = try PDFArchiveFontProgram(data:fixture.data,type1Length1:fixture.length1,type1Length2:fixture.length2)
        let gid = try XCTUnwrap(program.glyph(named:"A"))
        XCTAssertTrue(try program.glyphDataIsPresent(gid));XCTAssertEqual(try program.advance(glyph:gid),500)
        let pdf = self.fixture(font:"<< /Type /Font /Subtype /Type1 /BaseFont /ABCDEF+NativeTest /Encoding /WinAnsiEncoding /FirstChar 65 /LastChar 65 /Widths [520] /FontDescriptor 5 0 R >>",extras:[5:Data("<< /Type /FontDescriptor /FontName /ABCDEF+NativeTest /Flags 32 /CharSet (/A) /FontFile 6 0 R >>".utf8),6:stream("/Length1 \(fixture.length1) /Length2 \(fixture.length2)",fixture.data)])
        XCTAssertEqual(try evaluate(pdf,object:"Glyph",matching:"widthFromFontProgram").status,.failed)
        XCTAssertEqual(try evaluate(pdf,profile:.pdfa1b,object:"PDType1Font",matching:"CharSet").status,.passed)
    }
    func testActualCffCharStringsAndCidCharsetAreInspected() throws {
        let data = try Data(contentsOf:URL(fileURLWithPath:"/System/Library/Fonts/Supplemental/STIXGeneral.otf"))
        let program = try PDFArchiveFontProgram(data:data)
        XCTAssertEqual(program.format,.sfntCFF)
        let cff = try XCTUnwrap(program.cff)
        XCTAssertGreaterThan(cff.glyphCount,100)
        XCTAssertEqual(cff.charStrings.count,cff.glyphCount)
        let gid = try XCTUnwrap(program.glyph(named:"A"))
        XCTAssertTrue(try program.glyphDataIsPresent(gid))
        XCTAssertGreaterThan(try XCTUnwrap(program.advance(glyph:gid)),0)
    }
    func testNonstandardNamesWithoutAnyUnicodeAlternativeFailAndOtherFamiliesAreNotClaimed() throws {
        let pdf = fixture(font:"<< /Type /Font /Subtype /Type1 /BaseFont /Custom /Encoding << /Differences [65 /PrivateGlyphName] >> >>")
        XCTAssertEqual(try evaluate(pdf,object:"Glyph",matching:"toUnicode != null").status,.failed)
        let checks = PDFArchiveFontChecks(reader:try PDFStructureDocument(data:pdf),profile:.pdfa2u)
        let rule = try XCTUnwrap(PDFArchiveValidator.catalogue(profile:.pdfa2u).first{$0.objectType == "CosDocument"})
        XCTAssertNil(try checks.evaluate(rule))
    }
    func testPinnedAdobeAglCmapsAndCidToUnicodeAreAvailableOffline() throws {
        let data = try XCTUnwrap(PDFArchiveFontReferenceData.shared)
        XCTAssertEqual(PDFArchiveFontEncoding.unicode(name:"Aacute"),"Á")
        XCTAssertEqual(PDFArchiveFontEncoding.unicode(name:"a1"),"✁")
        let horizontal = try data.cmap("90ms-RKSJ-H"),vertical = try data.cmap("90ms-RKSJ-V")
        XCTAssertEqual(horizontal.registry,"Adobe");XCTAssertEqual(horizontal.ordering,"Japan1")
        XCTAssertEqual(horizontal.cid(Data([0x82,0xA0])),843)
        XCTAssertEqual(vertical.cid(Data([0x82,0xA0])),843)
        XCTAssertEqual(vertical.writingMode,1)
        XCTAssertEqual(try data.unicode(cid:843,registry:"Adobe",ordering:"Japan1",supplement:2),"あ")
        XCTAssertThrowsError(try data.unicode(cid:843,registry:"Adobe",ordering:"Japan1",supplement:999))
        let font = "<< /Type /Font /Subtype /Type0 /BaseFont /CJK /Encoding /90ms-RKSJ-H /DescendantFonts [5 0 R] >>"
        let child = Data("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /CJK /CIDSystemInfo << /Registry (Adobe) /Ordering (Japan1) /Supplement 2 >> >>".utf8)
        let pdf = fixture(font:font,content:Data("BT /F1 12 Tf <82A0> Tj ET".utf8),extras:[5:child])
        XCTAssertEqual(try evaluate(pdf,object:"Glyph",matching:"toUnicode != null").status,.passed)
        XCTAssertEqual(try evaluate(pdf,object:"PDType0Font",matching:"CIDFontOrdering").status,.passed)
    }
    func testEmbeddedUseCmapInheritsMappingAndCodespaceWithoutGuessing() throws {
        let base = toUnicode("1 beginbfchar <41> <0041> endbfchar")
        let child = Data("1 beginbfchar <42> <0042> endbfchar".utf8)
        let pdf = fixture(font:"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 5 0 R >>",extras:[5:stream("/UseCMap 6 0 R",child),6:stream("",base)])
        XCTAssertEqual(try evaluate(pdf,object:"Glyph",matching:"toUnicode != null").status,.passed)
        XCTAssertEqual(try evaluate(pdf,object:"CMapFile",matching:"WMode").status,.passed)
    }
    func testLexicalInventoryIncludesUnusedContainersWithoutInventingFontUsage() throws {
        let form = Data(("q q q <ABC> [(literal) 9] /Missing 12 Tf Q Q Q ").utf8)
        let pdf = fixture(content:Data(),extraResources:"/XObject << /Unused 5 0 R >>",extras:[5:stream("/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources << >>",form)])
        let evidence = try PDFArchiveContentScanner(reader:PDFStructureDocument(data:pdf)).scan(allowPartial:true)
        XCTAssertTrue(evidence.fonts.isEmpty)
        XCTAssertEqual(evidence.maxQDepth,3)
        XCTAssertTrue(evidence.lexicalComplete);XCTAssertTrue(evidence.resourceScanComplete)
        XCTAssertTrue(evidence.hexLexemes.contains{$0.digits == 3 && $0.valid && $0.location.contains("Unused")})
        XCTAssertTrue(evidence.undefinedResourceNames.contains{$0.hasSuffix("/Font/Missing")})
        XCTAssertTrue(evidence.lexicalValues.contains{$0.array?.first?.text == "literal"})
        let inherited = fixture(content:Data(),extraResources:"/XObject << /Unused 5 0 R >>",extras:[5:stream("/Type /XObject /Subtype /Form /BBox [0 0 10 10]",Data("/F1 12 Tf".utf8))])
        XCTAssertTrue(try PDFArchiveContentScanner(reader:PDFStructureDocument(data:inherited)).scan().inheritedResourceNames.contains{$0.hasSuffix("/Font/F1")})
    }
    func testInvalidHexBlocksLexicalCompletenessButNullReferenceIsNotParseFailure() throws {
        let badHex = fixture(content:Data("<G0> Tj".utf8))
        let evidence = try PDFArchiveContentScanner(reader:PDFStructureDocument(data:badHex)).scan(allowPartial:true)
        XCTAssertFalse(evidence.lexicalComplete);XCTAssertTrue(evidence.hexLexemes.contains{!$0.valid})
        let brokenInventory = fixture(font:"<< /Subtype 999 0 R >>",content:Data())
        let partial = try PDFArchiveContentScanner(reader:PDFStructureDocument(data:brokenInventory)).scan(allowPartial:true)
        // An undefined scalar reference resolves null; it does not corrupt the
        // lexical walk, and this font is never selected by the page stream.
        XCTAssertTrue(partial.lexicalComplete);XCTAssertTrue(partial.resourceScanComplete)
        XCTAssertTrue(partial.referencedFonts.isEmpty)
    }
    func testType3D0AndD1AdvancesAreComparedToActualWidths() throws {
        for command in ["500 0 d0","500 0 0 0 500 500 d1"] {
            for width in [500,520] {
                let font = "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 500 500] /FontMatrix [0.001 0 0 0.001 0 0] /FirstChar 65 /LastChar 65 /Widths [\(width)] /Encoding << /Differences [65 /A] >> /CharProcs << /A 5 0 R >> >>"
                XCTAssertEqual(try evaluate(fixture(font:font,extras:[5:stream("",Data(command.utf8))]),object:"Glyph",matching:"widthFromFontProgram").status,width == 500 ? .passed:.failed)
            }
        }
    }
    func testPrivateUseUnicodeRequiresActualTextAtAllThreePrivateUseRanges() throws {
        for target in ["E001","DB80DC00","DBC0DC00"] {
            let font = "<< /Type /Font /Subtype /Type1 /BaseFont /Custom /Encoding /WinAnsiEncoding /ToUnicode 5 0 R >>"
            let cmap = stream("",toUnicode("1 beginbfchar <41> <\(target)> endbfchar"))
            XCTAssertEqual(try evaluate(fixture(font:font,extras:[5:cmap]),profile:.pdfa2a,object:"Glyph",matching:"unicodePUA").status,.failed)
            let replacement = fixture(font:font,content:Data("/Span << /ActualText <FEFF0041> >> BDC BT /F1 12 Tf (A) Tj ET EMC".utf8),extras:[5:cmap])
            XCTAssertEqual(try evaluate(replacement,profile:.pdfa2a,object:"Glyph",matching:"unicodePUA").status,.passed)
        }
    }
    func testGlyphZeroIsNotSubstitutedForAnAbsentCharacter() throws {
        let program = type1(),font = "<< /Type /Font /Subtype /Type1 /BaseFont /NativeTest /Encoding /WinAnsiEncoding /FontDescriptor 5 0 R >>"
        let extras = [5:Data("<< /Flags 32 /FontFile 6 0 R >>".utf8),6:stream("/Length1 \(program.length1) /Length2 \(program.length2)",program.data)]
        let missing = fixture(font:font,content:Data("BT /F1 12 Tf (B) Tj ET".utf8),extras:extras)
        XCTAssertEqual(try evaluate(missing,object:"Glyph",matching:"isGlyphPresent").status,.failed)
        XCTAssertEqual(try evaluate(missing,object:"Glyph",matching:"name !=").status,.failed)
        let truncated = fixture(font:"<< /Type /Font /Subtype /Type0 /BaseFont /Native /Encoding /Identity-H /DescendantFonts [5 0 R] >>",content:Data("BT /F1 12 Tf <23> Tj ET".utf8),extras:[5:Data("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Native >>".utf8)])
        XCTAssertEqual(try evaluate(truncated,object:"Glyph",matching:"isGlyphPresent").status,.failed)
    }
    func testPdfA1CharsetCoversUsedGlyphsAndPdfA2CoversAllDefinedGlyphs() throws {
        let program = type1(),font = "<< /Type /Font /Subtype /Type1 /BaseFont /ABCDEF+NativeTest /Encoding /WinAnsiEncoding /FontDescriptor 5 0 R >>"
        let extras = [5:Data("<< /Flags 32 /CharSet (/space) /FontFile 6 0 R >>".utf8),6:stream("/Length1 \(program.length1) /Length2 \(program.length2)",program.data)]
        let selectedWithoutText = fixture(font:font,content:Data("BT /F1 12 Tf ET".utf8),extras:extras)
        XCTAssertEqual(try evaluate(selectedWithoutText,profile:.pdfa1b,object:"PDType1Font",matching:"CharSet").status,.passed)
        XCTAssertEqual(try evaluate(selectedWithoutText,profile:.pdfa2b,object:"PDType1Font",matching:"CharSet").status,.failed)
        XCTAssertEqual(try evaluate(fixture(font:font,extras:extras),profile:.pdfa1b,object:"PDType1Font",matching:"CharSet").status,.failed)
    }
    func testStructureElementActualTextIsResolvedThroughMcidForPrivateUseGlyphs() throws {
        let font = "<< /Type /Font /Subtype /Type1 /BaseFont /Custom /Encoding /WinAnsiEncoding /ToUnicode 5 0 R >>"
        let pdf = fixture(font:font,content:Data("/P << /MCID 0 >> BDC BT /F1 12 Tf (A) Tj ET EMC".utf8),catalogExtra:"/StructTreeRoot 6 0 R",extras:[5:stream("",toUnicode("1 beginbfchar <41> <E001> endbfchar")),6:Data("<< /Type /StructTreeRoot /K [7 0 R] >>".utf8),7:Data("<< /Type /StructElem /S /P /P 6 0 R /Pg 3 0 R /ActualText (A) /K 0 >>".utf8)])
        XCTAssertEqual(try evaluate(pdf,profile:.pdfa2a,object:"Glyph",matching:"unicodePUA").status,.passed)
        XCTAssertEqual(try PDFArchiveContentScanner(reader:PDFStructureDocument(data:pdf)).scan().fonts.first?.actualText,"A")
        let unresolved = fixture(font:font,content:Data("/P << /MCID 0 >> BDC BT /F1 12 Tf (A) Tj ET EMC".utf8),catalogExtra:"/StructTreeRoot 6 0 R",extras:[5:stream("",toUnicode("1 beginbfchar <41> <E001> endbfchar")),6:Data("<< /Type /StructTreeRoot /K [7 0 R] >>".utf8),7:Data("<< /Type /StructElem /S /P /P 6 0 R /K [7 0 R] >>".utf8)])
        XCTAssertEqual(try evaluate(unresolved,profile:.pdfa2a,object:"Glyph",matching:"unicodePUA").status,.notVerified)
    }
    func testPdfVerticalPlacementIsIndependentOfVmtxAndPdfA1UsedCidSetDiffersFromAllCidSet() throws {
        let data = metricFont(),program = try PDFArchiveFontProgram(data:data)
        XCTAssertEqual(try program.verticalMetrics(glyph:1)?.advance,1000)
        XCTAssertEqual(try program.advance(glyph:1),500)
        for delta in [0,20] {
            let font = "<< /Type /Font /Subtype /Type0 /BaseFont /ABCDEF+Metric /Encoding /Identity-V /DescendantFonts [5 0 R] >>"
            let child = Data("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /ABCDEF+Metric /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 6 0 R /CIDToGIDMap /Identity /W [1 [500]] /W2 [1 [-\(1000+delta) 250 880]] >>".utf8)
            let extras = [5:child,6:Data("<< /Flags 4 /FontFile2 7 0 R /CIDSet 8 0 R >>".utf8),7:stream("",data),8:stream("",Data([0x40]))]
            let pdf = fixture(font:font,content:Data("BT /F1 12 Tf <0001> Tj ET".utf8),extras:extras)
            XCTAssertEqual(try evaluate(pdf,object:"Glyph",matching:"widthFromFontProgram").status,.passed) // W2 does not duplicate vmtx.
            XCTAssertEqual(try evaluate(pdf,profile:.pdfa1b,object:"PDCIDFont",matching:"CIDSet").status,.passed)
            XCTAssertEqual(try evaluate(pdf,profile:.pdfa2b,object:"PDCIDFont",matching:"CIDSet").status,.failed)
        }
    }
    func testCidSetStreamMappingPreservesCoverageAndMalformedResults() throws {
        let font = "<< /Type /Font /Subtype /Type0 /BaseFont /ABCDEF+Metric /Encoding /Identity-H /DescendantFonts [5 0 R] >>"
        let child = Data("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /ABCDEF+Metric /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 6 0 R /CIDToGIDMap 9 0 R >>".utf8)
        var laterCID = Data(repeating:0,count:20)
        laterCID[18] = 1
        // Isolate CIDSet membership; the high-byte GID does not attest full font validity.
        let cases:[(String,Data,Data,PDFArchiveRuleStatus)] = [
            ("empty map",Data(),Data(),.passed),
            ("zero GIDs",Data([0,0,0,0]),Data(),.passed),
            ("CID0 excluded and high-byte GID covered",Data([0,1,0,0,1,0]),Data([0x20]),.passed),
            ("mapped CID missing",Data([0,1,0,0,1,0]),Data([0]),.failed),
            ("later CID covered",laterCID,Data([0,0x40]),.passed),
            ("CIDSet ends before mapped CID",laterCID,Data([0]),.failed),
            ("odd mapping length",Data([0]),Data([0]),.notVerified)
        ]
        for (name,map,bits,expected) in cases {
            let pdf = fixture(font:font,content:Data("BT /F1 12 Tf ET".utf8),extras:[
                5:child,6:Data("<< /Flags 4 /FontFile2 7 0 R /CIDSet 8 0 R >>".utf8),
                7:stream("",metricFont()),8:stream("",bits),9:stream("",map)
            ])
            let result = try evaluate(pdf,profile:.pdfa2b,object:"PDCIDFont",matching:"CIDSet")
            XCTAssertEqual(result.status,expected,"\(name): \(result.detail)")
        }
    }
    private func metricFont()->Data {
        func word(_ value:Int)->Data { Data([UInt8((value>>8)&255),UInt8(value&255)]) }
        func dword(_ value:Int)->Data { Data([UInt8((value>>24)&255),UInt8((value>>16)&255),UInt8((value>>8)&255),UInt8(value&255)]) }
        var head = Data(repeating:0,count:54);head.replaceSubrange(18..<20,with:word(1000))
        var hhea = Data(repeating:0,count:36);hhea.replaceSubrange(34..<36,with:word(3))
        let tables:[String:Data] = ["head":head,"maxp":dword(0x10000)+word(3),"hhea":hhea,"hmtx":word(500)+word(0)+word(500)+word(0)+word(500)+word(0),"vhea":hhea,"vmtx":word(900)+word(0)+word(1000)+word(40)+word(1100)+word(0),"loca":Data(repeating:0,count:8),"glyf":Data()]
        var result = dword(0x10000)+word(tables.count)+Data(repeating:0,count:6),payload = Data();let start = 12+tables.count*16
        for (tag,data) in tables.sorted(by:{$0.key<$1.key}) { result += Data(tag.utf8)+dword(0)+dword(start+payload.count)+dword(data.count);payload += data;while payload.count%4 != 0 { payload.append(0) } }
        return result+payload
    }
    func testOfflineReferenceDataRejectsForgedManifestMissingAglAndTamperedCmapBeforeParsing() throws {
        let source = try XCTUnwrap(PDFArchiveValidator.resourceDirectory()).deletingLastPathComponent().appendingPathComponent("PDFFontData",isDirectory:true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("CartaPDF-font-integrity-" + UUID().uuidString,isDirectory:true)
        try FileManager.default.copyItem(at:source,to:temporary)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let manifestURL = temporary.appendingPathComponent("MANIFEST.json"),manifestData = try Data(contentsOf:manifestURL)
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with:manifestData) as? [String:Any])
        var items = try XCTUnwrap(manifest["items"] as? [[String:Any]])
        let aglIndex = try XCTUnwrap(items.firstIndex{$0["name"] as? String == "glyphlist.txt"})
        let aglURL = temporary.appendingPathComponent(try XCTUnwrap(items[aglIndex]["file"] as? String)),aglData = try Data(contentsOf:aglURL)
        // First prove that the exact same temporary installation is usable.
        XCTAssertEqual(try PDFArchiveFontReferenceData(directory:temporary).glyphs["Aacute"],"Á")
        let alteredAgl = aglData + Data("\nFakeGlyph;0041\n".utf8)
        try alteredAgl.write(to:aglURL)
        items[aglIndex]["sha256"] = SHA256.hash(data:alteredAgl).map{String(format:"%02x",$0)}.joined()
        manifest["items"] = items
        try JSONSerialization.data(withJSONObject:manifest,options:.sortedKeys).write(to:manifestURL)
        XCTAssertThrowsError(try PDFArchiveFontReferenceData(directory:temporary)) { error in
            XCTAssertTrue(diagnosticContains(error.localizedDescription, "inventario dati font Adobe modificato"))
        }
        // A forged item hash cannot authorize changed bytes: the manifest itself
        // is pinned. With original manifest restored, item hashes still apply.
        try manifestData.write(to:manifestURL)
        XCTAssertThrowsError(try PDFArchiveFontReferenceData(directory:temporary)) { error in
            XCTAssertTrue(error.localizedDescription.contains(L10n.tr("hash dato Adobe: ") + "glyphlist.txt"))
        }
        try FileManager.default.removeItem(at:aglURL)
        XCTAssertThrowsError(try PDFArchiveFontReferenceData(directory:temporary))
        try aglData.write(to:aglURL)
        let reference = try PDFArchiveFontReferenceData(directory:temporary)
        let mapFile = try XCTUnwrap(items.first{$0["name"] as? String == "90ms-RKSJ-H"}?["file"] as? String)
        // These bytes are deliberately not a valid mapping. The failure must
        // come from SHA256 before any CMap parser can consume them.
        try Data("untrusted CMap bytes".utf8).write(to:temporary.appendingPathComponent(mapFile))
        XCTAssertThrowsError(try reference.cmap("90ms-RKSJ-H")) { error in
            XCTAssertTrue(error.localizedDescription.contains(L10n.tr("hash dato Adobe: ") + "90ms-RKSJ-H"))
        }
    }
    func testUnreferencedNamedFontsAreExemptButTfWithoutTextStillSelectsFontClauses() throws {
        let bad = "<< /Type /NotAFont /Subtype /Type0 /BaseFont /Unused /Encoding /NotAnAllowedCMap /DescendantFonts [5 0 R] >>"
        let descendant = Data("<< /Type /NotAFont /Subtype /CIDFontType2 /BaseFont /Unused /FontDescriptor 6 0 R >>".utf8)
        let extras = [5:descendant,6:Data("<< /FontFile2 7 0 R >>".utf8),7:stream("",Data("not a font program".utf8))]
        for profile:PDFArchiveProfile in [.pdfa1b,.pdfa2b,.pdfa3b,.pdfa4] {
            let unreferenced = fixture(font:bad,content:Data(),extras:extras)
            let evidence = try PDFArchiveContentScanner(reader:PDFStructureDocument(data:unreferenced)).scan()
            XCTAssertEqual(evidence.resourceFonts.count,1);XCTAssertTrue(evidence.referencedFonts.isEmpty);XCTAssertTrue(evidence.fonts.isEmpty)
            XCTAssertEqual(try evaluate(unreferenced,profile:profile,object:"PDFont",matching:"Type ==").status,.notApplicable)
            XCTAssertEqual(try evaluate(unreferenced,profile:profile,object:"PDCMap",matching:"CMapName").status,.notApplicable)
            let selected = fixture(font:bad,content:Data("BT /F1 12 Tf ET".utf8),extras:extras)
            let selectedEvidence = try PDFArchiveContentScanner(reader:PDFStructureDocument(data:selected)).scan()
            XCTAssertEqual(selectedEvidence.referencedFonts.count,1);XCTAssertTrue(selectedEvidence.fonts.isEmpty)
            XCTAssertEqual(try evaluate(selected,profile:profile,object:"PDFont",matching:"Type ==").status,.failed)
            XCTAssertEqual(try evaluate(selected,profile:profile,object:"PDCMap",matching:"CMapName").status,.failed)
        }
    }
    func testUnusedFormFontProgramsAreExemptUntilFormIsReferenced() throws {
        let font = "<< /Type /Font /Subtype /TrueType /BaseFont /Malformed /FontDescriptor 6 0 R >>"
        let resources = "/Resources << /Font << /Inner 5 0 R >> >>"
        let extras = [5:Data(font.utf8),6:Data("<< /Flags 4 /FontFile2 7 0 R >>".utf8),7:stream("",Data("not a font".utf8)),8:stream("/Type /XObject /Subtype /Form /BBox [0 0 10 10] \(resources)",Data("BT /Inner 12 Tf ET".utf8))]
        for invoked in [false,true] {
            let pdf = fixture(content:Data(invoked ? "/Unused Do".utf8:"".utf8),extraResources:"/XObject << /Unused 8 0 R >>",extras:extras)
            let evidence = try PDFArchiveContentScanner(reader:PDFStructureDocument(data:pdf)).scan()
            XCTAssertEqual(evidence.referencedFonts.count,invoked ? 1:0)
            XCTAssertEqual(try evaluate(pdf,object:"TrueTypeFontProgram",matching:"nrCmaps").status,invoked ? .notVerified:.notApplicable)
        }
    }
    func testExtGStateFontReferenceWithoutTextAndUnresolvedTfRemainObservable() throws {
        let bad = Data("<< /Type /NotAFont /Subtype /TrueType /BaseFont /Wrong >>".utf8)
        let pdf = fixture(content:Data("/G1 gs".utf8),extraResources:"/ExtGState << /G1 << /Font [5 0 R 12] >> >>",extras:[5:bad])
        let evidence = try PDFArchiveContentScanner(reader:PDFStructureDocument(data:pdf)).scan()
        XCTAssertEqual(evidence.referencedFonts.count,1);XCTAssertTrue(evidence.fonts.isEmpty)
        XCTAssertEqual(evidence.referencedFonts.first?.reference?.number,5)
        XCTAssertEqual(try evaluate(pdf,object:"PDFont",matching:"Type ==").status,.failed)
        let unresolved = fixture(content:Data("/Missing 12 Tf".utf8))
        XCTAssertEqual(try evaluate(unresolved,object:"PDFont",matching:"Type ==").status,.notVerified)
        let descendantMissing = fixture(font:"<< /Type /Font /Subtype /Type0 /BaseFont /Missing /Encoding /Identity-H /DescendantFonts [999 0 R] >>",content:Data("BT /F1 12 Tf ET".utf8))
        let checks = PDFArchiveFontChecks(reader:try PDFStructureDocument(data:descendantMissing),profile:.pdfa2b)
        let parentRule = try XCTUnwrap(PDFArchiveValidator.catalogue(profile:.pdfa2b).first{$0.objectType == "PDFont" && $0.expression == "Type == \"Font\""})
        XCTAssertEqual(try checks.evaluate(parentRule)?.status,.passed)
        XCTAssertTrue(checks.modelChecks.contains{$0.objectType == "FontDictionaryModel" && $0.status == .failed})
    }
    func testCffExpertAndExpertSubsetCharsetsAndEncodingAreIndependentOfNativeFontNames() throws {
        for (charset,count) in [(1,166),(2,87)] {
            let program = try PDFArchiveFontProgram(data:cffFixture(charset:charset,encoding:1,count:count))
            let cff = try XCTUnwrap(program.cff)
            XCTAssertEqual(cff.customNames.count,count)
            XCTAssertEqual(cff.customNames[1],"space")
            XCTAssertEqual(cff.customNames[2],charset == 1 ? "exclamsmall":"dollaroldstyle")
            XCTAssertEqual(program.builtInGlyphName(code:32),"space")
            XCTAssertEqual(program.builtInGlyphName(code:0),".notdef")
            if charset == 1 {
                XCTAssertEqual(program.builtInGlyphName(code:33),"exclamsmall")
                XCTAssertEqual(program.glyph(named:"exclamsmall"),2)
                XCTAssertEqual(program.glyphName(165),"Ydieresissmall")
            } else { XCTAssertEqual(program.builtInGlyphName(code:36),"dollaroldstyle") }
        }
        XCTAssertThrowsError(try PDFArchiveFontProgram(data:cffFixture(charset:1,encoding:1,count:167)))
        XCTAssertThrowsError(try PDFArchiveFontProgram(data:cffFixture(charset:2,encoding:1,count:88)))
    }
    func testCffExpertGlyphAndFullSubsetCharsetPredicateReadEmbeddedProgram() throws {
        let data = cffFixture(charset:1,encoding:1,count:166),program = try PDFArchiveFontProgram(data:data)
        let names = (0..<program.glyphCount).compactMap(program.glyphName).filter{$0 != ".notdef"}
        let font = "<< /Type /Font /Subtype /Type1 /BaseFont /ABCDEF+Expert /FontDescriptor 5 0 R >>"
        for omitted in [false,true] {
            let list = names.filter{!omitted || $0 != "Ydieresissmall"}.map{"/"+$0}.joined()
            let extras = [5:Data("<< /FontName /ABCDEF+Expert /Flags 4 /CharSet (\(list)) /FontFile3 6 0 R >>".utf8),6:stream("/Subtype /Type1C",data)]
            let pdf = fixture(font:font,content:Data("BT /F1 12 Tf <21> Tj ET".utf8),extras:extras)
            XCTAssertEqual(try evaluate(pdf,object:"Glyph",matching:"isGlyphPresent").status,.passed)
            XCTAssertEqual(try evaluate(pdf,profile:.pdfa2b,object:"PDType1Font",matching:"CharSet").status,omitted ? .failed:.passed)
        }
    }
    private func cffFixture(charset:Int,encoding:Int,count:Int,privateDictionary:Data = Data(),characters:[Int:Data] = [:],localSubrs:[Data] = [],globalSubrs:[Data] = [])->Data {
        func word(_ value:Int)->Data { Data([UInt8(value>>8),UInt8(value&255)]) }
        func number(_ value:Int)->Data { Data([29,UInt8((value>>24)&255),UInt8((value>>16)&255),UInt8((value>>8)&255),UInt8(value&255)]) }
        func index(_ values:[Data])->Data {
            guard !values.isEmpty else { return Data([0,0]) };var result = word(values.count)+Data([2]),offset = 1
            for value in values { result += word(offset);offset += value.count };result += word(offset)
            for value in values { result += value };return result
        }
        let name = index([Data("Expert".utf8)]),header = Data([1,0,4,4]),globals = index(globalSubrs)
        let hasPrivate = !privateDictionary.isEmpty || !localSubrs.isEmpty
        let topSize = hasPrivate ? 21:10,offset = header.count+name.count+7+topSize+2+globals.count
        let charData = index((0..<count).map{characters[$0] ?? Data([14])})
        var privateData = privateDictionary
        if !localSubrs.isEmpty { privateData += number(privateDictionary.count+6)+Data([19]) }
        var top = Data([UInt8(charset+139),15,UInt8(encoding+139),16])+number(offset)+Data([17])
        if hasPrivate { top += number(privateData.count)+number(offset+charData.count)+Data([18]) }
        var result = header
        for part in [name,index([top]),Data([0,0]),globals,charData,privateData] { result.append(part) }
        if !localSubrs.isEmpty { result.append(index(localSubrs)) }
        return result
    }
    func testSfntStructureIsCheckedIndependentlyOfNativeAcceptance() throws {
        let bytes = try nativeTrueType(),original = try PDFArchiveFontProgram(data:bytes),audit = original.structuralAudit()
        XCTAssertTrue(audit.issues.isEmpty,audit.issues.joined(separator:"; "))
        XCTAssertEqual(audit.checkedGlyphs,original.glyphCount)
        XCTAssertGreaterThan(audit.instructionBytes,0)
        XCTAssertTrue(audit.gaps.contains{diagnosticContains($0, "Bytecode TrueType")})
        let head = try XCTUnwrap(original.tables["head"])
        var forged = bytes;forged.replaceSubrange((head.lowerBound+12)..<(head.lowerBound+16),with:Data([0,0,0,0]))
        XCTAssertTrue(try PDFArchiveFontProgram(data:forged).structuralAudit().issues.contains{diagnosticContains($0, "magicNumber")})
        let gid = try XCTUnwrap(original.glyph(unicode:65)),loca = try XCTUnwrap(original.tables["loca"]),glyf = try XCTUnwrap(original.tables["glyf"]),array = Array(bytes)
        let format = try PDFArchiveFontProgram.u16(array,head.lowerBound+50)
        let start = format == 0 ? try PDFArchiveFontProgram.u16(array,loca.lowerBound+gid*2)*2:try PDFArchiveFontProgram.u32(array,loca.lowerBound+gid*4)
        forged = bytes;forged.replaceSubrange((glyf.lowerBound+start)..<(glyf.lowerBound+start+2),with:Data([0x7F,0xFF]))
        XCTAssertTrue(try PDFArchiveFontProgram(data:forged).structuralAudit().issues.contains{diagnosticContains($0, "endPtsOfContours")})
        let pdf = fixture(font:"<< /Type /Font /Subtype /TrueType /BaseFont /ArialMT /Encoding /WinAnsiEncoding /FontDescriptor 5 0 R >>",extras:[5:descriptor(file:6),6:stream("",forged)])
        let model = PDFArchiveFontChecks(reader:try PDFStructureDocument(data:pdf),profile:.pdfa2b).modelChecks
        XCTAssertTrue(model.contains{$0.objectType == "EmbeddedFontProgramModel" && $0.status == .failed})
        // Presence of FontFile is a distinct predicate, not structural proof.
        XCTAssertEqual(try evaluate(pdf,profile:.pdfa2b,object:"PDFont",matching:"containsFontFile").status,.passed)
        let unreferenced = fixture(font:"<< /Type /Font /Subtype /TrueType /BaseFont /ArialMT /FontDescriptor 5 0 R >>",content:Data(),extras:[5:descriptor(file:6),6:stream("",forged)])
        XCTAssertTrue(PDFArchiveFontChecks(reader:try PDFStructureDocument(data:unreferenced),profile:.pdfa2b).modelChecks.isEmpty)
    }
    func testSimpleCompositeAndInstructionBoundariesCannotBeCertifiedByCgFontLoading() throws {
        func word(_ value:Int)->Data { Data([UInt8((value>>8)&255),UInt8(value&255)]) }
        let simple = word(1)+Data(repeating:0,count:8)+word(0)+word(0)+Data([0x31])
        XCTAssertTrue(try PDFArchiveFontProgram(data:auditFont(glyphs:[simple])).structuralAudit().issues.isEmpty)
        let cycle = word(65535)+Data(repeating:0,count:8)+word(3)+word(0)+Data(repeating:0,count:4)
        XCTAssertTrue(try PDFArchiveFontProgram(data:auditFont(glyphs:[cycle])).structuralAudit().issues.contains{diagnosticContains($0, "ciclo")})
        let outside = word(65535)+Data(repeating:0,count:8)+word(3)+word(2)+Data(repeating:0,count:4)
        XCTAssertTrue(try PDFArchiveFontProgram(data:auditFont(glyphs:[outside])).structuralAudit().issues.contains{diagnosticContains($0, "GID fuori")})
        let truncatedPush = word(1)+Data(repeating:0,count:8)+word(0)+word(1)+Data([0xB0,0x31])
        let invalid = try PDFArchiveFontProgram(data:auditFont(glyphs:[truncatedPush])).structuralAudit()
        XCTAssertTrue(invalid.issues.contains{diagnosticContains($0, "PUSH troncato")});XCTAssertFalse(invalid.instructionScanComplete)
        let badFpgm = try PDFArchiveFontProgram(data:auditFont(glyphs:[simple],fpgm:Data([0x40,2,1]))).structuralAudit()
        XCTAssertTrue(badFpgm.issues.contains{($0.contains("fpgm: ") && diagnosticContains($0, "PUSH troncato"))})
        let tokensOnly = try PDFArchiveFontProgram(data:auditFont(glyphs:[simple],fpgm:Data([0xB0,0,0x21]))).structuralAudit()
        XCTAssertTrue(tokensOnly.issues.isEmpty);XCTAssertTrue(tokensOnly.gaps.contains{diagnosticContains($0, "hinting non eseguiti")})
    }
    private func auditFont(glyphs:[Data],fpgm:Data = Data(),extraTables:[String:Data] = [:],maxima:[Int] = [4,1,4,1,2,0,0,0,0,8,64,3,8])->Data {
        func word(_ value:Int)->Data { Data([UInt8((value>>8)&255),UInt8(value&255)]) }
        func dword(_ value:Int)->Data { Data([UInt8((value>>24)&255),UInt8((value>>16)&255),UInt8((value>>8)&255),UInt8(value&255)]) }
        var head = Data(repeating:0,count:54);head.replaceSubrange(12..<16,with:dword(0x5F0F3CF5));head.replaceSubrange(18..<20,with:word(1000));head.replaceSubrange(50..<52,with:word(1))
        var maxp = dword(0x10000)+word(glyphs.count)
        for field in maxima { maxp += word(field) }
        var hhea = Data(repeating:0,count:36);hhea.replaceSubrange(34..<36,with:word(glyphs.count))
        var glyf = Data(),loca = Data()
        for glyph in glyphs { loca += dword(glyf.count);glyf += glyph;if glyf.count%2 != 0 { glyf.append(0) } };loca += dword(glyf.count)
        var tables:[String:Data] = ["head":head,"maxp":maxp,"hhea":hhea,"hmtx":Data(),"loca":loca,"glyf":glyf]
        for _ in glyphs { tables["hmtx"]! += word(500)+word(0) };if !fpgm.isEmpty { tables["fpgm"] = fpgm }
        tables.merge(extraTables){_,new in new}
        var result = dword(0x10000)+word(tables.count)+Data(repeating:0,count:6),payload = Data();let start = 12+tables.count*16
        for (tag,data) in tables.sorted(by:{$0.key<$1.key}) { result += Data(tag.utf8)+dword(0)+dword(start+payload.count)+dword(data.count);payload += data;while payload.count%4 != 0 { payload.append(0) } }
        return result+payload
    }
    func testCffDeclaredWidthsUsePrivateDefaultsNominalAndRealSubroutineBiases() throws {
        // defaultWidthX500, nominalWidthX100; no native-font name or metric API.
        let parameters = Data([248,136,20,239,21]),subr = Data([139,139,21,11])
        let cases:[(Data,[Data],[Data],Double)] = [(Data([14]),[],[],500),(Data([189,14]),[],[],150),(Data([159,169,12,10,14]),[],[],150),(Data([189,32,10,14]),[subr],[],150),(Data([189,32,29,14]),[],[subr],150)]
        for (characters,local,global,expected) in cases {
            let bytes = cffFixture(charset:0,encoding:0,count:35,privateDictionary:parameters,characters:[34:characters],localSubrs:local,globalSubrs:global)
            let program = try PDFArchiveFontProgram(data:bytes)
            XCTAssertEqual(try program.cff?.declaredAdvance(glyph:34),expected)
            XCTAssertEqual(try program.advance(glyph:34),expected)
            let font = "<< /Type /Font /Subtype /Type1 /BaseFont /NativeCFF /FirstChar 65 /LastChar 65 /Widths [\(expected)] /FontDescriptor 5 0 R >>"
            let pdf = fixture(font:font,extras:[5:Data("<< /Flags 32 /FontFile3 6 0 R >>".utf8),6:stream("/Subtype /Type1C",bytes)])
            XCTAssertEqual(try evaluate(pdf,object:"Glyph",matching:"widthFromFontProgram").status,.passed)
        }
        let bad = cffFixture(charset:0,encoding:0,count:35,privateDictionary:parameters,characters:[34:Data([33,10,14])],localSubrs:[subr])
        XCTAssertThrowsError(try PDFArchiveFontProgram(data:bad).cff?.declaredAdvance(glyph:34))
    }
    func testPdfVerticalGrammarRejectsMalformedTripletsButDoesNotInventFontOriginAgreement() throws {
        let data = auditFont(glyphs:[Data(),Data()]),parent = "<< /Type /Font /Subtype /Type0 /BaseFont /Native /Encoding /Identity-V /DescendantFonts [5 0 R] >>"
        for (metrics,failed) in [("/DW2 [123 456] /W2 [1 [-777 1234 -22]]",false),("/DW2 [880]",true),("/W2 [1 [-1000 250]]",true),("/W2 [65535 [-1000 500 880 -1000 500 880]]",true)] {
            let child = Data("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Native /CIDToGIDMap /Identity /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 6 0 R /W [1 [500]] \(metrics) >>".utf8)
            let pdf = fixture(font:parent,content:Data("BT /F1 12 Tf <0001> Tj ET".utf8),extras:[5:child,6:descriptor(file:7),7:stream("",data)])
            XCTAssertEqual(try evaluate(pdf,object:"Glyph",matching:"widthFromFontProgram").status,.passed)
            let model = PDFArchiveFontChecks(reader:try PDFStructureDocument(data:pdf),profile:.pdfa2b).modelChecks
            XCTAssertEqual(model.contains{$0.id.hasSuffix("vertical-dictionary") && $0.status == .failed},failed)
        }
    }
    func testSfntCmapBodiesMaxpAndAllLocaOffsetsAreVerified() throws {
        let data = try nativeTrueType(),program = try PDFArchiveFontProgram(data:data)
        let record = try XCTUnwrap(program.cmapRecords.first{$0.platform == 3 && $0.encoding == 1})
        XCTAssertEqual(try PDFArchiveFontProgram.u16(Array(data),record.offset),4)
        var bad = data;bad.replaceSubrange((record.offset+6)..<(record.offset+8),with:Data([0,1]))
        XCTAssertTrue(try PDFArchiveFontProgram(data:bad).structuralAudit().issues.contains{diagnosticContains($0, "cmap4 segCount")})
        let count = try PDFArchiveFontProgram.u16(Array(data),4)
        let maxpEntry = try XCTUnwrap((0..<count).map{12+$0*16}.first{String(decoding:data[$0..<($0+4)],as:UTF8.self) == "maxp"})
        bad = data;bad.replaceSubrange((maxpEntry+12)..<(maxpEntry+16),with:Data([0,0,0,6]))
        XCTAssertTrue(try PDFArchiveFontProgram(data:bad).structuralAudit().issues.contains{diagnosticContains($0, "maxp versione1.0 e32byte")})
        let loca = try XCTUnwrap(program.tables["loca"]),head = try XCTUnwrap(program.tables["head"])
        let size = try PDFArchiveFontProgram.u16(Array(data),head.lowerBound+50) == 0 ? 2:4
        bad = data;bad.replaceSubrange((loca.lowerBound+size)..<(loca.lowerBound+size*2),with:Data(repeating:255,count:size))
        XCTAssertTrue(try PDFArchiveFontProgram(data:bad).structuralAudit().issues.contains{diagnosticContains($0, "loca offset non monotoni/fuori glyf")})
    }
    private func fontWord(_ value:Int)->Data { Data([UInt8((value>>8)&255),UInt8(value&255)]) }
    private func fontDword(_ value:Int)->Data { Data([UInt8((value>>24)&255),UInt8((value>>16)&255),UInt8((value>>8)&255),UInt8(value&255)]) }
    private func fontTriple(_ value:Int)->Data { Data([UInt8((value>>16)&255),UInt8((value>>8)&255),UInt8(value&255)]) }
    private func cmapTable(_ records:[(Int,Int,Data)])->Data {
        var result = fontWord(0)+fontWord(records.count),payload = Data()
        for (platform,encoding,data) in records { result += fontWord(platform)+fontWord(encoding)+fontDword(4+records.count*8+payload.count);payload += data }
        return result+payload
    }
    private func fontWithCmap(_ records:[(Int,Int,Data)]) throws -> PDFArchiveFontProgram {
        try PDFArchiveFontProgram(data:auditFont(glyphs:Array(repeating:Data(),count:4),extraTables:["cmap":cmapTable(records)]))
    }
    func testCmap2MixedByteSubHeadersDeltasAndEveryRangeAreVerified() throws {
        var keys = Data(repeating:0,count:512);keys.replaceSubrange((0x81*2)..<(0x81*2+2),with:fontWord(8))
        var singles = Data(repeating:0,count:512);singles.replaceSubrange(130..<132,with:fontWord(1))
        var subheaders = fontWord(0)+fontWord(256)+fontWord(0)+fontWord(10)
        subheaders += fontWord(0x40)+fontWord(2)+fontWord(65535)+fontWord(514)
        var mapping = fontWord(2)+fontWord(1050)+fontWord(0)
        mapping += keys+subheaders+singles+fontWord(3)+fontWord(0)
        let program = try fontWithCmap([(3,2,mapping)])
        XCTAssertTrue(program.structuralAudit().issues.isEmpty)
        XCTAssertEqual(try program.glyph(encodedCode:65,platform:3,encoding:2),1)
        XCTAssertEqual(try program.glyph(encodedCode:0x8140,platform:3,encoding:2),2)
        XCTAssertEqual(try program.glyph(encodedCode:0x8141,platform:3,encoding:2),0)
        XCTAssertEqual(try program.glyph(encodedCode:0x81,platform:3,encoding:2),0)
        XCTAssertEqual(try program.glyph(encodedCode:0x8240,platform:3,encoding:2),0)
        for (offset,value,reason) in [(6+0x81*2,7,"subHeaderKey"),(518+8,255,"firstCode/entryCount"),(518+14,65534,"idRangeOffset"),(1046,20,"GID fuori")] {
            var bad = mapping;bad.replaceSubrange(offset..<(offset+2),with:fontWord(value))
            let forged = try fontWithCmap([(3,2,bad)])
            XCTAssertTrue(forged.structuralAudit().issues.contains{diagnosticContains($0, reason)},reason)
            XCTAssertThrowsError(try forged.glyph(encodedCode:65,platform:3,encoding:2))
        }
    }
    func testCmap8RawMixedCodeMappingChecksIs32GroupsAndConvertsUnicodeToUtf16Units() throws {
        var bits = Data(repeating:0,count:8192);bits[0xD800/8] = 128
        var groups = fontDword(65)+fontDword(65)+fontDword(1)
        groups += fontDword(0xD800DC00)+fontDword(0xD800DC01)+fontDword(2)
        var mapping = fontWord(8)+fontWord(0)+fontDword(8232)+fontDword(0)
        mapping += bits+fontDword(2)+groups
        let program = try fontWithCmap([(0,4,mapping)])
        XCTAssertTrue(program.structuralAudit().issues.isEmpty)
        XCTAssertEqual(try program.glyph(unicode:65),1)
        XCTAssertEqual(try program.glyph(encodedCode:0xD800DC00,platform:0,encoding:4),2)
        XCTAssertEqual(try program.glyph(encodedCode:0xD800DC01,platform:0,encoding:4),3)
        XCTAssertEqual(try program.glyph(unicode:0x10000),2)
        XCTAssertEqual(try program.glyph(unicode:0x10001),3)
        XCTAssertNil(try program.glyph(unicode:0xD800))
        XCTAssertNil(try program.glyph(unicode:0x110000))
        for (offset,replacement,reason) in [(12+0xD800/8,Data([0]),"senza is32"),(12+65/8,Data([64]),"codice16"),(8208+16,fontDword(0xD800DC03),"GID fuori"),(2,fontWord(1),"reserved")] {
            var bad = mapping;bad.replaceSubrange(offset..<(offset+replacement.count),with:replacement)
            XCTAssertTrue(try fontWithCmap([(0,4,bad)]).structuralAudit().issues.contains{diagnosticContains($0, reason)},reason)
        }
    }
    func testCmap14DefaultAndNonDefaultSequencesAreSupplementalWithStrictBoundsAndPartition() throws {
        var base = fontWord(6)+fontWord(14)+fontWord(0)
        base += fontWord(65)+fontWord(2)+fontWord(1)+fontWord(1)
        var variation = fontWord(14)+fontDword(38)+fontDword(1)
        variation += fontTriple(0xFE0F)+fontDword(21)+fontDword(29)
        variation += fontDword(1)+fontTriple(65)+Data([0])
        variation += fontDword(1)+fontTriple(66)+fontWord(2)
        let program = try fontWithCmap([(0,3,base),(0,5,variation)])
        XCTAssertTrue(program.structuralAudit().issues.isEmpty)
        XCTAssertEqual(try program.glyph(unicode:65),1)
        XCTAssertEqual(try program.variationGlyph(unicode:65,selector:0xFE0F),1)
        XCTAssertEqual(try program.variationGlyph(unicode:66,selector:0xFE0F),2)
        XCTAssertNil(try program.variationGlyph(unicode:67,selector:0xFE0F))
        XCTAssertNil(try program.variationGlyph(unicode:65,selector:0xE0100))
        for (offset,replacement,reason) in [(13,fontDword(5),"offset UVS"),(33,fontTriple(65),"default e non-default"),(36,fontWord(4),"GID fuori"),(25,fontTriple(0xD800),"range non valido"),(29,fontDword(100),"UVS troncata"),(10,fontTriple(65),"selector non valido")] {
            var bad = variation;bad.replaceSubrange(offset..<(offset+replacement.count),with:replacement)
            let forged = try fontWithCmap([(0,3,base),(0,5,bad)])
            XCTAssertTrue(forged.structuralAudit().issues.contains{diagnosticContains($0, reason)},reason)
            XCTAssertThrowsError(try forged.variationGlyph(unicode:65,selector:0xFE0F))
        }
        XCTAssertTrue(try fontWithCmap([(3,1,variation)]).structuralAudit().issues.contains{diagnosticContains($0, "platform0/encoding5")})
    }
    func testCmap10SupplementaryTrimmedArrayMapsActualGlyphsAndRejectsTruncatedBody() throws {
        var mapping = fontWord(10)+fontWord(0)+fontDword(24)+fontDword(0)
        mapping += fontDword(0x10000)+fontDword(2)+fontWord(2)+fontWord(3)
        let program = try fontWithCmap([(0,4,mapping)])
        XCTAssertTrue(program.structuralAudit().issues.isEmpty)
        XCTAssertEqual(try program.glyph(unicode:0x10000),2)
        XCTAssertEqual(try program.glyph(unicode:0x10001),3)
        XCTAssertEqual(try program.glyph(unicode:0x10002),0)
        mapping.replaceSubrange(16..<20,with:fontDword(3))
        let invalid = try fontWithCmap([(0,4,mapping)])
        XCTAssertTrue(invalid.structuralAudit().issues.contains{diagnosticContains($0, "cmap10 range")})
        XCTAssertThrowsError(try invalid.glyph(unicode:0x10000))
    }
    private func cidCffFixture(format:Int,fdMatrix:Data = Data())->(bytes:Data,private1:Int,fdSelect:Int,fdArray:Int,local1:Int) {
        func number(_ value:Int)->Data { Data([29])+fontDword(value) }
        func index(_ values:[Data])->Data {
            if values.isEmpty { return fontWord(0) };var result = fontWord(values.count)+Data([2]),offset = 1
            for value in values { result += fontWord(offset);offset += value.count };result += fontWord(offset)
            for value in values { result += value };return result
        }
        let header = Data([1,0,4,4]),name = index([Data("CIDTest".utf8)]),strings = index([Data("Adobe".utf8),Data("Identity".utf8)])
        let globals = index([Data([32,10,11])]),charset = Data([0])+fontWord(10)+fontWord(20)+fontWord(30)
        let characters = index([Data([14]),Data([189,32,10,14]),Data([14]),Data([189,32,29,14])])
        let selection = format == 0 ? Data([0,0,0,1,1]):Data([3,0,2,0,0,0,0,2,1,0,4])
        let parameters0 = Data([248,136,20,239,21]),parameters1 = Data([249,180,20,247,192,21]),local = index([Data([139,139,21,11])])
        let private0 = parameters0+number(parameters0.count+6)+Data([19]),private1 = parameters1+number(parameters1.count+6)+Data([19])
        let topCount = 43,prefix = header.count+name.count+7+topCount+strings.count+globals.count
        let charOffset = prefix+charset.count,fdArrayOffset = charOffset+characters.count,fdArrayCount = 9+22+fdMatrix.count
        let selectOffset = fdArrayOffset+fdArrayCount,p0 = selectOffset+selection.count,p1 = p0+private0.count+local.count
        let dictionaries = index([number(private0.count)+number(p0)+Data([18]),number(private1.count)+number(p1)+Data([18])+fdMatrix])
        var top = number(391)+number(392)+number(0)+Data([12,30])
        top += number(prefix)+Data([15])+number(charOffset)+Data([17])
        top += number(fdArrayOffset)+Data([12,36])+number(selectOffset)+Data([12,37])
        var data = header+name+index([top])+strings+globals
        data += charset+characters+dictionaries+selection
        data += private0+local+private1+local
        return (data,p1,selectOffset,fdArrayOffset,p1+private1.count)
    }
    func testCidCffBothFdSelectFormatsUseCorrectPrivateWidthsAndGlobalToLocalContext() throws {
        for format in [0,3] {
            let fixture = cidCffFixture(format:format),program = try PDFArchiveFontProgram(data:fixture.bytes)
            XCTAssertEqual(program.cff?.cidByGlyph,[0:0,1:10,2:20,3:30])
            for (glyph,width) in [500.0,150.0,800.0,350.0].enumerated() {
                XCTAssertEqual(try XCTUnwrap(program.cff?.declaredAdvance(glyph:glyph)),width,accuracy:0.0000001)
                XCTAssertEqual(try XCTUnwrap(program.advance(glyph:glyph)),width,accuracy:0.0000001)
            }
            XCTAssertTrue(program.structuralAudit().issues.isEmpty)
            XCTAssertFalse(program.structuralAudit().gaps.contains{diagnosticContains($0, "non inventariati")})
            XCTAssertTrue(program.structuralAudit().gaps.contains{diagnosticContains($0, "Esecuzione completa Type2")})
            let parent = "<< /Type /Font /Subtype /Type0 /BaseFont /CIDTest /Encoding /Identity-H /DescendantFonts [5 0 R] >>"
            for width in [350,351,352] {
                let child = Data("<< /Type /Font /Subtype /CIDFontType0 /BaseFont /CIDTest /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 6 0 R /W [30 [\(width)]] >>".utf8)
                let data = self.fixture(font:parent,content:Data("BT /F1 12 Tf <001E> Tj ET".utf8),extras:[5:child,6:Data("<< /Flags 4 /FontFile3 7 0 R >>".utf8),7:stream("/Subtype /CIDFontType0C",fixture.bytes)])
                XCTAssertEqual(try evaluate(data,object:"Glyph",matching:"widthFromFontProgram").status,width<=351 ? .passed:.failed)
            }
        }
    }
    func testCidCffInventoryRejectsAnyInvalidFdPrivateAndSubrsBeforeWidthLookup() throws {
        let fixture = cidCffFixture(format:0)
        for (offset,replacement) in [(fixture.fdSelect+4,Data([2])),(fixture.fdArray+9+11+6,fontDword(fixture.bytes.count+100)),(fixture.private1+7,fontDword(65535)),(fixture.local1+3,fontWord(0))] {
            var bad = fixture.bytes;bad.replaceSubrange(offset..<(offset+replacement.count),with:replacement)
            // GID0 selects FD0: invalid data in FD1 must not escape inventory.
            XCTAssertThrowsError(try PDFArchiveFontProgram(data:bad))
        }
        let ranges = cidCffFixture(format:3)
        for (offset,replacement) in [(ranges.fdSelect+3,fontWord(1)),(ranges.fdSelect+6,fontWord(0)),(ranges.fdSelect+9,fontWord(3)),(ranges.fdSelect+8,Data([2]))] {
            var bad = ranges.bytes;bad.replaceSubrange(offset..<(offset+replacement.count),with:replacement)
            XCTAssertThrowsError(try PDFArchiveFontProgram(data:bad))
        }
    }
    func testCidFdFontMatrixRemainsExplicitlyUnresolvedAndDictTrailingOperandsAreRejected() throws {
        let bytes = cidCffFixture(format:0,fdMatrix:Data([140,139,139,140,139,139,12,7])).bytes
        let program = try PDFArchiveFontProgram(data:bytes)
        XCTAssertEqual(try program.cff?.declaredAdvance(glyph:1),150)
        XCTAssertNil(try program.cff?.declaredAdvance(glyph:3))
        XCTAssertTrue(program.structuralAudit().gaps.contains{diagnosticContains($0, "FD FontMatrix")})
        XCTAssertThrowsError(try PDFArchiveCFF.dictionary(Data([139])))
        XCTAssertThrowsError(try PDFArchiveCFF.dictionary(Data([22,20])))
    }
    func testCmap8SupplementaryConversionUsesSurrogateBoundaryAndMaximumScalarWithoutRawScalarFallback() throws {
        for (unicode,packed) in [(0x10000,0xD800DC00),(0x10400,0xD801DC00),(0x1F600,0xD83DDE00),(0x10FFFF,0xDBFFDFFF)] {
            var bits = Data(repeating:0,count:8192);let high = packed>>16;bits[high/8] = UInt8(1<<(7-high%8))
            var mapping = fontWord(8)+fontWord(0)+fontDword(8220)+fontDword(0)
            mapping += bits+fontDword(1)+fontDword(packed)+fontDword(packed)+fontDword(2)
            let program = try fontWithCmap([(0,4,mapping)])
            XCTAssertTrue(program.structuralAudit().issues.isEmpty)
            XCTAssertEqual(try program.glyph(unicode:UInt32(unicode)),2)
            XCTAssertEqual(try program.glyph(encodedCode:UInt32(packed),platform:0,encoding:4),2)
            XCTAssertEqual(try program.glyph(encodedCode:UInt32(unicode),platform:0,encoding:4),0)
            let bmp = fontWord(6)+fontWord(12)+fontWord(0)+fontWord(65)+fontWord(1)+fontWord(1)
            let mixed = try fontWithCmap([(0,3,bmp),(0,4,mapping)])
            XCTAssertEqual(try mixed.glyph(unicode:UInt32(unicode)),2)
        }
    }
    private func type2Audit(_ characters:Data,privateDictionary:Data = Data(),local:[Data] = [],global:[Data] = [],maximumOperations:Int = 2_000_000) throws -> PDFArchiveFontProgramAudit {
        let bytes = cffFixture(charset:0,encoding:0,count:2,privateDictionary:privateDictionary,characters:[1:characters],localSubrs:local,globalSubrs:global)
        return try XCTUnwrap(PDFArchiveFontProgram(data:bytes).cff).programAudit(maximumOperations:maximumOperations)
    }
    func testType2PathAndFlexAritiesAreCheckedAfterTheActualMovePoint() throws {
        let move = Data([139,139,21])
        for (op,count) in [(5,2),(6,1),(7,1),(8,6),(24,8),(25,8),(26,4),(27,5),(30,8),(31,9),(1234,7),(1235,13),(1236,9),(1237,11)] {
            let operation = op>=1200 ? Data([12,UInt8(op-1200)]):Data([UInt8(op)])
            let valid = move+Data(repeating:139,count:count)+operation+Data([14])
            let result = try type2Audit(valid)
            XCTAssertTrue(result.issues.isEmpty,"\(op): " + result.issues.joined(separator:"; "))
            XCTAssertEqual(result.checkedGlyphs,2)
            XCTAssertTrue(result.gaps.contains{diagnosticContains($0, "Esecuzione completa Type2")})
            let invalidCount = [27,31].contains(op) ? 2:count-1
            let invalid = move+Data(repeating:139,count:invalidCount)+operation+Data([14])
            XCTAssertTrue(try type2Audit(invalid).issues.contains{diagnosticContains($0, "arità operatore path")},"\(op)")
        }
        XCTAssertTrue(try type2Audit(Data([139,139,5,14])).issues.contains{diagnosticContains($0, "senza moveto")})
        XCTAssertTrue(try type2Audit(move).issues.contains{diagnosticContains($0, "endchar assente")})
        XCTAssertTrue(try type2Audit(Data([11])).issues.contains{diagnosticContains($0, "return fuori")})
        for code in [Data(),Data([28,0]),Data([255,0,0]),Data([12])] { XCTAssertFalse(try type2Audit(code).issues.isEmpty) }
    }
    func testType2HintMasksConsumeBinaryBytesAndValidateUnusedBitsAndDeclarationBoundaries() throws {
        let tail = Data([139,139,21,14])
        for code in [Data([139,189,18,19,128])+tail,Data([139,189,18,139,189,19,192])+tail,Data(repeating:139,count:16)+Data([18,19,31])+tail] {
            XCTAssertTrue(try type2Audit(code).issues.isEmpty)
        }
        for (code,reason) in [(Data([139,189,18,19]),"troncata"),(Data([19,0,14]),"senza stem"),(Data([139,189,18,19,129])+tail,"bit inutilizzati"),(Data([139,189,18,139,139,21,139,189,19,192,14]),"posizione dichiarazione")] {
            XCTAssertTrue(try type2Audit(code).issues.contains{diagnosticContains($0, reason)},reason)
        }
    }
    func testType2SubroutinesShareStackAndTerminateViaReturnOrEndcharWithoutInventingMissingBounds() throws {
        let move = Data([139,139,21])
        XCTAssertTrue(try type2Audit(Data([32,10,14]),local:[move+Data([11])]).issues.isEmpty)
        XCTAssertTrue(try type2Audit(Data([32,29]),global:[Data([14])]).issues.isEmpty)
        XCTAssertTrue(try type2Audit(Data([32,10,14]),local:[move]).issues.contains{diagnosticContains($0, "senza return/endchar")})
        XCTAssertTrue(try type2Audit(Data([33,10,14]),local:[Data([11])]).issues.contains{diagnosticContains($0, "fuori INDEX")})
        let recursion = try type2Audit(Data([32,10,14]),local:[Data([32,10,11])])
        XCTAssertTrue(recursion.issues.isEmpty)
        XCTAssertTrue(recursion.gaps.contains{diagnosticContains($0, "budget/nesting")})
    }
    func testType2DeterministicArithmeticTransientAndConditionalStackAreAuditedButUndefinedAndLegacyCasesStayUnknown() throws {
        let cases:[Data] = [Data([159,169,12,10,14]),Data([189,139,12,20,139,12,21,14]),Data([159,169,140,141,12,22,14]),Data([189,138,12,29,12,10,14]),Data([159,169,141,140,12,30,12,11,14]),Data([12,0,14])]
        for code in cases { XCTAssertTrue(try type2Audit(code).issues.isEmpty) }
        for code in [Data([139,12,21,14]),Data([138,12,26,14]),Data([12,23,14]),Data([16,14]),Data([12,8,14]),Data([139,139,204,236,14])] {
            let audit = try type2Audit(code)
            XCTAssertTrue(audit.issues.isEmpty)
            XCTAssertTrue(audit.gaps.contains{$0.hasPrefix("CFF GID")})
        }
        XCTAssertTrue(try type2Audit(Data([12,10,14])).issues.contains{diagnosticContains($0, "stack insufficiente")})
        XCTAssertTrue(try type2Audit(Data([139,139,21])+Data(repeating:139,count:49)+Data([8,14])).issues.contains{diagnosticContains($0, "oltre48")})
        let budget = try type2Audit(Data([139,139,21,14]),maximumOperations:1)
        XCTAssertTrue(budget.issues.isEmpty);XCTAssertTrue(budget.gaps.contains{diagnosticContains($0, "budget/nesting")})
    }
    func testCffPrivateOperandCardinalityAndInvalidEmbeddedType2GlyphProduceIndependentModelFailures() throws {
        for dictionary in [Data([139,6]),Data([139,140,10]),Data(repeating:139,count:13)+Data([12,12])] {
            XCTAssertTrue(try type2Audit(Data([14]),privateDictionary:dictionary).issues.contains{diagnosticContains($0, "Private")})
        }
        let characters = Data([139,139,21,139,5,14])
        let bytes = cffFixture(charset:0,encoding:0,count:35,characters:[34:characters])
        let font = "<< /Type /Font /Subtype /Type1 /BaseFont /NativeCFF /Encoding /WinAnsiEncoding /FontDescriptor 5 0 R >>"
        let pdf = fixture(font:font,extras:[5:Data("<< /Flags 32 /FontFile3 6 0 R >>".utf8),6:stream("/Subtype /Type1C",bytes)])
        for profile in [PDFArchiveProfile.pdfa1b,.pdfa2u,.pdfa4] {
            let rows = PDFArchiveFontChecks(reader:try PDFStructureDocument(data:pdf),profile:profile).modelChecks
            XCTAssertTrue(rows.contains{$0.objectType == "EmbeddedFontProgramModel" && $0.status == .failed})
            XCTAssertTrue(rows.contains{$0.objectType == "FontBytecodeModel" && $0.status == .notVerified})
        }
        // Presence is an independent predicate, not a bytecode validity claim.
        XCTAssertEqual(try evaluate(pdf,object:"Glyph",matching:"isGlyphPresent").status,.passed)
    }
    func testNativeCffAllCharstringsAreStructurallyAuditedWithoutClaimingHintGeometry() throws {
        let bytes = try Data(contentsOf:URL(fileURLWithPath:"/System/Library/Fonts/Supplemental/STIXGeneral.otf"))
        let program = try PDFArchiveFontProgram(data:bytes),audit = program.structuralAudit()
        XCTAssertTrue(audit.issues.isEmpty,audit.issues.prefix(8).joined(separator:"; "))
        XCTAssertGreaterThan(audit.checkedGlyphs,100)
        XCTAssertGreaterThan(audit.instructionBytes,0)
        XCTAssertTrue(audit.gaps.contains{diagnosticContains($0, "Esecuzione completa Type2")})
        XCTAssertFalse(audit.instructionScanComplete)
    }
    private let ttMaxima = [512,8,1024,32,2,0,0,0,0,64,64,8,16]
    private func ttSimple(_ points:[(Int,Int)],instructions:Data = Data())->Data {
        var result = fontWord(points.isEmpty ? 0:1)
        result += fontWord(points.map{$0.0}.min() ?? 0)+fontWord(points.map{$0.1}.min() ?? 0)
        result += fontWord(points.map{$0.0}.max() ?? 0)+fontWord(points.map{$0.1}.max() ?? 0)
        if !points.isEmpty { result += fontWord(points.count-1) }
        result += fontWord(instructions.count)+instructions+Data(repeating:1,count:points.count)
        var previous = 0
        for point in points { result += fontWord(point.0-previous);previous = point.0 }
        previous = 0
        for point in points { result += fontWord(point.1-previous);previous = point.1 }
        return result
    }
    private func ttComposite(_ components:[(gid:Int,flags:Int,a:Int,b:Int)],contours:Int = -1,instructions:Data = Data())->Data {
        var result = fontWord(contours)+fontWord(-32768)+fontWord(-32768)+fontWord(32767)+fontWord(32767)
        for component in components {
            result += fontWord(component.flags)+fontWord(component.gid)
            if component.flags&1 != 0 { result += fontWord(component.a)+fontWord(component.b) }
            else { result += Data([UInt8(component.a&255),UInt8(component.b&255)]) }
        }
        if components.contains(where:{$0.flags&256 != 0}) { result += fontWord(instructions.count)+instructions }
        return result
    }
    func testTrueTypeNegativeContourCountsAreCompositeAndInstructionsMayBeFlaggedOnAnyComponent() throws {
        let simple = ttSimple([(0,0)])
        // -1 is recommended, not required; the instruction bit can be on an
        // earlier component, and instructions still follow the last component.
        for contours in [-1,-2,-32768] {
            let composite = ttComposite([(0,0x123,0,0),(0,3,-10,20)],contours:contours,instructions:Data([0xB0,0,0x21]))
            let audit = try PDFArchiveFontProgram(data:auditFont(glyphs:[simple,composite],maxima:ttMaxima)).structuralAudit()
            XCTAssertTrue(audit.issues.isEmpty,audit.issues.joined(separator:"; "))
            XCTAssertTrue(audit.instructionScanComplete)
            XCTAssertTrue(audit.gaps.contains{diagnosticContains($0, "hinting non eseguiti")})
        }
    }
    func testTrueTypeCompositePointMatchingAcceptsContourAndPhantomIndicesWithoutPretendingHintGeometry() throws {
        let simple = ttSimple([(0,0)]),composite = ttComposite([(0,0x23,0,0),(0,1,4,4)])
        let audit = try PDFArchiveFontProgram(data:auditFont(glyphs:[simple,composite],maxima:ttMaxima)).structuralAudit()
        XCTAssertTrue(audit.issues.isEmpty,audit.issues.joined(separator:"; "))
        XCTAssertTrue(audit.instructionScanComplete)
        // Index4 is the fourth phantom point after the original point0.
        // Geometry of the matched/hinted coordinates remains unproved.
        XCTAssertFalse(audit.gaps.contains{diagnosticContains($0, "Associazioni punto-punto")})
    }
    func testTrueTypeCompositePointMatchingRejectsFirstComponentAndOutOfRangeParentOrChild() throws {
        let simple = ttSimple([(0,0)])
        let cases:[([(gid:Int,flags:Int,a:Int,b:Int)],String)] = [
            ([(0,1,0,0)],"primo componente"),
            ([(0,0x23,0,0),(0,1,6,4)],"punto parent fuori"),
            ([(0,0x23,0,0),(0,1,4,5)],"punto componente fuori"),
            ([(0,0x23,0,0),(0,1,65535,4)],"punto parent fuori"),
            ([(0,0x23,0,0),(0,0,4,255)],"punto componente fuori")]
        for (components,reason) in cases {
            let audit = try PDFArchiveFontProgram(data:auditFont(glyphs:[simple,ttComposite(components)],maxima:ttMaxima)).structuralAudit()
            XCTAssertTrue(audit.issues.contains{diagnosticContains($0, reason)},audit.issues.joined(separator:"; "))
        }
    }
    func testTrueTypeCompositeUnsignedBytePointIndicesAndNestedExpandedPointsAreVerified() throws {
        let many = ttSimple((0..<300).map{($0,0)})
        let bytes = ttComposite([(0,0x23,0,0),(0,0,255,255)])
        XCTAssertTrue(try PDFArchiveFontProgram(data:auditFont(glyphs:[many,bytes],maxima:ttMaxima)).structuralAudit().issues.isEmpty)
        let simple = ttSimple([(0,0),(1,1)])
        let child = ttComposite([(0,0x23,0,0),(0,3,0,0)]) // four expanded points
        let parent = ttComposite([(1,0x23,0,0),(0,1,7,5)]) // parent4+4 / child2+4
        var audit = try PDFArchiveFontProgram(data:auditFont(glyphs:[simple,child,parent],maxima:ttMaxima)).structuralAudit()
        XCTAssertTrue(audit.issues.isEmpty,audit.issues.joined(separator:"; "))
        let invalid = ttComposite([(1,0x23,0,0),(0,1,10,5)])
        audit = try PDFArchiveFontProgram(data:auditFont(glyphs:[simple,child,invalid],maxima:ttMaxima)).structuralAudit()
        XCTAssertTrue(audit.issues.contains{diagnosticContains($0, "punto parent fuori")})
    }
    func testTrueTypePackedCoordinateDeltasAndActualBoundsAreCheckedIncludingOffCurvePoints() throws {
        // (7,9),(-5,-2),(-5,-2): positive-short, negative-short, same.
        var packed = fontWord(1)+fontWord(-5)+fontWord(-2)+fontWord(7)+fontWord(9)
        packed += fontWord(2)+fontWord(0)+Data([0x37,0x06,0x31,7,12,9,11])
        let valid = try PDFArchiveFontProgram(data:auditFont(glyphs:[packed])).structuralAudit()
        XCTAssertTrue(valid.issues.isEmpty,valid.issues.joined(separator:"; "))
        for (range,value) in [(6..<8,6),(4..<6,-1)] {
            var invalid = packed;invalid.replaceSubrange(range,with:fontWord(value))
            let audit = try PDFArchiveFontProgram(data:auditFont(glyphs:[invalid])).structuralAudit()
            XCTAssertTrue(audit.issues.contains{diagnosticContains($0, "bounding box non contiene")})
        }
        var repeated = fontWord(1)+fontWord(0)+fontWord(0)+fontWord(3)+fontWord(0)
        repeated += fontWord(2)+fontWord(0)+Data([0x3B,2,1,1,1])
        XCTAssertTrue(try PDFArchiveFontProgram(data:auditFont(glyphs:[repeated])).structuralAudit().issues.isEmpty)
    }
    func testTrueTypeMaxpCompositeMaximaUseExpandedContoursPointsAndActualNestingDepth() throws {
        let simple = ttSimple([(0,0),(1,1)])
        let child = ttComposite([(0,0x23,0,0),(0,3,0,0)])
        let nested = ttComposite([(1,3,0,0)])
        for (field,limit) in [(2,3),(3,1),(12,1)] {
            var maxima = ttMaxima;maxima[field] = limit
            let audit = try PDFArchiveFontProgram(data:auditFont(glyphs:[simple,child,nested],maxima:maxima)).structuralAudit()
            XCTAssertTrue(audit.issues.contains{diagnosticContains($0, "aggregati compositi superano maxp")},"field\(field): " + audit.issues.joined(separator:"; "))
        }
        var maxima = ttMaxima;maxima[11] = 1
        let audit = try PDFArchiveFontProgram(data:auditFont(glyphs:[simple,child],maxima:maxima)).structuralAudit()
        XCTAssertTrue(audit.issues.contains{diagnosticContains($0, "maxComponentElements")})
    }
    func testTrueTypeReservedBitsFailButModernOverlapFlagAndEmptyOutlinesRemainAllowed() throws {
        let simple = ttSimple([(0,0)])
        var reserved = simple;reserved[14] |= 0x80
        XCTAssertTrue(try PDFArchiveFontProgram(data:auditFont(glyphs:[reserved])).structuralAudit().issues.contains{diagnosticContains($0, "riservato bit7")})
        var overlap = simple;overlap[14] |= 0x40
        // Apple older prose reserves bit6; current OpenType defines overlap.
        // Do not turn a current valid extension into an edition-blind failure.
        XCTAssertTrue(try PDFArchiveFontProgram(data:auditFont(glyphs:[overlap])).structuralAudit().issues.isEmpty)
        for bit in [0x2000,0x4000,0x8000] {
            let composite = ttComposite([(0,3|bit,0,0)])
            XCTAssertTrue(try PDFArchiveFontProgram(data:auditFont(glyphs:[simple,composite])).structuralAudit().issues.contains{diagnosticContains($0, "flag componente riservati")})
        }
        let legacy = try PDFArchiveFontProgram(data:auditFont(glyphs:[simple,ttComposite([(0,0x13,0,0)])])).structuralAudit()
        XCTAssertTrue(legacy.issues.isEmpty)
        XCTAssertTrue(legacy.gaps.contains{diagnosticContains($0, "legacy bit4")})
        XCTAssertTrue(try PDFArchiveFontProgram(data:auditFont(glyphs:[Data(),ttSimple([])])).structuralAudit().issues.isEmpty)
    }
    func testTrueTypeIncompleteChildDoesNotInventOutOfRangePointViolationsAndBudgetsStayUnknown() throws {
        let truncated = fontWord(1)+Data(repeating:0,count:8)
        let composite = ttComposite([(0,0x23,0,0),(0,1,400,400)])
        let bad = try PDFArchiveFontProgram(data:auditFont(glyphs:[truncated,composite],maxima:ttMaxima)).structuralAudit()
        XCTAssertTrue(bad.issues.contains{diagnosticContains($0, "endPtsOfContours troncato")})
        XCTAssertFalse(bad.issues.contains{diagnosticContains($0, "punto parent fuori") || diagnosticContains($0, "punto componente fuori")})
        XCTAssertTrue(bad.gaps.contains{diagnosticContains($0, "non interamente decodificati")})
        let program = try PDFArchiveFontProgram(data:auditFont(glyphs:[ttSimple([(0,0)]),ttComposite([(0,3,0,0)])]))
        for audit in [program.structuralAudit(maximumOperations:1),program.structuralAudit(maximumComponentDepth:1)] {
            XCTAssertTrue(audit.issues.isEmpty,audit.issues.joined(separator:"; "))
            XCTAssertTrue(audit.gaps.contains{diagnosticContains($0, "Budget")})
        }
        XCTAssertFalse(program.structuralAudit(maximumOperations:1).instructionScanComplete)
        let numbering = try PDFArchiveFontProgram(data:auditFont(glyphs:[ttSimple([(0,0)]),ttComposite([(0,0x23,0,0),(0,1,5,4)])],maxima:ttMaxima)).structuralAudit()
        XCTAssertTrue(numbering.issues.isEmpty)
        XCTAssertTrue(numbering.gaps.contains{diagnosticContains($0, "Numerazione intermedia phantom")})
    }
    func testTrueTypeCancellationIsUnknownAndActualMalformedBoundsFailEmbeddedModel() async throws {
        let bytes = auditFont(glyphs:[ttSimple([(0,0),(1,1)])])
        let program = try PDFArchiveFontProgram(data:bytes)
        let task = Task { while !Task.isCancelled { await Task.yield() };return program.structuralAudit() }
        task.cancel();let cancelled = await task.value
        XCTAssertTrue(cancelled.issues.isEmpty)
        XCTAssertFalse(cancelled.instructionScanComplete)
        XCTAssertTrue(cancelled.gaps.contains{diagnosticContains($0, "annullata")})
        var malformed = ttSimple([(0,0),(1,1)]);malformed.replaceSubrange(6..<8,with:fontWord(0))
        let pdf = fixture(font:"<< /Type /Font /Subtype /TrueType /BaseFont /Native /FontDescriptor 5 0 R >>",extras:[5:descriptor(file:6),6:stream("",auditFont(glyphs:[malformed]))])
        let rows = try PDFArchiveFontChecks(reader:PDFStructureDocument(data:pdf),profile:.pdfa2b).modelChecks
        XCTAssertTrue(rows.contains{$0.objectType == "EmbeddedFontProgramModel" && $0.status == .failed && diagnosticContains($0.detail, "bounding box non contiene")})
    }
    private func evaluate(_ data:Data,profile:PDFArchiveProfile = .pdfa2u,object:String,matching:String) throws -> PDFArchiveRuleEvaluation {
        let rule = try XCTUnwrap(PDFArchiveValidator.catalogue(profile:profile).first{$0.objectType == object && $0.expression.contains(matching)})
        return try XCTUnwrap(PDFArchiveFontChecks(reader:PDFStructureDocument(data:data),profile:profile).evaluate(rule))
    }
    private func nativeTrueType() throws -> Data { try Data(contentsOf:URL(fileURLWithPath:"/System/Library/Fonts/Supplemental/Arial.ttf")) }
    private func descriptor(file:Int)->Data { Data("<< /Type /FontDescriptor /FontName /ArialMT /Flags 32 /FontBBox [0 0 1000 1000] /ItalicAngle 0 /Ascent 800 /Descent -200 /CapHeight 700 /StemV 80 /FontFile2 \(file) 0 R >>".utf8) }
    private func toUnicode(_ commands:String)->Data { Data(("/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /Test def /CMapType 2 def 1 begincodespacerange <00> <FF> endcodespacerange " + commands + " endcmap end end").utf8) }
    private func stream(_ dictionary:String,_ data:Data)->Data { Data("<< \(dictionary) /Length \(data.count) >>\nstream\n".utf8)+data+Data("\nendstream".utf8) }
    private func fixture(font:String = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",content:Data = Data("BT /F1 12 Tf (A) Tj ET".utf8),extraResources:String = "",pageExtra:String = "",catalogExtra:String = "",extras:[Int:Data] = [:])->Data {
        var objects:[Int:Data] = [1:Data("<< /Type /Catalog /Pages 2 0 R \(catalogExtra) >>".utf8),2:Data("<< /Type /Pages /Count 1 /Kids [3 0 R] >>".utf8),3:Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /Font << /F1 4 0 R >> \(extraResources) >> /Contents 20 0 R \(pageExtra) >>".utf8),4:Data(font.utf8),20:stream("",content)]
        objects.merge(extras){_,new in new};var data = Data("%PDF-1.7\n".utf8),positions:[Int:Int] = [:]
        for id in objects.keys.sorted() { positions[id] = data.count;data += Data("\(id) 0 obj\n".utf8)+objects[id]!+Data("\nendobj\n".utf8) }
        let start = data.count,size = (objects.keys.max() ?? 0)+1
        data += Data("xref\n0 \(size)\n0000000000 65535 f \n".utf8)
        for id in 1..<size { data += Data(String(format:"%010lld 00000 %@ \n",Int64(positions[id] ?? 0),positions[id] == nil ? "f":"n").utf8) }
        return data+Data("trailer\n<< /Size \(size) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n".utf8)
    }
    private func type1()->(data:Data,length1:Int,length2:Int) {
        let header = Data("%!PS-AdobeFont-1.0: NativeTest 1.0\n11 dict begin /FontName /NativeTest def /FontType 1 def /FontMatrix [0.001 0 0 0.001 0 0] def /FontBBox [0 0 1000 1000] def /Encoding StandardEncoding def currentdict end currentfile eexec\n".utf8)
        let char = Data([139,248,136,13,14])
        let plain = Data("xxxxdup /Private 8 dict dup begin /lenIV -1 def /RD {string currentfile exch readstring pop} executeonly def /ND {noaccess def} executeonly def /Subrs 0 array def /CharStrings 2 dict dup begin /.notdef 5 RD ".utf8)+char+Data(" ND /A 5 RD ".utf8)+char+Data(" ND end end readonly put dup /FontName get exch definefont pop mark currentfile closefile".utf8)
        var cipher = Data(),state:UInt32 = 55665
        for byte in plain { let encrypted = byte ^ UInt8(state>>8);cipher.append(encrypted);state = ((UInt32(encrypted)+state)*52845+22719)&65535 }
        return(header+cipher+Data(repeating:48,count:512),header.count,cipher.count)
    }
}
