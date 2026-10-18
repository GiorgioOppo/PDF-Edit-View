import CryptoKit
import PDFKit
import Security
import XCTest
@testable import CartaPDF

final class PDFArchiveStructureChecksTests: XCTestCase {
    func testAnnotationFlagsAppearanceAndNullRectangleExceptions() throws {
        let appearance = stream("/Type /XObject /Subtype /Form /BBox [0 0 20 20] /Resources << >>", Data("q Q".utf8))
        let good = fixture(page: "/Annots [7 0 R]", extras: [5: appearance, 7: bytes("<< /Type /Annot /Subtype /Text /Rect [10 10 30 30] /F 4 /AP << /N 5 0 R >> >>")])
        XCTAssertEqual(try evaluate(good, object: "PDAnnot", expression: "F == null").status, .passed)
        XCTAssertEqual(try evaluate(good, object: "PDAnnot", expression: "F != null").status, .passed)
        XCTAssertEqual(try evaluate(good, object: "PDAnnot", expression: "AP != null").status, .passed)
        let missing = fixture(page: "/Annots [7 0 R]", extras: [7: bytes("<< /Subtype /Text /Rect [10 10 30 30] /F 0 >>")])
        XCTAssertEqual(try evaluate(missing, object: "PDAnnot", expression: "F == null").status, .failed)
        XCTAssertEqual(try evaluate(missing, object: "PDAnnot", expression: "AP != null").status, .failed)
        let popup = fixture(page: "/Annots [7 0 R]", extras: [7: bytes("<< /Subtype /Popup /Rect [10 10 30 30] >>")])
        XCTAssertEqual(try evaluate(popup, object: "PDAnnot", expression: "F != null").status, .passed)
        let zero = fixture(page: "/Annots [7 0 R]", extras: [7: bytes("<< /Subtype /Text /Rect [10 10 10 10] >>")])
        XCTAssertEqual(try evaluate(zero, object: "PDAnnot", expression: "AP != null").status, .passed)
        XCTAssertEqual(try evaluate(zero, object: "PDAnnot", expression: "F != null", profile: .pdfa4).status, .passed)
    }

    func testProjectionAndEngineeringAnnotationTypesAreProfileSpecific() throws {
        let data = fixture(page: "/Annots [7 0 R]", extras: [7: bytes("<< /Subtype /Projection /Rect [1 1 20 20] /F 4 >>")])
        XCTAssertEqual(try evaluate(data, object: "PDAnnot", expression: "Subtype ==", profile: .pdfa4).status, .passed)
        XCTAssertEqual(try evaluate(data, object: "PDAnnot", expression: "AP != null", profile: .pdfa4).status, .passed)
        XCTAssertEqual(try evaluate(data, object: "PDAnnot", expression: "Subtype ==", profile: .pdfa2u).status, .failed)
        let threeD = fixture(page: "/Annots [7 0 R]", extras: [7: bytes("<< /Subtype /3D /Rect [1 1 20 20] /F 4 /3DD 8 0 R >>"), 8: stream("/Type /3D /Subtype /U3D", Data([0x55,0x33,0x44,0]))])
        XCTAssertEqual(try evaluate(threeD, object: "PDAnnot", expression: "Subtype ==", profile: .pdfa4e).status, .passed)
        XCTAssertEqual(try evaluate(threeD, object: "PD3DStream", expression: "Subtype ==", profile: .pdfa4e).status, .passed)
        XCTAssertEqual(try evaluate(threeD, object: "PDAnnot", expression: "Subtype ==", profile: .pdfa4).status, .failed)
    }

    func testEngineeringPayloadCheckIsIndependentFromTheAllowedSubtypePredicate() throws {
        let data = fixture(page: "/Annots [7 0 R]", extras: [7: bytes("<< /Subtype /3D /Rect [1 1 20 20] /F 4 /3DD 8 0 R >>"),
                                                        8: stream("/Type /3D /Subtype /U3D", Data([0x55, 0x33, 0x44, 0]))], version: "2.0")
        XCTAssertEqual(try evaluate(data, object: "PD3DStream", expression: "Subtype ==", profile: .pdfa4e).status, .passed)
        let native = try PDFArchiveStructureChecks(reader: PDFStructureDocument(data: data), profile: .pdfa4e).modelChecks
        XCTAssertEqual(native.first { $0.testNumber == "native-u3d-structure" }?.status, .failed)
        XCTAssertEqual(native.first { $0.testNumber == "native-u3d-payload" }?.status, .notVerified)
    }

    func testEngineering3DRefFollowsTheTargetStreamWithoutInspectingPrivate3DDKeys() throws {
        let direct = fixture(page: "/Annots [7 0 R]", extras: [7: bytes("<< /Subtype /3D /Rect [1 1 20 20] /F 4 /3DD 8 0 R >>"),
            8: bytes("<< /Type /3DRef /3DD 9 0 R >>"), 9: stream("/Type /3D /Subtype /PRC", bytes("PRC"))], version: "2.0")
        let results = try PDFArchiveStructureChecks(reader: PDFStructureDocument(data: direct), profile: .pdfa4e).modelChecks
        XCTAssertEqual(results.first { $0.testNumber == "native-prc-structure" }?.status, .notVerified)
        let unrelated = fixture(catalog: "/PieceInfo << /App << /Private << /3DD 9 0 R >> >> >>",
                                extras: [9: stream("/Type /3D /Subtype /U3D", bytes("not U3D"))], version: "2.0")
        XCTAssertFalse(try PDFArchiveStructureChecks(reader: PDFStructureDocument(data: unrelated), profile: .pdfa4e).modelChecks.contains { $0.objectType == "EngineeringModel" })
    }

    func testRichMediaEngineeringAssetsAreReadFromMIMEAndInstanceReferencesWithoutCreatingPD3DStream() throws {
        let files = [
            7: bytes("<< /Type /Filespec /F (data.bin) /UF (data.bin) /AFRelationship /Data /EF << /F 8 0 R >> >>"),
            8: stream("/Type /EmbeddedFile /Subtype /model#2Fu3d", Data([0x55, 0x33, 0x44, 0])),
            9: bytes("<< /Subtype /RichMedia /Rect [1 1 20 20] /F 4 /RichMediaContent << /Configurations [<< /Subtype /3D /Instances [<< /Subtype /3D /Asset 7 0 R >>] >>] >> >>")
        ]
        let instance = fixture(page: "/Annots [9 0 R]", extras: files, version: "2.0")
        let checks = try PDFArchiveStructureChecks(reader: PDFStructureDocument(data: instance), profile: .pdfa4e)
        XCTAssertEqual(checks.modelChecks.first { $0.testNumber == "native-u3d-structure" }?.status, .failed)
        XCTAssertEqual(try evaluate(instance, object: "PD3DStream", expression: "Subtype ==", profile: .pdfa4e).status, .notApplicable)
        var named = files
        named[9] = bytes("<< /Subtype /RichMedia /Rect [1 1 20 20] /F 4 /RichMediaContent << /Assets << /Names [(model) 7 0 R] >> >> >>")
        let nameTree = fixture(page: "/Annots [9 0 R]", extras: named, version: "2.0")
        XCTAssertEqual(try PDFArchiveStructureChecks(reader: PDFStructureDocument(data: nameTree), profile: .pdfa4e).modelChecks.first { $0.testNumber == "native-u3d-structure" }?.status, .failed)
        named[8] = stream("/Type /EmbeddedFile /Subtype /application#2Foctet-stream", Data([0x55, 0x33, 0x44, 0]))
        let opaque = fixture(page: "/Annots [9 0 R]", extras: named, version: "2.0")
        XCTAssertFalse(try PDFArchiveStructureChecks(reader: PDFStructureDocument(data: opaque), profile: .pdfa4e).modelChecks.contains { $0.objectType == "EngineeringModel" })
    }

    func testInheritedButtonTypeRequiresAppearanceStateDictionaryEvenForPushbutton() throws {
        let appearance = stream("/Type /XObject /Subtype /Form /BBox [0 0 20 20]", Data("q Q".utf8))
        func button(_ normal: String) -> Data {
            fixture(catalog: "/AcroForm << /Fields [8 0 R] >>", page: "/Annots [7 0 R]",
                    extras: [5: appearance, 7: bytes("<< /Subtype /Widget /Parent 8 0 R /Rect [1 1 20 20] /F 4 /AP << /N \(normal) >> >>"),
                             8: bytes("<< /FT /Btn /Ff 65536 /Kids [7 0 R] >>")])
        }
        XCTAssertEqual(try evaluate(button("<< /Normal 5 0 R >>"), object: "PDAnnot", expression: "N_type == \"Dict\"").status, .passed)
        XCTAssertEqual(try evaluate(button("5 0 R"), object: "PDAnnot", expression: "N_type == \"Dict\"").status, .failed)
        XCTAssertEqual(try evaluate(button("<< /Normal /NotAStream >>"), object: "PDAnnot", expression: "N_type == \"Dict\"").status, .failed)
    }

    func testWidgetAndFieldActionsAndNeedAppearancesAreCheckedInTheirContexts() throws {
        let data = fixture(catalog: "/AcroForm << /Fields [7 0 R] /NeedAppearances true >>", page: "/Annots [7 0 R]",
                           extras: [7: bytes("<< /FT /Tx /Subtype /Widget /Rect [1 1 20 20] /F 4 /A << /S /URI /URI (https://example.com) >> /AA << /K << /S /JavaScript /JS () >> >> >>")])
        XCTAssertEqual(try evaluate(data, object: "PDWidgetAnnot", expression: "containsA").status, .failed)
        XCTAssertEqual(try evaluate(data, object: "PDAcroForm", expression: "NeedAppearances").status, .failed)
        XCTAssertEqual(try evaluate(data, object: "PDFormField", expression: "containsAA", profile: .pdfa1b).status, .failed)
        let good = fixture(catalog: "/AA << /E << /S /URI /URI (https://example.com) >> >>")
        XCTAssertEqual(try evaluate(good, object: "PDAdditionalActions", expression: "parentType", profile: .pdfa4).status, .passed)
        let bad = fixture(catalog: "/AA << /WC << /S /URI /URI (https://example.com) >> >>")
        XCTAssertEqual(try evaluate(bad, object: "PDAdditionalActions", expression: "parentType", profile: .pdfa4).status, .failed)
    }

    func testMissingWidgetAppearanceDoesNotFalsifyTheIndependentNeedAppearancesPredicate() throws {
        // Historical corpus names predate the current catalogue's rule numbers.
        // A missing appearance violates the widget rule; an absent optional
        // NeedAppearances entry remains valid under its own predicate.
        let data = fixture(catalog: "/AcroForm << /Fields [7 0 R] >>", page: "/Annots [7 0 R]",
                           extras: [7: bytes("<< /FT /Tx /Subtype /Widget /Rect [1 1 20 20] /F 4 >>")], version: "1.4")
        XCTAssertEqual(try evaluate(data, object: "PDAcroForm", expression: "NeedAppearances", profile: .pdfa1b).status, .passed)
        XCTAssertEqual(try evaluate(data, object: "PDWidgetAnnot", expression: "AP != null", profile: .pdfa1b).status, .failed)
    }

    func testPrivateApplicationKeysDoNotCreateStandardObjects() throws {
        let data = fixture(catalog: "/PieceInfo << /App << /LastModified (D:20261017180000Z) /Private << /Annots [7 0 R] /AF [8 0 R] >> >> >>",
                           extras: [7: bytes("<< /Subtype /Unknown /Rect [1 1 20 20] >>"), 8: bytes("<< /EF << /F 9 0 R >> >>"), 9: stream("", Data("private".utf8))])
        XCTAssertEqual(try evaluate(data, object: "PDAnnot", expression: "Subtype ==").status, .notApplicable)
        XCTAssertEqual(try evaluate(data, object: "EmbeddedFile", expression: "isValidPDFA").status, .notApplicable)
        let reader = try PDFStructureDocument(data: data)
        let unrelated = try XCTUnwrap(PDFArchiveValidator.catalogue(profile: .pdfa2u).first { $0.objectType == "PDFont" })
        XCTAssertNil(try PDFArchiveStructureChecks(reader: reader, profile: .pdfa2u).evaluate(unrelated))
    }

    func testOCGNamesUniquenessNestedOrderAndASHaveRealNegativeCases() throws {
        let groups = [7: bytes("<< /Type /OCG /Name (One) >>"), 8: bytes("<< /Type /OCG /Name (Two) >>")]
        let good = fixture(catalog: "/OCProperties << /OCGs [7 0 R 8 0 R] /D << /Name (Default) /Order [(Group) 7 0 R [8 0 R]] >> /Configs [<< /Name (Alternate) /Order [8 0 R 7 0 R] >>] >>", extras: groups)
        XCTAssertEqual(try evaluate(good, object: "PDOCConfig", expression: "hasDuplicateName").status, .passed)
        XCTAssertEqual(try evaluate(good, object: "PDOCConfig", expression: "OCGsNotContained").status, .passed)
        let missing = fixture(catalog: "/OCProperties << /OCGs [7 0 R 8 0 R] /D << /Name (Default) /Order [7 0 R] /AS [] >> /Configs [<< /Name (Default) >>] >>", extras: groups)
        XCTAssertEqual(try evaluate(missing, object: "PDOCConfig", expression: "hasDuplicateName").status, .failed)
        XCTAssertEqual(try evaluate(missing, object: "PDOCConfig", expression: "OCGsNotContained").status, .failed)
        XCTAssertEqual(try evaluate(missing, object: "PDOCConfig", expression: "AS == null").status, .failed)
    }

    func testRoleMapChainsCyclesAndParentPointersAreNotValidatedByPresence() throws {
        func data(_ map: String, parent: Int = 8) -> Data {
            fixture(catalog: "/StructTreeRoot 8 0 R /MarkInfo << /Marked true >>",
                    extras: [8: bytes("<< /Type /StructTreeRoot /K [9 0 R] /RoleMap << \(map) >> >>"),
                             9: bytes("<< /Type /StructElem /S /Custom /P \(parent) 0 R >>")])
        }
        let good = data("/Custom /Intermediate /Intermediate /P")
        XCTAssertEqual(try evaluate(good, object: "SENonStandard", expression: "isNotMapped", profile: .pdfa2a).status, .passed)
        XCTAssertEqual(try evaluate(good, object: "PDDocument", expression: "containsStruct", profile: .pdfa2a).status, .passed)
        let cyclic = data("/Custom /Intermediate /Intermediate /Custom")
        XCTAssertEqual(try evaluate(cyclic, object: "SENonStandard", expression: "circularMapping", profile: .pdfa2a).status, .failed)
        XCTAssertEqual(try evaluate(data("/Custom /P", parent: 2), object: "PDDocument", expression: "containsStruct", profile: .pdfa2a).status, .failed)
    }

    func testPartOneStandardTagsAndIndirectOrderArraysRespectTheirPDFVersion() throws {
        let ruby = fixture(catalog: "/StructTreeRoot 8 0 R",
                           extras: [8: bytes("<< /Type /StructTreeRoot /K [9 0 R] >>"),
                                    9: bytes("<< /Type /StructElem /S /Ruby /P 8 0 R >>")], version: "1.4")
        XCTAssertEqual(try evaluate(ruby, object: "SENonStandard", expression: "isNotMapped", profile: .pdfa1a).status, .failed)
        XCTAssertEqual(try evaluate(ruby, object: "SENonStandard", expression: "isNotMapped", profile: .pdfa2a).status, .notApplicable)
        let order = fixture(catalog: "/OCProperties << /OCGs [7 0 R] /D << /Name (Default) /Order [8 0 R] >> >>",
                            extras: [7: bytes("<< /Type /OCG /Name (One) >>"), 8: bytes("[(Nested) 7 0 R]")])
        XCTAssertEqual(try evaluate(order, object: "PDOCConfig", expression: "OCGsNotContained").status, .passed)
    }

    func testStructElemTypeIsOptionalButWhenPresentMustBeStructElem() throws {
        func data(_ type: String) -> Data {
            fixture(catalog: "/StructTreeRoot 8 0 R",
                    extras: [8: bytes("<< /Type /StructTreeRoot /K [9 0 R] >>"),
                             9: bytes("<< \(type) /S /P /P 8 0 R >>")], version: "1.4")
        }
        XCTAssertEqual(try evaluate(data(""), object: "PDDocument", expression: "containsStruct", profile: .pdfa1a).status, .passed)
        XCTAssertEqual(try evaluate(data("/Type /StructElem"), object: "PDDocument", expression: "containsStruct", profile: .pdfa1a).status, .passed)
        XCTAssertEqual(try evaluate(data("/Type /Other"), object: "PDDocument", expression: "containsStruct", profile: .pdfa1a).status, .failed)
    }

    func testParentTreeConsistencyAndUnprovedContentRemainSeparate() throws {
        func tagged(_ parentValue: String) -> Data {
            fixture(catalog: "/StructTreeRoot 8 0 R", page: "/StructParents 0", content: Data("/P << /MCID 0 >> BDC 0 0 10 10 re f EMC".utf8),
                    extras: [8: bytes("<< /Type /StructTreeRoot /K [9 0 R] /ParentTree << /Nums [0 [\(parentValue)]] >> /ParentTreeNextKey 1 >>"),
                             9: bytes("<< /Type /StructElem /S /P /P 8 0 R /Pg 3 0 R /K 0 >>")])
        }
        XCTAssertEqual(try evaluate(tagged("9 0 R"), object: "PDDocument", expression: "containsStruct", profile: .pdfa2a).status, .notVerified)
        XCTAssertEqual(try evaluate(tagged("null"), object: "PDDocument", expression: "containsStruct", profile: .pdfa2a).status, .failed)
        let nonexistent = fixture(catalog: "/StructTreeRoot 8 0 R", page: "/StructParents 0",
                                  extras: [8: bytes("<< /Type /StructTreeRoot /K [9 0 R] /ParentTree << /Nums [0 [9 0 R]] >> >>"),
                                           9: bytes("<< /Type /StructElem /S /P /P 8 0 R /Pg 3 0 R /K 0 >>")])
        XCTAssertEqual(try evaluate(nonexistent, object: "PDDocument", expression: "containsStruct", profile: .pdfa2a).status, .failed)
    }

    func testLanguageIsFoundInCatalogStructureAndContentPropertyLists() throws {
        let good = fixture(catalog: "/Lang (it-IT)", content: Data("/P << /Lang (en-US) >> BDC EMC".utf8))
        XCTAssertEqual(try evaluate(good, object: "CosLang", expression: "unicodeValue", profile: .pdfa2a).status, .passed)
        let bad = fixture(content: Data("/P << /Lang (invalid_language) >> BDC EMC".utf8))
        XCTAssertEqual(try evaluate(bad, object: "CosLang", expression: "unicodeValue", profile: .pdfa2a).status, .failed)
        let numericRegion = fixture(catalog: "/Lang (es-419)")
        XCTAssertEqual(try evaluate(numericRegion, object: "CosLang", expression: "unicodeValue", profile: .pdfa2a).status, .passed)
        XCTAssertEqual(try evaluate(numericRegion, object: "CosLang", expression: "unicodeValue", profile: .pdfa1a).status, .failed)
    }

    func testAssociatedFilesAndFourFNameTreeAreDifferentRequirements() throws {
        let extras = [7: bytes("<< /Type /Filespec /F (a.txt) /UF (a.txt) /AFRelationship /Source /EF << /F 8 0 R >> >>"),
                      8: stream("/Type /EmbeddedFile /Subtype /text#2Fplain", Data("contenuto locale".utf8))]
        let associated = fixture(catalog: "/AF [7 0 R] /Names << /EmbeddedFiles << /Names [(a.txt) 7 0 R] >> >>", extras: extras)
        XCTAssertEqual(try evaluate(associated, object: "CosFileSpecification", expression: "isAssociatedFile", profile: .pdfa3u).status, .passed)
        XCTAssertEqual(try evaluate(associated, object: "EmbeddedFile", expression: "Subtype !=", profile: .pdfa3u).status, .passed)
        let unassociated = fixture(catalog: "/Names << /EmbeddedFiles << /Names [(a.txt) 7 0 R] >> >>", extras: extras)
        XCTAssertEqual(try evaluate(unassociated, object: "CosFileSpecification", expression: "isAssociatedFile", profile: .pdfa3u).status, .failed)
        let noNameTree = fixture(catalog: "/AF [7 0 R]", extras: extras)
        XCTAssertEqual(try evaluate(noNameTree, object: "CosDocument", expression: "containsEmbeddedFiles == true", profile: .pdfa4f).status, .failed)
        XCTAssertEqual(try evaluate(associated, object: "CosDocument", expression: "containsEmbeddedFiles == true", profile: .pdfa4f).status, .passed)
    }

    func testEmbeddedNonPDFAAndDisallowedPartAreRejectedRecursively() throws {
        func container(_ attachment: Data) -> Data {
            fixture(catalog: "/Names << /EmbeddedFiles << /Names [(child.pdf) 7 0 R] >> >>",
                    extras: [7: bytes("<< /Type /Filespec /F (child.pdf) /UF (child.pdf) /EF << /F 8 0 R >> >>"), 8: stream("/Type /EmbeddedFile /Subtype /application#2Fpdf", attachment)])
        }
        XCTAssertEqual(try evaluate(container(fixture()), object: "EmbeddedFile", expression: "isValidPDFA").status, .failed)
        let declaredFour = Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\" pdfaid:part=\"4\" pdfaid:rev=\"2020\"/></rdf:RDF></x:xmpmeta>".utf8)
        let child = fixture(catalog: "/Metadata 9 0 R", extras: [9: stream("/Type /Metadata /Subtype /XML", declaredFour)], version: "2.0")
        XCTAssertEqual(try evaluate(container(child), object: "EmbeddedFile", expression: "isValidPDFA").status, .failed)
    }

    func testPDF2AssociatedFilesAreFoundOutsideTheClosedPartThreeObjectList() throws {
        let files = [7: bytes("<< /Type /Filespec /F (data.txt) /UF (data.txt) /AFRelationship /Data /EF << /F 8 0 R >> >>"),
                     8: stream("/Type /EmbeddedFile /Subtype /bad-MIME", bytes("local"))]
        let nested = fixture(catalog: "/CustomObject << /Nested [<< /AF [7 0 R] >>] >>", extras: files, version: "2.0")
        XCTAssertEqual(try evaluate(nested, object: "EmbeddedFile", expression: "Subtype !=", profile: .pdfa4f).status, .failed)
        let typedFile = fixture(catalog: "/CustomFiles [7 0 R]", extras: files, version: "2.0")
        XCTAssertEqual(try evaluate(typedFile, object: "EmbeddedFile", expression: "Subtype !=", profile: .pdfa4f).status, .failed)
        // PDF/A-3 Table E.1 does not allow arbitrary extension dictionaries to
        // supply associations, and this graph has no standard Filespec path.
        XCTAssertEqual(try evaluate(nested, object: "EmbeddedFile", expression: "Subtype !=", profile: .pdfa3u).status, .notApplicable)
        let binary = fixture(content: bytes("(/AF [7 0 R]) Tj"), extras: files, version: "2.0")
        XCTAssertEqual(try evaluate(binary, object: "EmbeddedFile", expression: "Subtype !=", profile: .pdfa4f).status, .notApplicable)
    }

    func testPDF2AttachmentCanAssociateItsOwnSchemaWithoutHidingItsRequirements() throws {
        let files = [
            7: bytes("<< /Type /Filespec /F (manifest.json) /UF (manifest.json) /AFRelationship /Data /AF [9 0 R] /EF << /F 8 0 R >> >>"),
            8: stream("/Type /EmbeddedFile /Subtype /application#2Fjson", bytes("{}")),
            9: bytes("<< /Type /Filespec /F (schema.json) /AFRelationship /Schema /EF << /F 10 0 R >> >>"),
            10: stream("/Type /EmbeddedFile /Subtype /application#2Fschema+json", bytes("{}"))
        ]
        let missingUF = fixture(catalog: "/AF [7 0 R]", extras: files, version: "2.0")
        XCTAssertEqual(try evaluate(missingUF, object: "CosFileSpecification", expression: "F != null", profile: .pdfa4f).status, .failed)
        var complete = files
        complete[9] = bytes("<< /Type /Filespec /F (schema.json) /UF (schema.json) /AFRelationship /Schema /EF << /F 10 0 R >> >>")
        let valid = fixture(catalog: "/AF [7 0 R]", extras: complete, version: "2.0")
        XCTAssertEqual(try evaluate(valid, object: "CosFileSpecification", expression: "F != null", profile: .pdfa4f).status, .passed)
        XCTAssertEqual(try evaluate(valid, object: "EmbeddedFile", expression: "Subtype !=", profile: .pdfa4f).status, .passed)
    }

    func testPDF2AssociationGraphCyclesTerminateAndUnreachableObjectsAreNotGuessedLive() throws {
        let objects = [
            7: bytes("<< /Next 9 0 R /AF [10 0 R] >>"), 9: bytes("<< /Back 7 0 R >>"),
            10: bytes("<< /Type /Filespec /F (a.txt) /UF (a.txt) /AFRelationship /Data /EF << /F 11 0 R >> >>"),
            11: stream("/Type /EmbeddedFile /Subtype /text#2Fplain", bytes("local")),
            12: bytes("<< /AF [13 0 R] >>"),
            13: bytes("<< /Type /Filespec /F (unreachable) /EF << /F 14 0 R >> >>"),
            14: stream("/Type /EmbeddedFile /Subtype /bad-MIME", bytes("unreachable"))
        ]
        let data = fixture(catalog: "/CustomObject 7 0 R", extras: objects, version: "2.0")
        XCTAssertEqual(try evaluate(data, object: "EmbeddedFile", expression: "Subtype !=", profile: .pdfa4f).status, .passed)
        XCTAssertEqual(try evaluate(data, object: "CosFileSpecification", expression: "F != null", profile: .pdfa4f).status, .passed)
    }

    func testMarkedContentAssociationsAndRichMediaAssetsAreTraversedInTheirRealContexts() throws {
        let files = [7: bytes("<< /Type /Filespec /F (a.txt) /UF (a.txt) /AFRelationship /Source /EF << /F 8 0 R >> >>"),
                     8: stream("/Type /EmbeddedFile /Subtype /text#2Fplain", bytes("local"))]
        let associated = fixture(catalog: "/Names << /EmbeddedFiles << /Names [(a.txt) 7 0 R] >> >>",
                                 content: bytes("/Formula << /AF [7 0 R] >> BDC EMC"), extras: files)
        XCTAssertEqual(try evaluate(associated, object: "CosFileSpecification", expression: "isAssociatedFile", profile: .pdfa3u).status, .passed)
        var invalidMIME = files
        invalidMIME[8] = stream("/Type /EmbeddedFile /Subtype /not-a-MIME-type", bytes("local"))
        let markedFour = fixture(content: bytes("/AF << /MCAF [7 0 R] >> BDC EMC"), extras: invalidMIME, version: "2.0")
        XCTAssertEqual(try evaluate(markedFour, object: "EmbeddedFile", expression: "Subtype !=", profile: .pdfa4f).status, .failed)
        var richFiles = invalidMIME
        richFiles[9] = bytes("<< /Subtype /RichMedia /Rect [1 1 20 20] /F 4 /RichMediaContent << /Assets << /Names [(asset) 7 0 R] >> >> >>")
        let rich = fixture(page: "/Annots [9 0 R]", extras: richFiles, version: "2.0")
        XCTAssertEqual(try evaluate(rich, object: "EmbeddedFile", expression: "Subtype !=", profile: .pdfa4e).status, .failed)
        let privateKey = fixture(catalog: "/OpenAction << /S /URI /URI (https://example.com) /F 7 0 R >>", extras: files)
        XCTAssertEqual(try evaluate(privateKey, object: "EmbeddedFile", expression: "isValidPDFA").status, .notApplicable)
    }

    func testInlineImageExactSampleBoundaryKeepsFollowingLanguageAndAssociationsVisible() throws {
        // The first four sample bytes look like an EI delimiter. A token search
        // would terminate too early and could hide or invent subsequent objects.
        let image = bytes("BI /W 8 /H 1 /CS /G /BPC 8 ID ") + Data([32, 69, 73, 32, 0, 0, 0, 0]) + bytes("\nEI\n")
        let invalid = fixture(content: image + bytes("/P << /Lang (bad_language) >> BDC EMC"))
        XCTAssertEqual(try evaluate(invalid, object: "CosLang", expression: "unicodeValue", profile: .pdfa2a).status, .failed)
        let valid = fixture(content: image + bytes("/P << /Lang (it-IT) >> BDC EMC"))
        XCTAssertEqual(try evaluate(valid, object: "CosLang", expression: "unicodeValue", profile: .pdfa2a).status, .passed)
        let files = [7: bytes("<< /Type /Filespec /F (local.txt) /UF (local.txt) /AFRelationship /Source /EF << /F 8 0 R >> >>"),
                     8: stream("/Type /EmbeddedFile /Subtype /bad-MIME", bytes("local"))]
        let associated = fixture(content: image + bytes("/AF << /MCAF [7 0 R] >> BDC EMC"), extras: files, version: "2.0")
        XCTAssertEqual(try evaluate(associated, object: "EmbeddedFile", expression: "Subtype !=", profile: .pdfa4f).status, .failed)
        let tagged = fixture(catalog: "/StructTreeRoot 8 0 R", page: "/StructParents 0",
                             content: image + bytes("/P << /MCID 1 >> BDC EMC"),
                             extras: [8: bytes("<< /Type /StructTreeRoot /K [9 0 R] /ParentTree << /Nums [0 [9 0 R]] >> >>"),
                                      9: bytes("<< /Type /StructElem /S /P /P 8 0 R /Pg 3 0 R /K 0 >>")])
        XCTAssertEqual(try evaluate(tagged, object: "PDDocument", expression: "containsStruct", profile: .pdfa2a).status, .failed)
    }

    func testInlineImageGuessedBoundaryNeverClaimsCompleteLanguageOrAssociationTraversal() throws {
        let content = bytes("BI /W 1 /H 1 /CS /G /BPC 8 /F /Unknown ID ABCD EI /P << /Lang (bad_language) >> BDC EMC")
        XCTAssertEqual(try evaluate(fixture(content: content), object: "CosLang", expression: "unicodeValue", profile: .pdfa2a).status, .notVerified)
        let prefixed = bytes("/P << /Lang (bad_language) >> BDC EMC\n") + content
        XCTAssertEqual(try evaluate(fixture(content: prefixed), object: "CosLang", expression: "unicodeValue", profile: .pdfa2a).status, .failed)
        XCTAssertEqual(try evaluate(fixture(content: content), object: "CosFileSpecification", expression: "isAssociatedFile", profile: .pdfa3u).status, .notVerified)
    }

    func testByteRangeExcludesExactlyContentsAndAcceptsLaterIncrementalRevision() throws {
        let placeholders = "/ByteRange [0000000000 0000000000 0000000000 0000000000]"
        var data = fixture(catalog: "/AcroForm << /Fields [7 0 R] >>", extras: [7: bytes("<< /FT /Sig /V 8 0 R >>"), 8: bytes("<< /Type /Sig \(placeholders) /Contents <3000> >>")])
        let reader = try PDFStructureDocument(data: data), gap = try XCTUnwrap(reader.object(.init(number: 8, generation: 0)).memberRanges["Contents"])
        let range = try XCTUnwrap(data.range(of: bytes(placeholders)))
        let corrected = String(format: "/ByteRange [%010d %010d %010d %010d]", 0, gap.lowerBound, gap.upperBound, data.count - gap.upperBound)
        data.replaceSubrange(range, with: bytes(corrected))
        XCTAssertEqual(try evaluate(data, object: "PDSignature", expression: "doesByteRange").status, .passed)
        let later = try PDFStructureDocument(data: data).setPageLabels(startPage: 0, firstNumber: 1, prefix: "Later-", style: .decimal)
        XCTAssertEqual(try evaluate(later, object: "PDSignature", expression: "doesByteRange").status, .passed)
        var invalid = data
        let bad = String(format: "/ByteRange [%010d %010d %010d %010d]", 0, gap.lowerBound - 1, gap.upperBound, data.count - gap.upperBound)
        invalid.replaceSubrange(range, with: bytes(bad))
        XCTAssertEqual(try evaluate(invalid, object: "PDSignature", expression: "doesByteRange").status, .failed)
    }

    @MainActor
    func testRealPKCSHasOneSignerAndEmbeddedCertificateWithoutTrustOrKeychainChanges() throws {
        let identity = try ephemeralIdentity()
        let signed = try PDFLocalCertificateEngine.sign(fixture(), identity: identity, reason: "Test strutturale")
        XCTAssertEqual(try evaluate(signed, object: "PKCSDataObject", expression: "SignerInfoCount").status, .passed)
        XCTAssertEqual(try evaluate(signed, object: "PKCSDataObject", expression: "signingCertificatePresent").status, .passed)
        let corrupt = fixture(catalog: "/AcroForm << /Fields [7 0 R] >>", extras: [7: bytes("<< /FT /Sig /V 8 0 R >>"), 8: bytes("<< /Type /Sig /Contents <3000> >>")])
        XCTAssertEqual(try evaluate(corrupt, object: "PKCSDataObject", expression: "SignerInfoCount").status, .failed)
    }

    func testFieldCyclesAreBoundedInsteadOfPresumedAbsent() throws {
        let data = fixture(catalog: "/AcroForm << /Fields [7 0 R] >>", extras: [7: bytes("<< /FT /Tx /Kids [7 0 R] >>")])
        let rule = try XCTUnwrap(PDFArchiveValidator.catalogue(profile: .pdfa2u).first { $0.objectType == "PDAcroForm" && $0.expression.contains("NeedAppearances") })
        let checks = try PDFArchiveStructureChecks(reader: PDFStructureDocument(data: data), profile: .pdfa2u)
        XCTAssertThrowsError(try checks.evaluate(rule))
    }

    func testPDF2AFModelRejectsMalformedRelationshipsAlsoForExternalFiles() throws {
        func model(_ data: Data) throws -> PDFArchiveRuleResult {
            try XCTUnwrap(PDFArchiveStructureChecks(reader: PDFStructureDocument(data: data), profile: .pdfa4f).modelChecks.first)
        }
        XCTAssertEqual(try model(fixture(catalog: "/AF /Invalid", version: "2.0")).status, .failed)
        XCTAssertEqual(try model(fixture(catalog: "/AF [(not a Filespec)]", version: "2.0")).status, .failed)
        XCTAssertEqual(try model(fixture(catalog: "/AF [<< /Type /Filespec /F (external.txt) >>]", version: "2.0")).status, .failed)
        XCTAssertEqual(try model(fixture(catalog: "/AF [<< /Type /Other /F (external.txt) /AFRelationship /Data >>]", version: "2.0")).status, .failed)
        XCTAssertEqual(try model(fixture(catalog: "/AF [<< /Type /Filespec /F (external.txt) /AFRelationship /Data >>]", version: "2.0")).status, .passed)
    }

    func testEmbeddedMIMEAcceptsEveryRFC6838PunctuationAndPreservesTheHistoricalExpression() throws {
        let types = ["application/octet-stream", "Application/Vnd.CartaPDF+JSON", "a!#$&-^_.+/b!#$&-^_.+",
                     "9/a", "a/9", String(repeating: "a", count: 127) + "/" + String(repeating: "b", count: 127)]
        for profile in [PDFArchiveProfile.pdfa4, .pdfa4e, .pdfa4f, .pdfa3u] {
            for mime in types {
                let result = try evaluate(mimeFixture(mime), object: "EmbeddedFile", expression: "Subtype !=", profile: profile)
                XCTAssertEqual(result.status, .passed, "\(profile.rawValue): \(mime)")
                XCTAssertTrue(result.detail.contains("Espressione XML storica conservata:"))
                XCTAssertTrue(result.detail.contains("Subtype != null"))
            }
        }
    }

    func testEmbeddedMIMERejectsInvalidNamesLengthsParametersAndPercentEscapes() throws {
        let invalid = ["", "/plain", "text/", "text/plain/extra", "text/plain; charset=utf-8",
                       "te xt/plain", "text/pläin", "text/pl%61in", "text/plain?", "text/pl*ain",
                       "text/pl'ain", "text/pl" + String(UnicodeScalar(UInt8(96))) + "ain", "text/pl~ain", "text/pl|ain", "text/pl=ain",
                       String(repeating: "a", count: 128) + "/plain", "text/" + String(repeating: "b", count: 128)]
        for mime in invalid {
            XCTAssertEqual(try evaluate(mimeFixture(mime), object: "EmbeddedFile", expression: "Subtype !=", profile: .pdfa4f).status, .failed, mime)
        }
        for punctuation in "!#$&-^_.+" {
            XCTAssertEqual(try evaluate(mimeFixture("text/\(punctuation)name"), object: "EmbeddedFile", expression: "Subtype !=", profile: .pdfa4f).status, .failed)
            XCTAssertEqual(try evaluate(mimeFixture("\(punctuation)type/plain"), object: "EmbeddedFile", expression: "Subtype !=", profile: .pdfa4f).status, .failed)
        }
        // The earlier RFC4288 grammar used by the 2012 profile permits these
        // initial characters; modern RFC6838 must not be imposed retroactively.
        XCTAssertEqual(try evaluate(mimeFixture("-type/.name"), object: "EmbeddedFile", expression: "Subtype !=", profile: .pdfa3u).status, .passed)
    }

    private func mimeFixture(_ mime: String) -> Data {
        let encodedName = String(decoding: PDFSyntaxValue.name(mime).encoded, as: UTF8.self)
        return fixture(catalog: "/AF [7 0 R]",
                       extras: [7: bytes("<< /Type /Filespec /F (local) /UF (local) /AFRelationship /Data /EF << /F 8 0 R >> >>"),
                                8: stream("/Type /EmbeddedFile /Subtype \(encodedName)", bytes("local"))],
                       version: "2.0")
    }

    func testPDF2MarkedAssociatedFilesRequireAFTagMCAFAndSequenceOperators() throws {
        let files = [7: bytes("<< /Type /Filespec /F (a.txt) /UF (a.txt) /AFRelationship /Data /EF << /F 8 0 R >> >>"),
                     8: stream("/Type /EmbeddedFile /Subtype /text#2Fplain", bytes("local"))]
        func model(_ content: String) throws -> PDFArchiveRuleStatus? {
            let data = fixture(content: bytes(content), extras: files, version: "2.0")
            return try PDFArchiveStructureChecks(reader: PDFStructureDocument(data: data), profile: .pdfa4f).modelChecks.first?.status
        }
        XCTAssertEqual(try model("/AF << /MCAF [7 0 R] >> BDC EMC"), .passed)
        XCTAssertEqual(try model("/AF << /MCAF [7 0 R] >> DP"), .failed)
        XCTAssertEqual(try model("/AF MP"), .failed)
        XCTAssertEqual(try model("/AF BMC EMC"), .failed)
        XCTAssertEqual(try model("/AF << >> BDC EMC"), .failed)
        XCTAssertEqual(try model("/AF << /MCAF [7 0 R (invalid)] >> BDC EMC"), .failed)
        let privateProperty = fixture(content: bytes("/Custom << /MCAF [7 0 R] >> BDC EMC"), extras: files, version: "2.0")
        XCTAssertNil(try PDFArchiveStructureChecks(reader: PDFStructureDocument(data: privateProperty), profile: .pdfa4f).modelChecks.first)
        XCTAssertEqual(try evaluate(privateProperty, object: "EmbeddedFile", expression: "Subtype !=", profile: .pdfa4f).status, .notApplicable)
    }

    func testDERRecursivelyRejectsNonminimalLengthsIntegersTagsAndConstructedStrings() throws {
        let invalid: [[UInt8]] = [
            [0x30, 0x04, 0x02, 0x81, 0x01, 0x01], // Inner long length for one byte.
            [0x30, 0x04, 0x02, 0x02, 0x00, 0x01], // Redundant positive sign.
            [0x30, 0x04, 0x02, 0x02, 0xff, 0xff], // Redundant negative sign.
            [0x30, 0x04, 0x1f, 0x02, 0x01, 0x01], // High-tag form for INTEGER.
            [0x30, 0x04, 0x1f, 0x80, 0x1f, 0x00], // Leading zero in high tag.
            [0x30, 0x04, 0x24, 0x02, 0x04, 0x00], // Constructed OCTET STRING.
            [0x30, 0x04, 0x30, 0x80, 0x00, 0x00], // Inner indefinite length.
            [0x30, 0x02, 0x00, 0x00],             // EOC in definite length.
            [0x30, 0x03, 0x02, 0x02, 0x01]       // Truncated inner value.
        ]
        for value in invalid { XCTAssertThrowsError(try PDFArchiveDEREnvelope(Data(value)), "\(value)") }
        let valid = Data([0x30, 0x06, 0x02, 0x01, 0x80, 0x02, 0x01, 0xff])
        XCTAssertEqual(try PDFArchiveDEREnvelope(valid + Data(repeating: 0, count: 8)).data, valid)
        XCTAssertThrowsError(try PDFArchiveDEREnvelope(valid + Data([1])))
    }

    func testDERPrimitiveCanonicalityIncludesBooleansBitsOIDStringsAndCalendarTimes() throws {
        func value(_ tag: UInt8, _ body: Data) -> Data { derTLV(48, derTLV(tag, body)) }
        let invalid = [
            value(1, Data([1])), value(1, Data()), value(3, Data([8, 0])),
            value(3, Data([1, 1])), value(3, Data([1])), value(5, Data([0])),
            value(6, Data([0x80, 0x2a])), value(6, Data([0x2a, 0x86])),
            value(12, Data([0xc0, 0x80])), value(19, bytes("not@Printable")),
            value(22, Data([0xff])), value(30, Data([0xd8, 0])),
            value(28, Data([0, 0x11, 0, 0])), value(23, bytes("260230120000Z")),
            value(23, bytes("2610181200Z")), value(23, bytes("261018120000+0000")),
            value(24, bytes("20261018120000.30Z")), value(24, bytes("20261018240000Z"))
        ]
        for data in invalid { XCTAssertThrowsError(try PDFArchiveDEREnvelope(data), data.description) }
        for data in [value(1, Data([255])), value(3, Data([3, 0xf8])),
                     value(6, Data([0x2a, 0x86, 0x48])), value(19, bytes("CartaPDF '()+,-./:=?")),
                     value(23, bytes("240229235959Z")), value(24, bytes("20261018120000.03Z"))] {
            XCTAssertNoThrow(try PDFArchiveDEREnvelope(data))
        }
    }

    func testDEROrdersSchemaIdentifiedExplicitAndImplicitCMSSets() throws {
        let one = derTLV(2, Data([1])), two = derTLV(2, Data([2]))
        let oid = derTLV(6, Data([42, 134, 72, 134, 247, 13, 1, 7, 2]))
        func cms(_ digest: Data, certificates: Data = Data(), signer: Data = Data()) -> Data {
            let signed = derTLV(48, one + derTLV(49, digest) + derTLV(48, Data()) + certificates + derTLV(49, signer))
            return derTLV(48, oid + derTLV(160, signed))
        }
        XCTAssertNoThrow(try PDFArchiveDEREnvelope(cms(one + two)).checkSignedDataSets())
        XCTAssertThrowsError(try PDFArchiveDEREnvelope(cms(two + one)).checkSignedDataSets())
        XCTAssertNoThrow(try PDFArchiveDEREnvelope(cms(Data(), certificates: derTLV(161, one + two))).checkSignedDataSets())
        XCTAssertThrowsError(try PDFArchiveDEREnvelope(cms(Data(), certificates: derTLV(161, two + one))).checkSignedDataSets())
        let attrOne = derTLV(48, derTLV(6, Data([42])) + derTLV(49, one))
        let attrTwo = derTLV(48, derTLV(6, Data([43])) + derTLV(49, two))
        func signer(_ attrs: Data) -> Data {
            derTLV(48, one + derTLV(48, derTLV(48, Data()) + one) + derTLV(48, Data()) +
                   derTLV(160, attrs) + derTLV(48, Data()) + derTLV(4, Data()))
        }
        XCTAssertNoThrow(try PDFArchiveDEREnvelope(cms(Data(), signer: signer(attrOne + attrTwo))).checkSignedDataSets())
        XCTAssertThrowsError(try PDFArchiveDEREnvelope(cms(Data(), signer: signer(attrTwo + attrOne))).checkSignedDataSets())
        let unorderedValues = derTLV(48, derTLV(6, Data([42])) + derTLV(49, two + one))
        XCTAssertThrowsError(try PDFArchiveDEREnvelope(cms(Data(), signer: signer(unorderedValues))).checkSignedDataSets())
    }

    func testDERX509NameOrderingAndDefaultOmissionAreCheckedInTheirSchemaPositions() throws {
        let one = derTLV(2, Data([1])), emptySequence = derTLV(48, Data())
        let oid = derTLV(6, Data([42, 134, 72, 134, 247, 13, 1, 7, 2]))
        let attributeA = derTLV(48, derTLV(6, Data([42])) + derTLV(19, bytes("A")))
        let attributeB = derTLV(48, derTLV(6, Data([42])) + derTLV(19, bytes("B")))
        func cms(version: Data = Data(), issuer: Data = Data(), critical: Data? = nil) -> Data {
            let name = issuer.isEmpty ? emptySequence : derTLV(48, derTLV(49, issuer))
            var tbs = version + one + emptySequence + name + emptySequence + emptySequence + emptySequence
            if let critical {
                let ext = derTLV(48, derTLV(6, Data([42])) + critical + derTLV(4, Data()))
                tbs += derTLV(163, derTLV(48, ext))
            }
            let cert = derTLV(48, derTLV(48, tbs) + emptySequence + derTLV(3, Data([0])))
            let signed = derTLV(48, one + derTLV(49, Data()) + emptySequence + derTLV(160, cert) + derTLV(49, Data()))
            return derTLV(48, oid + derTLV(160, signed))
        }
        XCTAssertNoThrow(try PDFArchiveDEREnvelope(cms(issuer: attributeA + attributeB)).checkSignedDataSets())
        XCTAssertThrowsError(try PDFArchiveDEREnvelope(cms(issuer: attributeB + attributeA)).checkSignedDataSets())
        XCTAssertThrowsError(try PDFArchiveDEREnvelope(cms(version: derTLV(160, derTLV(2, Data([0]))))).checkSignedDataSets())
        XCTAssertNoThrow(try PDFArchiveDEREnvelope(cms(version: derTLV(160, derTLV(2, Data([2]))), critical: derTLV(1, Data([255])))).checkSignedDataSets())
        XCTAssertThrowsError(try PDFArchiveDEREnvelope(cms(critical: derTLV(1, Data([0])))).checkSignedDataSets())
    }

    @MainActor
    func testRealCMSWithInnerBERIntegerFailsDERWhileOriginalStillPasses() throws {
        let signed = try PDFLocalCertificateEngine.sign(fixture(), identity: ephemeralIdentity(), reason: "DER regression")
        let reader = try PDFStructureDocument(data: signed)
        let signature = try XCTUnwrap(reader.allObjectIDs().first { id in
            let dictionary = try reader.object(id).value.dictionary ?? [:]
            return dictionary["Type"]?.name == "Sig"
        })
        let dictionary = try XCTUnwrap(reader.object(signature).value.dictionary)
        let contents = try XCTUnwrap(dictionary["Contents"]?.data)
        let envelope = try PDFArchiveDEREnvelope(contents)
        XCTAssertNoThrow(try envelope.checkSignedDataSets())
        let signedData = envelope.root.children[1].children[0]
        var values = signedData.children.map { envelope.data.subdata(in: $0.range) }
        let version = signedData.children[0]
        // Rebuild all ancestors so the sole defect is an INTEGER's redundant
        // positive sign byte, which permissive BER decoders may accept.
        values[0] = derTLV(2, Data([0]) + envelope.data.subdata(in: version.content))
        let badCMS = derTLV(48, envelope.data.subdata(in: envelope.root.children[0].range) +
                            derTLV(160, derTLV(48, values.reduce(Data(), +))))
        XCTAssertThrowsError(try PDFArchiveDEREnvelope(badCMS))
        let hex = badCMS.map { String(format: "%02X", $0) }.joined()
        let mutated = fixture(catalog: "/AcroForm << /Fields [7 0 R] >>",
                              extras: [7: bytes("<< /FT /Sig /V 8 0 R >>"), 8: bytes("<< /Type /Sig /Contents <\(hex)> >>")])
        XCTAssertEqual(try evaluate(mutated, object: "PKCSDataObject", expression: "SignerInfoCount").status, .failed)
        XCTAssertEqual(try evaluate(signed, object: "PKCSDataObject", expression: "SignerInfoCount").status, .passed)
    }

    private func derTLV(_ tag: UInt8, _ body: Data) -> Data {
        var length = Data()
        if body.count < 128 { length.append(UInt8(body.count)) }
        else {
            var count = body.count, bytes: [UInt8] = []
            while count > 0 { bytes.insert(UInt8(count & 255), at: 0); count >>= 8 }
            length.append(128 | UInt8(bytes.count)); length += Data(bytes)
        }
        return Data([tag]) + length + body
    }

    private func evaluate(_ data: Data, object: String, expression: String, profile: PDFArchiveProfile = .pdfa2u) throws -> PDFArchiveRuleEvaluation {
        let rule = try XCTUnwrap(PDFArchiveValidator.catalogue(profile: profile).first { $0.objectType == object && $0.expression.contains(expression) })
        return try XCTUnwrap(PDFArchiveStructureChecks(reader: PDFStructureDocument(data: data), profile: profile).evaluate(rule))
    }
    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private func stream(_ dictionary: String, _ data: Data) -> Data {
        bytes("<< \(dictionary) /Length \(data.count) >>\nstream\n") + data + bytes("\nendstream")
    }
    private func fixture(catalog: String = "", page: String = "", content: Data = Data(), extras: [Int: Data] = [:], version: String = "1.7") -> Data {
        var objects: [Int: Data] = [1: bytes("<< /Type /Catalog /Pages 2 0 R \(catalog) >>"),
            2: bytes("<< /Type /Pages /Count 1 /Kids [3 0 R] >>"),
            3: bytes("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Contents 4 0 R \(page) >>"), 4: stream("", content)]
        objects.merge(extras) { _, value in value }
        var data = bytes("%PDF-\(version)\n%") + Data([0xe2,0xe3,0xcf,0xd3,10]), offsets: [Int: Int] = [:]
        for id in objects.keys.sorted() { offsets[id] = data.count; data += bytes("\(id) 0 obj\n") + objects[id]! + bytes("\nendobj\n") }
        let start = data.count, size = (objects.keys.max() ?? 0) + 1
        data += bytes("xref\n0 \(size)\n0000000000 65535 f \n")
        for id in 1..<size { data += bytes(String(format: "%010lld 00000 %@ \n", Int64(offsets[id] ?? 0), offsets[id] == nil ? "f" : "n")) }
        return data + bytes("trailer\n<< /Size \(size) /Root 1 0 R /ID [<123456><789ABC>] >>\nstartxref\n\(start)\n%%EOF\n")
    }
    private func ephemeralIdentity() throws -> SecIdentity {
        let generated = P256.Signing.PrivateKey()
        let key = try XCTUnwrap(SecKeyCreateWithData(generated.x963Representation as CFData,
            [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits: 256] as CFDictionary, nil))
        func tlv(_ tag: UInt8, _ value: Data) -> Data {
            var length = Data()
            if value.count < 128 { length.append(UInt8(value.count)) }
            else { var size = value.count, bytes: [UInt8] = []; while size > 0 { bytes.insert(UInt8(size & 255), at: 0); size >>= 8 }; length.append(0x80 | UInt8(bytes.count)); length += Data(bytes) }
            return Data([tag]) + length + value
        }
        func sequence(_ value: Data) -> Data { tlv(48, value) }
        let keyAlgorithm = sequence(Data([6,7,42,134,72,206,61,2,1,6,8,42,134,72,206,61,3,1,7]))
        let signatureAlgorithm = sequence(Data([6,8,42,134,72,206,61,4,3,2]))
        let name = sequence(tlv(49, sequence(Data([6,3,85,4,3]) + tlv(12, bytes("CartaPDF Structure Test " + UUID().uuidString)))))
        var serial = Data([1]); withUnsafeBytes(of: UUID().uuid) { serial.append(contentsOf: $0) }
        let validity = sequence(tlv(23, bytes("200101000000Z")) + tlv(23, bytes("491231235959Z")))
        let publicKey = sequence(keyAlgorithm + tlv(3, Data([0]) + generated.publicKey.x963Representation))
        let body = sequence(tlv(2, serial) + signatureAlgorithm + name + validity + name + publicKey)
        let signature = try XCTUnwrap(SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, body as CFData, nil)) as Data
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, sequence(body + signatureAlgorithm + tlv(3, Data([0]) + signature)) as CFData))
        return try XCTUnwrap(SecIdentityCreate(nil, certificate, key))
    }
}
