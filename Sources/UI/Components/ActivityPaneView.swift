import SwiftUI
import AppKit

struct ActivityPaneView: View {
    @EnvironmentObject private var model: AppModel

    private var activityPlaceholder: (symbol: String, title: String, message: String)? {
        if model.ui.calendarAccessState == .notDetermined {
            return (
                "calendar.badge.exclamationmark",
                "Calendar access needed",
                "Click Grant Calendar Access once to load your calendars."
            )
        }
        if model.ui.calendarAccessState == .denied {
            return (
                "calendar.badge.exclamationmark",
                "Calendar access is off",
                "Open Calendar Settings, turn access on for \(appDisplayName), then refresh calendars."
            )
        }
        if model.ui.calendarAccessState == .restricted {
            return (
                "calendar.badge.exclamationmark",
                "Calendar access is restricted",
                "This Mac is blocking calendar access for \(appDisplayName). Check device or privacy restrictions."
            )
        }
        if model.ui.output.isEmpty {
            return (
                "clock.arrow.circlepath",
                "No activity yet",
                "Preview, sync, or drop an image to see activity here."
            )
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity")
                .font(.headline)
            Group {
                if model.ui.output.isEmpty, let placeholder = activityPlaceholder {
                    VStack(spacing: 10) {
                        Image(systemName: placeholder.symbol)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(placeholder.title)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Text(placeholder.message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(16)
                } else {
                    ScrollView(.vertical) {
                        Text(model.ui.output.isEmpty ? "No activity yet." : model.ui.output)
                            .font(.callout)
                            .textSelection(.enabled)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(10)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
