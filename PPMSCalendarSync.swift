import SwiftUI
import AppKit
import Foundation

#if PPMS_TEST_RUNNER
import AppKit


@MainActor
private func writeSnapshot(to outputURL: URL, width: CGFloat, height: CGFloat) throws {
    let detailsOnly = ProcessInfo.processInfo.environment["PPMS_SNAPSHOT_DETAILS_ONLY"] == "1"
    let sourceDetailsOnly = ProcessInfo.processInfo.environment["PPMS_SNAPSHOT_SOURCE_DETAILS_ONLY"] == "1"
    let sidebarOnly = ProcessInfo.processInfo.environment["PPMS_SNAPSHOT_SIDEBAR_ONLY"] == "1"
    let model = AppModel()
    let base = ContentView()
    let content = Group {
        if sidebarOnly {
            base.sidebarPane
                .environmentObject(model)
                .padding(16)
        } else if sourceDetailsOnly {
            base.sourceDetailsPane
                .environmentObject(model)
                .padding(16)
        } else if detailsOnly {
            base.detailColumn
                .environmentObject(model)
                .padding(16)
        } else {
            base.environmentObject(model)
        }
    }
    .frame(width: width, height: height)
    .background(Color.white)

    let renderer = ImageRenderer(content: content)
    renderer.scale = 2

    guard let cgImage = renderer.cgImage else {
        throw AppFailure.syncFailed("Failed to render UI snapshot.")
    }

    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    guard let pngData = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
        throw AppFailure.syncFailed("Failed to encode UI snapshot as PNG.")
    }

    try pngData.write(to: outputURL)
}

@main
struct TimeWeaverTestRunner {
    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        if let outputPath = environment["PPMS_SNAPSHOT_OUTPUT"] {
            let width = Double(environment["PPMS_SNAPSHOT_WIDTH"] ?? "") ?? 980
            let height = Double(environment["PPMS_SNAPSHOT_HEIGHT"] ?? "") ?? 900

            do {
                try await MainActor.run {
                    try writeSnapshot(
                        to: URL(fileURLWithPath: outputPath),
                        width: width,
                        height: height
                    )
                }
                print("Wrote snapshot: \(outputPath)")
                return
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                Foundation.exit(1)
            }
        }

        let source = SourceItem(
            name: environment["PPMS_TEST_SOURCE_NAME"] ?? "ppms",
            source: environment["PPMS_TEST_SOURCE_URL"] ?? "https://docs.google.com/spreadsheets/d/1J7XCLh20n1qBkhBNyfF0XwnM2vItuOlGl6j5iQR1aVg/edit?usp=sharing",
            bookingID: environment["PPMS_TEST_BOOKING_ID"] ?? "LJZ",
            calendar: environment["PPMS_TEST_CALENDAR"] ?? "Experiment"
        )
        let parserMode = ParserMode(rawValue: environment["PPMS_TEST_PARSER_MODE"] ?? "") ?? .rulesOnly
        let aiProvider = AIProvider(rawValue: environment["PPMS_TEST_AI_PROVIDER"] ?? "")
            ?? inferAIProvider(fromEndpoint: environment["PPMS_TEST_AI_ENDPOINT"] ?? "")
        let aiConfiguration: AIServiceConfiguration? = {
            guard
                let endpoint = environment["PPMS_TEST_AI_ENDPOINT"],
                let apiKey = environment["PPMS_TEST_AI_KEY"],
                let url = URL(string: endpoint)
            else {
                return nil
            }
            let model = environment["PPMS_TEST_AI_MODEL"] ?? ""
            if aiProvider == .custom && model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nil
            }
            return AIServiceConfiguration(provider: aiProvider, endpointURL: url, apiKey: apiKey, model: model)
        }()
        do {
            let result = try await ReservationExtractor.extract(
                source: source,
                workdayHours: defaultWorkdayHours(),
                upcomingOnly: false,
                parserMode: parserMode,
                aiConfiguration: aiConfiguration,
                timeZone: TimeZone(identifier: environment["PPMS_TEST_SCHEDULING_TZ"] ?? defaultSchedulingTimeZoneIdentifier) ?? .current
            )
            print("All matched reservations: \(result.allEvents.count)")
            print("Parser: \(result.parserLabel)")
            print("Review required: \(result.reviewRequired)")
            for event in result.allEvents {
                let prefix = event.isAllDay ? "all-day" : "timed"
                print("\(prefix)\t\(iso8601(event.start))\t\(iso8601(event.end))\t\(event.sourceName)")
            }
            let preview = try await CalendarSyncEngine().sync(
                sources: [source],
                workdayHours: defaultWorkdayHours(),
                upcomingOnly: true,
                previewOnly: true,
                parserMode: parserMode,
                aiConfiguration: aiConfiguration,
                aiApprovals: [],
                schedulingTimeZoneIdentifier: environment["PPMS_TEST_SCHEDULING_TZ"] ?? defaultSchedulingTimeZoneIdentifier
            )
            print("")
            print("Preview output:")
            print(preview.outputText)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            let details = String(describing: error)
            if details != error.localizedDescription {
                fputs("\(details)\n", stderr)
            }
            Foundation.exit(1)
        }
    }
}
#else
private func applyAppPresentation(menuBarModeEnabled: Bool) {
    NSApp.setActivationPolicy(menuBarModeEnabled ? .accessory : .regular)
}

@main
struct TimeWeaverApp: App {
    @StateObject private var model = AppModel()
    @State private var menuBarExtraInserted = false

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    syncAppPresentation(to: model.ui.menuBarModeEnabled)
                }
                .onChange(of: model.ui.menuBarModeEnabled) { enabled in
                    syncAppPresentation(to: enabled)
                }
        }
        .defaultSize(width: 1180, height: 900)

        MenuBarExtra(appDisplayName, systemImage: "calendar.badge.clock", isInserted: $menuBarExtraInserted) {
            MenuBarContentView()
                .environmentObject(model)
        }
    }

    private func syncAppPresentation(to enabled: Bool) {
        if menuBarExtraInserted != enabled {
            menuBarExtraInserted = enabled
        }
        applyAppPresentation(menuBarModeEnabled: enabled)
    }
}
#endif
