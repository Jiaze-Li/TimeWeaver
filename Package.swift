// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TimeWeaver",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "TimeWeaverCore",
            targets: ["TimeWeaverCore"]
        ),
        .library(
            name: "TimeWeaverAppLogic",
            targets: ["TimeWeaverAppLogic"]
        )
    ],
    targets: [
        .target(
            name: "TimeWeaverCore",
            path: "Sources/TimeWeaverCore"
        ),
        // TimeWeaverAppLogic manually enumerates source files because the target
        // spans multiple subdirectories (Models, Storage, UI) within Sources/.
        // Files that depend on AppKit or are UI-only (AppModel*, ContentView, etc.)
        // are intentionally excluded so this target remains testable without a display.
        .target(
            name: "TimeWeaverAppLogic",
            dependencies: ["TimeWeaverCore"],
            path: "Sources",
            exclude: [
                "TimeWeaverCore",
                "UI/AppModel.swift",
                "UI/AppModel+Automation.swift",
                "UI/AppModel+ImageImport.swift",
                "UI/AppModel+Persistence.swift",
                "UI/AppModel+SourcesAndCalendars.swift",
                "UI/AppModel+SyncFlow.swift",
                "UI/Components",
                "UI/ContentView.swift",
                "UI/ImageImportReviewSheet.swift",
                "UI/AutoReviewWindowView.swift"
            ],
            sources: [
                "Models/AppIdentity.swift",
                "Models/SourceItem.swift",
                "Models/ParserAIModels.swift",
                "Models/Defaults.swift",
                "Models/AppSettings.swift",
                "Models/LaunchAutomation.swift",
                "Models/SyncModels.swift",
                "Models/SyncState.swift",
                "Storage/Stores.swift",
                "Storage/SettingsCoordinator.swift",
                "UI/UIState.swift",
                "Sync/CalendarStoreProtocol.swift",
                "Sync/SyncStateStoreProtocol.swift",
                "Sync/ParserProtocols.swift",
                "Sync/SyncUtilities.swift",
                "Sync/CalendarSyncEngine.swift",
                "Sync/CalendarSyncEngine+EventLookup.swift",
                "Sync/CalendarSyncEngine+Mutation.swift",
                "Sync/CalendarSyncEngine+Orchestration.swift",
                "Sync/ReservationExtractor.swift",
                "Parsers/SourceIOUtilities.swift",
                "Parsers/DateTimeParsingUtilities.swift",
                "Parsers/XLSXPackage.swift",
                "Parsers/WorksheetParser.swift",
                "Parsers/XMLWorkbookParsers.swift",
                "Parsers/LocalImageParser.swift",
                "Parsers/AIWorkbookNormalizer.swift",
                "Parsers/AIWorkbookNormalizer+Snapshot.swift",
                "Parsers/AIWorkbookNormalizer+Resolution.swift",
                "Parsers/AIWorkbookNormalizer+ImageFlow.swift",
                "Parsers/AIWorkbookNormalizer+Transport.swift"
            ]
        ),
        .testTarget(
            name: "TimeWeaverCoreTests",
            dependencies: ["TimeWeaverCore"],
            path: "Tests/TimeWeaverCoreTests"
        ),
        .testTarget(
            name: "TimeWeaverAppLogicTests",
            dependencies: ["TimeWeaverAppLogic"],
            path: "Tests/TimeWeaverAppLogicTests"
        )
    ]
)
