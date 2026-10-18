import AppKit
import PDFKit
import XCTest
@testable import CartaPDF

final class CartaArchiveValidationTests: XCTestCase {
    @MainActor
    private func archivalFixture() throws -> Data {
        let model = PDFEditorModel()
        return try PDFNativeProfileConverter.redraw(model.document, archival: true)
    }

    @MainActor
    func testCLIReportsActualFileHashAndIndeterminateExitCodeWithoutChangingSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("archivio.pdf"), output = directory.appendingPathComponent("rapporto.json")
        let bytes = try archivalFixture()
        try bytes.write(to: source)
        let profile = try XCTUnwrap(PDFArchiveValidator.declaredProfile(data: bytes))
        let expected = PDFArchiveValidator.validate(data: bytes, profile: profile)
        XCTAssertEqual(expected.verdict, .indeterminate)
        XCTAssertEqual(CartaAutomation.cli(["validate-pdfa", source.path, profile.rawValue, output.path]), 3)
        let report = try JSONDecoder().decode(PDFArchiveValidationReport.self, from: Data(contentsOf: output))
        XCTAssertEqual(report.sha256, expected.sha256)
        XCTAssertEqual(report.profile, profile)
        XCTAssertEqual(report.rules.count, profile.expectedRuleCount)
        XCTAssertFalse(report.coverageComplete)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(CartaAutomation.cli(["validate-pdfa", source.path, profile.rawValue, source.path, "--overwrite"]), 1)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(CartaAutomation.cli(["validate-pdfa", source.path, profile.rawValue, output.path]), 1)
    }

    @MainActor
    func testCLIRejectsUnknownProfileAndReportsProvenViolationsWithExitTwo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("ordinario.pdf"), output = directory.appendingPathComponent("rapporto.json")
        let bytes = try PDFEditorModel().serializedData()
        try bytes.write(to: source)
        XCTAssertEqual(CartaAutomation.cli(["validate-pdfa", source.path, "5z", output.path]), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(CartaAutomation.cli(["validate-pdfa", source.path, "4", output.path]), 2)
        let report = try JSONDecoder().decode(PDFArchiveValidationReport.self, from: Data(contentsOf: output))
        XCTAssertEqual(report.verdict, .nonconforming)
        XCTAssertGreaterThan(report.failedCount, 0)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    @MainActor
    func testChangingProfileCancelsValidationAndDoesNotPublishAnObsoleteReport() async throws {
        let state = CartaArchiveValidationState(data: try archivalFixture(), sourceURL: nil, name: "Test.pdf")
        XCTAssertEqual(state.profile, state.declaredProfile)
        state.validate()
        XCTAssertTrue(state.busy)
        state.profile = .pdfa4f
        XCTAssertFalse(state.busy)
        XCTAssertNil(state.report)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(state.report)
        XCTAssertEqual(state.profile, .pdfa4f)
        XCTAssertTrue(diagnosticContains(state.status, "Avvia la verifica"))
    }
}
