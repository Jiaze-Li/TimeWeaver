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
            path: "Sources",
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
                "UI/UIState.swift"
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
