import Foundation

internal enum AccessibilityID {
    internal static let contentRoot = "bettermail.content-root"
    internal static let sidebar = "bettermail.sidebar"
    internal static let detailContainer = "bettermail.detail-container"

    internal static let actionItemsView = "bettermail.action-items.view"
    internal static let actionItemsShowDoneButton = "bettermail.action-items.show-done"
    internal static let actionItemsList = "bettermail.action-items.list"
    internal static let actionItemsEmptyViewCanvasButton = "bettermail.action-items.empty.view-canvas"

    internal static let threadList = "bettermail.thread-list"
    internal static let threadListNavigationBar = "bettermail.thread-list.navigation-bar"
    internal static let viewModeToggle = "bettermail.thread-list.view-mode-toggle"
    internal static let searchButton = "bettermail.thread-list.search-button"
    internal static let searchField = "bettermail.thread-list.search-field"
    internal static let fetchLimitField = "bettermail.thread-list.fetch-limit-field"
    internal static let refreshButton = "bettermail.thread-list.refresh-button"
    internal static let zoomFitButton = "bettermail.thread-list.zoom-fit-button"
    internal static let zoomResetButton = "bettermail.thread-list.zoom-reset-button"
    internal static let selectionActionBar = "bettermail.thread-list.selection-action-bar"
    internal static let backfillButton = "bettermail.thread-list.backfill-button"

    internal static let mailboxMoveSheet = "bettermail.mailbox-move.sheet"
    internal static let mailboxMoveAccountPicker = "bettermail.mailbox-move.account-picker"
    internal static let mailboxMoveSearchField = "bettermail.mailbox-move.search-field"
    internal static let mailboxMoveSubmitButton = "bettermail.mailbox-move.submit-button"
    internal static let mailboxMoveCancelButton = "bettermail.mailbox-move.cancel-button"

    internal static let threadInspector = "bettermail.thread-inspector"
    internal static let threadInspectorOpenInMailButton = "bettermail.thread-inspector.open-in-mail"
    internal static let threadInspectorCopySubjectButton = "bettermail.thread-inspector.copy-subject"
    internal static let threadInspectorCopyMailboxButton = "bettermail.thread-inspector.copy-mailbox"
    internal static let threadSummaryDisclosure = "bettermail.thread-summary.disclosure"
    internal static let threadSummaryToggle = "bettermail.thread-summary.toggle"
    internal static let threadSummaryRegenerateButton = "bettermail.thread-summary.regenerate"

    internal static let folderInspector = "bettermail.folder-inspector"
    internal static let folderInspectorRefreshThreadsButton = "bettermail.folder-inspector.refresh-threads"
    internal static let folderInspectorNameField = "bettermail.folder-inspector.name-field"
    internal static let folderInspectorColorPicker = "bettermail.folder-inspector.color-picker"
    internal static let folderInspectorRecalibrateColorButton = "bettermail.folder-inspector.recalibrate-color"
    internal static let folderInspectorMailboxClearButton = "bettermail.folder-inspector.clear-mailbox"
    internal static let folderInspectorMailboxRefreshButton = "bettermail.folder-inspector.refresh-mailboxes"
    internal static let folderInspectorMailboxAccountPicker = "bettermail.folder-inspector.mailbox-account-picker"
    internal static let folderInspectorMailboxFolderPicker = "bettermail.folder-inspector.mailbox-folder-picker"
    internal static let folderInspectorSummary = "bettermail.folder-inspector.summary"
    internal static let folderInspectorMinimap = "bettermail.folder-inspector.minimap"

    internal static let threadCanvas = "bettermail.thread-canvas"
    internal static let threadCanvasScrollView = "bettermail.thread-canvas.scroll-view"

    internal static let settingsView = "bettermail.settings.view"
    internal static let settingsAppearancePicker = "bettermail.settings.appearance-picker"
    internal static let settingsAutoRefreshToggle = "bettermail.settings.auto-refresh-toggle"
    internal static let settingsRefreshIntervalStepper = "bettermail.settings.refresh-interval-stepper"
    internal static let settingsInspectorLineLimitStepper = "bettermail.settings.inspector-line-limit-stepper"
    internal static let settingsStopPhrasesEditor = "bettermail.settings.stop-phrases-editor"
    internal static let settingsTextScaleStepper = "bettermail.settings.text-scale-stepper"
    internal static let settingsDetailedThresholdStepper = "bettermail.settings.detailed-threshold-stepper"
    internal static let settingsCompactThresholdStepper = "bettermail.settings.compact-threshold-stepper"
    internal static let settingsMinimalThresholdStepper = "bettermail.settings.minimal-threshold-stepper"
    internal static let settingsBackfillStartPicker = "bettermail.settings.backfill-start-picker"
    internal static let settingsBackfillEndPicker = "bettermail.settings.backfill-end-picker"
    internal static let settingsBackfillBatchSizeStepper = "bettermail.settings.backfill-batch-size-stepper"
    internal static let settingsStartBackfillButton = "bettermail.settings.start-backfill-button"
    internal static let settingsStartRegenAIButton = "bettermail.settings.start-regenai-button"
    internal static let settingsStopBatchButton = "bettermail.settings.stop-batch-button"
    internal static let settingsResetManualGroupingButton = "bettermail.settings.reset-manual-grouping-button"

    internal static func sidebarScope(_ scope: MailboxScope) -> String {
        switch scope {
        case .actionItems:
            return "bettermail.sidebar.scope.action-items"
        case .allEmails:
            return "bettermail.sidebar.scope.all-emails"
        case .allFolders:
            return "bettermail.sidebar.scope.all-folders"
        case .allInboxes:
            return "bettermail.sidebar.scope.all-inboxes"
        case .mailboxFolder(let account, let path):
            return "bettermail.sidebar.scope.mailbox.\(stable(account)).\(stable(path))"
        }
    }

    internal static func sidebarMailboxFolder(_ folderID: String) -> String {
        "bettermail.sidebar.mailbox-folder.\(stable(folderID))"
    }

    internal static func selectionAction(_ action: String) -> String {
        "bettermail.thread-list.selection-action.\(stable(action))"
    }

    internal static func actionItemRow(_ id: String) -> String {
        "bettermail.action-items.row.\(stable(id))"
    }

    internal static func actionItemDoneButton(_ id: String) -> String {
        "bettermail.action-items.done-button.\(stable(id))"
    }

    internal static func threadCanvasNode(_ id: String) -> String {
        "bettermail.thread-canvas.node.\(stable(id))"
    }

    internal static func threadCanvasFolderHeader(_ id: String) -> String {
        "bettermail.thread-canvas.folder-header.\(stable(id))"
    }

    private static func stable(_ rawValue: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let converted = rawValue.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
        let trimmed = converted.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "unknown" : trimmed
    }
}
