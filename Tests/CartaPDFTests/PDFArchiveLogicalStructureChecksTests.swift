import Foundation
import XCTest
@testable import CartaPDF

final class PDFArchiveLogicalStructureChecksTests: XCTestCase {
    func testMechanicalOwnershipPassDoesNotClaimMeaningfulTaggedContent() throws {
        let data = fixture(root: "/ParentTree << /Nums [0 [9 0 R]] >>", node: "/Pg 3 0 R /K 0", page: "/StructParents 0", content: marked(0))
        XCTAssertEqual(try check(data).status, .passed)
        let rule = try XCTUnwrap(PDFArchiveValidator.catalogue(profile: .pdfa2a).first { $0.objectType == "PDDocument" && $0.expression == "containsStructTreeRoot == true" })
        XCTAssertEqual(try PDFArchiveStructureChecks(reader: PDFStructureDocument(data: data), profile: .pdfa2a).evaluate(rule)?.status, .notVerified)
        XCTAssertTrue(try PDFArchiveStructureChecks(reader: PDFStructureDocument(data: data), profile: .pdfa2a).modelChecks.contains { $0.objectType == "LogicalStructureModel" })
    }
    func testParentTreeReverseOwnershipCannotBeProvedByAnElementReferenceAlone() throws {
        let orphan = fixture(root: "/ParentTree << /Nums [0 [9 0 R]] >>", page: "/StructParents 0", content: marked(0))
        XCTAssertEqual(try check(orphan).status, .failed)
        let wrong = fixture(root: "/ParentTree << /Nums [0 [10 0 R]] >>", node: "/Pg 3 0 R /K 0", page: "/StructParents 0", content: marked(0),
                            extras: [10: bytes("<< /S /P /P 8 0 R >>")])
        XCTAssertEqual(try check(wrong).status, .failed)
    }
    func testMCRRequiresAnActualPageAndAnIndirectStreamWhenPresent() throws {
        let form = stream("/Type /XObject /Subtype /Form /BBox [0 0 10 10] /StructParents 1 /Resources << >>", marked(0))
        let good = fixture(root: "/ParentTree << /Nums [1 [9 0 R]] >>",
                           node: "/K << /Type /MCR /Pg 3 0 R /Stm 7 0 R /MCID 0 >>", extras: [7: form])
        XCTAssertEqual(try check(good).status, .passed)
        for node in ["/K << /Type /MCR /Stm 7 0 R /MCID 0 >>",
                     "/K << /Type /MCR /Pg 2 0 R /Stm 7 0 R /MCID 0 >>",
                     "/K << /Type /MCR /Pg 3 0 R /Stm << >> /MCID 0 >>",
                     "/K << /Type /MCR /Pg 3 0 R /Stm 7 0 R /MCID 0.5 >>",
                     "/K << /Type /MCR /Pg 3 0 R /Stm 7 0 R /StmOwn << >> /MCID 0 >>"] {
            XCTAssertEqual(try check(fixture(root: "/ParentTree << /Nums [1 [9 0 R]] >>", node: node, extras: [7: form])).status, .failed)
        }
    }
    func testOBJRRequiresIndirectObjectPageAndReciprocalStructParent() throws {
        let annotation = bytes("<< /Type /Annot /Subtype /Text /Rect [1 1 2 2] /StructParent 2 >>")
        let good = fixture(root: "/ParentTree << /Nums [2 9 0 R] >>", node: "/K << /Type /OBJR /Pg 3 0 R /Obj 7 0 R >>",
                           page: "/Annots [7 0 R]", extras: [7: annotation])
        XCTAssertEqual(try check(good).status, .passed)
        for node in ["/K << /Type /OBJR /Pg 3 0 R >>", "/K << /Type /OBJR /Obj 7 0 R >>",
                     "/K << /Type /OBJR /Pg 3 0 R /Obj << /StructParent 2 >> >>"] {
            XCTAssertEqual(try check(fixture(root: "/ParentTree << /Nums [2 9 0 R] >>", node: node, extras: [7: annotation])).status, .failed)
        }
        let both = bytes("<< /Subtype /Text /Rect [1 1 2 2] /StructParent 2 /StructParents 3 >>")
        XCTAssertEqual(try check(fixture(root: "/ParentTree << /Nums [2 9 0 R] >>",
            node: "/K << /Type /OBJR /Pg 3 0 R /Obj 7 0 R >>", extras: [7: both])).status, .failed)
    }
    func testNullPgFallsBackToTheParentPageForMCRAndOBJRInEveryProfile() throws {
        let nullObject = bytes("null")
        let annotation = bytes("<< /Type /Annot /Subtype /Text /Rect [1 1 2 2] /StructParent 2 >>")
        for profile in PDFArchiveProfile.allCases {
            for null in ["null", "11 0 R", "99 0 R"] {
                let mcr = fixture(root: "/ParentTree << /Nums [0 [9 0 R]] >>",
                    node: "/Pg 3 0 R /K << /Type /MCR /Pg \(null) /Stm \(null) /MCID 0 >>",
                    page: "/StructParents 0", content: marked(0), extras: [11: nullObject])
                XCTAssertEqual(try check(mcr, profile: profile).status, .passed, "\(profile.rawValue), \(null)")
                let objr = fixture(root: "/ParentTree << /Nums [2 9 0 R] >>",
                    node: "/Pg 3 0 R /K << /Type /OBJR /Pg \(null) /Obj 7 0 R >>",
                    page: "/Annots [7 0 R]", extras: [7: annotation, 11: nullObject])
                XCTAssertEqual(try check(objr, profile: profile).status, .passed, "\(profile.rawValue), \(null)")
                let noParent = fixture(root: "/ParentTree << /Nums [0 [9 0 R]] >>",
                    node: "/K << /Type /MCR /Pg \(null) /MCID 0 >>",
                    page: "/StructParents 0", content: marked(0), extras: [11: nullObject])
                XCTAssertEqual(try check(noParent, profile: profile).status, .failed)
            }
        }
    }
    func testNullStreamAndPageEntriesDoNotFalsifyTheIndependentCatalogueStructureRule() throws {
        let rule = try XCTUnwrap(PDFArchiveValidator.catalogue(profile: .pdfa2a).first {
            $0.objectType == "PDDocument" && $0.expression == "containsStructTreeRoot == true"
        })
        for null in ["null", "11 0 R", "99 0 R"] {
            let data = fixture(root: "/ParentTree << /Nums [0 [9 0 R]] >>",
                node: "/Pg 3 0 R /K << /Type /MCR /Pg \(null) /Stm \(null) /MCID 0 >>",
                page: "/StructParents 0", content: marked(0), extras: [11: bytes("null")])
            let result = try PDFArchiveStructureChecks(reader: PDFStructureDocument(data: data), profile: .pdfa2a).evaluate(rule)
            XCTAssertEqual(result?.status, .notVerified)
        }
    }
    func testNullOptionalAttributesNamespacesAndReferencesAreOmittedButArrayMembersAreNot() throws {
        for profile in PDFArchiveProfile.allCases {
            for null in ["null", "11 0 R", "99 0 R"] {
                let data = fixture(root: "/RoleMap << /Unused \(null) >> /ClassMap << /Unused \(null) >>",
                    node: "/Type \(null) /A \(null) /C \(null) /R \(null) /NS \(null) /Ref \(null) /Pg \(null)",
                    extras: [11: bytes("null")])
                XCTAssertEqual(try check(data, profile: profile).status, .passed, "\(profile.rawValue), \(null)")
                let emptyClass = fixture(root: "/ClassMap << /Empty \(null) >>", node: "/C /Empty", extras: [11: bytes("null")])
                XCTAssertEqual(try check(emptyClass, profile: profile).status, .passed)
                for node in ["/A [\(null)]", "/C [\(null)]"] {
                    XCTAssertEqual(try check(fixture(node: node, extras: [11: bytes("null")]), profile: profile).status, .failed)
                }
                if profile.part == 4 {
                    XCTAssertEqual(try check(fixture(node: "/Ref [\(null)]", extras: [11: bytes("null")]), profile: profile).status, .failed)
                }
            }
        }
    }
    func testIndirectAliasChainsResolveScalarMCIDsAndMCRTypeNames() throws {
        let aliases = [11: bytes("12 0 R"), 12: bytes("0"), 13: bytes("14 0 R"), 14: bytes("/MCR")]
        for profile in [PDFArchiveProfile.pdfa1a, .pdfa2a, .pdfa4] {
            for child in ["11 0 R", "<< /Type 13 0 R /MCID 11 0 R >>"] {
                let data = fixture(root: "/ParentTree << /Nums [0 [9 0 R]] >>",
                    node: "/Pg 3 0 R /K \(child)", page: "/StructParents 0", content: marked(0), extras: aliases)
                XCTAssertEqual(try check(data, profile: profile).status, .passed)
            }
        }
    }
    func testAliasIdentityIsCanonicalForParentPageParentTreeAndIDTree() throws {
        let data = fixture(root: "/K 11 0 R /ParentTree << /Nums [0 [12 0 R]] >> /IDTree << /Names [(a) 12 0 R] >>",
            node: "/P 13 0 R /Pg 14 0 R /ID (a) /K 0", page: "/StructParents 0", content: marked(0),
            extras: [11: bytes("9 0 R"), 12: bytes("9 0 R"), 13: bytes("8 0 R"), 14: bytes("3 0 R")])
        XCTAssertEqual(try check(data).status, .passed)
        let rule = try XCTUnwrap(PDFArchiveValidator.catalogue(profile: .pdfa2a).first {
            $0.objectType == "PDDocument" && $0.expression == "containsStructTreeRoot == true"
        })
        XCTAssertEqual(try PDFArchiveStructureChecks(reader: PDFStructureDocument(data: data), profile: .pdfa2a).evaluate(rule)?.status, .notVerified)
    }
    func testAliasIdentityIsCanonicalForOBJRStmAndPageContentsStreams() throws {
        let annotation = bytes("<< /Type /Annot /Subtype /Text /Rect [1 1 2 2] /StructParent 2 >>")
        let objr = fixture(root: "/ParentTree << /Nums [2 12 0 R] >>",
            node: "/Pg 13 0 R /K << /Type /OBJR /Obj 11 0 R >>", page: "/Annots [7 0 R]",
            extras: [7: annotation, 11: bytes("7 0 R"), 12: bytes("9 0 R"), 13: bytes("3 0 R")])
        XCTAssertEqual(try check(objr).status, .passed)
        let form = stream("/Type /XObject /Subtype /Form /BBox [0 0 10 10] /StructParents 1 /Resources << >>", marked(0))
        let mcr = fixture(root: "/ParentTree << /Nums [1 [12 0 R]] >>",
            node: "/Pg 13 0 R /K << /Type /MCR /Stm 11 0 R /StmOwn 13 0 R /MCID 0 >>",
            extras: [7: form, 11: bytes("7 0 R"), 12: bytes("9 0 R"), 13: bytes("3 0 R")])
        XCTAssertEqual(try check(mcr).status, .passed)
        let pageStream = fixture(root: "/ParentTree << /Nums [0 [9 0 R]] >>",
            node: "/Pg 3 0 R /K << /Type /MCR /Stm 11 0 R /MCID 0 >>",
            page: "/StructParents 0 /Contents 11 0 R", content: marked(0), extras: [11: bytes("4 0 R")])
        XCTAssertEqual(try check(pageStream).status, .passed)
    }
    func testPDF2AliasIdentityIsCanonicalForNamespacesRoleMapsAndRefTargets() throws {
        let namespace = bytes("<< /Type /Namespace /NS (urn:example:carta) /RoleMapNS << /Custom [/P 13 0 R] >> >>")
        let data = fixture(root: "/Namespaces [11 0 R]",
            node: "/NS 13 0 R /A << /O /NSO /NS 13 0 R >> /Ref [14 0 R]",
            extras: [11: bytes("12 0 R"), 12: namespace, 13: bytes("12 0 R"), 14: bytes("9 0 R")], version: "2.0")
        XCTAssertEqual(try check(data, profile: .pdfa4).status, .passed)
    }
    func testCircularAndOverdeepAliasChainsRemainNotVerified() throws {
        let cycle = fixture(node: "/K 11 0 R", extras: [11: bytes("12 0 R"), 12: bytes("11 0 R")])
        XCTAssertEqual(try check(cycle).status, .notVerified)
        var aliases: [Int: Data] = [:]
        for id in 11...111 { aliases[id] = bytes("\(id + 1) 0 R") }
        aliases[112] = bytes("0")
        XCTAssertEqual(try check(fixture(node: "/K 11 0 R", extras: aliases)).status, .notVerified)
        let knownFailure = fixture(root: "/Type /Invalid", node: "/K 11 0 R",
            extras: [11: bytes("12 0 R"), 12: bytes("11 0 R")])
        XCTAssertEqual(try check(knownFailure).status, .failed)
    }
    func testDistinctContainersCannotShareOneParentTreeKey() throws {
        let form = stream("/Type /XObject /Subtype /Form /BBox [0 0 10 10] /StructParents 0 /Resources << >>", marked(0))
        let data = fixture(root: "/ParentTree << /Nums [0 [9 0 R]] >>", node: "/Pg 3 0 R /K [0 << /Type /MCR /Pg 3 0 R /Stm 7 0 R /MCID 0 >>]",
                           page: "/StructParents 0", content: marked(0), extras: [7: form])
        XCTAssertEqual(try check(data).status, .failed)
    }
    func testPageContentsArrayIsOneLogicalSequenceAndExplicitPageStmUsesPageOwnership() throws {
        let data = fixture(root: "/ParentTree << /Nums [0 [9 0 R 9 0 R]] >>",
                           node: "/Pg 3 0 R /K [0 << /Type /MCR /Pg 3 0 R /Stm 5 0 R /MCID 1 >>]",
                           page: "/StructParents 0 /Contents [4 0 R 5 0 R]", content: marked(0),
                           extras: [5: stream("", marked(1))])
        XCTAssertEqual(try check(data).status, .passed)
    }
    func testParentTreeNullHolesDoNotInventAContiguousMCIDRequirement() throws {
        let data = fixture(root: "/ParentTree << /Nums [0 [null 9 0 R]] >>", node: "/Pg 3 0 R /K 1",
                           page: "/StructParents 0", content: marked(1))
        for profile in [PDFArchiveProfile.pdfa1a, .pdfa2a, .pdfa4] {
            XCTAssertEqual(try check(data, profile: profile).status, .passed)
        }
    }
    func testNestedStructuralContentItemsFailButNonstructuralNestingIsAllowed() throws {
        let prefix = "/P << /MCID 0 >> BDC /Span << /MCID 1 >> BDC EMC EMC"
        let nested = fixture(root: "/ParentTree << /Nums [0 [9 0 R 9 0 R]] >>", node: "/Pg 3 0 R /K [0 1]",
                             page: "/StructParents 0", content: bytes(prefix))
        XCTAssertEqual(try check(nested).status, .failed)
        let nonstructural = fixture(root: "/ParentTree << /Nums [0 [9 0 R]] >>", node: "/Pg 3 0 R /K 0",
                                   page: "/StructParents 0", content: bytes("/P << /MCID 0 >> BDC /Span BMC EMC EMC"))
        XCTAssertEqual(try check(nonstructural).status, .passed)
    }
    func testStructuralMarkedContentCannotInvokeAnEntireStructuralXObject() throws {
        let form = stream("/Type /XObject /Subtype /Form /BBox [0 0 10 10] /StructParent 1", bytes("q Q"))
        func document(_ content: String) -> Data {
            fixture(root: "/ParentTree << /Nums [0 [9 0 R] 1 9 0 R] >>",
                    node: "/Pg 3 0 R /K [0 << /Type /OBJR /Pg 3 0 R /Obj 7 0 R >>]",
                    page: "/StructParents 0", resources: "/XObject << /F 7 0 R >>", content: bytes(content), extras: [7: form])
        }
        XCTAssertEqual(try check(document("/P << /MCID 0 >> BDC /F Do EMC")).status, .failed)
        XCTAssertEqual(try check(document("/P << /MCID 0 >> BDC EMC /F Do")).status, .passed)
    }
    func testNumberTreeLimitsOrderingAndCyclesAreMechanical() throws {
        let nodes = [11: bytes("<< /Nums [0 []] /Limits [0 0] >>"), 12: bytes("<< /Nums [1 []] /Limits [1 1] >>")]
        XCTAssertEqual(try check(fixture(root: "/ParentTree << /Kids [11 0 R 12 0 R] >>", extras: nodes)).status, .passed)
        XCTAssertEqual(try check(fixture(root: "/ParentTree << /Kids [12 0 R 11 0 R] >>", extras: nodes)).status, .failed)
        var wrong = nodes; wrong[11] = bytes("<< /Nums [0 []] /Limits [0 3] >>")
        XCTAssertEqual(try check(fixture(root: "/ParentTree << /Kids [11 0 R 12 0 R] >>", extras: wrong)).status, .failed)
        let cycle = fixture(root: "/ParentTree 11 0 R", extras: [11: bytes("<< /Kids [11 0 R] >>")])
        XCTAssertEqual(try check(cycle).status, .failed)
        XCTAssertEqual(try check(fixture(root: "/ParentTree << /Nums [0 []] /Kids [11 0 R] >>", extras: nodes)).status, .failed)
    }
    func testIDsAreByteStringsUniqueAndBidirectionallyMappedByIDTree() throws {
        let good = fixture(root: "/IDTree << /Names [<00FF> 9 0 R] >>", node: "/ID <00FF>")
        XCTAssertEqual(try check(good).status, .passed)
        XCTAssertEqual(try check(fixture(node: "/ID (a)")).status, .failed)
        XCTAssertEqual(try check(fixture(root: "/IDTree << /Names [(wrong) 9 0 R] >>", node: "/ID (a)")).status, .failed)
        let duplicate = fixture(root: "/K [9 0 R 10 0 R] /IDTree << /Names [(a) 9 0 R] >>", node: "/ID (a)",
                                extras: [10: bytes("<< /S /P /P 8 0 R /ID (a) >>")])
        XCTAssertEqual(try check(duplicate).status, .failed)
    }
    func testNameAndNumberTreeLimitsAreRequiredOnlyBelowTheirRoot() throws {
        let leaf = bytes("<< /Names [(a) 9 0 R] /Limits [(a) (a)] >>")
        XCTAssertEqual(try check(fixture(root: "/IDTree << /Kids [11 0 R] >>", node: "/ID (a)", extras: [11: leaf])).status, .passed)
        for leaf in [bytes("<< /Names [(a) 9 0 R] >>"), bytes("<< /Names [(a) 9 0 R] /Limits [(a) (z)] >>")] {
            XCTAssertEqual(try check(fixture(root: "/IDTree << /Kids [11 0 R] >>", node: "/ID (a)", extras: [11: leaf])).status, .failed)
        }
        XCTAssertEqual(try check(fixture(root: "/IDTree << /Names [(a) 9 0 R] /Limits [(a) (a)] >>", node: "/ID (a)")).status, .failed)
        XCTAssertEqual(try check(fixture(root: "/ParentTree << /Nums [0 []] /Limits [0 0] >>")).status, .failed)
        XCTAssertEqual(try check(fixture(root: "/ParentTree << /Kids [11 0 R] >>", extras: [11: bytes("<< /Nums [0 []] >>")])).status, .failed)
    }
    func testNumberTreeIntegerKeysAreNotInventedToBeNonnegativeMCIDs() throws {
        let data = fixture(root: "/ParentTree << /Nums [-3 [9 0 R]] >> /ParentTreeNextKey -2",
                           node: "/Pg 3 0 R /K 0", page: "/StructParents -3", content: marked(0))
        XCTAssertEqual(try check(data).status, .passed)
        XCTAssertTrue(try PDFArchiveStructureChecks(reader: PDFStructureDocument(data: data), profile: .pdfa2a).modelChecks.contains { $0.objectType == "LogicalStructureModel" && $0.status == .passed })
    }
    func testClassAttributesRevisionPairsAndMissingClassesUseTheirActualGrammar() throws {
        let root = "/ClassMap << /A [<< /O /Layout >> << /O /Layout >>] >>"
        let good = fixture(root: root, node: "/R 2 /A [<< /O /Layout >> 1 << /O /Layout >>] /C [/A 2 /Undefined 0]")
        XCTAssertEqual(try check(good).status, .passed)
        for node in ["/R -1", "/A [1 << /O /Layout >>]", "/A << /Private 1 >>", "/C [/A 1 2]", "/C [null]", "/A [null]", "/A [[<< /O /Layout >>]]"] {
            XCTAssertEqual(try check(fixture(root: root, node: node)).status, .failed)
        }
        XCTAssertEqual(try check(fixture(root: "/ClassMap << /A [<< /O /Layout >> 1] >>")).status, .failed)
    }
    func testPDF2NamespacesRequireIndirectMembershipWithoutRetrofittingPDF17() throws {
        let ns = bytes("<< /Type /Namespace /NS (urn:example:carta) /RoleMapNS << /Custom [/P 11 0 R] >> >>")
        let good = fixture(root: "/Namespaces [11 0 R]", node: "/NS 11 0 R", extras: [11: ns], version: "2.0")
        XCTAssertEqual(try check(good, profile: .pdfa4).status, .passed)
        let missing = fixture(node: "/NS 11 0 R", extras: [11: ns], version: "2.0")
        XCTAssertEqual(try check(missing, profile: .pdfa4).status, .failed)
        XCTAssertEqual(try check(missing, profile: .pdfa2a).status, .passed)
        XCTAssertEqual(try check(fixture(root: "/Namespaces [11 0 R]", node: "/NS << /NS (urn:example:carta) >>", extras: [11: ns]), profile: .pdfa4).status, .failed)
        XCTAssertEqual(try check(fixture(root: "/Namespaces [11 0 R]", extras: [11: bytes("<< /NS (urn:example:carta) /RoleMapNS << /Custom 1 >> >>")]), profile: .pdfa4).status, .failed)
        XCTAssertEqual(try check(fixture(node: "/A << /O /NSO >>"), profile: .pdfa4).status, .failed)
        XCTAssertEqual(try check(fixture(node: "/A << /O /NSO >>"), profile: .pdfa2a).status, .passed)
    }
    func testRootChildrenHierarchyAndPDF2NullRulesAreNotPresenceTests() throws {
        for root in ["/K 0", "/K << /Type /MCR /Pg 3 0 R /MCID 0 >>", "/K [9 0 R 9 0 R]", "/K [[9 0 R]]"] {
            XCTAssertEqual(try check(fixture(root: root)).status, .failed)
        }
        XCTAssertEqual(try check(fixture(root: "/K null"), profile: .pdfa4).status, .failed)
        XCTAssertEqual(try check(fixture(root: "/K null"), profile: .pdfa2a).status, .passed)
        let cycle = fixture(node: "/K 9 0 R")
        XCTAssertEqual(try check(cycle).status, .failed)
    }
    func testRoleMapCyclesAreAllowedByBasePDFWhilePDFASpecificRuleStillRejectsThem() throws {
        let data = fixture(root: "/RoleMap << /Custom /Other /Other /Custom >>", node: "/S /Custom")
        XCTAssertEqual(try check(data).status, .passed)
        let rule = try XCTUnwrap(PDFArchiveValidator.catalogue(profile: .pdfa2a).first { $0.objectType == "SENonStandard" && $0.expression.contains("circularMapping") })
        XCTAssertEqual(try PDFArchiveStructureChecks(reader: PDFStructureDocument(data: data), profile: .pdfa2a).evaluate(rule)?.status, .failed)
        XCTAssertEqual(try check(fixture(root: "/RoleMap << /Custom 1 >>")).status, .failed)
    }
    func testMCIDSequenceBalanceAndAmbiguousInlineDataPreserveKnownViolations() throws {
        func document(_ content: Data) -> Data {
            fixture(root: "/ParentTree << /Nums [0 [9 0 R]] >>", node: "/Pg 3 0 R /K 0", page: "/StructParents 0", content: content)
        }
        XCTAssertEqual(try check(document(bytes("EMC") + marked(0))).status, .failed)
        XCTAssertEqual(try check(document(bytes("/P << /MCID 0 >> BDC"))).status, .failed)
        let ambiguous = bytes("BI /W 1 /H 1 /CS /G /BPC 8 /F /Unknown ID ABCD EI")
        XCTAssertEqual(try check(document(marked(0) + ambiguous)).status, .notVerified)
        XCTAssertEqual(try check(document(bytes("EMC") + marked(0) + ambiguous)).status, .failed)
    }
    func testIndirectPropertyResourcesAndDuplicateMCIDsAreActuallyRead() throws {
        let properties = bytes("<< /P << /MCID 0 >> >>")
        let good = fixture(root: "/ParentTree << /Nums [0 [9 0 R]] >>", node: "/Pg 3 0 R /K 0", page: "/StructParents 0",
                           resources: "/Properties 7 0 R", content: bytes("/P /P BDC EMC"), extras: [7: properties])
        XCTAssertEqual(try check(good).status, .passed)
        let duplicate = fixture(root: "/ParentTree << /Nums [0 [9 0 R]] >>", node: "/Pg 3 0 R /K 0",
                                page: "/StructParents 0", content: marked(0) + marked(0))
        XCTAssertEqual(try check(duplicate).status, .failed)
    }
    func testFormWithUnprovedInheritedPropertyResourcesDoesNotInventMissingMCIDProof() throws {
        let form = stream("/Type /XObject /Subtype /Form /BBox [0 0 10 10] /StructParents 1", bytes("/P /PropertiesFromCaller BDC EMC"))
        let data = fixture(root: "/ParentTree << /Nums [1 [9 0 R]] >>",
                           node: "/K << /Type /MCR /Pg 3 0 R /Stm 7 0 R /MCID 0 >>", extras: [7: form])
        XCTAssertEqual(try check(data).status, .notVerified)
    }
    func testStandardLayoutNamesNumbersAndRectanglesAreTypedInEveryProfile() throws {
        let good = "/A << /O /Layout /Placement /Block /WritingMode /RlTb /TextAlign /Justify /BBox [10 20 0 0] /Width /Auto /Height 10 /LineHeight /Normal /BaselineShift -2 >>"
        for profile in PDFArchiveProfile.allCases {
            XCTAssertEqual(try check(fixture(node: good), profile: profile).status, .passed)
            for attribute in ["/Placement /Unknown", "/WritingMode 1", "/TextAlign /Left", "/BBox [0 0 1]", "/Width /Automatic", "/SpaceBefore (1)"] {
                XCTAssertEqual(try check(fixture(node: "/A << /O /Layout \(attribute) >>"), profile: profile).status, .failed, attribute)
            }
        }
    }
    func testPDF2WritingModeExpansionIsNotRetroactivelyAcceptedInPDF17() throws {
        for mode in ["TbLr", "LrBt", "RlBt", "BtRl", "BtLr"] {
            let data = fixture(node: "/A << /O /Layout /WritingMode /\(mode) >>")
            XCTAssertEqual(try check(data, profile: .pdfa4).status, .passed)
            XCTAssertEqual(try check(data, profile: .pdfa2a).status, .failed)
        }
    }
    func testRGBColorsAndNullableBorderEdgesHaveTheirDistinctArrayShapes() throws {
        let good = "/A << /O /Layout /Color [0 .5 1] /BackgroundColor [1 1 1] /BorderColor [[1 0 0] null [0 1 0] [0 0 1]] /BorderStyle [/None null /Dashed /Solid] /BorderThickness [0 null 1 2] >>"
        for profile in [PDFArchiveProfile.pdfa2a, .pdfa3u, .pdfa4e] {
            XCTAssertEqual(try check(fixture(node: good), profile: profile).status, .passed)
            for attribute in ["/Color [0 1]", "/Color [0 1 1.1]", "/BackgroundColor [null 0 0]",
                "/BorderColor [[1 0] null null null]", "/BorderStyle [/Solid /Solid]", "/BorderStyle /Unknown",
                "/BorderThickness -1", "/BorderThickness [1 2 3]"] {
                XCTAssertEqual(try check(fixture(node: "/A << /O /Layout \(attribute) >>"), profile: profile).status, .failed, attribute)
            }
        }
    }
    func testSignedPaddingAndColumnArraysDoNotInventPositiveOrExactCountRules() throws {
        let good = "/A << /O /Layout /Padding [-1 2 -3 4] /TPadding -2 /ColumnCount 3 /ColumnWidths [10] /ColumnGap [2 3 4 5 6] >>"
        XCTAssertEqual(try check(fixture(node: good)).status, .passed)
        for attribute in ["/Padding [1 null 2 3]", "/TPadding [1 2 3]", "/ColumnCount 2.5", "/ColumnWidths [1 /Auto]", "/ColumnGap [1 null]"] {
            XCTAssertEqual(try check(fixture(node: "/A << /O /Layout \(attribute) >>")).status, .failed)
        }
    }
    func testGlyphOrientationAndDecorationThicknessFollowTheirNumericalGrammar() throws {
        for angle in ["-180", "-90", "0", "90", "180", "270", "360"] {
            XCTAssertEqual(try check(fixture(node: "/A << /O /Layout /GlyphOrientationVertical \(angle) /TextDecorationThickness 0 >>")).status, .passed)
        }
        for angle in ["45", "450", "-270"] {
            XCTAssertEqual(try check(fixture(node: "/A << /O /Layout /GlyphOrientationVertical \(angle) >>")).status, .failed)
        }
        XCTAssertEqual(try check(fixture(node: "/A << /O /Layout /GlyphOrientationVertical 90.0 >>")).status, .passed)
        XCTAssertEqual(try check(fixture(node: "/A << /O /Layout /GlyphOrientationVertical 90.0 >>"), profile: .pdfa4).status, .failed)
        XCTAssertEqual(try check(fixture(node: "/A << /O /Layout /TextDecorationThickness -0.1 >>")).status, .failed)
    }
    func testFutureListNumberingNamesUseTheStandardFallbackInsteadOfAnInventedBan() throws {
        for profile in PDFArchiveProfile.allCases {
            XCTAssertEqual(try check(fixture(node: "/S /L /A << /O /List /ListNumbering /FutureUnicodeNumbering >>"), profile: profile).status, .passed)
            XCTAssertEqual(try check(fixture(node: "/S /L /A << /O /List /ListNumbering (Decimal) >>"), profile: profile).status, .failed)
        }
        XCTAssertEqual(try check(fixture(node: "/S /L /A << /O /List /ContinuedList true /ContinuedFrom (previous) >>"), profile: .pdfa4).status, .passed)
        XCTAssertEqual(try check(fixture(node: "/S /L /A << /O /List /ContinuedList /True >>"), profile: .pdfa4).status, .failed)
    }
    func testTableAttributeTypesAndPDFVersionContextAreNotInterchangeable() throws {
        XCTAssertEqual(try check(fixture(node: "/S /TH /A << /O /Table /Scope /Both /RowSpan 2 /ColSpan 1 >>")).status, .passed)
        for attributes in ["/Scope /Cell", "/RowSpan 1.5", "/ColSpan (2)", "/Headers [1]", "/Summary 1"] {
            XCTAssertEqual(try check(fixture(node: "/S /TH /A << /O /Table \(attributes) >>")).status, .failed)
        }
        let unrelated = fixture(node: "/S /P /A << /O /Table /RowSpan 2 /Scope /Row >>")
        XCTAssertEqual(try check(unrelated, profile: .pdfa2a).status, .failed)
        XCTAssertEqual(try check(unrelated, profile: .pdfa4).status, .passed)
    }
    func testHeadersResolveByteIDsAndTransitiveRoleMapsWithoutGuessingHeaderMeaning() throws {
        let root = "/K [9 0 R 10 0 R] /IDTree << /Names [<00FF> 10 0 R] >> /RoleMap << /Head /Intermediate /Intermediate /TH >>"
        let header = bytes("<< /S /Head /P 8 0 R /ID <00FF> >>")
        XCTAssertEqual(try check(fixture(root: root, node: "/S /TD /A << /O /Table /Headers [<00FF>] >>", extras: [10: header])).status, .passed)
        for headers in ["[(missing)]", "[<00FE>]"] {
            XCTAssertEqual(try check(fixture(root: root, node: "/S /TD /A << /O /Table /Headers \(headers) >>", extras: [10: header])).status, .failed)
        }
        let wrong = bytes("<< /S /TD /P 8 0 R /ID <00FF> >>")
        XCTAssertEqual(try check(fixture(root: root, node: "/S /TD /A << /O /Table /Headers [<00FF>] >>", extras: [10: wrong])).status, .failed)
    }
    func testClassAndDirectAttributePrecedenceIsAppliedBeforeHeaderRelationships() throws {
        let root = "/K [9 0 R 10 0 R] /IDTree << /Names [(h) 10 0 R] >> /ClassMap << /Old << /O /Table /Headers [(missing)] >> /Current << /O /Table /Headers [(h)] >> >>"
        let header = bytes("<< /S /TH /P 8 0 R /ID (h) >>")
        for node in ["/S /TD /C /Old /A << /O /Table /Headers [(h)] >>",
            "/S /TD /C [/Old /Current]",
            "/S /TD /A [<< /O /Table /Headers [(missing)] >> << /O /Table /Headers [(h)] >>]"] {
            XCTAssertEqual(try check(fixture(root: root, node: node, extras: [10: header])).status, .passed)
        }
        XCTAssertEqual(try check(fixture(root: root, node: "/S /TD /C /Old /A << /O /Table /Headers null >>", extras: [10: header])).status, .failed)
    }
    func testOutdatedAttributeRevisionsRemainUnknownRatherThanInvalidHeaderProof() throws {
        let old = fixture(node: "/S /TD /R 2 /A [<< /O /Table /Headers [(old-id)] >> 1]")
        XCTAssertEqual(try check(old).status, .notVerified)
        let current = fixture(node: "/S /TD /R 2 /A [<< /O /Table /Headers [(old-id)] >> 2]")
        XCTAssertEqual(try check(current).status, .failed)
    }
    func testUnresolvedRoleCyclesAndCustomNamespacesDoNotBecomeFalseHeaderTypeFailures() throws {
        let header = bytes("<< /S /Head /P 8 0 R /ID (h) >>")
        let cycle = fixture(root: "/K [9 0 R 10 0 R] /IDTree << /Names [(h) 10 0 R] >> /RoleMap << /Head /Other /Other /Head >>",
            node: "/S /TD /A << /O /Table /Headers [(h)] >>", extras: [10: header])
        XCTAssertEqual(try check(cycle).status, .notVerified)
        let ns = bytes("<< /Type /Namespace /NS (urn:example:custom-table) >>")
        let custom = fixture(root: "/Namespaces [11 0 R]", node: "/S /TD /NS 11 0 R /A << /O /Table /Headers [(h)] >>", extras: [11: ns])
        XCTAssertEqual(try check(custom, profile: .pdfa4).status, .notVerified)
    }
    func testUserPropertiesHaveRequiredTypedFieldsAndASeparateMarkInfoFlag() throws {
        let good = "/A << /O /UserProperties /P [<< /N (part) /V << /Arbitrary [1 /Name true] >> /F (formatted) /H false >>] >>"
        XCTAssertEqual(try check(fixture(node: good, catalog: "/MarkInfo << /UserProperties true >>")).status, .passed)
        XCTAssertEqual(try check(fixture(node: good)).status, .failed)
        for attributes in ["/P [<< /V 1 >>]", "/P [<< /N (n) >>]", "/P [<< /N (n) /V 1 /F 1 >>]",
            "/P [<< /N (n) /V 1 /H /True >>]", "/P [null]", ""] {
            XCTAssertEqual(try check(fixture(node: "/A << /O /UserProperties \(attributes) >>", catalog: "/MarkInfo << /UserProperties true >>")).status, .failed)
        }
        XCTAssertEqual(try check(fixture(node: "/A << /O /UserProperties /P [] >>")).status, .passed)
        XCTAssertEqual(try check(fixture(node: "/A << /O /UserProperties /P [<< /N (n) /V null >>] >>",
            catalog: "/MarkInfo << /UserProperties true >>")).status, .notVerified)
    }
    func testPrintFieldNamesAreTypedWithoutInventingPDF2RoleRestrictions() throws {
        XCTAssertEqual(try check(fixture(node: "/S /Form /A << /O /PrintField /Role /cb /checked /neutral /Desc (box) >>")).status, .passed)
        XCTAssertEqual(try check(fixture(node: "/S /Form /A << /O /PrintField /Role /lb /Checked /on >>"), profile: .pdfa4).status, .passed)
        XCTAssertEqual(try check(fixture(node: "/S /Form /A << /O /PrintField /Checked true >>"), profile: .pdfa4).status, .failed)
        XCTAssertEqual(try check(fixture(node: "/A << /O /PrintField /Role /lb >>")).status, .failed)
        XCTAssertEqual(try check(fixture(node: "/A << /O /PrintField /checked true >>")).status, .failed)
    }
    func testAttributeAliasAndNullSemanticsPreserveKnownFailuresAlongsideCycles() throws {
        let aliases = [11: bytes("12 0 R"), 12: bytes("[0 .5 1]"), 13: bytes("14 0 R"), 14: bytes("13 0 R")]
        XCTAssertEqual(try check(fixture(node: "/A << /O /Layout /Color 11 0 R /Padding null >>", extras: aliases)).status, .passed)
        XCTAssertEqual(try check(fixture(node: "/A << /O /Layout /Color 13 0 R >>", extras: aliases)).status, .notVerified)
        XCTAssertEqual(try check(fixture(node: "/A << /O /Layout /Color [2 0 0] /Padding 13 0 R >>", extras: aliases)).status, .failed)
    }
    func testCustomAndLaterVersionAttributeSchemasStayExplicitlyUnproved() throws {
        XCTAssertEqual(try check(fixture(node: "/A << /O /MyExport /Color (custom-representation) >>")).status, .notVerified)
        XCTAssertEqual(try check(fixture(node: "/A << /O /Layout /Color [0 0 0] >>"), profile: .pdfa1a).status, .notVerified)
        XCTAssertEqual(try check(fixture(node: "/A << /O /Layout /PrivateExtension 1 >>")).status, .notVerified)
    }
    func testAttributeNumericalTypesAndRangesDoNotDependOnDoubleRoundingOrOverflow() throws {
        let large = String(repeating: "9", count: 400)
        XCTAssertEqual(try check(fixture(node: "/A << /O /Layout /Width \(large) /ColumnCount \(large) >>")).status, .passed)
        XCTAssertEqual(try check(fixture(node: "/A << /O /Layout /BorderThickness -0.0000 >>")).status, .passed)
        for attribute in ["/Color [1.0000000000000000000000000000000001 0 0]",
            "/Color [-0.0000000000000000000000000000000001 0 0]",
            "/BorderThickness -0.0000000000000000000000000000000001",
            "/GlyphOrientationVertical 90.0000000000000000000000000000000001"] {
            XCTAssertEqual(try check(fixture(node: "/A << /O /Layout \(attribute) >>")).status, .failed)
        }
        XCTAssertEqual(try check(fixture(node: "/A << /O /Layout /TextPosition /Sup >>"), profile: .pdfa4).status, .passed)
        XCTAssertEqual(try check(fixture(node: "/A << /O /Layout /TextPosition /Superscript >>"), profile: .pdfa4).status, .failed)
    }

    private func check(_ data: Data, profile: PDFArchiveProfile = .pdfa2a) throws -> PDFArchiveRuleResult {
        try XCTUnwrap(PDFArchiveLogicalStructureChecks(reader: PDFStructureDocument(data: data), profile: profile).modelCheck)
    }
    private func marked(_ id: Int) -> Data { bytes("/P << /MCID \(id) >> BDC EMC\n") }
    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private func stream(_ attributes: String, _ data: Data) -> Data { bytes("<< \(attributes) /Length \(data.count) >>\nstream\n") + data + bytes("\nendstream") }
    private func fixture(root: String = "", node: String = "", page: String = "", resources: String = "", content: Data = Data(), catalog: String = "",
                         extras: [Int: Data] = [:], version: String = "1.7") -> Data {
        func merged(_ defaults: String, _ additions: String) -> Data {
            var a = PDFSyntaxLexer(bytes("<< \(defaults) >>")), b = PDFSyntaxLexer(bytes("<< \(additions) >>"))
            var values = try! a.value().dictionary!
            values.merge(try! b.value().dictionary!) { _, new in new }
            return PDFSyntaxValue.dictionary(values).encoded
        }
        var objects: [Int: Data] = [
            1: merged("/Type /Catalog /Pages 2 0 R /StructTreeRoot 8 0 R", catalog),
            2: bytes("<< /Type /Pages /Count 1 /Kids [3 0 R] >>"),
            3: merged("/Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << \(resources) >> /Contents 4 0 R", page),
            4: stream("", content),
            8: merged("/Type /StructTreeRoot /K [9 0 R]", root),
            9: merged("/Type /StructElem /S /P /P 8 0 R", node)]
        objects.merge(extras) { _, value in value }
        var data = bytes("%PDF-\(version)\n%") + Data([0xe2, 0xe3, 0xcf, 0xd3, 10]), offsets: [Int: Int] = [:]
        for id in objects.keys.sorted() { offsets[id] = data.count; data += bytes("\(id) 0 obj\n") + objects[id]! + bytes("\nendobj\n") }
        let xref = data.count, size = (objects.keys.max() ?? 0) + 1
        data += bytes("xref\n0 \(size)\n0000000000 65535 f \n")
        for id in 1..<size { data += bytes(String(format: "%010lld 00000 %@ \n", Int64(offsets[id] ?? 0), offsets[id] == nil ? "f" : "n")) }
        return data + bytes("trailer\n<< /Size \(size) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n")
    }
}
