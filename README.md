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
- Auto sync while the app is open
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

## Build

From the project directory:

```bash
chmod +x ./build_native_app.sh
./build_native_app.sh
```

This builds:

```text
./build/TimeWeaver.app
```

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

For migration stability, the app still stores local data under the legacy support directory:

```text
~/Library/Application Support/PPMSCalendarSync
```

Keychain entries also still use the legacy service name:

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

- `PPMSCalendarSync.swift` — main app source
- `Info.plist` — bundle metadata
- `build_native_app.sh` — app bundle build script
- `create_dmg.sh` — DMG packaging script
- `DEVELOPMENT_LOG.md` — full project history, preferences, and handoff log
