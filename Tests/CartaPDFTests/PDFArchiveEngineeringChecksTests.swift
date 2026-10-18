import Foundation
import XCTest
@testable import CartaPDF

final class PDFArchiveEngineeringChecksTests: XCTestCase {
    func testMinimalU3DAndOptionalUnitsHeaderHaveOnlyTheRequiredBlock() {
        for data in [file(), file(profile: 8), file(major: -1), file(minor: 32767)] {
            let audit = PDFArchiveEngineeringChecks.audit(data, subtype: "U3D")
            XCTAssertEqual(audit.structure.status, .passed)
            XCTAssertEqual(audit.payload.status, .notApplicable)
        }
        XCTAssertEqual(PDFArchiveEngineeringChecks.audit(file(major: 1), subtype: "U3D").structure.status, .notVerified)
    }

    func testU3DHeaderMagicFileSizeDeclarationEncodingAndProfileAreChecked() {
        var badMagic = file(); badMagic[0] = 0
        var badFileSize = file(); badFileSize.replaceSubrange(24..<32, with: u64(999))
        var badDeclaration = file(); badDeclaration.replaceSubrange(20..<24, with: u32(35))
        var badEncoding = file(); badEncoding.replaceSubrange(32..<36, with: u32(0))
        var missingUnits = file(); missingUnits.replaceSubrange(16..<20, with: u32(8))
        for data in [Data(), Data([0x55, 0x33, 0x44, 0]), badMagic, badFileSize, badDeclaration,
                     badEncoding, missingUnits, file(profile: 1), file(profile: 16)] {
            XCTAssertEqual(PDFArchiveEngineeringChecks.audit(data, subtype: "U3D").structure.status, .failed)
        }
    }

    func testU3DBlockBoundsAndBothZeroPaddingRegionsAreIndependent() {
        let body = block(0xffffff54, Data([1]), metadata: u32(0))
        XCTAssertEqual(PDFArchiveEngineeringChecks.audit(file(body: body), subtype: "U3D").structure.status, .passed)
        var dataPadding = body; dataPadding[13] = 1
        let metadata = u32(1) + u32(0) + string("a") + string("")
        let metaBody = block(0xffffff54, Data(), metadata: metadata)
        var metaPadding = metaBody; metaPadding[metaPadding.count - 1] = 1
        var huge = body; huge.replaceSubrange(4..<8, with: u32(UInt32.max))
        var hugeMeta = body; hugeMeta.replaceSubrange(8..<12, with: u32(UInt32.max))
        for bytes in [dataPadding, metaPadding, huge, hugeMeta, Data(body.dropLast()), body + Data([0])] {
            XCTAssertEqual(PDFArchiveEngineeringChecks.audit(file(body: bytes), subtype: "U3D").structure.status, .failed)
        }
    }

    func testU3DMetadataUTF8StringsBinaryValuesCountsAttributesAndResidue() {
        let text = u32(1) + u32(0) + string("titolo") + string("Geometria è locale")
        let binary = u32(1) + u32(1) + string("bytes") + u32(3) + Data([0xff, 0, 0x80])
        for value in [text, binary, u32(0)] {
            XCTAssertEqual(PDFArchiveEngineeringChecks.audit(file(metadata: value), subtype: "U3D").structure.status, .passed)
        }
        let invalid: [Data] = [
            u32(2), u32(1) + u32(4) + string("k") + string("v"),
            u32(1) + u32(0) + u16(2) + Data([0xc0, 0x80]) + string("v"),
            u32(1) + u32(1) + string("k") + u32(100) + Data([1]),
            text + Data([0]), Data([0, 0, 0])
        ]
        for value in invalid {
            XCTAssertEqual(PDFArchiveEngineeringChecks.audit(file(metadata: value), subtype: "U3D").structure.status, .failed)
        }
    }

    func testU3DDeclarationBoundaryAndContinuationPriorityAreChecked() {
        let updates = block(0xffffff15, u32(1)) + block(0xffffff15, u32(2))
        XCTAssertEqual(PDFArchiveEngineeringChecks.audit(file(body: updates, declaration: 36), subtype: "U3D").structure.status, .passed)
        let invalid: [Data] = [
            file(body: updates), // Continuation inside declaration section.
            file(body: updates, declaration: 40), // Splits the first block.
            file(body: block(0xffffff15, u32(2)) + block(0xffffff15, u32(1)), declaration: 36),
            file(body: block(0xffffff15, u32(0)), declaration: 36),
            file(body: block(0xffffff15, u32(0x80000000)), declaration: 36),
            file(body: block(0xffffff15, u32(1) + u32(2)), declaration: 36),
            file(body: block(0xffffff3b, Data())) // Mesh continuation in declaration.
        ]
        for data in invalid {
            XCTAssertEqual(PDFArchiveEngineeringChecks.audit(data, subtype: "U3D").structure.status, .failed)
        }
    }

    func testU3DExtensionsStayUnknownAndUnknownBaseBlocksFail() {
        let custom = block(0x100, Data([0, 1, 2, 3]))
        XCTAssertEqual(PDFArchiveEngineeringChecks.audit(file(body: custom), subtype: "U3D").structure.status, .failed)
        XCTAssertEqual(PDFArchiveEngineeringChecks.audit(file(profile: 2, body: custom), subtype: "U3D").structure.status, .notVerified)
        XCTAssertEqual(PDFArchiveEngineeringChecks.audit(file(body: block(0xffffff16, Data())), subtype: "U3D").structure.status, .failed)
        XCTAssertEqual(PDFArchiveEngineeringChecks.audit(file(body: block(0xdeadbeef, Data())), subtype: "U3D").structure.status, .failed)
        let opaque = PDFArchiveEngineeringChecks.audit(file(body: block(0xffffff54, Data())), subtype: "U3D")
        XCTAssertEqual(opaque.structure.status, .passed)
        XCTAssertEqual(opaque.payload.status, .notVerified)
    }

    func testU3DRepeatedHeaderCannotMasqueradeAsAnotherDeclaration() {
        let duplicate = file(body: file())
        XCTAssertEqual(PDFArchiveEngineeringChecks.audit(duplicate, subtype: "U3D").structure.status, .failed)
    }

    func testU3DPriorityZeroAtObservedCorpusOffsetHasAnIndependentCounterfactual() {
        // An independently extracted corpus payload has a 55-byte header
        // metadata section and PriorityUpdate(0) at byte92. Synthetic metadata
        // recreates that boundary without embedding the licensed sample.
        let metadata = u32(1) + u32(0) + string("k") + string(String(repeating: "v", count: 42))
        XCTAssertEqual(metadata.count, 55)
        let original = file(body: block(0xffffff15, u32(0)) + block(0xffffff15, u32(256)), metadata: metadata, declaration: 92)
        XCTAssertEqual(PDFArchiveEngineeringChecks.audit(original, subtype: "U3D").structure.status, .failed)
        var corrected = original
        corrected.replaceSubrange(104..<108, with: u32(1))
        XCTAssertEqual(original.count, corrected.count)
        XCTAssertEqual(PDFArchiveEngineeringChecks.audit(corrected, subtype: "U3D").structure.status, .passed)
    }

    func testPRCHeaderOrMagicAloneNeverProvesItsSchema() {
        for bytes in [Data(), Data("PRC".utf8), file()] {
            let audit = PDFArchiveEngineeringChecks.audit(bytes, subtype: "PRC")
            XCTAssertEqual(audit.structure.status, .notVerified)
            XCTAssertEqual(audit.payload.status, .notVerified)
        }
    }

    private func file(profile: UInt32 = 0, major: Int16 = 0, minor: Int16 = 0, body: Data = Data(), metadata: Data = Data(), declaration: UInt32? = nil) -> Data {
        let length = profile & 8 == 0 ? 24 : 32
        let headerSize = 12 + length + ((metadata.count + 3) & ~3)
        let header = u16(UInt16(bitPattern: major)) + u16(UInt16(bitPattern: minor)) + u32(profile) +
            u32(declaration ?? UInt32(headerSize + body.count)) + u64(UInt64(headerSize + body.count)) + u32(106) +
            (profile & 8 == 0 ? Data() : u64(Double(0.001).bitPattern))
        return block(0x00443355, header, metadata: metadata) + body
    }
    private func block(_ type: UInt32, _ data: Data, metadata: Data = Data()) -> Data {
        u32(type) + u32(UInt32(data.count)) + u32(UInt32(metadata.count)) + data +
            Data(repeating: 0, count: (4 - data.count % 4) % 4) + metadata +
            Data(repeating: 0, count: (4 - metadata.count % 4) % 4)
    }
    private func string(_ text: String) -> Data { u16(UInt16(text.utf8.count)) + Data(text.utf8) }
    private func u16(_ value: UInt16) -> Data { Data([UInt8(value & 255), UInt8(value >> 8)]) }
    private func u32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8((value >> ($0 * 8)) & 255) }) }
    private func u64(_ value: UInt64) -> Data { Data((0..<8).map { UInt8((value >> ($0 * 8)) & 255) }) }
}
