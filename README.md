# PPMS Calendar Sync

PPMS Calendar Sync is a native macOS app that reads Google Sheets booking workbooks, matches reservations by booking ID, and writes the matching time slots into Apple Calendar.

The app is designed for lab equipment booking sheets that use monthly tabs and slot-based rows such as `8:30-1pm`, `1pm-6pm`, and `overnight`.

## Features

- Native macOS app built with SwiftUI and EventKit
- Multiple sheet sources in one app
- Per-source booking ID, title, and target calendar
- Custom slot time mapping
- Preview before sync
- Automatic polling while the app is open
- Incremental sync without duplicate calendar events
- No automatic deletes; removed bookings are only surfaced as manual delete candidates

## What It Syncs

For each enabled source, the app:

1. Downloads or opens the workbook
2. Scans month-named tabs
3. Finds cells whose content matches the configured booking ID
4. Converts each matching slot into a calendar event using the configured slot-time rules
5. Merges adjacent slots into continuous events
6. Creates or updates the matching Apple Calendar events

Event title:

- Uses the source name, for example `ppms`

Event notes:

- Stores only the original sheet link

## Safety Defaults

- Default calendar is chosen per source
- Default filter is `Only upcoming reservations`
- Preview mode does not write to Calendar
- Sync mode creates and updates events
- Deleted or removed bookings are never deleted automatically

## Requirements

- macOS 13 or later
- Calendar access granted to the app
- A public Google Sheets link or a local `.xlsx` workbook
- Swift toolchain with Apple frameworks available on the build machine

## Build

From the project directory:

```bash
chmod +x ./build_native_app.sh
./build_native_app.sh
```

This builds the app bundle into:

```text
./build/PPMS Calendar Sync.app
```

To build directly to another location:

```bash
./build_native_app.sh "/Users/yourname/Desktop/PPMS Calendar Sync.app"
```

## Usage

1. Launch the app.
2. Grant Calendar access when macOS asks.
3. Add one or more sources.
4. For each source, provide:
   - sheet link or local workbook path
   - booking ID
   - event title
   - target Apple Calendar
5. Adjust slot times if your sheet uses a different booking schedule.
6. Run `Preview` to inspect matches and planned changes.
7. Run `Sync Enabled Sources` to write events into Calendar.

## Automation

- `Auto sync while the app is open` enables periodic sync
- The polling interval is configurable in minutes
- The app only adds or updates events it owns

## Project Structure

- `PPMSCalendarSync.swift` — app source
- `Info.plist` — app bundle metadata
- `build_native_app.sh` — local build script

## Release Readiness

This repository is structured so it can be published to GitHub directly after final review. Before a public release, you may want to add:

- app screenshots
- a project license
- notarization and Developer ID signing
- CI packaging and release automation
