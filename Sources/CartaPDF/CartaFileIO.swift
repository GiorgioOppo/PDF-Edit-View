import Foundation

enum CartaFileIO {
    static func atomicWrite(_ data: Data, to destination: URL, replaceExisting: Bool = true) throws {
        try Task.checkCancellation()
        let manager = FileManager.default, parent = destination.deletingLastPathComponent()
        let values = try? parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values?.volumeAvailableCapacityForImportantUsage, capacity < Int64(data.count) + 1_048_576 {
            throw CartaAutomationError.message(L10n.tr("Spazio insufficiente per scrivere il file e la copia temporanea."))
        }
        var isDirectory: ObjCBool = false
        let exists = manager.fileExists(atPath: destination.path, isDirectory: &isDirectory)
        if isDirectory.boolValue { throw CartaAutomationError.message(L10n.tr("L’output è una cartella.")) }
        if exists && !replaceExisting { throw CocoaError(.fileWriteFileExists) }
        let temporary = parent.appendingPathComponent(".CartaPDF-\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        var committed = false
        defer { if !committed { try? manager.removeItem(at: temporary) } }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            let chunk = 1_048_576
            var offset = 0
            while offset < data.count {
                try Task.checkCancellation()
                let end = min(offset + chunk, data.count)
                try handle.write(contentsOf: data[offset..<end])
                offset = end
            }
            try handle.synchronize()
            try handle.close()
        } catch { try? handle.close(); throw error }
        try Task.checkCancellation()
        if manager.fileExists(atPath: destination.path) {
            guard replaceExisting else { throw CocoaError(.fileWriteFileExists) }
            _ = try manager.replaceItemAt(destination, withItemAt: temporary)
        } else { try manager.moveItem(at: temporary, to: destination) }
        committed = true
    }
}
