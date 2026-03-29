import Foundation

struct UIState {
    var sources: [SourceItem]
    var sourceStatuses: [UUID: SourceRuntimeStatus]
    var workdayStart: String
    var workdayEnd: String
    var selectedSourceID: UUID?
    var draftEnabled: Bool
    var draftName: String
    var draftSource: String
    var draftBookingID: String
    var draftCalendar: String
    var calendars: [String]
    var calendarAccessState: CalendarAccessState
    var output: String
    var status: String
    var isBusy: Bool
    var isCalendarLoading: Bool
    var autoSyncEnabled: Bool
    var autoSyncMinutes: String
    var upcomingOnly: Bool
    var confirmBeforeSync: Bool
    var confirmBeforeDeletion: Bool
    var menuBarModeEnabled: Bool
    var parserMode: ParserMode
    var aiProvider: AIProvider
    var aiEndpointURL: String
    var aiModel: String
    var aiAPIKey: String
    var aiApprovals: [AIApprovalRecord]
    var schedulingTimeZoneIdentifier: String
    var lastImageImportUndo: ImageImportUndoRecord?
    var pendingImageImportReview: ImageImportReview?
    var pendingAIReviews: [PendingAIReview]
    var pendingSyncConfirmation: PendingSyncConfirmation?
    var showAdvancedAISettings: Bool

    static func initial(
        sources: [SourceItem],
        sourceStatuses: [UUID: SourceRuntimeStatus],
        workdayStart: String,
        workdayEnd: String,
        selectedSourceID: UUID?,
        draftEnabled: Bool,
        draftName: String,
        draftSource: String,
        draftBookingID: String,
        draftCalendar: String,
        autoSyncEnabled: Bool,
        autoSyncMinutes: String,
        upcomingOnly: Bool,
        confirmBeforeSync: Bool,
        confirmBeforeDeletion: Bool,
        menuBarModeEnabled: Bool,
        parserMode: ParserMode,
        aiProvider: AIProvider,
        aiEndpointURL: String,
        aiModel: String,
        aiAPIKey: String,
        aiApprovals: [AIApprovalRecord],
        schedulingTimeZoneIdentifier: String
    ) -> UIState {
        UIState(
            sources: sources,
            sourceStatuses: sourceStatuses,
            workdayStart: workdayStart,
            workdayEnd: workdayEnd,
            selectedSourceID: selectedSourceID,
            draftEnabled: draftEnabled,
            draftName: draftName,
            draftSource: draftSource,
            draftBookingID: draftBookingID,
            draftCalendar: draftCalendar,
            calendars: ["Experiment"],
            calendarAccessState: .unknown,
            output: "",
            status: "Ready",
            isBusy: false,
            isCalendarLoading: false,
            autoSyncEnabled: autoSyncEnabled,
            autoSyncMinutes: autoSyncMinutes,
            upcomingOnly: upcomingOnly,
            confirmBeforeSync: confirmBeforeSync,
            confirmBeforeDeletion: confirmBeforeDeletion,
            menuBarModeEnabled: menuBarModeEnabled,
            parserMode: parserMode,
            aiProvider: aiProvider,
            aiEndpointURL: aiEndpointURL,
            aiModel: aiModel,
            aiAPIKey: aiAPIKey,
            aiApprovals: aiApprovals,
            schedulingTimeZoneIdentifier: schedulingTimeZoneIdentifier,
            lastImageImportUndo: nil,
            pendingImageImportReview: nil,
            pendingAIReviews: [],
            pendingSyncConfirmation: nil,
            showAdvancedAISettings: false
        )
    }
}
