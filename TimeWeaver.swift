import SwiftUI
import AppKit
import Foundation

#if TIMEWEAVER_TEST_RUNNER
import AppKit


@MainActor
private func writeSnapshot(to outputURL: URL, width: CGFloat, height: CGFloat) throws {
    let detailsOnly = ProcessInfo.processInfo.environment["TIMEWEAVER_SNAPSHOT_DETAILS_ONLY"] == "1"
    let sourceDetailsOnly = ProcessInfo.processInfo.environment["TIMEWEAVER_SNAPSHOT_SOURCE_DETAILS_ONLY"] == "1"
    let sidebarOnly = ProcessInfo.processInfo.environment["TIMEWEAVER_SNAPSHOT_SIDEBAR_ONLY"] == "1"
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
        if let outputPath = environment["TIMEWEAVER_SNAPSHOT_OUTPUT"] {
            let width = Double(environment["TIMEWEAVER_SNAPSHOT_WIDTH"] ?? "") ?? 980
            let height = Double(environment["TIMEWEAVER_SNAPSHOT_HEIGHT"] ?? "") ?? 900

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
            name: environment["TIMEWEAVER_TEST_SOURCE_NAME"] ?? "timeweaver",
            source: environment["TIMEWEAVER_TEST_SOURCE_URL"] ?? "https://docs.google.com/spreadsheets/d/1J7XCLh20n1qBkhBNyfF0XwnM2vItuOlGl6j5iQR1aVg/edit?usp=sharing",
            bookingID: environment["TIMEWEAVER_TEST_BOOKING_ID"] ?? defaultBookingID,
            calendar: environment["TIMEWEAVER_TEST_CALENDAR"] ?? defaultCalendarName
        )
        let parserMode = ParserMode(rawValue: environment["TIMEWEAVER_TEST_PARSER_MODE"] ?? "") ?? .rulesOnly
        let aiProvider = AIProvider(rawValue: environment["TIMEWEAVER_TEST_AI_PROVIDER"] ?? "")
            ?? inferAIProvider(fromEndpoint: environment["TIMEWEAVER_TEST_AI_ENDPOINT"] ?? "")
        let aiConfiguration: AIServiceConfiguration? = {
            guard
                let endpoint = environment["TIMEWEAVER_TEST_AI_ENDPOINT"],
                let apiKey = environment["TIMEWEAVER_TEST_AI_KEY"],
                let url = URL(string: endpoint)
            else {
                return nil
            }
            let model = environment["TIMEWEAVER_TEST_AI_MODEL"] ?? ""
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
                timeZone: TimeZone(identifier: environment["TIMEWEAVER_TEST_SCHEDULING_TZ"] ?? defaultSchedulingTimeZoneIdentifier) ?? .current
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
                schedulingTimeZoneIdentifier: environment["TIMEWEAVER_TEST_SCHEDULING_TZ"] ?? defaultSchedulingTimeZoneIdentifier
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

private final class TimeWeaverAppDelegate: NSObject, NSApplicationDelegate {
    private var backgroundModel: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard BackgroundCheckLaunch.isRequested() else { return }
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            let model = AppModel()
            self.backgroundModel = model
            guard model.ui.autoSyncEnabled else {
                NSApp.terminate(nil)
                return
            }
            model.checkAndReviewCalendarChanges()
        }
    }
}

/// Choose the GUI or no-window entry point before SwiftUI creates scenes.
@main
enum TimeWeaverLauncher {
    static func main() {
        if BackgroundCheckLaunch.isRequested() {
            BackgroundTimeWeaverApp.main()
        } else {
            TimeWeaverApp.main()
        }
    }
}

struct BackgroundTimeWeaverApp: App {
    @NSApplicationDelegateAdaptor(TimeWeaverAppDelegate.self) private var delegate

    var body: some Scene {
        // A settings-only app creates no main window during a cold check.
        Settings {
            EmptyView()
        }
    }
}

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
