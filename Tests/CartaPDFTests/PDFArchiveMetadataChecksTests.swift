import Foundation
import PDFKit
import XCTest
@testable import CartaPDF

final class PDFArchiveMetadataChecksTests: XCTestCase {
    private let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    private var catalogueDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CartaPDF/Resources/PDFAProfiles")
    }
    private func rule(_ object: String, _ expression: String, profile: PDFArchiveProfile = .pdfa2u) throws -> PDFArchiveCatalogueRule {
        try XCTUnwrap(PDFArchiveValidator.catalogue(profile: profile, directory: catalogueDirectory).first { $0.objectType == object && $0.expression == expression })
    }
    private func evaluate(_ object: String, _ expression: String, _ data: Data, profile: PDFArchiveProfile = .pdfa2u) throws -> PDFArchiveRuleEvaluation {
        let checks = PDFArchiveMetadataChecks(reader: try PDFStructureDocument(data: data), profile: profile)
        return try XCTUnwrap(checks.evaluate(rule(object, expression, profile: profile)))
    }
    private func packet(_ properties: String = "", descriptions: String? = nil) -> Data {
        let description = descriptions ?? "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" xmlns:pdf=\"http://ns.adobe.com/pdf/1.3/\" xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\" xmlns:my=\"urn:example:custom:\">\(properties)</rdf:Description>"
        return Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"\(rdf)\">\(description)</rdf:RDF></x:xmpmeta>".utf8)
    }
    private func fixture(_ xmp: Data, secondary: [Data] = [], info: [String: PDFSyntaxValue]? = nil, mainFilter: String = "", secondaryFilter: String = "") -> Data {
        func stream(_ bytes: Data, filter: String) -> Data {
            let encoded = filter.isEmpty ? bytes : Data((bytes.map { String(format: "%02X", $0) }.joined() + ">").utf8)
            return Data("<< /Type /Metadata /Subtype /XML \(filter) /Length \(encoded.count) >>\nstream\n".utf8) + encoded + Data("\nendstream".utf8)
        }
        var objects: [Int: Data] = [1: Data("<< /Type /Catalog /Pages 2 0 R /Metadata 4 0 R >>".utf8),
            2: Data("<< /Type /Pages /Count 1 /Kids [3 0 R] >>".utf8),
            3: Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> >>".utf8),
            4: stream(xmp, filter: mainFilter)]
        if let info { objects[5] = PDFSyntaxValue.dictionary(info).encoded }
        for (index, bytes) in secondary.enumerated() { objects[6 + index] = stream(bytes, filter: secondaryFilter) }
        let count = (objects.keys.max() ?? 4) + 1
        var data = Data("%PDF-1.7\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8), offsets = [Int: Int]()
        for id in objects.keys.sorted() { offsets[id] = data.count; data += Data("\(id) 0 obj\n".utf8) + objects[id]! + Data("\nendobj\n".utf8) }
        let xref = data.count
        data += Data("xref\n0 \(count)\n0000000000 65535 f \n".utf8)
        for id in 1..<count { data += Data((offsets[id].map { String(format: "%010d 00000 n \n", $0) } ?? "0000000000 00000 f \n").utf8) }
        data += Data("trailer\n<< /Size \(count) /Root 1 0 R \(info == nil ? "" : "/Info 5 0 R") >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        return data
    }

    func testSerializationAcceptsCanonicalAbbreviatedStructuredAndQualifiedRDF() throws {
        let samples = [
            "<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">Titolo</rdf:li></rdf:Alt></dc:title>",
            "<my:person rdf:parseType=\"Resource\"><my:name>Alice</my:name></my:person>",
            "<my:person><rdf:Description my:name=\"Alice\"/></my:person>",
            "<my:term rdf:parseType=\"Resource\"><rdf:value>testo</rdf:value><my:role>autore</my:role></my:term>",
            "<my:term rdf:value=\"testo\" my:role=\"autore\"/>",
            "<my:term><rdf:Description my:role=\"autore\"><rdf:value>testo</rdf:value></rdf:Description></my:term>"
        ]
        for sample in samples {
            let result = try evaluate("XMPPackage", "isSerializationValid", fixture(packet(sample)))
            XCTAssertEqual(result.status, .passed, sample + ": " + result.detail)
        }
        let attribute = "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" dc:format=\"application/pdf\"/>"
        XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", fixture(packet(descriptions: attribute))).status, .passed)
    }

    func testWellFormedXMLDoesNotHideInvalidXMPSerialization() throws {
        let invalid = [
            "<dc:title>mixed<rdf:Alt/></dc:title>",
            "<dc:title><rdf:Alt><dc:wrong>test</dc:wrong></rdf:Alt></dc:title>",
            "<my:prop rdf:parseType=\"Literal\">text</my:prop>",
            "<my:prop rdf:parseType=\"Collection\"/>",
            "<dc:format>application/pdf</dc:format><dc:format>application/pdf</dc:format>",
            "<my:prop rdf:resource=\"urn:test\">text</my:prop>",
            "<my:prop rdf:parseType=\"Resource\"><my:role>r</my:role><rdf:value>value</rdf:value></my:prop>"
        ]
        for sample in invalid { XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", fixture(packet(sample))).status, .failed, sample) }
        let different = "<rdf:Description rdf:about=\"urn:a\"/><rdf:Description rdf:about=\"urn:b\"/>"
        XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", fixture(packet(descriptions: different))).status, .failed)
    }

    func testExternalDTDAndLegacyTypedLiteralStayNotVerified() throws {
        let dtd = Data("<!DOCTYPE x [<!ENTITY remote SYSTEM 'https://example.invalid/must-not-fetch'>]>".utf8) + packet()
        XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", fixture(dtd)).status, .notVerified)
        let typed = packet("<my:number rdf:datatype=\"http://www.w3.org/2001/XMLSchema#integer\">1</my:number>")
        XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", fixture(typed)).status, .notVerified)
    }

    func testPDFA4TypedLiteralsAreRejectedByItsNormativeXMPSerialization() throws {
        let typed = fixture(packet("<my:number rdf:datatype=\"http://www.w3.org/2001/XMLSchema#integer\">1</my:number>"))
        for profile in [PDFArchiveProfile.pdfa4, .pdfa4e, .pdfa4f] {
            XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", typed, profile: profile).status, .failed)
        }
        // The later Annex C prohibition is not retroactively applied to 2004/2005.
        for profile in [PDFArchiveProfile.pdfa1b, .pdfa2b, .pdfa3b] {
            XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", typed, profile: profile).status, .notVerified)
        }
    }

    func testLegacyNodeIDAttributesUseTheNormativeAdobeEdition() throws {
        let description = "<rdf:Description rdf:about=\"\" rdf:nodeID=\"legacy\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:coverage rdf:nodeID=\"property\">Text</dc:coverage></rdf:Description>"
        let data = fixture(packet(descriptions: description))
        XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", data, profile: .pdfa1b).status, .notVerified)
        for profile in [PDFArchiveProfile.pdfa2b, .pdfa3b] {
            XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", data, profile: profile).status, .passed)
        }
        for profile in [PDFArchiveProfile.pdfa4, .pdfa4e, .pdfa4f] {
            XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", data, profile: profile).status, .failed)
        }
    }

    func testDTDWordsInsideCommentsCDATAAndProcessingInstructionsAreLiteral() throws {
        for properties in [
            "<!-- <!DOCTYPE fake [<!ENTITY fake 'ignored'>]> -->",
            "<dc:coverage><![CDATA[<!DOCTYPE fake> <!ENTITY fake 'literal'>]]></dc:coverage>",
            "<?example text=\"<!DOCTYPE fake>\"?>"
        ] {
            XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", fixture(packet(properties))).status, .passed, properties)
        }
    }

    func testExplicitXMLBaseIsResolvedLocallyAtEveryRDFLevel() throws {
        let source = String(decoding: packet("<my:uri rdf:resource=\"document.pdf\"/>"), as: UTF8.self)
        let samples = [
            source.replacingOccurrences(of: "<x:xmpmeta ", with: "<x:xmpmeta xml:base=\"https://example.com/\" "),
            source.replacingOccurrences(of: "<rdf:RDF ", with: "<rdf:RDF xml:base=\"https://example.com/\" "),
            source.replacingOccurrences(of: "<rdf:Description ", with: "<rdf:Description xml:base=\"https://example.com/\" "),
            source.replacingOccurrences(of: "<my:uri ", with: "<my:uri xml:base=\"https://example.com/\" ")
        ]
        for sample in samples {
            XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", fixture(Data(sample.utf8))).status, .passed, sample)
        }
    }

    func testXMLBaseWithoutExplicitAbsoluteAncestorStaysUnknown() throws {
        for base in ["../metadata/", "", "//example.com/path", "bad base", "https://example.com/%zz"] {
            let source = String(decoding: packet(), as: UTF8.self).replacingOccurrences(of: "<x:xmpmeta ", with: "<x:xmpmeta xml:base=\"\(base)\" ")
            XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", fixture(Data(source.utf8))).status, .notVerified, base)
        }
    }

    func testXMLBaseUnicodeAndExcludedCharactersUseUTF8EscapingWithoutNormalization() throws {
        for (base, expected) in [
            ("https://example.invalid/rosé name/", "https://example.invalid/ros%C3%A9%20name/document.pdf"),
            ("https://example.invalid/Cafe\u{0301}/", "https://example.invalid/Cafe%CC%81/document.pdf"),
            ("https://example.invalid/%2e%2e/", "https://example.invalid/%2e%2e/document.pdf")
        ] {
            let descriptions = "<rdf:Description rdf:about=\"document.pdf\" xml:base=\"\(base)\"/><rdf:Description rdf:about=\"\(expected)\"/>"
            XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", fixture(packet(descriptions: descriptions))).status, .passed, base)
        }
    }

    func testRelativeURIPropertyValuesUseOnlyExplicitInheritedXMLBase() throws {
        func document(_ value: String, base: String?) -> Data {
            let attribute = base.map { " xml:base=\"\($0)\"" } ?? ""
            return fixture(packet(descriptions: "<rdf:Description rdf:about=\"\"\(attribute) xmlns:xmpMM=\"http://ns.adobe.com/xap/1.0/mm/\"><xmpMM:DocumentID>\(value)</xmpMM:DocumentID></rdf:Description>"))
        }
        XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", document("../document.pdf", base: "https://example.invalid/a/b/metadata.xmp")).status, .passed)
        XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", document("../document.pdf", base: nil)).status, .notVerified)
        // Merely transforming a file URI must not read the named location.
        XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", document("../must-not-read.pdf", base: "file:///private/tmp/nonexistent-metadata/packet.xmp")).status, .passed)
        let nested = "<rdf:Description rdf:about=\"\" xml:base=\"https://example.invalid/a/b/\" xmlns:xmpMM=\"http://ns.adobe.com/xap/1.0/mm/\"><xmpMM:DocumentID xml:base=\"../c/\">../document.pdf</xmpMM:DocumentID></rdf:Description>"
        XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", fixture(packet(descriptions: nested))).status, .passed)
        let array = "<rdf:Description rdf:about=\"\" xml:base=\"https://example.invalid/a/\" xmlns:xmpMM=\"http://ns.adobe.com/xap/1.0/mm/\" xmlns:stRef=\"http://ns.adobe.com/xap/1.0/sType/ResourceRef#\"><xmpMM:DerivedFrom rdf:parseType=\"Resource\"><stRef:documentID rdf:resource=\"../document.pdf\"/></xmpMM:DerivedFrom></rdf:Description>"
        XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", fixture(packet(descriptions: array))).status, .passed)
    }

    func testRFC3986NormalAndAbnormalResolutionExamplesPreserveQueriesAndFragments() throws {
        // Published RFC3986 §5.4 examples, independent of the resolver's code.
        let cases = [
            ("g:h", "g:h"), ("g", "http://a/b/c/g"), ("./g", "http://a/b/c/g"),
            ("g/", "http://a/b/c/g/"), ("/g", "http://a/g"), ("//g", "http://g"),
            ("?y", "http://a/b/c/d;p?y"), ("g?y", "http://a/b/c/g?y"),
            ("#s", "http://a/b/c/d;p?q#s"), ("g#s", "http://a/b/c/g#s"),
            ("g?y#s", "http://a/b/c/g?y#s"), (";x", "http://a/b/c/;x"),
            ("g;x", "http://a/b/c/g;x"), ("g;x?y#s", "http://a/b/c/g;x?y#s"),
            ("", "http://a/b/c/d;p?q"), (".", "http://a/b/c/"), ("./", "http://a/b/c/"),
            ("..", "http://a/b/"), ("../", "http://a/b/"), ("../g", "http://a/b/g"),
            ("../..", "http://a/"), ("../../", "http://a/"), ("../../g", "http://a/g"),
            ("../../../g", "http://a/g"), ("../../../../g", "http://a/g"),
            ("/./g", "http://a/g"), ("/../g", "http://a/g"), ("g.", "http://a/b/c/g."),
            (".g", "http://a/b/c/.g"), ("g..", "http://a/b/c/g.."), ("..g", "http://a/b/c/..g"),
            ("./../g", "http://a/b/g"), ("./g/.", "http://a/b/c/g/"),
            ("g/./h", "http://a/b/c/g/h"), ("g/../h", "http://a/b/c/h"),
            ("g;x=1/./y", "http://a/b/c/g;x=1/y"), ("g;x=1/../y", "http://a/b/c/y"),
            ("g?y/./x", "http://a/b/c/g?y/./x"), ("g?y/../x", "http://a/b/c/g?y/../x"),
            ("g#s/./x", "http://a/b/c/g#s/./x"), ("g#s/../x", "http://a/b/c/g#s/../x"),
            ("http:g", "http:g")
        ]
        for (relative, absolute) in cases {
            let descriptions = "<rdf:Description rdf:about=\"\(relative)\" xml:base=\"http://a/b/c/d;p?q\"/><rdf:Description rdf:about=\"\(absolute)\"/>"
            XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", fixture(packet(descriptions: descriptions))).status, .passed, relative + " → " + absolute)
            let different = descriptions.replacingOccurrences(of: "<rdf:Description rdf:about=\"\(absolute)\"/>", with: "<rdf:Description rdf:about=\"urn:example:distinct\"/>")
            XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", fixture(packet(descriptions: different))).status, .failed)
        }
        let escaped = "<rdf:Description rdf:about=\"%2e%2e/g\" xml:base=\"https://example.invalid/a/b/\"/><rdf:Description rdf:about=\"https://example.invalid/a/b/%2e%2e/g\"/>"
        XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", fixture(packet(descriptions: escaped))).status, .passed)
        let inheritedEmpty = "<rdf:Description rdf:about=\"\" xml:base=\"https://example.invalid/a/b?q#old\" xmlns:my=\"urn:example:custom:\"><my:uri rdf:resource=\"#new\"/></rdf:Description>"
        XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", fixture(packet(descriptions: inheritedEmpty))).status, .passed)
    }

    func testMalformedLegacyTypedLiteralProductionsFailBeforeUnknownTypeSemantics() throws {
        let values = [
            "<my:typed rdf:datatype=\"urn:type\" rdf:resource=\"urn:resource\"/>",
            "<my:typed rdf:datatype=\"urn:type\" rdf:parseType=\"Resource\"/>",
            "<my:typed rdf:datatype=\"urn:type\"><my:child>value</my:child></my:typed>",
            "<my:typed rdf:datatype=\"malformed URI\">value</my:typed>"
        ]
        for profile in [PDFArchiveProfile.pdfa1b, .pdfa2b, .pdfa3b] {
            for value in values { XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", fixture(packet(value)), profile: profile).status, .failed, value) }
        }
    }

    func testPlainInternalEntitiesAreExpandedLocallyWithoutLosingTextOrAttributes() throws {
        let declaration = "<!DOCTYPE x:xmpmeta [<!ENTITY title 'Carta locale'><!ENTITY mime 'application/pdf'>]>"
        let description = "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" dc:format=\"&mime;\"><dc:coverage>&title;</dc:coverage></rdf:Description>"
        let data = Data(declaration.utf8) + packet(descriptions: description)
        XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", fixture(data)).status, .passed)
        XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", fixture(data)).status, .passed)
        let title = Data(declaration.utf8) + packet("<pdf:Keywords>&title;</pdf:Keywords>")
        XCTAssertEqual(try evaluate("CosInfo", "Keywords == null || Keywords == XMPKeywords", fixture(title, info: ["Keywords": .string("Carta locale")]), profile: .pdfa1b).status, .passed)
        // Expansion must preserve character data; Foundation's parser can omit
        // an internal entity's literal prefix when resolution is disabled.
        XCTAssertEqual(try evaluate("CosInfo", "Keywords == null || Keywords == XMPKeywords", fixture(title, info: ["Keywords": .string("")]), profile: .pdfa1b).status, .failed)
        let utf16 = Data([0xFF, 0xFE]) + String(decoding: data, as: UTF8.self).data(using: .utf16LittleEndian)!
        XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", fixture(utf16)).status, .passed)
    }

    func testInternalEntitySubsetDoesNotExecuteMarkupNestedOrExternalDeclarations() throws {
        let unsupported = [
            "<!DOCTYPE x:xmpmeta SYSTEM 'file:///private/tmp/must-not-read'>",
            "<!DOCTYPE x:xmpmeta [<!ENTITY remote SYSTEM 'https://example.invalid/must-not-fetch'>]>",
            "<!DOCTYPE x:xmpmeta [<!ENTITY % parameter 'value'>]>",
            "<!DOCTYPE x:xmpmeta [<!ENTITY first 'value'><!ENTITY second '&first;&first;'>]>",
            "<!DOCTYPE x:xmpmeta [<!ENTITY markup '<rdf:RDF/>'>]>",
            "<!DOCTYPE x:xmpmeta [<!ATTLIST rdf:Description rdf:about CDATA 'urn:injected'>]>"
        ]
        for declaration in unsupported {
            XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", fixture(Data(declaration.utf8) + packet())).status, .notVerified, declaration)
        }
        let empty = Data("<!DOCTYPE x:xmpmeta>".utf8) + packet()
        XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", fixture(empty)).status, .passed)
        let duplicate = Data("<!DOCTYPE x:xmpmeta [<!ENTITY v 'first'><!ENTITY v 'second'>]>".utf8) + packet("<pdf:Keywords>&v;</pdf:Keywords>")
        XCTAssertEqual(try evaluate("CosInfo", "Keywords == null || Keywords == XMPKeywords", fixture(duplicate, info: ["Keywords": .string("first")]), profile: .pdfa1b).status, .passed)
    }

    func testMIMETokenAndQuotedParametersFollowRFC2045Grammar() throws {
        func mime(_ text: String) throws -> PDFArchiveRuleStatus {
            try evaluate("XMPProperty", "isValueTypeCorrect == true", fixture(packet("<dc:format><![CDATA[\(text)]]></dc:format>"))).status
        }
        for value in ["application/pdf", "application/vnd.example+pdf;version=1.7", "text/plain; charset=\"UTF-8\"", #"application/pdf;name="Carta \"locale\".pdf""#, "application/x'example%type; token*=utf-8''Carta.pdf", " application / pdf ; version = 1.7 "] {
            XCTAssertEqual(try mime(value), .passed, value)
        }
        for value in ["application", "/pdf", "application/", "application/pdf;", "application/pdf;name", "application/pdf;name=", "application/pdf;name=\"unterminated", "application/pdf;name=a b", "application/pdf;name=résumé", "application/pdf,application/xml"] {
            XCTAssertEqual(try mime(value), .failed, value)
        }
        XCTAssertEqual(try mime("application/pdf (comment)"), .notVerified)
        XCTAssertEqual(try mime("application(comment)/pdf"), .notVerified)
        XCTAssertEqual(try mime("application/pdf; name(comment)=value"), .notVerified)
        XCTAssertEqual(try mime("application/pdf;\r\n name=value"), .notVerified)
    }

    func testSecondaryPacketsAndDeclaredByteEncodingAreChecked() throws {
        let utf16 = Data([0xFF, 0xFE]) + String(decoding: packet(), as: UTF8.self).data(using: .utf16LittleEndian)!
        let data = fixture(packet(), secondary: [utf16])
        XCTAssertEqual(try evaluate("XMPPackage", "actualEncoding == \"UTF-8\"", data).status, .failed)
        let latinDeclaration = Data("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>".utf8) + packet()
        XCTAssertEqual(try evaluate("XMPPackage", "actualEncoding == \"UTF-8\"", fixture(latinDeclaration)).status, .failed)
        let forbidden = Data("<?xpacket begin=\"\" bytes=\"1000\" encoding=\"UTF-8\"?>".utf8) + packet()
        for expression in ["bytes == null", "encoding == null"] {
            XCTAssertEqual(try evaluate("XMPPackage", expression, fixture(packet(), secondary: [forbidden])).status, .failed)
        }
    }

    func testCatalogMetadataFilterRestrictionDoesNotForbidSecondaryFiltering() throws {
        let expression = "isCatalogMetadata == false || Filter == null"
        XCTAssertEqual(try evaluate("PDMetadata", expression, fixture(packet(), mainFilter: "/Filter /ASCIIHexDecode"), profile: .pdfa1b).status, .failed)
        XCTAssertEqual(try evaluate("PDMetadata", expression, fixture(packet(), secondary: [packet()], secondaryFilter: "/Filter /ASCIIHexDecode"), profile: .pdfa1b).status, .passed)
    }

    func testIdentificationUsesExactNamespaceAndRequiredPrefix() throws {
        let valid = fixture(packet("<pdfaid:part>02</pdfaid:part><pdfaid:conformance>U</pdfaid:conformance>"))
        XCTAssertEqual(try evaluate("PDFAIdentification", "part == 2", valid).status, .passed)
        let spoof = String(decoding: packet("<pdfaid:part>2</pdfaid:part>"), as: UTF8.self).replacingOccurrences(of: "http://www.aiim.org/pdfa/ns/id/", with: "urn:spoof:")
        XCTAssertEqual(try evaluate("MainXMPPackage", "containsPDFAIdentification == true", fixture(Data(spoof.utf8))).status, .failed)
        let alternative = String(decoding: packet("<pdfaid:part>2</pdfaid:part>"), as: UTF8.self).replacingOccurrences(of: "pdfaid", with: "different")
        XCTAssertEqual(try evaluate("PDFAIdentification", "partPrefix == null || partPrefix == \"pdfaid\"", fixture(Data(alternative.utf8))).status, .failed)
    }

    func testPredefinedRegistriesDistinguish2004AndSeptember2005() throws {
        let data = fixture(packet("<xmp:Label>Blue</xmp:Label>"))
        let old = "isPredefinedInXMP2004 == true || isDefinedInCurrentPackage == true"
        let new = "isPredefinedInXMP2005 == true || isDefinedInMainPackage == true || isDefinedInCurrentPackage == true"
        XCTAssertEqual(try evaluate("XMPProperty", old, data, profile: .pdfa1b).status, .failed)
        XCTAssertEqual(try evaluate("XMPProperty", new, data).status, .passed)
        let declaration = "<rdf:Description rdf:about=\"\" xmlns:photoshop=\"http://ns.adobe.com/photoshop/1.0/\"><photoshop:SupplementalCategories>Archive</photoshop:SupplementalCategories></rdf:Description>"
        let scalar = fixture(packet(descriptions: declaration))
        XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", scalar, profile: .pdfa1b).status, .passed)
        XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", scalar).status, .failed)
    }

    func testScalarArrayDateAndLanguageAlternativeTypesAreActuallyValidated() throws {
        let valid = packet("<xmp:CreateDate>2024-02-29T12:00:00</xmp:CreateDate><dc:creator><rdf:Seq><rdf:li>Alice</rdf:li></rdf:Seq></dc:creator><dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">Titolo</rdf:li></rdf:Alt></dc:title>")
        XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", fixture(valid)).status, .passed)
        for invalid in ["<xmp:CreateDate>2024-02-30</xmp:CreateDate>", "<dc:creator><rdf:Bag><rdf:li>Alice</rdf:li></rdf:Bag></dc:creator>", "<dc:title><rdf:Alt><rdf:li>Missing language</rdf:li></rdf:Alt></dc:title>"] {
            XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", fixture(packet(invalid))).status, .failed)
        }
        let boolean = "<rdf:Description rdf:about=\"\" xmlns:rights=\"http://ns.adobe.com/xap/1.0/rights/\"><rights:Marked>True</rights:Marked></rdf:Description>"
        XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", fixture(packet(descriptions: boolean))).status, .passed)
        XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", fixture(packet(descriptions: boolean.replacingOccurrences(of: "True", with: "true")))).status, .failed)
    }

    private func extensionProperties(customType: Bool = false) -> String {
        let type = customType ? "Address" : "Text"
        let typeDefinition = customType ? """
        <pdfaSchema:valueType><rdf:Seq><rdf:li rdf:parseType="Resource">
        <pdfaType:type>Address</pdfaType:type><pdfaType:namespaceURI>urn:example:address:</pdfaType:namespaceURI><pdfaType:prefix>addr</pdfaType:prefix><pdfaType:description>Address structure</pdfaType:description>
        <pdfaType:field><rdf:Seq><rdf:li rdf:parseType="Resource"><pdfaField:name>street</pdfaField:name><pdfaField:valueType>Text</pdfaField:valueType><pdfaField:description>Street</pdfaField:description></rdf:li></rdf:Seq></pdfaType:field>
        </rdf:li></rdf:Seq></pdfaSchema:valueType>
        """ : ""
        return """
        <pdfaExtension:schemas xmlns:pdfaExtension="http://www.aiim.org/pdfa/ns/extension/" xmlns:pdfaSchema="http://www.aiim.org/pdfa/ns/schema#" xmlns:pdfaProperty="http://www.aiim.org/pdfa/ns/property#" xmlns:pdfaType="http://www.aiim.org/pdfa/ns/type#" xmlns:pdfaField="http://www.aiim.org/pdfa/ns/field#">
        <rdf:Bag><rdf:li rdf:parseType="Resource"><pdfaSchema:schema>Local custom schema</pdfaSchema:schema><pdfaSchema:namespaceURI>urn:example:custom:</pdfaSchema:namespaceURI><pdfaSchema:prefix>my</pdfaSchema:prefix>
        <pdfaSchema:property><rdf:Seq><rdf:li rdf:parseType="Resource"><pdfaProperty:name>Code</pdfaProperty:name><pdfaProperty:valueType>\(type)</pdfaProperty:valueType><pdfaProperty:category>external</pdfaProperty:category><pdfaProperty:description>Local property</pdfaProperty:description></rdf:li></rdf:Seq></pdfaSchema:property>
        \(typeDefinition)</rdf:li></rdf:Bag></pdfaExtension:schemas>
        """
    }

    func testExtensionContainerAndEveryDefinitionPredicateUseRealRDFFields() throws {
        let data = fixture(packet(extensionProperties(customType: true)))
        let evaluator = PDFArchiveMetadataChecks(reader: try PDFStructureDocument(data: data), profile: .pdfa2u)
        let rules = try PDFArchiveValidator.catalogue(profile: .pdfa2u, directory: catalogueDirectory).filter { $0.objectType.hasPrefix("Extension") }
        XCTAssertEqual(rules.count, 19)
        for rule in rules {
            let result = try XCTUnwrap(evaluator.evaluate(rule))
            XCTAssertEqual(result.status, .passed, rule.expression + ": " + result.detail)
        }
    }

    func testExtensionNamespaceURIResolvesBeforeMatchingExpandedPropertyNames() throws {
        let source = String(decoding: packet(extensionProperties() + "<my:Code>value</my:Code>"), as: UTF8.self)
            .replacingOccurrences(of: "<rdf:Description ", with: "<rdf:Description xml:base=\"https://example.invalid/\" ")
            .replacingOccurrences(of: "xmlns:my=\"urn:example:custom:\"", with: "xmlns:my=\"https://example.invalid/custom/\"")
            .replacingOccurrences(of: "<pdfaSchema:namespaceURI>urn:example:custom:</pdfaSchema:namespaceURI>", with: "<pdfaSchema:namespaceURI>custom/</pdfaSchema:namespaceURI>")
        let data = fixture(Data(source.utf8))
        XCTAssertEqual(try evaluate("XMPProperty", "isPredefinedInXMP2005 == true || isDefinedInMainPackage == true || isDefinedInCurrentPackage == true", data).status, .passed)
        XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", data).status, .passed)
        let wrongBase = source.replacingOccurrences(of: "xml:base=\"https://example.invalid/\"", with: "xml:base=\"https://different.invalid/\"")
        XCTAssertEqual(try evaluate("XMPProperty", "isPredefinedInXMP2005 == true || isDefinedInMainPackage == true || isDefinedInCurrentPackage == true", fixture(Data(wrongBase.utf8))).status, .failed)
    }

    func testExtensionWrongBagPrefixCategoryUndefinedTypeAndUnknownFieldsFail() throws {
        let base = extensionProperties()
        let badBag = base.replacingOccurrences(of: "<rdf:Bag>", with: "<rdf:Seq>").replacingOccurrences(of: "</rdf:Bag>", with: "</rdf:Seq>")
        XCTAssertEqual(try evaluate("ExtensionSchemasContainer", "isValidBag == true && prefix == \"pdfaExtension\"", fixture(packet(badBag))).status, .failed)
        let badPrefix = base.replacingOccurrences(of: "pdfaProperty", with: "wrongPrefix")
        XCTAssertEqual(try evaluate("ExtensionSchemaProperty", "isNameValidText == true && namePrefix == \"pdfaProperty\"", fixture(packet(badPrefix))).status, .failed)
        let category = base.replacingOccurrences(of: ">external<", with: ">secret<")
        XCTAssertEqual(try evaluate("ExtensionSchemaProperty", "isCategoryValidText == true && (category == \"external\" || category == \"internal\") && categoryPrefix == \"pdfaProperty\"", fixture(packet(category))).status, .failed)
        let unknownType = base.replacingOccurrences(of: ">Text<", with: ">NotDeclared<")
        XCTAssertEqual(try evaluate("ExtensionSchemaProperty", "isValueTypeValidText == true && isValueTypeDefined == true && valueTypePrefix == \"pdfaProperty\"", fixture(packet(unknownType))).status, .failed)
        let extra = base.replacingOccurrences(of: "<pdfaSchema:schema>", with: "<pdfaSchema:undefined>bad</pdfaSchema:undefined><pdfaSchema:schema>")
        XCTAssertEqual(try evaluate("ExtensionSchemaObject", "containsUndefinedFields == false", fixture(packet(extra))).status, .failed)
    }

    func testCustomStructuredValueTypeValidatesDeclaredFieldTypeAndNamespace() throws {
        let property = "<my:Code rdf:parseType=\"Resource\" xmlns:addr=\"urn:example:address:\"><addr:street>Via Roma</addr:street></my:Code>"
        let good = fixture(packet(extensionProperties(customType: true) + property))
        XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", good).status, .passed)
        let bad = property.replacingOccurrences(of: "<addr:street>Via Roma</addr:street>", with: "<addr:street><rdf:Seq><rdf:li>Wrong shape</rdf:li></rdf:Seq></addr:street>")
        XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", fixture(packet(extensionProperties(customType: true) + bad))).status, .failed)
    }

    func testMainPackageExtensionCanDescribeSecondaryPropertyOnlyForAllowedEditions() throws {
        let data = fixture(packet(extensionProperties()), secondary: [packet("<my:Code>second packet</my:Code>")])
        XCTAssertEqual(try evaluate("XMPProperty", "isPredefinedInXMP2005 == true || isDefinedInMainPackage == true || isDefinedInCurrentPackage == true", data).status, .passed)
        XCTAssertEqual(try evaluate("XMPProperty", "isPredefinedInXMP2004 == true || isDefinedInCurrentPackage == true", data, profile: .pdfa1b).status, .failed)
    }

    func testInfoSynchronizesExactUnicodeDefaultLanguageAndSingleCreator() throws {
        let properties = "<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\"> Caffè </rdf:li></rdf:Alt></dc:title><dc:creator><rdf:Seq><rdf:li>Alice</rdf:li></rdf:Seq></dc:creator>"
        let data = fixture(packet(properties), info: ["Title": .string(" Caffè "), "Author": .string("Alice")])
        XCTAssertEqual(try evaluate("CosInfo", "Title == null || Title == XMPTitle", data, profile: .pdfa1b).status, .passed)
        XCTAssertEqual(try evaluate("CosInfo", "Author == null || (Author == XMPCreator && XMPCreatorSize == 1)", data, profile: .pdfa1b).status, .passed)
        let two = properties.replacingOccurrences(of: "<rdf:li>Alice</rdf:li>", with: "<rdf:li>Alice</rdf:li><rdf:li>Bob</rdf:li>")
        XCTAssertEqual(try evaluate("CosInfo", "Author == null || (Author == XMPCreator && XMPCreatorSize == 1)", fixture(packet(two), info: ["Author": .string("Alice")]), profile: .pdfa1b).status, .failed)
        XCTAssertEqual(try evaluate("CosInfo", "Title == null || Title == XMPTitle", fixture(packet(properties), info: ["Title": .string("Caffè")]), profile: .pdfa1b).status, .failed)
    }

    func testInfoDateEquivalenceUsesActualOffsetsAndNeverAssumesLocalTimezone() throws {
        let props = "<xmp:CreateDate>2026-10-17T14:30:00Z</xmp:CreateDate>"
        let equal = fixture(packet(props), info: ["CreationDate": .string("D:20261017163000+02'00'")])
        XCTAssertEqual(try evaluate("CosInfo", "doCreationDatesMatch != false", equal, profile: .pdfa1b).status, .passed)
        let local = fixture(packet(props), info: ["CreationDate": .string("D:20261017143000")])
        XCTAssertEqual(try evaluate("CosInfo", "doCreationDatesMatch != false", local, profile: .pdfa1b).status, .notVerified)
        let different = fixture(packet(props), info: ["CreationDate": .string("D:20261017143001Z")])
        XCTAssertEqual(try evaluate("CosInfo", "doCreationDatesMatch != false", different, profile: .pdfa1b).status, .failed)
    }

    func testDifferentDateGranularitiesNeverInventMissingComponentsButProveContradictions() throws {
        func status(_ xmp: String, _ pdf: String) throws -> PDFArchiveRuleStatus {
            try evaluate("CosInfo", "doCreationDatesMatch != false", fixture(packet("<xmp:CreateDate>\(xmp)</xmp:CreateDate>"), info: ["CreationDate": .string(pdf)]), profile: .pdfa1b).status
        }
        for (xmp, pdf) in [
            ("2026", "D:20260101"), ("2026-10", "D:20261017"),
            ("2026-10-17T14:30Z", "D:20261017143000Z"),
            ("2026-10-17T14:30Z", "D:20261017163000+02'00'")
        ] { XCTAssertEqual(try status(xmp, pdf), .notVerified, xmp + " / " + pdf) }
        for (xmp, pdf) in [
            ("2025", "D:20260101"), ("2026-09", "D:20261017"),
            ("2026-10-17T14:30Z", "D:20261017143100Z"),
            ("2026-10-17T14:30Z", "D:20261017163100+02'00'")
        ] { XCTAssertEqual(try status(xmp, pdf), .failed, xmp + " / " + pdf) }
        XCTAssertEqual(try status("2026-10-17T14:30:00.000Z", "D:20261017163000+02'00'"), .passed)
        XCTAssertEqual(try status("2026-10-17T14:30:00.001Z", "D:20261017163000+02'00'"), .failed)
    }

    func testUnimplementedVocabularyStaysUnknownAndForeignRuleReturnsNil() throws {
        let description = "<rdf:Description rdf:about=\"\" xmlns:exif=\"http://ns.adobe.com/exif/1.0/\"><exif:ExifVersion>0231</exif:ExifVersion></rdf:Description>"
        let data = fixture(packet(descriptions: description))
        XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", data).status, .notVerified)
        let checks = PDFArchiveMetadataChecks(reader: try PDFStructureDocument(data: data), profile: .pdfa4)
        XCTAssertNil(try checks.evaluate(rule("CosInfo", "size == 1 && ModDate != null", profile: .pdfa4)))
    }

    func testEditionBoundExifVersionsFlashpixAndApplicationRatingCheckKnownSemantics() throws {
        func status(_ properties: String, profile: PDFArchiveProfile = .pdfa2b) throws -> PDFArchiveRuleStatus {
            let description = "<rdf:Description rdf:about=\"\" xmlns:exif=\"http://ns.adobe.com/exif/1.0/\" xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\">\(properties)</rdf:Description>"
            return try evaluate("XMPProperty", "isValueTypeCorrect == true", fixture(packet(descriptions: description)), profile: profile).status
        }
        for profile in [PDFArchiveProfile.pdfa1b, .pdfa2b, .pdfa3b] {
            XCTAssertEqual(try status("<exif:ExifVersion>0210</exif:ExifVersion><exif:FlashpixVersion>0100</exif:FlashpixVersion>", profile: profile), .passed)
            XCTAssertEqual(try status("<exif:FlashpixVersion>0101</exif:FlashpixVersion>", profile: profile), .failed)
            XCTAssertEqual(try status("<exif:ExifVersion>version2.1</exif:ExifVersion>", profile: profile), .failed)
            XCTAssertEqual(try status("<exif:ExifVersion>0231</exif:ExifVersion>", profile: profile), .notVerified)
        }
        XCTAssertEqual(try status("<xmp:Rating>3</xmp:Rating>"), .notVerified)
        XCTAssertEqual(try status("<xmp:Rating>three</xmp:Rating>"), .failed)
        XCTAssertEqual(try status("<xmp:Rating>1.5</xmp:Rating>"), .failed)
    }

    func testRelativeDocumentIdentifierIsUnknownWithoutWeakeningMalformedURIValidation() throws {
        func documentID(_ id: String) -> Data {
            fixture(packet(descriptions: "<rdf:Description rdf:about=\"\" xmlns:xmpMM=\"http://ns.adobe.com/xap/1.0/mm/\"><xmpMM:DocumentID>\(id)</xmpMM:DocumentID></rdf:Description>"))
        }
        XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", documentID("e6c240460e7044949ca42990dc07c037")).status, .notVerified)
        XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", documentID("urn:uuid:550e8400-e29b-41d4-a716-446655440000")).status, .passed)
        XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", documentID("malformed identifier %zz")).status, .failed)
        for malformed in ["https://example.com/path[wrong]", "urn:example#first#second", "https://example.com/?q=[wrong]"] {
            XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", documentID(malformed)).status, .failed, malformed)
        }
        for valid in ["https://example.com/path%5Bencoded%5D", "https://[2001:db8::1]/", "urn:example:a?query=a/b?c#fragment"] {
            XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", documentID(valid)).status, .passed, valid)
        }
        XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", documentID("https://example.com/Caffè")).status, .notVerified)
    }

    @MainActor
    func testActualCoreGraphicsArchivalMetadataDoesNotMisclassifyBareDocumentID() throws {
        let source = try XCTUnwrap(PDFDocument(data: fixture(packet())))
        let generated = try PDFNativeProfileConverter.redraw(source, archival: true)
        let reader = try PDFStructureDocument(data: generated)
        let root = try reader.dictionary(.reference(reader.rootID))
        let xmp = String(decoding: try reader.decodedStream(XCTUnwrap(root["Metadata"]?.reference)), as: UTF8.self)
        let regex = try NSRegularExpression(pattern: "<xmpMM:DocumentID>([^<]+)</xmpMM:DocumentID>")
        let match = try XCTUnwrap(regex.firstMatch(in: xmp, range: NSRange(xmp.startIndex..., in: xmp)))
        let id = (xmp as NSString).substring(with: match.range(at: 1))
        let evaluation = try evaluate("XMPProperty", "isValueTypeCorrect == true", generated)
        if URLComponents(string: id)?.scheme == nil {
            XCTAssertEqual(evaluation.status, .notVerified, "Bare Apple ID is a URI-reference, not proof of an absolute URI: \(id)")
            XCTAssertTrue(evaluation.detail.contains("URI-reference"))
        } else { XCTAssertEqual(evaluation.status, .passed, evaluation.detail) }
    }

    func testNestedQualifiersAreNotSilentlyOmittedFromPropertyMembership() throws {
        let qualified = "<dc:coverage rdf:parseType=\"Resource\"><rdf:value>place</rdf:value><xmp:Label rdf:parseType=\"Resource\"><rdf:value>label</rdf:value><my:Unknown>qualifier</my:Unknown></xmp:Label></dc:coverage>"
        XCTAssertEqual(try evaluate("XMPProperty", "isPredefinedInXMP2005 == true || isDefinedInMainPackage == true || isDefinedInCurrentPackage == true", fixture(packet(qualified))).status, .failed)
    }

    func testProlepticGregorianDatesAndNoTimezoneAreNotAffectedByHistoricalCutover() throws {
        let data = fixture(packet("<xmp:CreateDate>1582-10-10T12:00:00Z</xmp:CreateDate>"), info: ["CreationDate": .string("D:15821010120000Z")])
        XCTAssertEqual(try evaluate("CosInfo", "doCreationDatesMatch != false", data, profile: .pdfa1b).status, .passed)
        let different = fixture(packet("<xmp:CreateDate>1582-10-20T12:00:00Z</xmp:CreateDate>"), info: ["CreationDate": .string("D:15821010120000Z")])
        XCTAssertEqual(try evaluate("CosInfo", "doCreationDatesMatch != false", different, profile: .pdfa1b).status, .failed)
        let oldGap = fixture(packet("<xmp:CreateDate>1582-10-10T12:00:00</xmp:CreateDate>"))
        XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", oldGap).status, .passed)
    }

    func testMatchingAboutConstraintUsesTheNormativeAdobeEdition() throws {
        let descriptions = "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:format>application/pdf</dc:format></rdf:Description><rdf:Description rdf:about=\"uuid:edca6282-72cf-4feb-af65-a32e50200f25\" xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"><xmp:CreatorTool>Test</xmp:CreatorTool></rdf:Description>"
        let data = fixture(packet(descriptions: descriptions))
        XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", data, profile: .pdfa1b).status, .passed)
        XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", data, profile: .pdfa2b).status, .failed)
    }

    func testPacketWrapperRequiresPairedHeaderTrailerAndDefinedPseudoAttributes() throws {
        let header = "<?xpacket begin='\u{FEFF}' id='W5M0MpCehiHzreSzNTczkc9d'?>"
        let trailer = "<?xpacket end='w'?>"
        func wrapped(_ start: String, _ end: String) -> Data { Data(start.utf8) + packet() + Data(end.utf8) }
        XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", fixture(wrapped(header, trailer))).status, .passed)
        for data in [wrapped(header, ""), wrapped(header.replacingOccurrences(of: "W5M0MpCehiHzreSzNTczkc9d", with: "wrong"), trailer), wrapped(header, "<?xpacket end='invalid'?>"), wrapped(header.replacingOccurrences(of: "begin=", with: "begin='' begin="), trailer), wrapped(trailer, header), packet("<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?>")] {
            XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", fixture(data)).status, .failed)
        }
        let unknown = header.replacingOccurrences(of: "?>", with: " future='value'?>")
        XCTAssertEqual(try evaluate("XMPPackage", "isSerializationValid", fixture(wrapped(unknown, trailer))).status, .notVerified)
    }

    func testIdentificationRequiresCompleteSchemaButDoesNotCompareSelectedProfile() throws {
        let predicate = "containsPDFAIdentification == true"
        for invalid in ["", "<pdfaid:part>2</pdfaid:part>", "<pdfaid:conformance>B</pdfaid:conformance>", "<pdfaid:part>2</pdfaid:part><pdfaid:conformance></pdfaid:conformance>", "<pdfaid:part>2</pdfaid:part><pdfaid:conformance>b</pdfaid:conformance>", "<pdfaid:part>0</pdfaid:part><pdfaid:conformance>B</pdfaid:conformance>"] {
            XCTAssertEqual(try evaluate("MainXMPPackage", predicate, fixture(packet(invalid))).status, .failed, invalid)
        }
        let valid2b = fixture(packet("<pdfaid:part>2</pdfaid:part><pdfaid:conformance>B</pdfaid:conformance>"))
        XCTAssertEqual(try evaluate("MainXMPPackage", predicate, valid2b, profile: .pdfa2u).status, .passed)
        XCTAssertEqual(try evaluate("PDFAIdentification", "conformance == \"U\" || conformance == \"A\"", valid2b, profile: .pdfa2u).status, .failed)
        let valid1b = fixture(packet("<pdfaid:part>1</pdfaid:part><pdfaid:conformance>B</pdfaid:conformance>"))
        XCTAssertEqual(try evaluate("MainXMPPackage", predicate, valid1b, profile: .pdfa2u).status, .passed)
        for invalid in ["<pdfaid:part>4</pdfaid:part>", "<pdfaid:part>4</pdfaid:part><pdfaid:rev>20_y</pdfaid:rev>", "<pdfaid:part>4</pdfaid:part><pdfaid:rev>2020</pdfaid:rev><pdfaid:conformance></pdfaid:conformance>"] {
            XCTAssertEqual(try evaluate("MainXMPPackage", predicate, fixture(packet(invalid)), profile: .pdfa4).status, .failed, invalid)
        }
        XCTAssertEqual(try evaluate("MainXMPPackage", predicate, fixture(packet("<pdfaid:part>4</pdfaid:part><pdfaid:rev>2020</pdfaid:rev>")), profile: .pdfa4f).status, .passed)
    }

    private func dynamicMedia(_ properties: String) -> Data {
        fixture(packet(descriptions: "<rdf:Description rdf:about=\"\" xmlns:xmpDM=\"http://ns.adobe.com/xmp/1.0/DynamicMedia/\">\(properties)</rdf:Description>"))
    }

    func testDynamicMediaStructuredTypesAndExplicitRelativePathAreValidated() throws {
        let time = "<xmpDM:value>50</xmpDM:value><xmpDM:scale>1/25</xmpDM:scale>"
        let samples = [
            "<xmpDM:markers><rdf:Seq><rdf:li rdf:parseType=\"Resource\"><xmpDM:startTime rdf:parseType=\"Resource\">\(time)</xmpDM:startTime><xmpDM:type>Chapter</xmpDM:type><xmpDM:name>Capitolo</xmpDM:name></rdf:li></rdf:Seq></xmpDM:markers>",
            "<xmpDM:contributedMedia><rdf:Bag><rdf:li rdf:parseType=\"Resource\"><xmpDM:path>file:///C:/Audio/sound.mp3</xmpDM:path><xmpDM:duration rdf:parseType=\"Resource\">\(time)</xmpDM:duration><xmpDM:managed>True</xmpDM:managed></rdf:li></rdf:Bag></xmpDM:contributedMedia>",
            "<xmpDM:relativePeakAudioFilePath>../Audio/sound.mp3</xmpDM:relativePeakAudioFilePath>",
            "<xmpDM:introTime rdf:parseType=\"Resource\">\(time)</xmpDM:introTime>",
            "<xmpDM:outCue rdf:parseType=\"Resource\">\(time)</xmpDM:outCue>",
            "<xmpDM:relativeTimestamp rdf:parseType=\"Resource\">\(time)</xmpDM:relativeTimestamp>",
            "<xmpDM:timeScaleParams rdf:parseType=\"Resource\"><xmpDM:quality>High</xmpDM:quality><xmpDM:frameSize>123.02</xmpDM:frameSize><xmpDM:frameOverlappingPercentage>1.0</xmpDM:frameOverlappingPercentage></xmpDM:timeScaleParams>",
            "<xmpDM:projectRef rdf:parseType=\"Resource\"><xmpDM:type>movie</xmpDM:type><xmpDM:path>file:///film.mov</xmpDM:path></xmpDM:projectRef>",
            "<xmpDM:startTimecode rdf:parseType=\"Resource\"><xmpDM:timeValue>00:00:00:00</xmpDM:timeValue><xmpDM:timeFormat>25Timecode</xmpDM:timeFormat></xmpDM:startTimecode>"
        ]
        for sample in samples { XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", dynamicMedia(sample)).status, .passed, sample) }
        for sample in ["<xmpDM:duration>01:23:42</xmpDM:duration>", samples[0].replacingOccurrences(of: ">Chapter<", with: ">Unspecified<"), samples[3].replacingOccurrences(of: ">1/25<", with: ">1/0<"), samples[6].replacingOccurrences(of: ">High<", with: ">Best<")] {
            XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", dynamicMedia(sample)).status, .failed, sample)
        }
    }

    func testClosedChoiceValuesRequireActualScalarOrSequenceShape() throws {
        for sample in ["<xmpDM:videoPixelDepth>8Int</xmpDM:videoPixelDepth>", "<xmpDM:timeSignature>12/8</xmpDM:timeSignature>", "<xmpDM:pullDown>WSSWW_24p</xmpDM:pullDown>"] {
            XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", dynamicMedia(sample)).status, .passed)
        }
        for sample in ["<xmpDM:videoPixelDepth>64Int</xmpDM:videoPixelDepth>", "<xmpDM:videoPixelDepth><rdf:Seq><rdf:li>8Int</rdf:li></rdf:Seq></xmpDM:videoPixelDepth>"] {
            XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", dynamicMedia(sample)).status, .failed)
        }
        let tiff = "<rdf:Description rdf:about=\"\" xmlns:tiff=\"http://ns.adobe.com/tiff/1.0/\"><tiff:YCbCrSubSampling><rdf:Seq><rdf:li>+2</rdf:li><rdf:li>01</rdf:li></rdf:Seq></tiff:YCbCrSubSampling><tiff:Orientation>8</tiff:Orientation></rdf:Description>"
        XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", fixture(packet(descriptions: tiff))).status, .passed)
        XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", fixture(packet(descriptions: tiff.replacingOccurrences(of: ">8<", with: ">9<")))).status, .failed)
    }

    func testGPSCoordinateRejectsDiscardedComponentsAndImpossibleBounds() throws {
        for value in ["10,bad,20,30N", "90,0,1N", "180,1.0E", "10,,20N", "10,2e1N"] {
            let xmp = packet(descriptions: "<rdf:Description rdf:about=\"\" xmlns:exif=\"http://ns.adobe.com/exif/1.0/\"><exif:GPSLatitude>\(value)</exif:GPSLatitude></rdf:Description>")
            XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", fixture(xmp)).status, .failed, value)
        }
    }

    func testAdditionalStructureFieldsAreNotFalselyConfirmed() throws {
        let sample = "<xmpDM:duration rdf:parseType=\"Resource\"><xmpDM:futureField>text</xmpDM:futureField></xmpDM:duration>"
        XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", dynamicMedia(sample)).status, .notVerified)
        let point = packet(descriptions: "<rdf:Description rdf:about=\"\" xmlns:crs=\"http://ns.adobe.com/camera-raw-settings/1.0/\"><crs:ToneCurve><rdf:Seq><rdf:li>0, 0</rdf:li></rdf:Seq></crs:ToneCurve></rdf:Description>")
        XCTAssertEqual(try evaluate("XMPProperty", "isValueTypeCorrect == true", fixture(point)).status, .notVerified)
    }

    func testOfficialMetadataCorpusRegressionWhenAvailable() throws {
        // veraPDF-corpus 377728596647e40edf16003d68d620773ce96ec5, CC BY 4.0.
        // Optional external integration data; the application does not fetch it.
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CARTAPDF_METADATA_CORPUS"] ?? "/private/tmp/CartaPDF-ISO-corpus/files")
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { throw XCTSkip("Corpus ufficiale locale non installato.") }
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !files.isEmpty else { throw XCTSkip("Corpus ufficiale locale non installato.") }
        func target(_ profile: PDFArchiveProfile, _ name: String, _ object: String, _ predicate: String, _ expected: PDFArchiveRuleStatus) throws {
            let file = try XCTUnwrap(files.first { $0.path.contains("/PDF_A-\(profile.rawValue)/") && $0.lastPathComponent == "veraPDF test suite \(name).pdf" })
            let actual = try evaluate(object, predicate, Data(contentsOf: file), profile: profile)
            XCTAssertEqual(actual.status, expected, file.path + ": " + actual.detail)
        }
        try target(.pdfa1b, "6-7-9-t01-pass-a", "XMPPackage", "isSerializationValid", .passed)
        for suffix in ["b", "c", "e", "s", "t", "u", "z"] { try target(.pdfa2b, "6-6-2-3-1-t02-pass-" + suffix, "XMPProperty", "isValueTypeCorrect == true", .passed) }
        for suffix in ["a", "b", "c", "d", "e", "f"] { try target(.pdfa2b, "6-6-4-t01-fail-" + suffix, "MainXMPPackage", "containsPDFAIdentification == true", .failed) }
        try target(.pdfa1a, "6-7-11-t01-fail-a", "MainXMPPackage", "containsPDFAIdentification == true", .failed)
        try target(.pdfa2a, "6-6-4-t01-fail-a", "MainXMPPackage", "containsPDFAIdentification == true", .failed)
        try target(.pdfa2u, "6-6-4-t01-fail-a", "MainXMPPackage", "containsPDFAIdentification == true", .failed)
        for suffix in ["b", "c", "d", "e", "f", "g", "h", "i"] { try target(.pdfa4, "6-7-3-t01-fail-" + suffix, "MainXMPPackage", "containsPDFAIdentification == true", .failed) }
    }
}
