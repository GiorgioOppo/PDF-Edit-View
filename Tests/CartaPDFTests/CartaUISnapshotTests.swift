import AppKit
import CryptoKit
import PDFKit
import QuartzCore
import SwiftUI
import XCTest
@testable import CartaPDF

/// Opt-in native rendering for a human localization review. This does not drive the desktop.
#if DEBUG
@MainActor
final class CartaUISnapshotTests: XCTestCase {
    func testExportNativeInterfaceSnapshotsWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let outputPath = environment["CARTAPDF_UI_AUDIT_OUTPUT_DIRECTORY"], !outputPath.isEmpty,
              let fixturePath = environment["CARTAPDF_UI_AUDIT_FIXTURE"], !fixturePath.isEmpty else {
            throw XCTSkip("Set CARTAPDF_UI_AUDIT_OUTPUT_DIRECTORY and CARTAPDF_UI_AUDIT_FIXTURE for the native UI audit.")
        }

        let application = NSApplication.shared
        let previousPolicy = application.activationPolicy()
        _ = application.setActivationPolicy(.accessory)
        defer { _ = application.setActivationPolicy(previousPolicy) }

        // Keep launch-language arguments intact while avoiding personal author names in the images.
        let previousArgumentDomain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var auditArgumentDomain = previousArgumentDomain
        auditArgumentDomain["Carta.annotationAuthor"] = "UI Audit"
        auditArgumentDomain["Carta.sidebarWidth"] = 180.0
        UserDefaults.standard.setVolatileDomain(auditArgumentDomain, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previousArgumentDomain, forName: UserDefaults.argumentDomain) }

        let fixtureURL = URL(fileURLWithPath: fixturePath)
        let fixtureData = try Data(contentsOf: fixtureURL)
        let fixtureHash = sha256(fixtureData)
        let document = try XCTUnwrap(PDFDocument(data: fixtureData))
        XCTAssertGreaterThan(document.pageCount, 0)

        let directory = URL(fileURLWithPath: outputPath, isDirectory: true)
            .appendingPathComponent(L10n.language, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let model = PDFEditorModel()
        model.replaceDocument(document, fileName: fixtureURL.lastPathComponent)
        let originalSidebarWidth = CartaPreferences.shared.sidebarWidth
        defer {
            if CartaPreferences.shared.sidebarWidth != originalSidebarWidth {
                CartaPreferences.shared.sidebarWidth = originalSidebarWidth
            }
        }

        var snapshots: [SnapshotRecord] = []
        func capture<V: View>(_ id: String, _ view: V, width: CGFloat, height: CGFloat,
                              scenario: String = "Synthetic fixture; controls were not activated.") async throws {
            print("CARTAPDF_UI_AUDIT_BEGIN \(id)")
            snapshots.append(try await render(id: id, view: view, size: NSSize(width: width, height: height),
                                             directory: directory, scenario: scenario))
            print("CARTAPDF_UI_AUDIT_END \(id)")
        }

        try await capture("editor", ContentView(model: model), width: 880, height: 650)
        model.activeTool = .text
        try await capture("editor-text-formatting", ContentView(model: model), width: 880, height: 650)
        model.activeTool = .select
        try await capture("tools", ToolBrowserView(model: model), width: 940, height: 650)

        // Use a separate in-memory registration domain, so the image contains no account name.
        let auditDefaults = try XCTUnwrap(UserDefaults(suiteName: "CartaPDF.UIAudit.\(UUID().uuidString)"))
        auditDefaults.register(defaults: ["Carta.annotationAuthor": "UI Audit", "Carta.sidebarWidth": 214.0])
        let preferences = CartaPreferences(defaults: auditDefaults)
        try await capture("preferences", CartaPreferencesView(preferences: preferences), width: 560, height: 650)
        try await capture("forms-constrained", PDFFormsView(model: model), width: 620, height: 650,
                          scenario: "Deliberately constrained 620-point viewport; compare fitting size with the view's 700-point minimum.")
        try await capture("forms", PDFFormsView(model: model), width: 700, height: 650)
        try await capture("keyboard-annotations", CartaKeyboardEditingAuditView.make(model: model), width: 820, height: 620)

        let workflows: [(String, WorkflowWorkspaceKind)] = [
            ("workflow-merge", .merge), ("workflow-split", .split), ("workflow-layout", .layout),
            ("workflow-numbering", .numbering), ("workflow-crop", .crop)
        ]
        for (id, kind) in workflows {
            let controller = WorkflowController(model: model, kind: kind)
            if kind == .merge {
                controller.buildMerge()
                try await waitUntilIdle { controller.busy }
                XCTAssertNil(controller.error)
            } else if kind == .split {
                controller.splitCount = 1
                controller.buildSplit()
                try await waitUntilIdle { controller.busy }
                XCTAssertNil(controller.error)
            }
            try await capture(id, WorkflowWorkspaceView(controller: controller), width: 980, height: 640,
                              scenario: kind == .merge || kind == .split
                                ? "An in-memory preview was generated from the synthetic fixture; no export or file picker was used."
                                : "Synthetic fixture; controls were not activated.")
            controller.cancel()
        }

        let scan = ScanWorkspaceController(snapshot: fixtureData, prioritizedPage: 0)
        scan.reports = [
            ScanPageReport(page: 1, state: "Testo già presente", confidence: 1, lines: 4, angle: 0),
            ScanPageReport(page: 2, state: "Riconosciuta", confidence: 0.94, lines: 12, angle: 1.2),
            ScanPageReport(page: 3, state: "Nessun testo rilevato", confidence: 0, lines: 0, angle: 0)
        ]
        let scanScenario = "Seeded example OCR rows test presentation only; no OCR result is claimed."
        try await capture("ocr", ScanWorkspaceView(controller: scan) { _ in }, width: 1120, height: 760,
                          scenario: scanScenario)
        try await capture("ocr-minimum", ScanWorkspaceView(controller: scan) { _ in }, width: 1080, height: 620,
                          scenario: scanScenario)
        scan.cancel()

        let export = ScanExportController(snapshot: fixtureData, name: fixtureURL.lastPathComponent, canRaster: true)
        try await capture("export", ScanExportWorkspaceView(controller: export) { _, _ in }, width: 1000, height: 760)
        try await capture("export-minimum", ScanExportWorkspaceView(controller: export) { _, _ in }, width: 760, height: 580)
        export.format = .csv
        try await capture("export-csv", ScanExportWorkspaceView(controller: export) { _, _ in }, width: 760, height: 580)
        export.cancel()

        print("CARTAPDF_UI_AUDIT_STRUCTURE_INIT_BEGIN")
        let structure = try PDFStructureWorkspaceState(data: fixtureData, sourceURL: nil, name: fixtureURL.lastPathComponent)
        print("CARTAPDF_UI_AUDIT_STRUCTURE_INIT_END")
        let sections: [(String, PDFStructureSection)] = [
            ("structure-objects", .structure), ("structure-original", .originalContent),
            ("structure-preflight", .preflight), ("structure-certificates", .certificates)
        ]
        for (id, section) in sections {
            try await capture(id, PDFStructureWorkspaceView(state: structure, initialSection: section), width: 820, height: 600)
        }

        let archive = CartaArchiveValidationState(data: fixtureData, sourceURL: nil, name: fixtureURL.lastPathComponent)
        archive.validate()
        try await waitUntilIdle { archive.busy }
        XCTAssertNotNil(archive.report)
        let archiveScenario = "Actual local PDF/A analysis of the synthetic fixture; incomplete scope remains visible."
        try await capture("pdfa", CartaArchiveValidationView(state: archive), width: 1120, height: 760,
                          scenario: archiveScenario)
        // Closing the first owned view runs its production onDisappear cancellation.
        // Prepare the second viewport independently instead of capturing that lifecycle message.
        archive.validate()
        try await waitUntilIdle { archive.busy }
        XCTAssertNotNil(archive.report)
        try await capture("pdfa-minimum", CartaArchiveValidationView(state: archive), width: 880, height: 680,
                          scenario: archiveScenario)
        archive.cancel()

        XCTAssertEqual(sha256(try Data(contentsOf: fixtureURL)), fixtureHash, "The source fixture must remain unchanged.")
        let manifest = SnapshotManifest(selectedLanguage: L10n.language, preferredLanguages: Locale.preferredLanguages,
                                        sourceFixtureName: fixtureURL.lastPathComponent, sourceFixtureSHA256: fixtureHash,
                                        snapshots: snapshots)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        XCTAssertEqual(snapshots.count, 23)
    }

    private func waitUntilIdle(_ isBusy: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(60)
        while isBusy(), Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(isBusy(), "The in-memory preparation did not finish before the audit timeout.")
    }

    private func render<V: View>(id: String, view: V, size: NSSize, directory: URL,
                                 scenario: String) async throws -> SnapshotRecord {
        let bounds = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .windowBackgroundColor
        let controller = NSHostingController(rootView: view.environment(\.locale, L10n.currentLocale).environment(\.colorScheme, .light)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)))
        controller.sizingOptions = []
        let hosting = controller.view
        hosting.wantsLayer = true
        hosting.frame = bounds
        window.contentViewController = controller
        window.setContentSize(size)
        hosting.frame = bounds
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) })
        // This test owns the window. Ordering it behind other windows outside every display
        // starts native display-list rendering without making it key or activating the app.
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentViewController = nil; window.contentView = nil; window.close() }

        // Yield to native layout and async PDF thumbnails; no part of the window is on screen.
        for _ in 0..<4 {
            window.contentView?.layoutSubtreeIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        displayLayers(hosting.layer)
        CATransaction.flush()
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "Audit windows must remain outside every display.")

        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds), "No native bitmap for \(id).")
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext)
        // The companion bitmap has a logical point size, so its graphics context may
        // already include Retina scaling. Normalize once before working in pixels.
        context.concatenate(context.ctm.inverted())
        let scaleX = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / hosting.bounds.height
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh))
        context.scaleBy(x: scaleX, y: -scaleY)
        hosting.layer?.render(in: context)
        context.restoreGState()
        // SwiftUI's display list lives in layers; native controls can draw directly into
        // their NSView cache. Compose those actual controls at their existing frame/clip.
        try drawNativeControls(in: hosting, root: hosting, context: context, scaleX: scaleX, scaleY: scaleY)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        XCTAssertTrue(hasPixelVariation(bitmap), "\(id) rendered a uniform image; it cannot be treated as a UI snapshot.")
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), "Could not encode \(id).")
        let filename = id + ".png"
        try png.write(to: directory.appendingPathComponent(filename), options: .atomic)
        let fitting = hosting.fittingSize
        return SnapshotRecord(id: id, file: filename, requestedWidth: Double(size.width), requestedHeight: Double(size.height),
                              renderedWidth: Double(hosting.bounds.width), renderedHeight: Double(hosting.bounds.height),
                              fittingWidth: Double(fitting.width), fittingHeight: Double(fitting.height),
                              pixelWidth: bitmap.pixelsWide, pixelHeight: bitmap.pixelsHigh,
                              sha256: sha256(png), scenario: scenario)
    }

    private func displayLayers(_ layer: CALayer?) {
        guard let layer else { return }
        layer.setNeedsDisplay()
        layer.displayIfNeeded()
        for child in layer.sublayers ?? [] { displayLayers(child) }
    }

    private func drawNativeControls(in view: NSView, root: NSView, context: CGContext,
                                    scaleX: CGFloat, scaleY: CGFloat) throws {
        guard !view.isHiddenOrHasHiddenAncestor else { return }
        if view is NSControl || view is NSTextView || view is NSTableHeaderView || view is PDFView {
            let rect = root.convert(view.bounds, from: view)
            var clipping = root.bounds
            var ancestor = view.superview
            while let current = ancestor, current !== root {
                if current is NSClipView { clipping = clipping.intersection(root.convert(current.bounds, from: current)) }
                ancestor = current.superview
            }
            if !rect.intersection(clipping).isEmpty,
               let native = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: native)
                if let image = native.cgImage {
                    func pixels(_ value: NSRect) -> CGRect {
                        CGRect(x: value.minX * scaleX, y: (root.bounds.height - value.maxY) * scaleY,
                               width: value.width * scaleX, height: value.height * scaleY)
                    }
                    context.saveGState()
                    context.clip(to: pixels(clipping))
                    context.draw(image, in: pixels(rect))
                    context.restoreGState()
                }
            }
            return
        }
        for child in view.subviews {
            try drawNativeControls(in: child, root: root, context: context, scaleX: scaleX, scaleY: scaleY)
        }
    }

    private func hasPixelVariation(_ bitmap: NSBitmapImageRep) -> Bool {
        guard let bytes = bitmap.bitmapData, bitmap.bitsPerPixel >= 24 else { return false }
        let stride = bitmap.bitsPerPixel / 8
        var first: UInt32?
        for y in Swift.stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 64)) {
            for x in Swift.stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 64)) {
                let offset = y * bitmap.bytesPerRow + x * stride
                let value = UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2])
                if let first, value != first { return true }
                first = value
            }
        }
        return false
    }

    private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private struct SnapshotRecord: Encodable {
        let id: String
        let file: String
        let requestedWidth: Double
        let requestedHeight: Double
        let renderedWidth: Double
        let renderedHeight: Double
        let fittingWidth: Double
        let fittingHeight: Double
        let pixelWidth: Int
        let pixelHeight: Int
        let sha256: String
        let scenario: String
    }

    private struct SnapshotManifest: Encodable {
        let formatVersion = 1
        let method = "Native NSHostingView layers and actual NSControl/NSView bitmap caches composed at native frames and clip rectangles; owned borderless NSWindow outside every display; no desktop input or accessibility automation."
        let appearance = "Aqua / light"
        let selectedLanguage: String
        let preferredLanguages: [String]
        let sourceFixtureName: String
        let sourceFixtureSHA256: String
        let windowsOrderedOnScreen = false
        let windowsOrderedOffScreen = true
        let interpretation = "These PNGs support human review of visible native controls. Dimensions and hashes are measured; no automatic clipping or linguistic completeness claim is made."
        let snapshots: [SnapshotRecord]
    }
}

#endif
