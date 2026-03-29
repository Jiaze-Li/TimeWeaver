import Foundation

func normalizeWorkbookPath(_ target: String) -> String {
    if target.hasPrefix("xl/") {
        return target
    }
    if target.hasPrefix("/xl/") {
        return String(target.dropFirst())
    }
    return "xl/\(target)"
}

func imageMimeType(for url: URL) -> String? {
    switch url.pathExtension.lowercased() {
    case "png":
        return "image/png"
    case "jpg", "jpeg":
        return "image/jpeg"
    case "webp":
        return "image/webp"
    case "gif":
        return "image/gif"
    case "heic":
        return "image/heic"
    case "heif":
        return "image/heif"
    default:
        return nil
    }
}

func localImageURL(from source: String) -> URL? {
    let expanded = NSString(string: source).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: expanded) else {
        return nil
    }
    let url = URL(fileURLWithPath: expanded)
    guard imageMimeType(for: url) != nil else {
        return nil
    }
    return url
}

func downloadWorkbook(from source: String) async throws -> URL {
    let expanded = NSString(string: source).expandingTildeInPath
    if FileManager.default.fileExists(atPath: expanded) {
        return URL(fileURLWithPath: expanded)
    }

    let downloadURL: URL
    if source.contains("docs.google.com/spreadsheets") {
        let pattern = "/d/([a-zA-Z0-9-_]+)"
        let regex = try! NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source) else {
            throw AppFailure.invalidSource
        }
        let sheetID = String(source[range])
        guard let url = URL(string: "https://docs.google.com/spreadsheets/d/\(sheetID)/export?format=xlsx") else {
            throw AppFailure.invalidSource
        }
        downloadURL = url
    } else if let url = URL(string: source), let scheme = url.scheme, scheme.hasPrefix("http") {
        downloadURL = url
    } else {
        throw AppFailure.unsupportedSource(source)
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 60
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpAdditionalHeaders = [
        "User-Agent": "PPMSCalendarSync/1.0"
    ]
    let session = URLSession(configuration: configuration)
    let request = URLRequest(url: downloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    let (tempURL, response) = try await session.download(for: request)
    if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
        throw AppFailure.syncFailed("Workbook download failed with HTTP \(httpResponse.statusCode).")
    }
    let finalURL = FileManager.default.temporaryDirectory.appendingPathComponent("ppms-\(UUID().uuidString).xlsx")
    try? FileManager.default.removeItem(at: finalURL)
    try FileManager.default.moveItem(at: tempURL, to: finalURL)
    return finalURL
}
