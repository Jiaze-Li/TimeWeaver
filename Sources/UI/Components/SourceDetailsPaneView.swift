import SwiftUI
import AppKit

struct SourceDetailsPaneView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    PaneHeader(
                        title: "Source Details",
                        subtitle: "Saved sheet sources can stay in the list without participating in sync. Dropped images are treated as one-time imports and do not replace the saved source."
                    )
                    Spacer(minLength: 8)
                    sourceEnabledToggle
                }

                VStack(alignment: .leading, spacing: 8) {
                    PaneHeader(
                        title: "Source Details",
                        subtitle: "Saved sheet sources can stay in the list without participating in sync. Dropped images are treated as one-time imports and do not replace the saved source."
                    )
                    sourceEnabledToggle
                }
            }

            FieldLabel(title: "Source")
            sourceFieldRow

            SourceDropZone { urls in
                model.handleDroppedSourceFiles(urls)
            }

            bookingFields

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 10) {
                    calendarPicker
                    if model.ui.calendarAccessState != .granted {
                        Button(model.ui.calendarAccessState.promptButtonTitle) {
                            clearInputFocus()
                            model.requestCalendarAccess()
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Refresh Calendars") {
                        clearInputFocus()
                        model.refreshCalendars()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                VStack(alignment: .leading, spacing: 10) {
                    calendarPicker
                    HStack(spacing: 10) {
                        if model.ui.calendarAccessState != .granted {
                            Button(model.ui.calendarAccessState.promptButtonTitle) {
                                clearInputFocus()
                                model.requestCalendarAccess()
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                        }
                        Button("Refresh Calendars") {
                            clearInputFocus()
                            model.refreshCalendars()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            clearInputFocus()
        }
    }

    @ViewBuilder
    private var bookingFields: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                bookingIDField
                eventTitleField
            }

            VStack(alignment: .leading, spacing: 10) {
                bookingIDField
                eventTitleField
            }
        }
    }

    private var sourceFieldRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 10) {
                sourceFieldInput
                browseSourceButton
            }

            VStack(alignment: .leading, spacing: 8) {
                sourceFieldInput
                browseSourceButton
            }
        }
    }

    private var bookingIDField: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(title: "Booking ID")
            TextField(defaultBookingID, text: deferredBinding(model: model, \.draftBookingID))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onChange(of: model.ui.draftBookingID) { _ in
                    model.draftFieldsChanged()
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var eventTitleField: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(title: "Event Title")
            TextField("ppms", text: deferredBinding(model: model, \.draftName))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onChange(of: model.ui.draftName) { _ in
                    model.draftFieldsChanged()
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var calendarPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(title: "Calendar")
            Picker("", selection: deferredBinding(model: model, \.draftCalendar)) {
                ForEach(calendarChoices, id: \.self) { calendar in
                    Text(calendar).tag(calendar)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: model.ui.draftCalendar) { _ in
                model.draftFieldsChanged()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceFieldInput: some View {
        TextField("Google Sheets link, local .xlsx workbook, or image path", text: deferredBinding(model: model, \.draftSource))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: model.ui.draftSource) { _ in
                model.draftFieldsChanged()
            }
    }

    private var browseSourceButton: some View {
        Button("Browse") {
            clearInputFocus()
            model.chooseSourceFile()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(minWidth: 88)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var sourceEnabledToggle: some View {
        Toggle("Use in sync", isOn: deferredBinding(model: model, \.draftEnabled))
            .toggleStyle(.checkbox)
            .fixedSize()
            .controlSize(.small)
            .help("When off, this source stays saved but is skipped during preview and sync.")
            .onChange(of: model.ui.draftEnabled) { _ in
                model.draftFieldsChanged()
            }
    }

    private var calendarChoices: [String] {
        var values = model.ui.calendars
        let current = model.ui.draftCalendar.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty && !values.contains(current) {
            values.insert(current, at: 0)
        }
        return values
    }
}
