import Foundation

enum BackgroundCheckLaunch {
    static let argument = "--background-check-once"

    static func isRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains(argument)
    }
}

struct LaunchAutomation: Codable {
    private static let controlFileURL = URL(fileURLWithPath: "/tmp/timeweaver_launch_automation.json")

    enum Action: String, Codable {
        case preview
        case sync
    }

    var action: Action
    var outputPath: String
    var terminateAfterCompletion: Bool
    var sources: [SourceItem]?
    var workdayHours: WorkdayHours?
    var upcomingOnly: Bool?
    var parserMode: ParserMode?
    var aiProvider: AIProvider?
    var aiEndpointURL: String?
    var aiModel: String?
    var aiAPIKey: String?

    static func fromEnvironment() -> LaunchAutomation? {
        let environment = ProcessInfo.processInfo.environment
        guard let actionRaw = environment["TIMEWEAVER_AUTOTEST_ACTION"],
              let action = Action(rawValue: actionRaw),
              let outputPath = environment["TIMEWEAVER_AUTOTEST_OUTPUT"],
              !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let terminateAfterCompletion = environment["TIMEWEAVER_AUTOTEST_EXIT"] == "1"
        return LaunchAutomation(
            action: action,
            outputPath: outputPath,
            terminateAfterCompletion: terminateAfterCompletion,
            sources: nil,
            workdayHours: nil,
            upcomingOnly: nil,
            parserMode: nil,
            aiProvider: nil,
            aiEndpointURL: nil,
            aiModel: nil,
            aiAPIKey: nil
        )
    }

    static func load() -> LaunchAutomation? {
        if let fromEnvironment = fromEnvironment() {
            return fromEnvironment
        }
        guard let data = try? Data(contentsOf: controlFileURL),
              let automation = try? JSONDecoder().decode(LaunchAutomation.self, from: data) else {
            return nil
        }
        try? FileManager.default.removeItem(at: controlFileURL)
        return automation
    }

    static func save(_ automation: LaunchAutomation) throws {
        let data = try JSONEncoder().encode(automation)
        try data.write(to: controlFileURL)
    }
}
