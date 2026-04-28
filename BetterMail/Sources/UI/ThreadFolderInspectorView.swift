import AppKit
import SwiftUI

internal struct ThreadFolderInspectorView: View {
    internal let folder: ThreadFolder
    internal let mailboxAccounts: [MailboxAccount]
    internal let isMailboxHierarchyLoading: Bool
    internal let mailboxEditingDisabledReason: String?
    internal let preferredMailboxAccount: String?
    internal let textScale: CGFloat
    internal let minimapModel: FolderMinimapModel?
    internal let minimapSelectedNodeID: String?
    internal let minimapViewportRect: CGRect?
    internal let summaryState: ThreadSummaryState?
    internal let canRegenerateSummary: Bool
    internal let isRefreshingFolderThreads: Bool
    internal let onRegenerateSummary: (() -> Void)?
    internal let onMinimapJump: (CGPoint) -> Void
    internal let onJumpToLatest: () -> Void
    internal let onJumpToOldest: () -> Void
    internal let onRefreshFolderThreads: () -> Void
    internal let onRefreshMailboxHierarchy: () -> Void
    internal let onRecalibrateColor: () -> ThreadFolderColor?
    internal let onPreview: (String, ThreadFolderColor, String?, String?) -> Void
    internal let onSave: (String, ThreadFolderColor, String?, String?) -> Void

    internal static let minimapHeight: CGFloat = 160

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    @State private var draftTitle: String
    @State private var draftColor: Color
    @State private var draftMailboxAccount: String?
    @State private var draftMailboxPath: String?
    @State private var baselineTitle: String
    @State private var baselineColor: ThreadFolderColor
    @State private var baselineMailboxAccount: String?
    @State private var baselineMailboxPath: String?
    @State private var isResettingDraft = false
    @State private var pendingSaveTask: Task<Void, Never>?

    internal init(folder: ThreadFolder,
                  mailboxAccounts: [MailboxAccount],
                  isMailboxHierarchyLoading: Bool,
                  mailboxEditingDisabledReason: String?,
                  preferredMailboxAccount: String?,
                  textScale: CGFloat,
                  minimapModel: FolderMinimapModel?,
                  minimapSelectedNodeID: String?,
                  minimapViewportRect: CGRect?,
                  summaryState: ThreadSummaryState?,
                  canRegenerateSummary: Bool,
                  isRefreshingFolderThreads: Bool,
                  onRegenerateSummary: (() -> Void)?,
                  onMinimapJump: @escaping (CGPoint) -> Void,
                  onJumpToLatest: @escaping () -> Void,
                  onJumpToOldest: @escaping () -> Void,
                  onRefreshFolderThreads: @escaping () -> Void,
                  onRefreshMailboxHierarchy: @escaping () -> Void,
                  onRecalibrateColor: @escaping () -> ThreadFolderColor?,
                  onPreview: @escaping (String, ThreadFolderColor, String?, String?) -> Void,
                  onSave: @escaping (String, ThreadFolderColor, String?, String?) -> Void) {
        self.folder = folder
        self.mailboxAccounts = mailboxAccounts
        self.isMailboxHierarchyLoading = isMailboxHierarchyLoading
        self.mailboxEditingDisabledReason = mailboxEditingDisabledReason
        self.preferredMailboxAccount = preferredMailboxAccount
        self.textScale = textScale
        self.minimapModel = minimapModel
        self.minimapSelectedNodeID = minimapSelectedNodeID
        self.minimapViewportRect = minimapViewportRect
        self.summaryState = summaryState
        self.canRegenerateSummary = canRegenerateSummary
        self.isRefreshingFolderThreads = isRefreshingFolderThreads
        self.onRegenerateSummary = onRegenerateSummary
        self.onMinimapJump = onMinimapJump
        self.onJumpToLatest = onJumpToLatest
        self.onJumpToOldest = onJumpToOldest
        self.onRefreshFolderThreads = onRefreshFolderThreads
        self.onRefreshMailboxHierarchy = onRefreshMailboxHierarchy
        self.onRecalibrateColor = onRecalibrateColor
        self.onPreview = onPreview
        self.onSave = onSave
        let initialColor = Color(red: folder.color.red,
                                 green: folder.color.green,
                                 blue: folder.color.blue,
                                 opacity: folder.color.alpha)
        let initialMailboxAccount = folder.mailboxDestination?.account ?? preferredMailboxAccount
        let initialMailboxPath = folder.mailboxDestination?.path
        _draftTitle = State(initialValue: folder.title)
        _draftColor = State(initialValue: initialColor)
        _draftMailboxAccount = State(initialValue: initialMailboxAccount)
        _draftMailboxPath = State(initialValue: initialMailboxPath)
        _baselineTitle = State(initialValue: folder.title)
        _baselineColor = State(initialValue: folder.color)
        _baselineMailboxAccount = State(initialValue: folder.mailboxDestination?.account)
        _baselineMailboxPath = State(initialValue: folder.mailboxDestination?.path)
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Text(NSLocalizedString("threadcanvas.folder.inspector.title",
                                       comment: "Title for the folder inspector panel"))
                    .font(DesignTokens.font(size: 13, weight: .semibold, textScale: textScale))
                Spacer()
                Button(action: onRefreshFolderThreads) {
                    Label(NSLocalizedString("threadcanvas.folder.inspector.refresh_threads",
                                            comment: "Button label for refreshing the selected folder threads"),
                          systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .disabled(isRefreshingFolderThreads)
                .help(NSLocalizedString("threadcanvas.folder.inspector.refresh_threads.help",
                                        comment: "Help text for refreshing the selected folder threads"))
                .accessibilityIdentifier(AccessibilityID.folderInspectorRefreshThreadsButton)
                if isRefreshingFolderThreads {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Divider()

            folderMinimapSection

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    folderNameField
                    folderColorPicker
                    folderMailboxField
                    folderSummaryField
                    folderPreview
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(inspectorPrimaryForegroundStyle)
        .shadow(color: Color.black.opacity(isGlassInspectorEnabled ? (colorScheme == .light ? 0.14 : 0.35) : 0),
                radius: 1.2,
                x: 0,
                y: 1)
        .background(inspectorBackground)
        .accessibilityIdentifier(AccessibilityID.folderInspector)
        .accessibilityLabel(NSLocalizedString("threadcanvas.folder.inspector.title",
                                              comment: "Title for the folder inspector panel"))
        .onChange(of: folder.id) { _, _ in
            resetDraft(with: folder)
        }
        .onChange(of: draftMailboxAccount) { _, newValue in
            guard !isResettingDraft else { return }
            if let account = newValue, !mailboxChoices(for: account).contains(where: { $0.path == draftMailboxPath }) {
                draftMailboxPath = mailboxChoices(for: account).first?.path
            }
            updatePreviewIfNeeded()
        }
        .onChange(of: draftMailboxPath) { _, _ in
            updatePreviewIfNeeded()
        }
        .onDisappear {
            flushPendingSave()
        }
    }

    private var folderMinimapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(NSLocalizedString("threadcanvas.folder.inspector.minimap",
                                       comment: "Folder minimap section label"))
                    .font(DesignTokens.font(size: 12, textScale: textScale))
                    .foregroundStyle(inspectorSecondaryForegroundStyle)
                Spacer()
                Button(action: onJumpToLatest) {
                    Image(systemName: "arrow.up.to.line.compact")
                        .font(DesignTokens.font(size: 12, textScale: textScale))
                }
                .buttonStyle(.plain)
                .controlSize(.mini)
                .disabled(!hasMinimapNodes)
                .accessibilityLabel(NSLocalizedString("threadcanvas.folder.inspector.minimap.jump.latest",
                                                      comment: "Accessibility label for jump to latest folder node"))
                .help(NSLocalizedString("threadcanvas.folder.inspector.minimap.jump.latest",
                                        comment: "Help text for jump to latest folder node"))
                Button(action: onJumpToOldest) {
                    Image(systemName: "arrow.down.to.line.compact")
                        .font(DesignTokens.font(size: 12, textScale: textScale))
                }
                .buttonStyle(.plain)
                .controlSize(.mini)
                .disabled(!hasMinimapNodes)
                .accessibilityLabel(NSLocalizedString("threadcanvas.folder.inspector.minimap.jump.oldest",
                                                      comment: "Accessibility label for jump to oldest folder node"))
                .help(NSLocalizedString("threadcanvas.folder.inspector.minimap.jump.oldest",
                                        comment: "Help text for jump to oldest folder node"))
            }
            FolderMinimapSurface(model: minimapModel,
                                 textScale: textScale,
                                 selectedNodeID: minimapSelectedNodeID,
                                 viewportRect: minimapViewportRect,
                                 foreground: inspectorPrimaryForegroundStyle,
                                 secondaryForeground: inspectorSecondaryForegroundStyle,
                                 onJump: onMinimapJump)
            .frame(height: Self.minimapHeight)
            .accessibilityIdentifier(AccessibilityID.folderInspectorMinimap)
        }
    }

    private var folderNameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString("threadcanvas.folder.inspector.name",
                                   comment: "Folder name field label"))
                .font(DesignTokens.font(size: 12, textScale: textScale))
                .foregroundStyle(inspectorSecondaryForegroundStyle)
            TextField("", text: $draftTitle)
                .font(DesignTokens.font(size: 13, textScale: textScale))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(AccessibilityID.folderInspectorNameField)
                .onChange(of: draftTitle) { _, _ in
                    updatePreviewIfNeeded()
                }
        }
    }

    private var folderColorPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(NSLocalizedString("threadcanvas.folder.inspector.color",
                                       comment: "Folder color picker label"))
                    .font(DesignTokens.font(size: 12, textScale: textScale))
                    .foregroundStyle(inspectorSecondaryForegroundStyle)
                Spacer()
                Button(NSLocalizedString("threadcanvas.folder.inspector.color.recalibrate",
                                         comment: "Button to recalibrate a folder color to match the current palette")) {
                    applyRecalibratedColor()
                }
                .buttonStyle(.link)
                .font(DesignTokens.font(size: 11, textScale: textScale))
                .help(NSLocalizedString("threadcanvas.folder.inspector.color.recalibrate.help",
                                        comment: "Help text for recalibrating a folder color"))
                .accessibilityIdentifier(AccessibilityID.folderInspectorRecalibrateColorButton)
            }
            ColorPicker("", selection: $draftColor, supportsOpacity: true)
                .labelsHidden()
                .accessibilityIdentifier(AccessibilityID.folderInspectorColorPicker)
                .accessibilityLabel(NSLocalizedString("threadcanvas.folder.inspector.color",
                                                      comment: "Folder color picker label"))
                .onChange(of: draftColor) { _, _ in
                    updatePreviewIfNeeded()
                }
        }
    }

    private var folderMailboxField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(NSLocalizedString("threadcanvas.folder.inspector.mailbox",
                                       comment: "Folder mailbox field label"))
                    .font(DesignTokens.font(size: 12, textScale: textScale))
                    .foregroundStyle(inspectorSecondaryForegroundStyle)
                Spacer()
                Button(NSLocalizedString("threadcanvas.folder.inspector.mailbox.clear",
                                         comment: "Button to clear a folder mailbox destination")) {
                    draftMailboxAccount = preferredMailboxAccount
                    draftMailboxPath = nil
                    updatePreviewIfNeeded()
                }
                .buttonStyle(.link)
                .font(DesignTokens.font(size: 11, textScale: textScale))
                .disabled(draftMailboxPath == nil && folder.mailboxDestination == nil)
                .accessibilityIdentifier(AccessibilityID.folderInspectorMailboxClearButton)

                Button(action: onRefreshMailboxHierarchy) {
                    Image(systemName: "arrow.clockwise")
                        .font(DesignTokens.font(size: 11, textScale: textScale))
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("threadcanvas.folder.inspector.mailbox.refresh",
                                        comment: "Help text for refreshing mailbox hierarchy"))
                .disabled(isMailboxHierarchyLoading)
                .accessibilityIdentifier(AccessibilityID.folderInspectorMailboxRefreshButton)
                .accessibilityLabel(NSLocalizedString("threadcanvas.folder.inspector.mailbox.refresh",
                                                      comment: "Accessibility label for refreshing mailbox hierarchy"))
            }

            if let mailboxEditingDisabledReason {
                Text(mailboxEditingDisabledReason)
                    .font(DesignTokens.font(size: 11, textScale: textScale))
                    .foregroundStyle(inspectorSecondaryForegroundStyle)
            }

            Picker(NSLocalizedString("threadcanvas.folder.inspector.mailbox.account",
                                     comment: "Folder mailbox account picker label"),
                   selection: $draftMailboxAccount) {
                Text(NSLocalizedString("threadcanvas.folder.inspector.mailbox.none",
                                       comment: "Folder mailbox none option"))
                    .tag(Optional<String>.none)
                ForEach(mailboxAccounts, id: \.name) { account in
                    Text(account.name).tag(Optional(account.name))
                }
            }
            .pickerStyle(.menu)
            .disabled((mailboxEditingDisabledReason != nil && folder.mailboxDestination == nil) || mailboxAccounts.isEmpty)
            .accessibilityIdentifier(AccessibilityID.folderInspectorMailboxAccountPicker)

            if let draftMailboxAccount {
                Picker(NSLocalizedString("threadcanvas.folder.inspector.mailbox.folder",
                                         comment: "Folder mailbox path picker label"),
                       selection: $draftMailboxPath) {
                    Text(NSLocalizedString("threadcanvas.folder.inspector.mailbox.none",
                                           comment: "Folder mailbox none option"))
                        .tag(Optional<String>.none)
                    ForEach(mailboxChoices(for: draftMailboxAccount), id: \.id) { choice in
                        Text(choice.displayPath).tag(Optional(choice.path))
                    }
                }
                .pickerStyle(.menu)
                .disabled((mailboxEditingDisabledReason != nil && folder.mailboxDestination == nil) || mailboxChoices(for: draftMailboxAccount).isEmpty)
                .accessibilityIdentifier(AccessibilityID.folderInspectorMailboxFolderPicker)
            }

            Text(mailboxSelectionLabel)
                .font(DesignTokens.font(size: 11, textScale: textScale))
                .foregroundStyle(inspectorSecondaryForegroundStyle)
        }
    }

    private var folderPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString("threadcanvas.folder.inspector.preview",
                                   comment: "Folder preview label"))
                .font(DesignTokens.font(size: 12, textScale: textScale))
                .foregroundStyle(inspectorSecondaryForegroundStyle)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(draftColor.opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.4))
                )
                .overlay(alignment: .leading) {
                    Text(draftTitle.isEmpty
                         ? NSLocalizedString("threadcanvas.subject.placeholder",
                                             comment: "Placeholder subject when missing")
                         : draftTitle)
                        .font(DesignTokens.font(size: 13, weight: .semibold, textScale: textScale))
                        .foregroundStyle(inspectorPrimaryForegroundStyle)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                .frame(height: 72)
        }
    }

    private var folderSummaryField: some View {
        let summaryText = summaryState?.text ?? ""
        let statusText = summaryState?.statusMessage ?? ""
        let placeholder = NSLocalizedString("threadcanvas.folder.inspector.summary.empty",
                                            comment: "Placeholder when no folder summary is available")
        let displayText = summaryText.isEmpty ? (statusText.isEmpty ? placeholder : statusText) : summaryText
        let isSummarizing = summaryState?.isSummarizing == true

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(NSLocalizedString("threadcanvas.folder.inspector.summary",
                                       comment: "Folder summary label"))
                    .font(DesignTokens.font(size: 12, textScale: textScale))
                    .foregroundStyle(inspectorSecondaryForegroundStyle)
                if let onRegenerateSummary {
                    Button(action: onRegenerateSummary) {
                        Image(systemName: "arrow.clockwise")
                            .font(DesignTokens.font(size: 12, textScale: textScale))
                    }
                    .buttonStyle(.plain)
                    .controlSize(.mini)
                    .disabled(!canRegenerateSummary || isSummarizing)
                    .accessibilityLabel(NSLocalizedString("threadcanvas.folder.inspector.summary.regenerate",
                                                          comment: "Accessibility label for regenerating a folder summary"))
                    .help(NSLocalizedString("threadcanvas.folder.inspector.summary.regenerate",
                                            comment: "Help text for regenerating a folder summary"))
                }
                if isSummarizing {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
            }
            ScrollView {
                Text(displayText)
                    .font(DesignTokens.font(size: 13, textScale: textScale))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(minHeight: 96, maxHeight: 160)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.15))
            .cornerRadius(8)
            .opacity(summaryText.isEmpty ? 0.75 : 1)
        }
        .accessibilityIdentifier(AccessibilityID.folderInspectorSummary)
    }

    private var isGlassInspectorEnabled: Bool {
        if #available(macOS 26, *) {
            return !reduceTransparency
        }
        return false
    }

    private var inspectorPrimaryForegroundStyle: Color {
        Color.glassPrimary(colorScheme: colorScheme, isGlassEnabled: isGlassInspectorEnabled)
    }

    private var inspectorSecondaryForegroundStyle: Color {
        Color.glassSecondary(colorScheme: colorScheme, isGlassEnabled: isGlassInspectorEnabled)
    }

    private var inspectorBackground: some View {
        GlassBackground(
            cornerRadius: DesignTokens.CornerRadius.panel,
            fillOpacity: DesignTokens.Opacity.fill(for: colorScheme),
            strokeOpacity: DesignTokens.Opacity.stroke(for: colorScheme),
            shadowOpacity: DesignTokens.Opacity.shadow(for: colorScheme),
            shadowRadius: 16,
            shadowY: 8,
            tintOpacity: DesignTokens.Opacity.tint(for: colorScheme)
        )
    }

    private var draftFolderColor: ThreadFolderColor {
        let nsColor = NSColor(draftColor)
        let resolved = nsColor.usingColorSpace(.deviceRGB) ?? nsColor
        return ThreadFolderColor(red: resolved.redComponent,
                                 green: resolved.greenComponent,
                                 blue: resolved.blueComponent,
                                 alpha: resolved.alphaComponent)
    }

    private var hasMinimapNodes: Bool {
        guard let minimapModel else { return false }
        return !minimapModel.nodes.isEmpty
    }

    private var mailboxSelectionLabel: String {
        guard let account = effectiveMailboxDestination?.account,
              let path = effectiveMailboxDestination?.path else {
            return NSLocalizedString("threadcanvas.folder.inspector.mailbox.none",
                                     comment: "Folder mailbox none option")
        }
        return "\(account) / \(path)"
    }

    private var effectiveMailboxDestination: (account: String, path: String)? {
        let trimmedAccount = draftMailboxAccount?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedPath = draftMailboxPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedAccount.isEmpty, !trimmedPath.isEmpty else { return nil }
        return (trimmedAccount, trimmedPath)
    }

    private func mailboxChoices(for account: String) -> [MailboxFolderChoice] {
        guard let mailboxAccount = mailboxAccounts.first(where: { $0.name == account }) else { return [] }
        return MailboxHierarchyBuilder.folderChoices(for: mailboxAccount)
    }

    private func updatePreviewIfNeeded() {
        guard !isResettingDraft else { return }
        let color = draftFolderColor
        onPreview(draftTitle, color, effectiveMailboxDestination?.account, effectiveMailboxDestination?.path)
        scheduleSaveIfNeeded(title: draftTitle,
                             color: color,
                             mailboxAccount: effectiveMailboxDestination?.account,
                             mailboxPath: effectiveMailboxDestination?.path)
    }

    private func applyRecalibratedColor() {
        guard let recalibratedColor = onRecalibrateColor() else { return }
        draftColor = Color(red: recalibratedColor.red,
                           green: recalibratedColor.green,
                           blue: recalibratedColor.blue,
                           opacity: recalibratedColor.alpha)
    }

    private func resetDraft(with folder: ThreadFolder) {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        isResettingDraft = true
        draftTitle = folder.title
        draftColor = Color(red: folder.color.red,
                           green: folder.color.green,
                           blue: folder.color.blue,
                           opacity: folder.color.alpha)
        draftMailboxAccount = folder.mailboxDestination?.account ?? preferredMailboxAccount
        draftMailboxPath = folder.mailboxDestination?.path
        baselineTitle = folder.title
        baselineColor = folder.color
        baselineMailboxAccount = folder.mailboxDestination?.account
        baselineMailboxPath = folder.mailboxDestination?.path
        DispatchQueue.main.async {
            isResettingDraft = false
        }
    }

    private func scheduleSaveIfNeeded(title: String,
                                      color: ThreadFolderColor,
                                      mailboxAccount: String?,
                                      mailboxPath: String?) {
        guard title != baselineTitle ||
                color != baselineColor ||
                mailboxAccount != baselineMailboxAccount ||
                mailboxPath != baselineMailboxPath else { return }
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            onSave(title, color, mailboxAccount, mailboxPath)
            baselineTitle = title
            baselineColor = color
            baselineMailboxAccount = mailboxAccount
            baselineMailboxPath = mailboxPath
        }
    }

    private func flushPendingSave() {
        guard !isResettingDraft else { return }
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        let color = draftFolderColor
        let mailboxAccount = effectiveMailboxDestination?.account
        let mailboxPath = effectiveMailboxDestination?.path
        guard draftTitle != baselineTitle ||
                color != baselineColor ||
                mailboxAccount != baselineMailboxAccount ||
                mailboxPath != baselineMailboxPath else { return }
        onSave(draftTitle, color, mailboxAccount, mailboxPath)
        baselineTitle = draftTitle
        baselineColor = color
        baselineMailboxAccount = mailboxAccount
        baselineMailboxPath = mailboxPath
    }

}

internal struct FolderMinimapSurface: View {
    let model: FolderMinimapModel?
    let textScale: CGFloat
    let selectedNodeID: String?
    let viewportRect: CGRect?
    let foreground: Color
    let secondaryForeground: Color
    let onJump: (CGPoint) -> Void

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.25))
                    )

                if let model, !model.nodes.isEmpty {
                    Canvas { context, size in
                        let graphFrame = graphRect(in: size)
                        let pointsByID = Dictionary(uniqueKeysWithValues: model.nodes.map { node in
                            (node.id, point(for: node, in: graphFrame))
                        })

                        for edge in model.edges {
                            guard let source = pointsByID[edge.sourceID],
                                  let destination = pointsByID[edge.destinationID] else {
                                continue
                            }
                            var path = Path()
                            path.move(to: source)
                            path.addLine(to: destination)
                            context.stroke(path,
                                           with: .color(secondaryForeground.opacity(0.7)),
                                           lineWidth: 1.5)
                        }

                        if let viewportRect {
                            let viewportDrawRect = rect(for: viewportRect, in: graphFrame)
                            context.fill(Path(viewportDrawRect),
                                         with: .color(secondaryForeground.opacity(0.12)))
                            context.stroke(Path(viewportDrawRect),
                                           with: .color(secondaryForeground.opacity(0.9)),
                                           lineWidth: 1)
                        }

                        for node in model.nodes {
                            let center = point(for: node, in: graphFrame)
                            let isSelected = node.id == selectedNodeID

                            if isSelected {
                                let haloRect = CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)
                                context.fill(Path(ellipseIn: haloRect),
                                             with: .color(Color.black.opacity(0.26)))

                                let markerRect = CGRect(x: center.x - 4.25, y: center.y - 4.25, width: 8.5, height: 8.5)
                                context.fill(Path(ellipseIn: markerRect), with: .color(foreground))
                                context.stroke(Path(ellipseIn: markerRect),
                                               with: .color(secondaryForeground.opacity(0.55)),
                                               lineWidth: 1)
                            } else {
                                let haloRect = CGRect(x: center.x - 6.5, y: center.y - 3.5, width: 13, height: 7)
                                context.fill(Path(roundedRect: haloRect, cornerRadius: 3.5),
                                             with: .color(Color.black.opacity(0.23)))

                                let tickRect = CGRect(x: center.x - 5, y: center.y - 1.5, width: 10, height: 3)
                                context.fill(Path(roundedRect: tickRect, cornerRadius: 1.5),
                                             with: .color(foreground.opacity(0.96)))
                                context.stroke(Path(roundedRect: tickRect, cornerRadius: 1.5),
                                               with: .color(secondaryForeground.opacity(0.45)),
                                               lineWidth: 0.8)
                            }
                        }

                        for tick in model.timeTicks {
                            let tickY = graphFrame.minY + (tick.normalizedY * graphFrame.height)
                            var tickPath = Path()
                            tickPath.move(to: CGPoint(x: graphFrame.maxX + 2, y: tickY))
                            tickPath.addLine(to: CGPoint(x: graphFrame.maxX + 8, y: tickY))
                            context.stroke(tickPath,
                                           with: .color(secondaryForeground.opacity(0.85)),
                                           lineWidth: 1)

                            let text = Self.timeFormatter.string(from: tick.date)
                            let resolved = context.resolve(
                                Text(text)
                                    .font(.system(size: 9 * textScale, weight: .medium))
                                    .foregroundStyle(secondaryForeground)
                            )
                            context.draw(resolved,
                                         at: CGPoint(x: graphFrame.maxX + 10, y: tickY),
                                         anchor: .leading)
                        }
                    }
                } else {
                    Text(NSLocalizedString("threadcanvas.folder.inspector.minimap.empty",
                                           comment: "Placeholder text when minimap has no nodes"))
                        .font(.system(size: 12 * textScale))
                        .foregroundStyle(secondaryForeground)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        guard model != nil else { return }
                        let normalizedPoint = Self.normalizedPoint(value.location, in: proxy.size)
                        onJump(normalizedPoint)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(NSLocalizedString("threadcanvas.folder.inspector.minimap.accessibility.label",
                                                  comment: "Accessibility label for folder minimap"))
            .accessibilityHint(NSLocalizedString("threadcanvas.folder.inspector.minimap.accessibility.hint",
                                                 comment: "Accessibility hint for folder minimap"))
            .help(NSLocalizedString("threadcanvas.folder.inspector.minimap.help",
                                    comment: "Help text for folder minimap"))
            .accessibilityValue(accessibilityValueText)
        }
    }

    private var accessibilityValueText: String {
        var parts: [String] = []
        if viewportRect != nil {
            parts.append(NSLocalizedString("threadcanvas.folder.inspector.minimap.viewport.visible",
                                           comment: "Accessibility value when viewport overlay is visible on minimap"))
        }
        if selectedNodeID != nil {
            parts.append(NSLocalizedString("threadcanvas.folder.inspector.minimap.selected.visible",
                                           comment: "Accessibility value when selected node is visible on minimap"))
        }
        return parts.joined(separator: ", ")
    }

    private func graphRect(in size: CGSize) -> CGRect {
        let leftPadding: CGFloat = 10
        let rightPadding: CGFloat = 88
        let verticalPadding: CGFloat = 10
        let width = max(size.width - leftPadding - rightPadding, 1)
        let height = max(size.height - (verticalPadding * 2), 1)
        return CGRect(x: leftPadding, y: verticalPadding, width: width, height: height)
    }

    private func point(for node: FolderMinimapNode, in graphFrame: CGRect) -> CGPoint {
        let x = graphFrame.minX + (node.normalizedX * graphFrame.width)
        let y = graphFrame.minY + (node.normalizedY * graphFrame.height)
        return CGPoint(x: x, y: y)
    }

    private func rect(for normalizedRect: CGRect, in graphFrame: CGRect) -> CGRect {
        let x = graphFrame.minX + (normalizedRect.minX * graphFrame.width)
        let y = graphFrame.minY + (normalizedRect.minY * graphFrame.height)
        let width = max(normalizedRect.width * graphFrame.width, 1)
        let height = max(normalizedRect.height * graphFrame.height, 1)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    internal static func normalizedPoint(_ location: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        let graphFrame = CGRect(x: 10,
                                y: 10,
                                width: max(size.width - 98, 1),
                                height: max(size.height - 20, 1))
        let normalizedX = min(max((location.x - graphFrame.minX) / graphFrame.width, 0), 1)
        let normalizedY = min(max((location.y - graphFrame.minY) / graphFrame.height, 0), 1)
        return CGPoint(x: normalizedX, y: normalizedY)
    }
}
