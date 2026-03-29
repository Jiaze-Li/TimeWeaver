import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var quickActionsWidth: CGFloat = 0

    private enum QuickActionLayoutMode {
        case singleRow
        case pairedRows
        case singleColumn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerPane
            primaryActionsPane

            HSplitView {
                sidebarPane
                    .frame(minWidth: 150, idealWidth: 205, maxWidth: 320, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)

                ScrollView {
                    detailColumn
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(minWidth: 640, minHeight: 620)
        .overlay(syncLoadingOverlay)
        .sheet(item: $model.ui.pendingImageImportReview) { review in
            ImageImportReviewSheet(review: review)
                .environmentObject(model)
        }
        .alert(item: $model.ui.pendingSyncConfirmation) { confirmation in
            Alert(
                title: Text("Confirm Sync"),
                message: Text(confirmation.message),
                primaryButton: .default(Text("Continue")) {
                    model.confirmPendingSync()
                },
                secondaryButton: .cancel(Text("Cancel")) {
                    model.cancelPendingSync()
                }
            )
        }
    }

    @ViewBuilder
    private var syncLoadingOverlay: some View {
        if model.ui.isBusy {
            ZStack {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(model.ui.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 220)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .shadow(radius: 8)
            }
        }
    }

    private func deferredBinding<Value: Equatable>(_ keyPath: WritableKeyPath<UIState, Value>) -> Binding<Value> {
        Binding(
            get: { model.ui[keyPath: keyPath] },
            set: { newValue in
                guard model.ui[keyPath: keyPath] != newValue else { return }
                DispatchQueue.main.async {
                    model.ui[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func clearInputFocus() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        NSApp.mainWindow?.makeFirstResponder(nil)
    }

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

    var detailColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            editorPane
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var summaryPane: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                SummaryCard(title: "Sources", value: "\(model.ui.sources.count)", symbol: "square.stack.3d.up")
                SummaryCard(title: "Active", value: "\(model.ui.sources.filter(\.enabled).count)", symbol: "checkmark.circle")
                SummaryCard(title: "Calendars", value: "\(model.ui.calendars.count)", symbol: "calendar")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 94), spacing: 8)], spacing: 8) {
                SummaryCard(title: "Sources", value: "\(model.ui.sources.count)", symbol: "square.stack.3d.up")
                    .frame(maxWidth: .infinity, alignment: .leading)
                SummaryCard(title: "Active", value: "\(model.ui.sources.filter(\.enabled).count)", symbol: "checkmark.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                SummaryCard(title: "Calendars", value: "\(model.ui.calendars.count)", symbol: "calendar")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var sidebarPane: some View {
        VSplitView {
            sourcesPane
                .frame(minHeight: 120, idealHeight: 220, maxHeight: .infinity, alignment: .topLeading)
            outputPane
                .frame(minHeight: 160, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            clearInputFocus()
        }
    }

    private var headerPane: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appDisplayName)
                            .font(.title2.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(appTagline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    headerStatusPane
                        .frame(maxWidth: 360, alignment: .leading)
                }

                Spacer(minLength: 12)

                summaryPane
                    .frame(idealWidth: 240, maxWidth: 300, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appDisplayName)
                        .font(.title2.weight(.semibold))
                    Text(appTagline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                headerStatusPane
                summaryPane
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            clearInputFocus()
        }
    }

    private var headerStatusPane: some View {
        HStack(alignment: .center, spacing: 8) {
            if model.ui.isBusy || model.ui.isCalendarLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Text(model.ui.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    // Manage Sources has 3 buttons, Run Sync has 5 — split 3:5
    private var manageSourcesMaxWidth: CGFloat {
        quickActionsWidth > 0 ? (quickActionsWidth - 12) * 3 / 8 : .infinity
    }
    private var runSyncMaxWidth: CGFloat {
        quickActionsWidth > 0 ? (quickActionsWidth - 12) * 5 / 8 : .infinity
    }

    private var primaryActionsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Actions")
                .font(.headline)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    manageSourcesPane(layout: .singleRow)
                        .frame(maxWidth: manageSourcesMaxWidth, alignment: .topLeading)
                    runSyncPane(layout: .singleRow)
                        .frame(maxWidth: runSyncMaxWidth, alignment: .topLeading)
                }

                HStack(alignment: .top, spacing: 12) {
                    manageSourcesPane(layout: .pairedRows)
                        .frame(maxWidth: manageSourcesMaxWidth, alignment: .topLeading)
                    runSyncPane(layout: .pairedRows)
                        .frame(maxWidth: runSyncMaxWidth, alignment: .topLeading)
                }

                VStack(alignment: .leading, spacing: 10) {
                    manageSourcesPane(layout: .singleColumn)
                    Divider()
                    runSyncPane(layout: .singleColumn)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { quickActionsWidth = geo.size.width }
                .onChange(of: geo.size.width) { quickActionsWidth = $0 }
        })
        .contentShape(Rectangle())
        .onTapGesture {
            clearInputFocus()
        }
    }

    @ViewBuilder
    private func manageSourcesPane(layout: QuickActionLayoutMode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Manage Sources")
                .font(.subheadline.weight(.semibold))
            switch layout {
            case .singleRow:
                HStack(spacing: 8) {
                    newSourceButton
                    saveSourceButton
                    removeSourceButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .pairedRows:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        newSourceButton
                        saveSourceButton
                    }
                    HStack(spacing: 8) {
                        removeSourceButton
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .singleColumn:
                VStack(alignment: .leading, spacing: 8) {
                    newSourceButton
                    saveSourceButton
                    removeSourceButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
    }

    @ViewBuilder
    private func runSyncPane(layout: QuickActionLayoutMode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run Sync")
                .font(.subheadline.weight(.semibold))
            switch layout {
            case .singleRow:
                HStack(spacing: 8) {
                    previewButton
                    syncButton
                    approveAIButton
                    openCalendarButton
                    undoImportButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .pairedRows:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        previewButton
                        syncButton
                    }
                    HStack(spacing: 8) {
                        approveAIButton
                        openCalendarButton
                        undoImportButton
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .singleColumn:
                VStack(alignment: .leading, spacing: 8) {
                    previewButton
                    syncButton
                    approveAIButton
                    openCalendarButton
                    undoImportButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.ui.pendingAIReviews.isEmpty {
                Text("\(model.ui.pendingAIReviews.count) source(s) need AI approval before low-confidence sync can run.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
    }

    private var newSourceButton: some View {
        Button {
            clearInputFocus()
            model.newSource()
        } label: {
            Label("New", systemImage: "plus")
        }
        .buttonStyle(.bordered)
    }

    private var saveSourceButton: some View {
        Button {
            clearInputFocus()
            model.saveCurrentSource()
        } label: {
            Label("Save", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.bordered)
    }

    private var removeSourceButton: some View {
        Button(role: .destructive) {
            clearInputFocus()
            model.removeSelectedSource()
        } label: {
            Label("Remove", systemImage: "trash")
        }
        .buttonStyle(.bordered)
        .disabled(model.ui.selectedSourceID == nil)
    }

    private var previewButton: some View {
        Button {
            clearInputFocus()
            model.previewAll()
        } label: {
            Label("Preview", systemImage: "eye")
        }
        .buttonStyle(.bordered)
        .disabled(model.ui.isBusy)
    }

    private var syncButton: some View {
        Button {
            clearInputFocus()
            model.syncAll()
        } label: {
            Label("Sync", systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.ui.isBusy)
    }

    private var openCalendarButton: some View {
        Button {
            clearInputFocus()
            model.openCalendarApp()
        } label: {
            Label("Calendar", systemImage: "calendar")
        }
        .buttonStyle(.bordered)
    }

    private var approveAIButton: some View {
        Button {
            clearInputFocus()
            model.approvePendingAIReviews()
        } label: {
            Label("Approve AI", systemImage: "checkmark.shield")
        }
        .buttonStyle(.bordered)
        .disabled(model.ui.pendingAIReviews.isEmpty || model.ui.isBusy)
    }

    private var undoImportButton: some View {
        Button(role: .destructive) {
            clearInputFocus()
            model.undoLastImageImport()
        } label: {
            Label("Undo Import", systemImage: "arrow.uturn.backward")
        }
        .buttonStyle(.bordered)
        .disabled(model.ui.lastImageImportUndo == nil || model.ui.isBusy)
    }

    private var outputPane: some View {
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

    private var sourcesPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sources")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.ui.sources) { item in
                        Button {
                            clearInputFocus()
                            model.selectSource(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    sourceStatusIcon(for: item)
                                    Text(item.name)
                                        .lineLimit(1)
                                    Spacer(minLength: 6)
                                    if !item.enabled {
                                        Text("Off")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                Capsule()
                                                    .fill(Color.secondary.opacity(0.12))
                                            )
                                    }
                                }
                                Text(sourceStatusSummary(for: item))
                                    .font(.caption)
                                    .foregroundStyle(sourceStatusColor(for: item))
                                    .lineLimit(1)
                                Text("\(item.bookingID) -> \(item.calendar)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(model.ui.selectedSourceID == item.id ? Color.accentColor.opacity(0.12) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .help(sourceStatusHelp(for: item))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var editorPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            sourceDetailsPane
            aiParsingPane
            defaultHoursPane
            automationPane
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

    private var defaultHoursPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            PaneHeader(
                title: "Default Work Hours",
                subtitle: "Used only when a sheet shows dates without specific times. If the sheet already includes exact times, those times win automatically."
            )

            WorkdayHoursEditor(start: deferredBinding(\.workdayStart), end: deferredBinding(\.workdayEnd))
                .onChange(of: model.ui.workdayStart) { _ in
                    model.workdayChanged()
                }
                .onChange(of: model.ui.workdayEnd) { _ in
                    model.workdayChanged()
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            clearInputFocus()
        }
    }

    var sourceDetailsPane: some View {
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

    private var aiParsingPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            PaneHeader(
                title: "AI Parsing",
                subtitle: "For most customers, setup is just: choose a supported AI platform, paste the API key, and let the app fill the endpoint and default model."
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    FieldLabel(title: "Parser Mode")
                    Text("(\(model.ui.parserMode.inlineSummary))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("", selection: deferredBinding(\.parserMode)) {
                    ForEach(ParserMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: model.ui.parserMode) { _ in
                    model.parserSettingsChanged()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(title: "AI Platform")
                HStack(spacing: 10) {
                    Picker("", selection: deferredBinding(\.aiProvider)) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.pickerTitle).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 180, maxWidth: 280, alignment: .leading)
                    .onChange(of: model.ui.aiProvider) { _ in
                        model.aiProviderChanged()
                    }
                    Spacer(minLength: 0)
                }
                Text(model.ui.aiProvider.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(title: "API Key")
                SecureField("Stored in macOS Keychain", text: deferredBinding(\.aiAPIKey))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onChange(of: model.ui.aiAPIKey) { _ in
                        model.parserSettingsChanged()
                    }
            }

            DisclosureGroup(isExpanded: deferredBinding(\.showAdvancedAISettings)) {
                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 10) {
                            aiEndpointField
                            aiModelField
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            aiEndpointField
                            aiModelField
                        }
                    }
                    Text("Supported platforms auto-fill the endpoint and default model. Custom mode keeps the endpoint editable for providers or gateways outside the preset list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Leave Model Override blank to use the app's recommended model automatically. Image sources may use a different built-in model than sheet sources.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } label: {
                Text("Advanced AI Settings")
                    .font(.subheadline.weight(.medium))
            }

            Text("Approved AI layouts stored: \(model.ui.aiApprovals.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private var automationPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            PaneHeader(
                title: "Automation",
                subtitle: "Polling only runs while the app stays open. Closed apps do not sync."
            )

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    automationToggles
                    automationIntervalField
                }

                VStack(alignment: .leading, spacing: 10) {
                    automationToggles
                    automationIntervalField
                }
            }
            Text("The app can add, update, and remove previously synced events when the source changes. You can confirm every sync, or only ask before deletions.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

    private var bookingIDField: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(title: "Booking ID")
            TextField("LJZ", text: deferredBinding(\.draftBookingID))
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
            TextField("ppms", text: deferredBinding(\.draftName))
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
            Picker("", selection: deferredBinding(\.draftCalendar)) {
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
        TextField("Google Sheets link, local .xlsx workbook, or image path", text: deferredBinding(\.draftSource))
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
        Toggle("Use in sync", isOn: deferredBinding(\.draftEnabled))
            .toggleStyle(.checkbox)
            .fixedSize()
            .controlSize(.small)
            .help("When off, this source stays saved but is skipped during preview and sync.")
            .onChange(of: model.ui.draftEnabled) { _ in
                model.draftFieldsChanged()
            }
    }

    private var aiEndpointField: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(title: "API Endpoint")
            TextField(model.ui.aiProvider.defaultEndpointURL.isEmpty ? "Enter provider endpoint" : model.ui.aiProvider.defaultEndpointURL, text: deferredBinding(\.aiEndpointURL))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onChange(of: model.ui.aiEndpointURL) { _ in
                    model.parserSettingsChanged()
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var aiModelField: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(title: "Model Override")
            TextField(model.ui.aiProvider == .custom ? "Enter model name" : "Auto (\(model.ui.aiProvider.automaticModelSummary))", text: deferredBinding(\.aiModel))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onChange(of: model.ui.aiModel) { _ in
                    model.parserSettingsChanged()
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var automationToggles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Only future reservations", isOn: deferredBinding(\.upcomingOnly))
                .onChange(of: model.ui.upcomingOnly) { _ in
                    model.automationChanged()
                }
                .controlSize(.small)
            Toggle("Auto sync while the app is open", isOn: deferredBinding(\.autoSyncEnabled))
                .onChange(of: model.ui.autoSyncEnabled) { _ in
                    model.automationChanged()
                }
                .controlSize(.small)
            Toggle("Show confirmation before sync", isOn: deferredBinding(\.confirmBeforeSync))
                .onChange(of: model.ui.confirmBeforeSync) { _ in
                    model.automationChanged()
                }
                .controlSize(.small)
            Toggle("Ask before deleting removed events", isOn: deferredBinding(\.confirmBeforeDeletion))
                .onChange(of: model.ui.confirmBeforeDeletion) { _ in
                    model.automationChanged()
                }
                .controlSize(.small)
            Toggle("Keep running in menu bar", isOn: deferredBinding(\.menuBarModeEnabled))
                .onChange(of: model.ui.menuBarModeEnabled) { _ in
                    model.automationChanged()
                }
                .controlSize(.small)
        }
    }

    private var automationIntervalField: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(title: "Interval (minutes)")
            TextField("15", text: deferredBinding(\.autoSyncMinutes))
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 92, idealWidth: 110, maxWidth: 140, alignment: .leading)
                .controlSize(.small)
                .onSubmit {
                    model.automationChanged()
                }
                .onChange(of: model.ui.autoSyncMinutes) { _ in
                    model.automationChanged()
                }
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

    @ViewBuilder
    private func sourceStatusIcon(for item: SourceItem) -> some View {
        switch model.runtimeStatus(for: item) {
        case .idle:
            Image(systemName: item.enabled ? "circle" : "pause.circle")
                .foregroundStyle(item.enabled ? Color.secondary : Color.secondary.opacity(0.8))
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .review:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .failure:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private func sourceStatusSummary(for item: SourceItem) -> String {
        switch model.runtimeStatus(for: item) {
        case .idle:
            return item.enabled ? "Ready to read" : "Saved but skipped"
        case .loading:
            return "Reading sheet..."
        case .success(let matchCount):
            let noun = matchCount == 1 ? "match" : "matches"
            return "Read OK · \(matchCount) \(noun)"
        case .review(let matchCount):
            let noun = matchCount == 1 ? "match" : "matches"
            return "Review needed · \(matchCount) \(noun)"
        case .failure:
            return "Read failed"
        }
    }

    private func sourceStatusHelp(for item: SourceItem) -> String {
        switch model.runtimeStatus(for: item) {
        case .idle:
            return item.enabled ? "This source is enabled and ready for preview or sync." : "This source is saved but currently skipped during preview and sync."
        case .loading:
            return "The app is downloading or parsing this source now."
        case .success(let matchCount):
            let noun = matchCount == 1 ? "reservation" : "reservations"
            return "The last read succeeded and found \(matchCount) matching \(noun)."
        case .review(let matchCount):
            let noun = matchCount == 1 ? "reservation" : "reservations"
            return "The source was parsed, but the AI confidence is too low for unattended sync. Preview and approve this layout before syncing. Current preview found \(matchCount) matching \(noun)."
        case .failure(let message):
            return message
        }
    }

    private func sourceStatusColor(for item: SourceItem) -> Color {
        switch model.runtimeStatus(for: item) {
        case .idle:
            return .secondary
        case .loading:
            return .secondary
        case .success:
            return .green
        case .review:
            return .orange
        case .failure:
            return .red
        }
    }
}

struct MenuBarContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appDisplayName)
                .font(.headline)
            Text(model.ui.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Button("Show Window") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.plain)

            Button("Preview Now") {
                model.previewAll()
            }
            .buttonStyle(.plain)
            .disabled(model.ui.isBusy)

            Button("Sync Now") {
                model.syncAll()
            }
            .buttonStyle(.plain)
            .disabled(model.ui.isBusy)

            Button("Open Calendar") {
                model.openCalendarApp()
            }
            .buttonStyle(.plain)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
    }
}
