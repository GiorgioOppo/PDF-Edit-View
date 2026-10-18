import AppKit
import CoreGraphics
import CryptoKit
import PDFKit
import Security
import XCTest
@testable import CartaPDF

final class PDFStructureEngineTests: XCTestCase {
    func testSyntaxReaderPreservesEscapesAndDoesNotTreatStringBytesAsObjects() throws {
        var lexer = PDFSyntaxLexer(Data("<< /Name /A#20B /S (a\\(b\\)\\n\\101) /Ref 12 3 R /Hex <4142F> >>".utf8))
        let dictionary = try XCTUnwrap(lexer.value().dictionary)
        XCTAssertEqual(dictionary["Name"]?.name, "A B")
        XCTAssertEqual(dictionary["S"]?.data, Data("a(b)\nA".utf8))
        XCTAssertEqual(dictionary["Ref"]?.reference, PDFObjectID(number: 12, generation: 3))
        XCTAssertEqual(dictionary["Hex"]?.data, Data([65, 66, 240]))
        var opaqueName = PDFSyntaxLexer(Data("/N#E9".utf8))
        XCTAssertEqual(try opaqueName.value().encoded, Data("/N#E9".utf8))
        XCTAssertEqual(PDFSyntaxValue.bytes(Data([0x84, 0xA0])).text, "—€")
    }

    func testPageLabelsUseRealCatalogNumberTreeAndPreserveOriginalRevision() throws {
        let source = fixture()
        let result = try PDFStructureDocument(data: source).setPageLabels(startPage: 0, firstNumber: 3, prefix: "cap-", style: .romanLower)
        XCTAssertTrue(result.starts(with: source))
        let reader = try PDFStructureDocument(data: result)
        let root = try reader.dictionary(.reference(reader.rootID))
        XCTAssertEqual(root["Custom"]?.name, "Preserved")
        let labels = try reader.dictionary(root["PageLabels"])
        XCTAssertEqual(labels["Nums"]?.array?.count, 2)
        let pdf = try XCTUnwrap(PDFDocument(data: result))
        withExtendedLifetime(pdf) { XCTAssertEqual(pdf.page(at: 0)?.label, "cap-iii") }
        XCTAssertTrue((PDFDocument(data: result)?.string ?? "").contains("Originale"))
    }

    func testAttachmentsPreserveExactBytesAndCollectionSurvivesReopening() throws {
        let original = fixture(), bytes = Data([0, 1, 2, 255]) + Data("stream endobj /Type".utf8)
        let result = try PDFStructureDocument(data: original).addingAttachments([(name: "dati ò.bin", data: bytes)], portfolio: true)
        XCTAssertTrue(result.starts(with: original))
        let reader = try PDFStructureDocument(data: result)
        let files = try reader.embeddedFiles()
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.name, "dati ò.bin")
        XCTAssertEqual(try reader.extractAttachment(XCTUnwrap(files.first)), bytes)
        XCTAssertNotNil(try reader.dictionary(.reference(reader.rootID))["Collection"])
        let removed = try reader.removingAttachment(XCTUnwrap(files.first))
        XCTAssertTrue(try PDFStructureDocument(data: removed).embeddedFiles().isEmpty)
        XCTAssertTrue(removed.starts(with: result), "Removing a reference is explicitly not secure erasure")
    }

    @MainActor
    func testPortfolioHasAnActualIndexPageAndEmbeddedOriginalFiles() throws {
        let files = [(name: "alfa.txt", data: Data("alfa".utf8)), (name: "documento.pdf", data: fixture())]
        let result = try PDFNativeProfileConverter.portfolioIndex(files: files)
        let reader = try PDFStructureDocument(data: result)
        XCTAssertEqual(try reader.embeddedFiles().count, 2)
        XCTAssertTrue((PDFDocument(data: result)?.string ?? "").contains("alfa.txt"))
        for file in try reader.embeddedFiles() { XCTAssertEqual(try reader.extractAttachment(file), files.first { $0.name == file.name }?.data) }
    }

    @MainActor
    func testImageExtractionHasOriginalResolutionAndReplacementMutatesXObjectWithoutOverlay() throws {
        let source = fixture(), reader = try PDFStructureDocument(data: source)
        let image = try XCTUnwrap(reader.embeddedImages().first)
        XCTAssertEqual(image.width, 2); XCTAssertEqual(image.height, 2)
        let extracted = try reader.extractImage(image)
        XCTAssertEqual(extracted.fileExtension, "png")
        let representation = try XCTUnwrap(NSBitmapImageRep(data: extracted.data))
        XCTAssertEqual(representation.pixelsWide, 2); XCTAssertEqual(representation.pixelsHigh, 2)
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let result = try reader.replaceImage(image.id, with: XCTUnwrap(context.makeImage()))
        let reopened = try PDFStructureDocument(data: result)
        let replaced = try reopened.object(image.id)
        let samples = try XCTUnwrap(replaced.stream)
        XCTAssertEqual(samples.count, 12)
        for offset in stride(from: 0, to: samples.count, by: 3) {
            XCTAssertLessThan(samples[offset], 10); XCTAssertGreaterThan(samples[offset + 1], 240); XCTAssertLessThan(samples[offset + 2], 10)
        }
        XCTAssertNil(replaced.value.dictionary?["Filter"])
        XCTAssertTrue(result.starts(with: source))
        XCTAssertTrue(PDFDocument(data: result)?.page(at: 0)?.annotations.isEmpty == true)
        let pixel = try renderedPixel(result, point: CGPoint(x: 60, y: 60))
        XCTAssertLessThan(pixel.0, 10); XCTAssertGreaterThan(pixel.1, 240); XCTAssertLessThan(pixel.2, 10)
    }

    func testActualTextOperatorIsReplacedAndUnsupportedFontIsRefused() throws {
        let source = fixture(), reader = try PDFStructureDocument(data: source)
        let run = try XCTUnwrap(reader.originalTextRuns().first)
        XCTAssertEqual(run.text, "Originale")
        let result = try reader.replaceOriginalText(run, with: "Nuovo")
        XCTAssertTrue(result.starts(with: source))
        let updated = try PDFStructureDocument(data: result)
        let stream = try updated.decodedStream(run.streamID)
        XCTAssertFalse(String(decoding: stream, as: UTF8.self).contains("Originale"))
        XCTAssertTrue((PDFDocument(data: result)?.string ?? "").contains("Nuovo"))
        XCTAssertFalse((PDFDocument(data: result)?.string ?? "").contains("Originale"))
        XCTAssertTrue(PDFDocument(data: result)?.page(at: 0)?.annotations.isEmpty == true)
        let unsupported = try PDFStructureDocument(data: fixture(font: "<< /Type /Font /Subtype /Type1 /BaseFont /Symbol >>"))
        XCTAssertTrue(try unsupported.originalTextRuns().isEmpty)
        XCTAssertThrowsError(try unsupported.replaceOriginalText(run, with: "Nuovo"))
        XCTAssertThrowsError(try reader.replaceOriginalText(run, with: "漢字"))
    }

    @MainActor
    func testLayerVisibilityChangesActualDefaultOCGConfigurationAndRendering() throws {
        let source = fixture(), reader = try PDFStructureDocument(data: source)
        let layer = try XCTUnwrap(reader.optionalLayers().first)
        XCTAssertTrue(layer.visible)
        let before = try renderedPixel(source, point: CGPoint(x: 170, y: 50))
        XCTAssertGreaterThan(before.2, 240)
        let result = try reader.setLayerVisibility(layer.id, visible: false)
        let updated = try PDFStructureDocument(data: result)
        XCTAssertFalse(try XCTUnwrap(updated.optionalLayers().first).visible)
        let after = try renderedPixel(result, point: CGPoint(x: 170, y: 50))
        XCTAssertGreaterThan(after.0, 240); XCTAssertGreaterThan(after.1, 240); XCTAssertGreaterThan(after.2, 240)
    }

    func testAccessibilityAuthoringCreatesParentTreeMCIDAndActualAlternativeText() throws {
        let source = fixture(), reader = try PDFStructureDocument(data: source)
        let result = try reader.tagPages(language: "it-IT", tags: [.init(role: "Figure", description: "Figura con un quadrato rosso e un’area blu")])
        let updated = try PDFStructureDocument(data: result)
        let root = try updated.dictionary(.reference(updated.rootID))
        XCTAssertEqual(root["Lang"]?.text, "it-IT")
        let tree = try updated.dictionary(root["StructTreeRoot"])
        let element = try updated.dictionary(tree["K"]?.array?.first)
        XCTAssertEqual(element["S"]?.name, "Figure")
        XCTAssertEqual(element["Alt"]?.text, "Figura con un quadrato rosso e un’area blu")
        let parent = try updated.dictionary(tree["ParentTree"])
        XCTAssertEqual(parent["Nums"]?.array?.count, 2)
        let page = try XCTUnwrap(updated.pageIDs().first)
        XCTAssertEqual(try updated.dictionary(.reference(page))["StructParents"]?.int, 0)
        let streams = try updated.contentStreamIDs(on: page)
        XCTAssertTrue(String(decoding: try updated.decodedStream(XCTUnwrap(streams.first)), as: UTF8.self).contains("/MCID 0"))
        XCTAssertTrue(streams.contains { (try? String(decoding: updated.decodedStream($0), as: UTF8.self).contains("Originale")) == true })
        XCTAssertThrowsError(try updated.tagPages(language: "it", tags: [.init(role: "P", description: "Testo")]))
    }

    func testPreflightReportsRealUnembeddedFontAndImagePlacementDPI() throws {
        let reader = try PDFStructureDocument(data: fixture())
        let items = try reader.preflight()
        XCTAssertTrue(items.contains { $0.title.contains("Helvetica") && diagnosticContains($0.detail, "non incorporato") })
        let placements = try reader.imagePlacements(on: XCTUnwrap(reader.pageIDs().first))
        XCTAssertEqual(try XCTUnwrap(placements.first).dpi, 2, accuracy: 0.01)
        XCTAssertTrue(items.contains { diagnosticContains($0.title, "Immagine") && $0.severity == "avviso" })
        XCTAssertTrue(items.contains { $0.title == L10n.tr("Limite della validazione") && diagnosticContains($0.detail, "Non è un validatore completo") })
    }

    @MainActor
    func testNativePDFAGenerationContainsArchivalXMPAndOutputIntent() throws {
        let source = try XCTUnwrap(PDFDocument(data: fixture()))
        let result = try PDFNativeProfileConverter.redraw(source, archival: true)
        let reader = try PDFStructureDocument(data: result), root = try reader.dictionary(.reference(reader.rootID))
        let metadata = try XCTUnwrap(root["Metadata"]?.reference)
        let xmp = String(decoding: try reader.decodedStream(metadata), as: UTF8.self)
        XCTAssertTrue(xmp.contains("pdfaid:"))
        XCTAssertFalse((try reader.resolve(root["OutputIntents"])?.array ?? []).isEmpty)
        XCTAssertEqual(PDFDocument(data: result)?.pageCount, 1)
        XCTAssertTrue(try reader.archivalChecks().contains { $0.title == L10n.tr("Dichiarazione PDF/A in XMP") })
    }

    @MainActor
    func testICCPrintPreparationEmbedsAnActualCMYKOutputProfile() throws {
        let source = try XCTUnwrap(PDFDocument(data: fixture()))
        let profile = try XCTUnwrap(CGColorSpace(name: CGColorSpace.genericCMYK))
        let result = try PDFNativeProfileConverter.redraw(source, outputProfile: profile, condition: "CMYK test locale")
        let reader = try PDFStructureDocument(data: result), root = try reader.dictionary(.reference(reader.rootID))
        let intentValue = try XCTUnwrap(reader.resolve(root["OutputIntents"])?.array?.first)
        let intent = try reader.dictionary(intentValue)
        XCTAssertEqual(intent["S"]?.name, "GTS_PDFX")
        let profileID = try XCTUnwrap(intent["DestOutputProfile"]?.reference)
        let bytes = try reader.decodedStream(profileID)
        XCTAssertGreaterThan(bytes.count, 128)
        XCTAssertEqual(CGColorSpace(iccData: bytes as CFData)?.model, .cmyk)
        XCTAssertTrue(try reader.preflight().contains { $0.title.contains("GTS_PDFX") })
    }

    @MainActor
    func testOriginalJPEGExtractionPreservesTheEncodedBytesExactly() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 6, bitsPerPixel: 24))
        let samples = try XCTUnwrap(bitmap.bitmapData)
        for (index, byte) in [UInt8(255),0,0, 0,255,0, 0,0,255, 255,255,255].enumerated() { samples[index] = byte }
        let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]))
        let reader = try PDFStructureDocument(data: fixture(imageData: jpeg, imageFilter: "/Filter /DCTDecode"))
        let image = try XCTUnwrap(reader.embeddedImages().first)
        let extracted = try reader.extractImage(image)
        XCTAssertEqual(extracted.fileExtension, "jpg")
        XCTAssertEqual(extracted.data, jpeg)
    }

    func testCompressedXrefAndObjectStreamsCanBeReadAndUpdatedIncrementally() throws {
        let source = compressedObjectFixture()
        XCTAssertNotNil(PDFDocument(data: source), "The object-stream fixture itself must be accepted by PDFKit")
        let reader = try PDFStructureDocument(data: source)
        XCTAssertEqual(try reader.pageIDs().count, 1)
        XCTAssertEqual(try reader.originalTextRuns().first?.text, "Compresso")
        let result = try reader.setPageLabels(startPage: 0, firstNumber: 1, prefix: "S-", style: .decimal)
        let pdf = try XCTUnwrap(PDFDocument(data: result))
        withExtendedLifetime(pdf) { XCTAssertEqual(pdf.page(at: 0)?.label, "S-1") }
        XCTAssertTrue(result.starts(with: source))
    }

    @MainActor
    func testEncryptedPDFStructuralChangesAreRefusedRatherThanRemovingProtection() throws {
        let pdf = try XCTUnwrap(PDFDocument(data: fixture()))
        let encrypted = try XCTUnwrap(pdf.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "lettore", PDFDocumentWriteOption.ownerPasswordOption: "proprietario"]))
        let reader = try PDFStructureDocument(data: encrypted)
        XCTAssertTrue(reader.encrypted)
        XCTAssertThrowsError(try reader.setPageLabels(startPage: 0, firstNumber: 1, prefix: "", style: .decimal))
        XCTAssertThrowsError(try reader.addingAttachments([(name: "a.txt", data: Data())]))
    }

    @MainActor
    func testRealCMSByteRangeSignatureVerifiesAndDetectsByteTamperingWithoutKeychainWrites() throws {
        let identity = try ephemeralIdentity()
        let source = fixture()
        let signed = try PDFLocalCertificateEngine.sign(source, identity: identity, reason: "Verifica test locale")
        XCTAssertTrue(signed.starts(with: source))
        let results = try PDFLocalCertificateEngine.verify(signed)
        let signature = try XCTUnwrap(results.first)
        XCTAssertTrue(signature.integrityValid, signature.detail)
        XCTAssertFalse(signature.locallyTrusted, "The in-memory self-signed test certificate is deliberately not trusted")
        XCTAssertEqual(signature.bytesAfterSignature, 0)
        XCTAssertEqual(signature.digest.count, 64)
        var modified = signed
        let range = try XCTUnwrap(modified.range(of: Data("Originale".utf8)))
        modified.replaceSubrange(range, with: Data("Alterato!".utf8))
        XCTAssertTrue(try PDFLocalCertificateEngine.verify(modified).allSatisfy { !$0.integrityValid })
        let later = try PDFStructureDocument(data: signed).setPageLabels(startPage: 0, firstNumber: 1, prefix: "Dopo-", style: .decimal)
        let previous = try XCTUnwrap(PDFLocalCertificateEngine.verify(later).first)
        XCTAssertTrue(previous.integrityValid)
        XCTAssertGreaterThan(previous.bytesAfterSignature, 0, "The signed revision remains valid but later bytes are explicitly not covered")
    }

    @MainActor
    func testRepeatedInMemoryECDSASignaturesRemainValidAcrossDistinctKeys() throws {
        for iteration in 0..<24 {
            let identity = try ephemeralIdentity()
            let signed = try PDFLocalCertificateEngine.sign(fixture(), identity: identity, reason: "Firma ripetuta \(iteration)")
            let signatures = try PDFLocalCertificateEngine.verify(signed)
            XCTAssertEqual(signatures.count, 1)
            XCTAssertTrue(try XCTUnwrap(signatures.first).integrityValid, "Iteration \(iteration): \(signatures.first?.detail ?? "missing signature")")
        }
    }

    private func fixture(font: String = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>", imageData: Data? = nil, imageFilter: String = "") -> Data {
        let content = Data("BT /F1 18 Tf 40 160 Td (Originale) Tj ET\nq 72 0 0 72 30 30 cm /Im1 Do Q\n/OC /L1 BDC 0 0 1 rg 150 30 40 40 re f EMC\n".utf8)
        let pixels = Data([255,0,0, 255,0,0, 255,0,0, 255,0,0])
        let objects: [Int: Data] = [
            1: Data("<< /Type /Catalog /Pages 2 0 R /Custom /Preserved /OCProperties << /OCGs [7 0 R] /D << /BaseState /ON /Order [7 0 R] >> >> >>".utf8),
            2: Data("<< /Type /Pages /Count 1 /Kids [3 0 R] >>".utf8),
            3: Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 220] /Resources << /Font << /F1 4 0 R >> /XObject << /Im1 6 0 R >> /Properties << /L1 7 0 R >> >> /Contents 5 0 R >>".utf8),
            4: Data(font.utf8), 5: stream("", content),
            6: stream("/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8 \(imageFilter)", imageData ?? pixels),
            7: Data("<< /Type /OCG /Name (Area blu) >>".utf8)
        ]
        return classic(objects, root: 1)
    }
    private func stream(_ dictionary: String, _ data: Data) -> Data {
        Data("<< \(dictionary) /Length \(data.count) >>\nstream\n".utf8) + data + Data("\nendstream".utf8)
    }
    private func classic(_ objects: [Int: Data], root: Int) -> Data {
        var data = Data("%PDF-1.7\n".utf8), offsets: [Int: Int] = [:]
        for id in objects.keys.sorted() { offsets[id] = data.count; data += Data("\(id) 0 obj\n".utf8) + objects[id]! + Data("\nendobj\n".utf8) }
        let xref = data.count, size = (objects.keys.max() ?? 0) + 1
        data += Data("xref\n0 \(size)\n0000000000 65535 f \n".utf8)
        for id in 1..<size { data += Data(String(format: "%010lld 00000 %@ \n", Int64(offsets[id] ?? 0), offsets[id] == nil ? "f" : "n").utf8) }
        return data + Data("trailer\n<< /Size \(size) /Root \(root) 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
    }
    private func compressedObjectFixture() -> Data {
        let values = ["<< /Type /Catalog /Pages 3 0 R >>", "<< /Type /Pages /Count 1 /Kids [4 0 R] >>", "<< /Type /Page /Parent 3 0 R /MediaBox [0 0 300 220] /Resources << /Font << /F1 5 0 R >> >> /Contents 6 0 R >>", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"]
        var body = Data(), header = ""
        for (index, value) in values.enumerated() { header += "\(index + 2) \(body.count) "; body += Data((value + "\n").utf8) }
        let objectStream = Data(header.utf8) + body
        var data = Data("%PDF-1.7\n".utf8)
        let firstOffset = data.count
        data += Data("1 0 obj\n".utf8) + stream("/Type /ObjStm /N 4 /First \(header.utf8.count) /Filter /FlateDecode", storedZlib(objectStream)) + Data("\nendobj\n".utf8)
        let contentOffset = data.count
        data += Data("6 0 obj\n".utf8) + stream("", Data("BT /F1 18 Tf 40 160 Td (Compresso) Tj ET".utf8)) + Data("\nendobj\n".utf8)
        let xrefOffset = data.count
        var entries = Data()
        func entry(_ type: Int, _ one: Int, _ two: Int) { entries += Data([UInt8(type), UInt8((one >> 24) & 255), UInt8((one >> 16) & 255), UInt8((one >> 8) & 255), UInt8(one & 255), UInt8((two >> 8) & 255), UInt8(two & 255)]) }
        entry(0, 0, 65535); entry(1, firstOffset, 0)
        for index in 0..<4 { entry(2, 1, index) }
        entry(1, contentOffset, 0); entry(1, xrefOffset, 0)
        data += Data("7 0 obj\n".utf8) + stream("/Type /XRef /Root 2 0 R /Size 8 /W [1 4 2] /Filter /FlateDecode", storedZlib(entries)) + Data("\nendobj\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8)
        return data
    }
    private func storedZlib(_ bytes: Data) -> Data {
        let count = bytes.count
        precondition(count < 65536)
        var output = Data([0x78, 0x01, 0x01, UInt8(count & 255), UInt8(count >> 8), UInt8((~count) & 255), UInt8(((~count) >> 8) & 255)]) + bytes
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let sum = (b << 16) | a
        output += Data([UInt8(sum >> 24), UInt8((sum >> 16) & 255), UInt8((sum >> 8) & 255), UInt8(sum & 255)])
        return output
    }
    @MainActor
    private func renderedPixel(_ data: Data, point: CGPoint) throws -> (Int, Int, Int) {
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        defer { withExtendedLifetime(pdf) {} }
        let page = try XCTUnwrap(pdf.page(at: 0))
        let context = try XCTUnwrap(CGContext(data: nil, width: 300, height: 220, bitsPerComponent: 8, bytesPerRow: 1200,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 300, height: 220)); page.draw(with: .mediaBox, to: context)
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self), offset = ((219 - Int(point.y)) * 300 + Int(point.x)) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }
    private func ephemeralIdentity() throws -> SecIdentity {
        let generated = P256.Signing.PrivateKey()
        var keyError: Unmanaged<CFError>?
        let key = try XCTUnwrap(SecKeyCreateWithData(generated.x963Representation as CFData,
            [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate,
             kSecAttrKeySizeInBits: 256] as CFDictionary, &keyError), "\(String(describing: keyError?.takeRetainedValue()))")
        let publicData = generated.publicKey.x963Representation
        func tlv(_ tag: UInt8, _ value: Data) -> Data {
            var length = Data()
            if value.count < 128 { length.append(UInt8(value.count)) }
            else { var count = value.count, bytes: [UInt8] = []; while count > 0 { bytes.insert(UInt8(count & 255), at: 0); count >>= 8 }; length.append(0x80 | UInt8(bytes.count)); length += Data(bytes) }
            return Data([tag]) + length + value
        }
        func sequence(_ value: Data) -> Data { tlv(48, value) }
        let keyAlgorithm = sequence(Data([6,7,42,134,72,206,61,2,1, 6,8,42,134,72,206,61,3,1,7]))
        let signatureAlgorithm = sequence(Data([6,8,42,134,72,206,61,4,3,2]))
        // Native certificate implementations can cache by issuer+serial.
        // Each unrelated ephemeral key needs its own actual identity.
        let name = sequence(tlv(49, sequence(Data([6,3,85,4,3]) + tlv(12, Data(("CartaPDF Native Test " + UUID().uuidString).utf8)))))
        var serial = Data([1])
        withUnsafeBytes(of: UUID().uuid) { serial.append(contentsOf: $0) }
        let validity = sequence(tlv(23, Data("200101000000Z".utf8)) + tlv(23, Data("491231235959Z".utf8)))
        let spki = sequence(keyAlgorithm + tlv(3, Data([0]) + publicData))
        let tbs = sequence(tlv(2, serial) + signatureAlgorithm + name + validity + name + spki)
        let signature = try XCTUnwrap(SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, nil)) as Data
        let certificateData = sequence(tbs + signatureAlgorithm + tlv(3, Data([0]) + signature))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, certificateData as CFData))
        return try XCTUnwrap(SecIdentityCreate(nil, certificate, key))
    }
}
