import Foundation

struct XLSXPackage {
    let rootURL: URL

    init(xlsxURL: URL) throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ppms-xlsx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-qq", xlsxURL.path, "-d", tempDir.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw AppFailure.syncFailed("Could not unpack workbook.")
        }
        rootURL = tempDir
    }

    func data(at relativePath: String) throws -> Data {
        let fileURL = rootURL.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: fileURL) else {
            throw AppFailure.missingWorkbookData(relativePath)
        }
        return data
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

struct ParsedWorkbookSheet {
    var name: String
    var year: Int?
    var month: Int?
    var worksheet: WorksheetParser
}
