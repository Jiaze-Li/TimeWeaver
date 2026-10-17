import Foundation
import AppKit
import UniformTypeIdentifiers

extension AppModel {
    func chooseSourceFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "xlsx"),
            UTType.png,
            UTType.jpeg,
            UTType.gif,
            UTType.webP,
            UTType(filenameExtension: "heic"),
            UTType(filenameExtension: "heif")
        ].compactMap { $0 }
        if panel.runModal() == .OK, let url = panel.url {
            if imageMimeType(for: url) != nil {
                startInstantImageImport(from: url)
            } else {
                _ = applySourceFile(url)
            }
        }
    }

    func handleDroppedSourceFiles(_ urls: [URL]) -> Bool {
        guard let first = urls.first else { return false }
        if imageMimeType(for: first) != nil {
            startInstantImageImport(from: first)
            return true
        }
        return applySourceFile(first)
    }

    private func startInstantImageImport(from imageURL: URL) {
        guard !ui.isBusy else {
            ui.status = "Wait for the current task to finish first"
            return
        }
        ui.lastImageImportUndo = nil
        guard let source = makeInstantImageImportSource(from: imageURL) else {
            return
        }

        beginBusyTask(status: "Reading \(source.bookingID) schedule from image...")

        Task {
            do {
                let preview = try await performSync(
                    sources: [source],
                    upcomingOnly: false,
                    previewOnly: true
                )

                guard let report = preview.reports.first, report.errorMessage == nil else {
                    ui.output = preview.outputText
                    ui.status = preview.reports.first?.errorMessage ?? "Could not read the dropped image"
                    ui.isBusy = false
                    return
                }

                let extraction = preview.extractions[source.id]
                guard let plan = buildImageImportPlan(source: source, report: report, previewOutput: preview.outputText, extraction: extraction) else {
                    ui.output = preview.outputText
                    ui.status = "No matching \(source.bookingID) schedule items found in the dropped image"
                    ui.isBusy = false
                    return
                }

                let entries = report.actions
                    .filter { ["would create", "would update", "would delete"].contains($0.status) }
                    .map { ImageImportEventEntry(
                        syncKey: $0.syncKey,
                        title: $0.title,
                        originalTitle: $0.title,
                        start: $0.start,
                        end: $0.end,
                        status: $0.status
                    ) }
                ui.output = plan.previewOutput
                ui.status = "Read \(plan.matchedCount) \(plan.matchedCount == 1 ? "schedule item" : "schedule items") — review and confirm below"
                ui.pendingImageImportReview = ImageImportReview(plan: plan, entries: entries)
                ui.isBusy = false
            } catch {
                ui.output = error.localizedDescription
                ui.status = error.localizedDescription
            }
            ui.isBusy = false
        }
    }

    private func makeInstantImageImportSource(from imageURL: URL) -> SourceItem? {
        let name = ui.draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookingID = ui.draftBookingID.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = ui.draftCalendar.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty, !bookingID.isEmpty, !calendar.isEmpty else {
            ui.status = "Set Booking ID, Event Title, and Calendar before dropping an image"
            ui.output = "Image import uses the current Booking ID, Event Title, and Calendar as context. Fill those fields first, then drop the timetable image again."
            return nil
        }

        let sourceKey = "image-import|\(name)|\(bookingID)|\(calendar)|\(imageURL.path)"
        return SourceItem(
            id: deterministicUUID(for: sourceKey),
            enabled: true,
            name: name,
            source: imageURL.path,
            bookingID: bookingID,
            calendar: calendar
        )
    }

    private func buildImageImportPlan(
        source: SourceItem,
        report: SourceSyncReport,
        previewOutput: String,
        extraction: ExtractionResult? = nil
    ) -> ImageImportPlan? {
        guard report.totalMatchedCount > 0 else {
            return nil
        }

        let createCount = report.actions.filter { $0.status == "would create" }.count
        let updateCount = report.actions.filter { $0.status == "would update" }.count
        let deleteCount = report.actions.filter { $0.status == "would delete" }.count
        let sampleIntervals = report.actions
            .filter { ["would create", "would update", "would delete"].contains($0.status) }
            .map { customerFacingInterval(start: $0.start, end: $0.end) }

        return ImageImportPlan(
            source: source,
            matchedCount: report.totalMatchedCount,
            createCount: createCount,
            updateCount: updateCount,
            deleteCount: deleteCount,
            reviewRequired: report.reviewRequired,
            workbookFingerprint: report.workbookFingerprint,
            previewOutput: previewOutput,
            sampleIntervals: Array(sampleIntervals.prefix(8)),
            extraction: extraction
        )
    }

    private func imageImportApprovals(for plan: ImageImportPlan) -> [AIApprovalRecord] {
        guard plan.reviewRequired, let workbookFingerprint = plan.workbookFingerprint else {
            return ui.aiApprovals
        }
        let temporaryApproval = AIApprovalRecord(
            sourceKey: sourceIdentity(for: plan.source),
            workbookFingerprint: workbookFingerprint,
            approvedAtISO: iso8601(Date())
        )
        if ui.aiApprovals.contains(where: { $0.sourceKey == temporaryApproval.sourceKey && $0.workbookFingerprint == temporaryApproval.workbookFingerprint }) {
            return ui.aiApprovals
        }
        return ui.aiApprovals + [temporaryApproval]
    }

    func confirmImageImportReview(entries: [ImageImportEventEntry]) {
        guard let review = ui.pendingImageImportReview, !ui.isBusy else { return }

        for entry in entries {
            guard TimeWeaverCore.validateTimeInterval(start: entry.start, end: entry.end) else {
                ui.status = "Start time must be before end time for '\(entry.title)'"
                return
            }
        }

        var eventOverrides: [String: EventOverride] = [:]
        for entry in entries {
            if entry.title != entry.originalTitle || entry.start != entry.originalStart || entry.end != entry.originalEnd {
                eventOverrides[entry.syncKey] = EventOverride(
                    title: entry.title,
                    start: entry.start,
                    end: entry.end
                )
            }
        }

        let plan = review.plan
        ui.pendingImageImportReview = nil
        ui.isBusy = true
        ui.status = "Adding \(plan.source.bookingID) schedule to Apple Calendar..."
        Task {
            do {
                let sourceKey = sourceIdentity(for: plan.source)
                let beforeSnapshot = SettingsStore.loadState().events.filter { $0.value.sourceID == sourceKey }
                var cachedExtractions: [UUID: ExtractionResult] = [:]
                if let extraction = plan.extraction {
                    cachedExtractions[plan.source.id] = extraction
                }
                let syncResult = try await performSync(
                    sources: [plan.source],
                    upcomingOnly: false,
                    previewOnly: false,
                    aiApprovals: imageImportApprovals(for: plan),
                    eventOverrides: eventOverrides,
                    cachedExtractions: cachedExtractions
                )
                let afterSnapshot = SettingsStore.loadState().events.filter { $0.value.sourceID == sourceKey }
                if !afterSnapshot.isEmpty || !beforeSnapshot.isEmpty {
                    ui.lastImageImportUndo = ImageImportUndoRecord(
                        sourceIdentityKey: sourceKey,
                        calendarName: plan.source.calendar,
                        beforeSnapshot: beforeSnapshot,
                        afterSnapshot: afterSnapshot
                    )
                }
                ui.output = syncResult.outputText
                ui.status = "Image schedule synced"
            } catch {
                ui.output = error.localizedDescription
                ui.status = error.localizedDescription
            }
            ui.isBusy = false
        }
    }

    func cancelImageImportReview() {
        ui.pendingImageImportReview = nil
        ui.status = "Image import cancelled"
    }
}
