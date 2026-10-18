import CoreGraphics
import Foundation
import XCTest
@testable import CartaPDF

final class PDFArchiveObjectChecksTests: XCTestCase {
    func testUnsupportedICCFilterDoesNotBecomeAnInvalidProfileProof() throws {
        let data = fixture(catalog:"/OutputIntents [<< /S /GTS_PDFA1 /DestOutputProfile 7 0 R >> << /S /GTS_PDFX /DestOutputProfile 7 0 R >>]",
                           extras:[7:stream("/Filter /ASCIIHexDecode",bytes("0000"))])
        XCTAssertEqual(try evaluate(data,object:"OutputIntents",expression:"sameOutputProfileIndirect == true",profile:.pdfa1b).status,.notVerified)
    }

    func testSingleOutputIntentDoesNotApplyCrossEntryIdentityOrICCValidityRequirement() throws {
        let data = fixture(catalog: "/OutputIntents [<< /S /GTS_PDFA1 /DestOutputProfile 7 0 R >>]",
                           extras: [7: stream("", bytes("malformed ICC"))])
        for profile in [PDFArchiveProfile.pdfa1b, .pdfa2u, .pdfa4] {
            XCTAssertEqual(try evaluate(data, object: "OutputIntents", expression: "sameOutputProfileIndirect == true", profile: profile).status, .passed)
            let reader = try PDFStructureDocument(data: data)
            let independent = PDFArchiveGraphicsChecks(reader: reader, profile: profile).modelChecks
            XCTAssertTrue(independent.contains { $0.objectType == "ICCStructuralModel" && $0.status == .failed })
        }
        let direct = fixture(catalog: "/OutputIntents [<< /S /GTS_PDFA1 /DestOutputProfile << /Private (not a stream) >> >>]")
        XCTAssertEqual(try evaluate(direct, object: "OutputIntents", expression: "sameOutputProfileIndirect == true").status, .passed)
    }
    func testBlendModesCheckEveryArrayElementAndAnnotation() throws {
        let good = fixture(resources: "/ExtGState << /G << /BM [/Normal /Multiply /Compatible] >> >>",
                           page: "/Annots [7 0 R]", content: bytes("/G gs"), extras: [7: bytes("<< /Subtype /Square /Rect [1 1 20 20] /BM /Screen >>")])
        XCTAssertEqual(try evaluate(good, object: "CosBM").status, .passed)
        let bad = fixture(resources: "/ExtGState << /G << /BM [/Normal /NotStandard] >> >>", content: bytes("/G gs"))
        XCTAssertEqual(try evaluate(bad, object: "CosBM").status, .failed)
        let annotation = fixture(page: "/Annots [7 0 R]", extras: [7: bytes("<< /Subtype /Square /Rect [1 1 20 20] /BM /Custom >>")])
        XCTAssertEqual(try evaluate(annotation, object: "CosBM").status, .failed)
    }

    func testPrivateDictionaryKeysNeverCreateGraphicsObjects() throws {
        let data = fixture(catalog: "/PieceInfo << /App << /Private << /BM /Custom /RI /Custom /HalftoneType 9 /OutputIntents [7 0 R] >> >> >>",
                           extras: [7: bytes("<< /S /GTS_PDFA1 /DestOutputProfileRef << /ProfileName (private) >> >>")])
        for family in ["CosBM", "CosRenderingIntent", "PDHalftone", "PDOutputIntent", "OutputIntents", "CosIIFilter", "CosUnicodeName"] {
            XCTAssertEqual(try evaluate(data, object: family, profile: .pdfa4).status, .notApplicable, family)
        }
    }

    func testRenderingIntentIncludesOperatorsGraphicsStatesAndImages() throws {
        XCTAssertEqual(try evaluate(fixture(content: bytes("/Perceptual ri")), object: "CosRenderingIntent").status, .passed)
        XCTAssertEqual(try evaluate(fixture(content: bytes("/Custom ri")), object: "CosRenderingIntent").status, .failed)
        XCTAssertEqual(try evaluate(fixture(resources: "/ExtGState << /G << /RI /Custom >> >>", content: bytes("/G gs")), object: "CosRenderingIntent").status, .failed)
        let image = stream("/Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray /Intent /Custom", Data([128]))
        let data = fixture(resources: "/XObject << /I 7 0 R >>", content: bytes("/I Do"), extras: [7: image])
        XCTAssertEqual(try evaluate(data, object: "CosRenderingIntent").status, .failed)
        let inline = fixture(content: bytes("BI /W 1 /H 1 /CS /RGB /BPC 8 /Intent /Custom /F /Fl ID x EI"))
        XCTAssertEqual(try evaluate(inline, object: "CosRenderingIntent").status, .failed)
    }

    func testAppearanceAndNestedPatternResourcesAreVisited() throws {
        let form = stream("/Type /XObject /Subtype /Form /BBox [0 0 20 20] /Resources << /Pattern << /P 9 0 R >> >>", bytes("/Saturation ri /Pattern cs /P scn 0 0 20 20 re f"))
        let pattern = stream("/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 1 1] /XStep 1 /YStep 1 /Resources << /ExtGState << /G << /BM /Custom >> >> >>", bytes("/G gs"))
        let data = fixture(page: "/Annots [7 0 R]",
                           extras: [7: bytes("<< /Subtype /Square /Rect [1 1 20 20] /AP << /N 8 0 R >> >>"), 8: form, 9: pattern])
        XCTAssertEqual(try evaluate(data, object: "CosRenderingIntent").status, .passed)
        XCTAssertEqual(try evaluate(data, object: "CosBM").status, .failed)
    }

    func testInlineFilterArraysAndAbbreviationsAreProfileSpecific() throws {
        let disallowed = fixture(content: bytes("BI /W 1 /H 1 /CS /G /BPC 8 /F [/Fl /LZW] /L 1 ID x\nEI"))
        XCTAssertEqual(try evaluate(disallowed, object: "CosIIFilter").status, .failed)
        XCTAssertEqual(try evaluate(disallowed, object: "CosIIFilter", profile: .pdfa1b).status, .failed)
        let allowed = fixture(content: bytes("BI /W 1 /H 1 /CS /G /BPC 8 /F [/AHx /RL] /L 1 ID x\nEI"))
        // The visible filter names are permitted, but their compressed byte
        // boundary is not proved by the untrusted declared L alone.
        XCTAssertEqual(try evaluate(allowed, object: "CosIIFilter").status, .notVerified)
        let crypt = fixture(content: bytes("BI /W 1 /H 1 /CS /G /BPC 8 /F /Crypt /L 1 ID x\nEI"))
        XCTAssertEqual(try evaluate(crypt, object: "CosIIFilter", profile: .pdfa4).status, .failed)
    }

    func testInlineBinaryBoundaryKeepsLaterRenderingIntentVisible() throws {
        let image = bytes("BI /W 8 /H 1 /CS /G /BPC 8 ID ") + Data([32, 69, 73, 32, 0, 0, 0, 0]) + bytes("\nEI\n/Custom ri")
        XCTAssertEqual(try evaluate(fixture(content: image), object: "CosRenderingIntent").status, .failed)
        let unknown = fixture(content: bytes("BI /W 1 /H 1 /CS /G /BPC 8 /F /Fl ID x EI /Custom ri"))
        XCTAssertEqual(try evaluate(unknown, object: "CosRenderingIntent").status, .notVerified)
        XCTAssertEqual(try evaluate(unknown, object: "CosIIFilter").status, .notVerified)
        let forbidden = fixture(content: bytes("BI /W 1 /H 1 /CS /G /BPC 8 /F /LZW ID x EI"))
        XCTAssertEqual(try evaluate(forbidden, object: "CosIIFilter").status, .failed)
    }

    func testUnicodeFontNamesUseOriginalEscapedBytesAndDoNotRequireNFC() throws {
        func font(_ name: String) -> Data {
            fixture(resources: "/Font << /F 7 0 R >>",
                    extras: [7: bytes("<< /Type /Font /Subtype /Type1 /BaseFont /\(name) /FontDescriptor << /FontName /\(name) >> >>")])
        }
        XCTAssertEqual(try evaluate(font("ABCDEF+Caf#C3#A9"), object: "CosUnicodeName").status, .passed)
        XCTAssertEqual(try evaluate(font("ABCDEF+Cafe#CC#81"), object: "CosUnicodeName").status, .passed)
        XCTAssertEqual(try evaluate(font("ABCDEF+Caf#C3"), object: "CosUnicodeName").status, .failed)
        XCTAssertEqual(try evaluate(font("ABCDEF+Caf#ED#A0#80"), object: "CosUnicodeName").status, .failed)
    }

    func testUnicodeColorantsAndRoleMapKeysAreContextual() throws {
        let separation = fixture(resources: "/ColorSpace << /C [/Separation /Spot#C3 /DeviceGray << /FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 1 >>] >>")
        XCTAssertEqual(try evaluate(separation, object: "CosUnicodeName").status, .failed)
        let deviceN = fixture(resources: "/ColorSpace << /C [/DeviceN [/Cyan /Spot#C2] /DeviceCMYK << >>] >>")
        XCTAssertEqual(try evaluate(deviceN, object: "CosUnicodeName").status, .failed)
        let structure = fixture(catalog: "/StructTreeRoot 7 0 R",
                                extras: [7: bytes("<< /Type /StructTreeRoot /RoleMap << /Custom#C2 /P >> /K [8 0 R] >>"),
                                         8: bytes("<< /Type /StructElem /S /P /P 7 0 R >>")])
        XCTAssertEqual(try evaluate(structure, object: "CosUnicodeName", profile: .pdfa4).status, .failed)
        let privateName = fixture(catalog: "/Private#FF /Also#FF")
        XCTAssertEqual(try evaluate(privateName, object: "CosUnicodeName").status, .notApplicable)
    }

    func testICCBasedAlternateColorantsAreVisitedWithoutInspectingPrivateICCData() throws {
        let icc = try profileData()
        let transform = stream("/FunctionType 4 /Domain [0 1 0 1 0 1] /Range [0 1 0 1 0 1]", bytes("{ }"))
        func data(_ spot: String) -> Data {
            fixture(resources: "/ColorSpace << /C [/ICCBased 7 0 R] >>",
                    extras: [7: stream("/N 3 /Alternate [/DeviceN [/One /Two /\(spot)] /DeviceRGB 8 0 R]", icc),
                             8: transform])
        }
        XCTAssertEqual(try evaluate(data("Spot#C3#A9"), object: "CosUnicodeName").status, .passed)
        XCTAssertEqual(try evaluate(data("Spot#FF"), object: "CosUnicodeName").status, .failed)
    }

    func testTypeThreeGlyphStreamsAndFontDescendantsAreVisited() throws {
        let glyph = stream("", bytes("/Custom ri"))
        let data = fixture(resources: "/Font << /F 7 0 R >>", content: bytes("BT /F 12 Tf (a) Tj ET"),
                           extras: [7: bytes("<< /Type /Font /Subtype /Type3 /FontBBox [0 0 10 10] /FontMatrix [1 0 0 1 0 0] /Resources << >> /CharProcs << /a 8 0 R >> >>"), 8: glyph])
        XCTAssertEqual(try evaluate(data, object: "CosRenderingIntent").status, .failed)
        let descendant = fixture(resources: "/Font << /F 7 0 R >>",
                                 extras: [7: bytes("<< /Type /Font /Subtype /Type0 /BaseFont /Good /DescendantFonts [8 0 R] >>"),
                                          8: bytes("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Bad#FF >>")])
        XCTAssertEqual(try evaluate(descendant, object: "CosUnicodeName").status, .failed)
    }

    func testOptionalStructElemTypeAndPrivateMCRKeysKeepTheirOwnMeaning() throws {
        let data = fixture(catalog: "/StructTreeRoot 7 0 R",
                           extras: [7: bytes("<< /Type /StructTreeRoot /K [8 0 R] >>"),
                                    8: bytes("<< /S /P /P 7 0 R /K << /Type /MCR /MCID 0 /Pg 3 0 R /S /Private#FF >> >>")])
        XCTAssertEqual(try evaluate(data, object: "CosUnicodeName", profile: .pdfa4).status, .passed)
        let invalid = fixture(catalog: "/StructTreeRoot 7 0 R",
                              extras: [7: bytes("<< /Type /StructTreeRoot /K [8 0 R] >>"),
                                       8: bytes("<< /S /Custom#FF /P 7 0 R >>")])
        XCTAssertEqual(try evaluate(invalid, object: "CosUnicodeName", profile: .pdfa4).status, .failed)
    }

    func testHalftonesAreFoundThroughHTWithoutOptionalTypeOrHalftoneType() throws {
        let badType = fixture(resources: "/ExtGState << /G << /HT << /HalftoneType 6 >> >> >>", content: bytes("/G gs"))
        XCTAssertEqual(try evaluate(badType, object: "PDHalftone", expression: "HalftoneType").status, .failed)
        let missingType = fixture(resources: "/ExtGState << /G << /HT << /HalftoneName (Custom) >> >> >>", content: bytes("/G gs"))
        XCTAssertEqual(try evaluate(missingType, object: "PDHalftone", expression: "HalftoneType").status, .failed)
        XCTAssertEqual(try evaluate(missingType, object: "PDHalftone", expression: "HalftoneName").status, .failed)
        let defaultName = fixture(resources: "/ExtGState << /G << /HT /Default >> >>", content: bytes("/G gs"))
        XCTAssertEqual(try evaluate(defaultName, object: "PDHalftone", expression: "HalftoneType").status, .notApplicable)
    }

    func testHalftoneTransferFunctionsUseActualTypeFiveColorantContext() throws {
        func data(_ entries: String) -> Data {
            fixture(resources: "/ExtGState << /G << /HT << /HalftoneType 5 /Default << /HalftoneType 1 /TransferFunction /Identity >> \(entries) >> >> >>", content: bytes("/G gs"))
        }
        let good = data("/Cyan << /HalftoneType 1 >> /Spot << /HalftoneType 1 /TransferFunction /Identity >>")
        XCTAssertEqual(try evaluate(good, object: "PDHalftone", expression: "TransferFunction").status, .passed)
        let primary = data("/Cyan << /HalftoneType 1 /TransferFunction /Identity >>")
        XCTAssertEqual(try evaluate(primary, object: "PDHalftone", expression: "TransferFunction").status, .failed)
        let spot = data("/Spot << /HalftoneType 1 >>")
        XCTAssertEqual(try evaluate(spot, object: "PDHalftone", expression: "TransferFunction").status, .failed)
    }

    func testTypeFiveModelChecksRemainSeparateFromTrueCataloguePredicates() throws {
        let data = fixture(resources: "/ExtGState << /G << /HT << /HalftoneType 5 /Default << /HalftoneType 5 /Default << /HalftoneType 1 >> >> >> >> >>", version: "2.0")
        let reader = try PDFStructureDocument(data: data), checks = PDFArchiveObjectChecks(reader: reader, profile: .pdfa4)
        let catalogue = try PDFArchiveValidator.catalogue(profile: .pdfa4)
        let typeRule = try XCTUnwrap(catalogue.first { $0.objectType == "PDHalftone" && $0.expression.hasPrefix("HalftoneType") })
        let typeResult = try XCTUnwrap(checks.evaluate(typeRule))
        XCTAssertEqual(typeResult.status, .passed)
        XCTAssertEqual(checks.modelChecks.first?.status, .failed)
        XCTAssertEqual(checks.modelChecks.first?.specification, "ISO 32000-2:2020")
        let missing = fixture(resources: "/ExtGState << /G << /HT << /HalftoneType 5 /Cyan << /HalftoneType 1 >> >> >> >>", version: "2.0")
        XCTAssertEqual(try PDFArchiveObjectChecks(reader: PDFStructureDocument(data: missing), profile: .pdfa4).modelChecks.first?.status, .failed)
        let indirect = fixture(resources: "/ExtGState << /G << /HT << /HalftoneType 7 0 R /Cyan << /HalftoneType 1 >> >> >> >>",
                               extras: [7: bytes("5")], version: "2.0")
        XCTAssertEqual(try PDFArchiveObjectChecks(reader: PDFStructureDocument(data: indirect), profile: .pdfa4).modelChecks.first?.status, .failed)
    }

    func testOutputProfilesMustShareIndirectIdentityWithinEachArray() throws {
        let icc = try profileData()
        let source = "/OutputIntents [<< /S /GTS_PDFA1 /DestOutputProfile 7 0 R >> << /S /GTS_PDFX /DestOutputProfile 7 0 R >>]"
        let same = fixture(catalog: source, extras: [7: stream("", icc)])
        XCTAssertEqual(try evaluate(same, object: "OutputIntents", expression: "sameOutput").status, .passed)
        let different = fixture(catalog: source.replacingOccurrences(of: "/S /GTS_PDFX /DestOutputProfile 7", with: "/S /GTS_PDFX /DestOutputProfile 8"),
                                extras: [7: stream("", icc), 8: stream("", icc)])
        XCTAssertEqual(try evaluate(different, object: "OutputIntents", expression: "sameOutput").status, .failed)
        let local = fixture(catalog: "/OutputIntents [<< /S /GTS_PDFA1 /DestOutputProfile 7 0 R >>]",
                            page: "/OutputIntents [<< /S /GTS_PDFA1 /DestOutputProfile 8 0 R >>]",
                            extras: [7: stream("", icc), 8: stream("", icc)], version: "2.0")
        XCTAssertEqual(try evaluate(local, object: "OutputIntents", expression: "sameOutput", profile: .pdfa4).status, .passed)
    }

    func testOutputIntentExternalReferencesAndCountsRespectProfileAndPageScope() throws {
        let pdfa = fixture(catalog: "/OutputIntents [<< /S /GTS_PDFA1 /DestOutputProfileRef << /ProfileName (external) >> >>]")
        XCTAssertEqual(try evaluate(pdfa, object: "PDOutputIntent").status, .passed)
        XCTAssertEqual(try evaluate(pdfa, object: "PDOutputIntent", profile: .pdfa4).status, .failed)
        let pdfx = fixture(catalog: "/OutputIntents [<< /S /GTS_PDFX /DestOutputProfileRef << /ProfileName (external) >> >>]")
        XCTAssertEqual(try evaluate(pdfx, object: "PDOutputIntent").status, .failed)
        let local = fixture(page: "/OutputIntents [<< /S /GTS_PDFA1 >> << /S /GTS_PDFA1 >>]", version: "2.0")
        XCTAssertEqual(try evaluate(local, object: "OutputIntents", expression: "numberOf", profile: .pdfa4).status, .failed)
    }

    func testClassicXrefSeparatorsIncludeHistoricalRevisions() throws {
        XCTAssertEqual(try evaluate(fixture(xrefEOL: "\r\n"), object: "CosXRef", expression: "xrefEOL", profile: .pdfa4).status, .passed)
        XCTAssertEqual(try evaluate(fixture(xrefEOL: " \n"), object: "CosXRef", expression: "xrefEOL", profile: .pdfa4).status, .failed)
        XCTAssertEqual(try evaluate(fixture(xrefEOL: "\n\n"), object: "CosXRef", expression: "xrefEOL", profile: .pdfa4).status, .failed)
        let bad = fixture(headerSpace: "  ")
        XCTAssertEqual(try evaluate(bad, object: "CosXRef", expression: "subsection", profile: .pdfa1b).status, .failed)
        let reader = try PDFStructureDocument(data: bad)
        let revised = try reader.setPageLabels(startPage: 0, firstNumber: 1, prefix: "Later-", style: .decimal)
        XCTAssertEqual(try evaluate(revised, object: "CosXRef", expression: "subsection", profile: .pdfa1b).status, .failed)
    }

    func testUnresolvedColorContextDoesNotHideKnownBlendModeViolation() throws {
        let data = fixture(resources: "/ExtGState << /G << /BM /Custom >> >> /ColorSpace << /C /Missing >>", content: bytes("/G gs"))
        XCTAssertEqual(try evaluate(data, object: "CosUnicodeName").status, .notVerified)
        XCTAssertEqual(try evaluate(data, object: "CosBM").status, .failed)
        let reader = try PDFStructureDocument(data: data)
        let other = try XCTUnwrap(PDFArchiveValidator.catalogue(profile: .pdfa2u).first { $0.objectType == "PDFont" })
        XCTAssertNil(try PDFArchiveObjectChecks(reader: reader, profile: .pdfa2u).evaluate(other))
    }

    func testUnusedResourceExemptionForAppearanceRulesIsLimitedToPDFAOneThroughThree() throws {
        // TechNote0010 A010 exempts never-named resources beyond the base
        // format clauses. These definitions are identical; only their use differs.
        let resources = "/ExtGState << /G << /BM /Custom /RI /Custom /HT << /HalftoneType 6 >> >> >>"
        let unused = fixture(resources: resources), used = fixture(resources: resources, content: bytes("/G gs"))
        for profile: PDFArchiveProfile in [.pdfa2u, .pdfa3u] {
            for family in ["CosBM", "CosRenderingIntent", "PDHalftone"] {
                XCTAssertEqual(try evaluate(unused, object: family, profile: profile).status, .notApplicable, family)
                XCTAssertEqual(try evaluate(used, object: family, profile: profile).status, .failed, family)
            }
        }
        XCTAssertEqual(try evaluate(unused, object: "CosRenderingIntent", profile: .pdfa1b).status, .notApplicable)
        XCTAssertEqual(try evaluate(used, object: "CosRenderingIntent", profile: .pdfa1b).status, .failed)
        // No equivalent exemption for part4 is inferred from this resolution.
        for family in ["CosBM", "CosRenderingIntent", "PDHalftone"] {
            XCTAssertEqual(try evaluate(unused, object: family, profile: .pdfa4).status, .failed, family)
        }
    }

    func testNestedAppearanceResourcesRequireNominalReferencesAtEveryLevel() throws {
        let definitions = "/Resources << /ExtGState << /G << /BM /Custom /RI /Custom /HT << /HalftoneType 6 >> >> >> >>"
        let form = stream("/Type /XObject /Subtype /Form /BBox [0 0 20 20] \(definitions)", bytes("/G gs"))
        let pattern = stream("/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 20 20] /XStep 20 /YStep 20 \(definitions)", bytes("/G gs"))
        for (resource, content, object) in [("/XObject << /F 7 0 R >>", "/F Do", form),
                                           ("/Pattern << /P 7 0 R >>", "/Pattern cs /P scn 0 0 20 20 re f", pattern)] {
            let unused = fixture(resources: resource, extras: [7: object])
            let used = fixture(resources: resource, content: bytes(content), extras: [7: object])
            for family in ["CosBM", "CosRenderingIntent", "PDHalftone"] {
                XCTAssertEqual(try evaluate(unused, object: family).status, .notApplicable, family)
                XCTAssertEqual(try evaluate(used, object: family).status, .failed, family)
            }
        }
        let noInvocation = stream("/Type /XObject /Subtype /Form /BBox [0 0 20 20] \(definitions)", bytes("0 0 20 20 re f"))
        let usedFormUnusedState = fixture(resources: "/XObject << /F 7 0 R >>", content: bytes("/F Do"), extras: [7: noInvocation])
        XCTAssertEqual(try evaluate(usedFormUnusedState, object: "CosBM").status, .notApplicable)
    }

    func testUnprovedUsageCannotFailAnUnreferencedAppearanceResource() throws {
        let resources = "/ExtGState << /G << /BM /Custom /RI /Custom /HT << /HalftoneType 6 >> >> >>"
        let ambiguous = bytes("BI /W 1 /H 1 /CS /G /BPC 8 /F /Fl ID x EI /G gs")
        let unknown = fixture(resources: resources, content: ambiguous)
        let definitelyUsed = fixture(resources: resources, content: bytes("/G gs ") + ambiguous)
        for family in ["CosBM", "CosRenderingIntent", "PDHalftone"] {
            XCTAssertEqual(try evaluate(unknown, object: family).status, .notVerified, family)
            XCTAssertEqual(try evaluate(definitelyUsed, object: family).status, .failed, family)
            XCTAssertEqual(try evaluate(fixture(content: bytes("/Missing gs")), object: family).status, .notVerified, family)
        }
    }

    func testUnusedResourceExemptionDoesNotSkipBaseFormatNamesOrInlineFilters() throws {
        let form = stream("/Type /XObject /Subtype /Form /BBox [0 0 20 20] /Resources << /Font << /F << /Type /Font /Subtype /Type1 /BaseFont /Bad#FF >> >> >>",
                          bytes("BI /W 1 /H 1 /CS /G /BPC 8 /F /LZW ID x EI"))
        let unused = fixture(resources: "/XObject << /NeverNamed 7 0 R >>", extras: [7: form])
        XCTAssertEqual(try evaluate(unused, object: "CosUnicodeName").status, .failed)
        XCTAssertEqual(try evaluate(unused, object: "CosIIFilter").status, .failed)
        for family in ["CosBM", "CosRenderingIntent", "PDHalftone"] {
            XCTAssertEqual(try evaluate(unused, object: family).status, .notApplicable, family)
        }
    }

    private func evaluate(_ data: Data, object: String, expression: String? = nil, profile: PDFArchiveProfile = .pdfa2u) throws -> PDFArchiveRuleEvaluation {
        let rule = try XCTUnwrap(PDFArchiveValidator.catalogue(profile: profile).first {
            $0.objectType == object && (expression == nil || $0.expression.contains(expression!))
        })
        return try XCTUnwrap(PDFArchiveObjectChecks(reader: PDFStructureDocument(data: data), profile: profile).evaluate(rule))
    }
    private func profileData() throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        return try XCTUnwrap(space.copyICCData()) as Data
    }
    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private func stream(_ dictionary: String, _ data: Data) -> Data {
        bytes("<< \(dictionary) /Length \(data.count) >>\nstream\n") + data + bytes("\nendstream")
    }
    private func fixture(catalog: String = "", resources: String = "", page: String = "", content: Data = Data(),
                         extras: [Int: Data] = [:], version: String = "1.7", xrefEOL: String = "\n", headerSpace: String = " ") -> Data {
        var objects: [Int: Data] = [1: bytes("<< /Type /Catalog /Pages 2 0 R \(catalog) >>"),
                                   2: bytes("<< /Type /Pages /Count 1 /Kids [3 0 R] >>"),
                                   3: bytes("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << \(resources) >> /Contents 4 0 R \(page) >>"),
                                   4: stream("", content)]
        objects.merge(extras) { _, value in value }
        var data = bytes("%PDF-\(version)\n%") + Data([0xe2, 0xe3, 0xcf, 0xd3, 10]), offsets: [Int: Int] = [:]
        for id in objects.keys.sorted() { offsets[id] = data.count; data += bytes("\(id) 0 obj\n") + objects[id]! + bytes("\nendobj\n") }
        let start = data.count, size = (objects.keys.max() ?? 0) + 1
        data += bytes("xref\(xrefEOL)0\(headerSpace)\(size)\n0000000000 65535 f \n")
        for id in 1..<size { data += bytes(String(format: "%010lld 00000 %@ \n", Int64(offsets[id] ?? 0), offsets[id] == nil ? "f" : "n")) }
        return data + bytes("trailer\n<< /Size \(size) /Root 1 0 R /ID [<123456><789ABC>] >>\nstartxref\n\(start)\n%%EOF\n")
    }
}
