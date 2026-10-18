# TimeWeaver

TimeWeaver is a native macOS app that turns sheets, timetables, and images into Apple Calendar events.

It started as a PPMS booking sync tool and has since been generalized into a customer-facing import-and-sync desktop app.

## What It Does

- Reads Google Sheets links, local `.xlsx` workbooks, and supported timetable images
- Matches entries by `Booking ID`
- Writes matching reservations into a chosen Apple Calendar
- Supports preview, sync, update, and optional removal of events that were previously created by the app
- Supports one-off image import and ongoing sheet automation in the same app
- Supports built-in parsing, AI parsing, and provider-specific fallbacks

## Current Product Direction

TimeWeaver is no longer positioned as a PPMS-only utility. The product goal is:

- a general sheet/image to calendar tool
- compact but readable desktop UI
- explicit main actions instead of hidden toolbar flows
- customer-friendly wording instead of technical parser logs
- minimal customer setup for supported AI providers

## Current Features

- Native macOS app built with SwiftUI and EventKit
- Multiple saved sources
- Adjustable split view between left and right columns
- Preview before sync
- Sync confirmation with change counts
- Optional confirmation before deleting removed events
- Auto review while the app is open, with optional scheduled cold checks when closed
- Optional menu bar mode
- Drag-and-drop image import with immediate preview/confirm flow
- AI providers with presets:
  - OpenAI
  - Gemini
  - Anthropic / Claude
  - Kimi
  - DeepSeek (text only)
  - Custom
- Local timetable image parser for structured schedule images, so some image imports do not require any API key

## Build & Test

### Run Unit and Integration Tests

```bash
swift test
```

### Build Native App

From the project directory:

```bash
chmod +x ./build_native_app.sh
./build_native_app.sh
```

This builds:

```text
./build/TimeWeaver.app
```

For architecture details, synchronization workflow, and system constraints, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Optional scheduled background checks

With the optional macOS **user LaunchAgent**, the same **Automation → Interval (minutes)**
setting controls checks both while TimeWeaver is open and after it has quit (minimum 1 minute).
A lightweight shell gate reads the saved settings every minute and only launches TimeWeaver
when the selected interval has elapsed. It **does not** download or parse any sheets during
intermediate ticks. Changing the interval or disabling Auto sync in the UI takes effect
without reinstalling the LaunchAgent, once the setting has been saved.

When nothing has changed, the app exits without opening its main window.
When there are changes, the usual Review dialog appears; Accept or Ignore then exits
the cold-check process. Checks never write to calendars before Accept.

After building the app and enabling **Auto sync while the app is open**, install once:

```bash
./build_native_app.sh
./scripts/install_background_check.sh
```

If you use an app outside the build folder (for example, your Desktop copy), pass
its absolute path as the first argument to the install script. Keep the app path stable,
or rerun the installer if it moves. **If upgrading from the old fixed 10-minute
LaunchAgent, rerun the installer once** to replace its launchd configuration. Future
interval changes only require editing the TimeWeaver setting.

The Mac must be awake with the user logged in. launchd is not a precise scheduler:
checks may be delayed around the minute boundary or after sleep. If TimeWeaver is
already running, macOS reuses the existing app and its in-app timer handles checking.

To turn off cold checks, disable Auto sync, or uninstall completely:

```bash
./scripts/uninstall_background_check.sh
```

Ignored batches are saved to `ignored-reviews.json`; open **Automation → Ignored Changes**
and click **Review Again** to fetch a fresh preview, then choose Accept or Ignore.
The saved snapshot is never directly executed.

## Build a DMG

```bash
chmod +x ./create_dmg.sh
./create_dmg.sh
```

This creates:

```text
./build/TimeWeaver.dmg
```

## Release Artifacts

Local release artifacts are expected here:

- `build/TimeWeaver.app`
- `build/TimeWeaver.dmg`

The DMG is the primary customer-facing download.

## Runtime Requirements

- macOS 13 or later
- Calendar access granted to the app
- Public Google Sheets link, local `.xlsx`, or supported timetable image
- API key only when an AI provider is needed

## Data and Settings

App data is now stored under Bundle ID:

```text
~/Library/Application Support/com.jiaze.timeweaver
```

On first launch after upgrading, files from the legacy directory below are copied automatically if the new location is empty:

```text
~/Library/Application Support/PPMSCalendarSync
```

Keychain entries still use the legacy service name (for backward compatibility):

```text
PPMSCalendarSync
```

This is intentional so existing users do not lose settings during the rename to TimeWeaver.

## Packaging / Publishing Notes

- App bundle name: `TimeWeaver.app`
- Desktop build target used during local QA: `/Users/jack/Desktop/TimeWeaver.app`
- The project is suitable for GitHub publication
- Before external customer distribution, prefer rotating any API keys that were ever used in local testing

## Important Product Notes

- Complex structured timetable images should prefer the local timetable parser first
- Gemini is currently the strongest provider for difficult image interpretation
- DeepSeek is currently treated as text-only in this app
- Customer-facing output should stay concise and non-technical

## Project Files

- `TimeWeaver.swift` — app shell and UI entry point
- `Sources/Models/SourceItem.swift` — source model and workday/slot baseline structs
- `Sources/Models/AppSettings.swift` — persisted settings and AI approval model
- `Sources/Models/SyncState.swift` — sync-state storage model
- `Sources/TimeWeaverCore/SyncDecisionLogic.swift` — parser fallback and sync decision logic
- `Tests/TimeWeaverCoreTests/SyncDecisionLogicTests.swift` — unit tests for fallback, mutation, and fingerprint logic
- `Sources/Sync/CalendarSyncEngine.swift` — reservation extraction and calendar sync engine
- `Sources/Storage/Stores.swift` — settings/keychain persistence and migration
- `Sources/Parsers/AIWorkbookNormalizer.swift` — AI workbook/image normalization and provider request flow
- `Sources/Parsers/LocalImageParser.swift` — local timetable image parser and OCR/color heuristics
- `Sources/Parsers/XMLWorkbookParsers.swift` — workbook/sharedStrings/relationship XML parsing
- `Sources/Parsers/WorksheetParser.swift` — worksheet cell extraction parser
- `Sources/Parsers/XLSXPackage.swift` — workbook unzip and file access wrapper
- `Sources/UI/Components/` — reusable UI component split target (next step)
- `Info.plist` — bundle metadata
- `build_native_app.sh` — app bundle build script
- `create_dmg.sh` — DMG packaging script
- `ARCHITECTURE.md` — system architecture, synchronization data flow, and key constraints
- `DEVELOPMENT_LOG.md` — archived historical development log
