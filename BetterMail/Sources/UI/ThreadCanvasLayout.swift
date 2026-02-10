import Foundation
import CoreGraphics

internal struct ThreadCanvasLayoutMetrics {
    internal static let defaultDayCount = 7
    internal static let minZoom: CGFloat = 0.01
    internal static let maxZoom: CGFloat = 1.6

    internal let zoom: CGFloat
    internal let dayCount: Int
    internal let columnWidthAdjustment: CGFloat

    internal var clampedZoom: CGFloat {
        min(max(zoom, Self.minZoom), Self.maxZoom)
    }

    internal var dayHeight: CGFloat {
        120 * clampedZoom
    }

    internal var columnWidth: CGFloat {
        (260 + columnWidthAdjustment) * clampedZoom
    }

    internal var columnSpacing: CGFloat {
        24 * clampedZoom
    }

    internal var dayLabelWidth: CGFloat {
        96 * clampedZoom
    }

    internal var contentPadding: CGFloat {
        20 * clampedZoom
    }

    internal var nodeHeight: CGFloat {
        64 * clampedZoom
    }

    internal var nodeHorizontalInset: CGFloat {
        12 * clampedZoom
    }

    internal var nodeVerticalSpacing: CGFloat {
        30 * clampedZoom
    }

    internal var nodeCornerRadius: CGFloat {
        12 * clampedZoom
    }

    internal var fontScale: CGFloat {
        min(max(clampedZoom, 0.85), 1.2)
    }

    internal var nodeWidth: CGFloat {
        max(columnWidth - (nodeHorizontalInset * 2), 24)
    }

    internal init(zoom: CGFloat,
                  dayCount: Int = ThreadCanvasLayoutMetrics.defaultDayCount,
                  columnWidthAdjustment: CGFloat = 0) {
        self.zoom = zoom
        self.dayCount = max(dayCount, 1)
        self.columnWidthAdjustment = columnWidthAdjustment
    }
}

internal struct ThreadTimelineLayoutConstants {
    internal static let summaryColumnExtraWidth: CGFloat = 160
    internal static let tagColumnExtraWidth: CGFloat = 160

    internal static func dotSize(fontScale: CGFloat) -> CGFloat {
        6 * fontScale
    }

    internal static func timeWidth(fontScale: CGFloat) -> CGFloat {
        52 * fontScale
    }

    internal static func elementSpacing(fontScale: CGFloat) -> CGFloat {
        8 * fontScale
    }

    internal static func tagSpacing(fontScale: CGFloat) -> CGFloat {
        6 * fontScale
    }

    internal static func rowHorizontalPadding(fontScale: CGFloat) -> CGFloat {
        6 * fontScale
    }

    internal static func rowVerticalPadding(fontScale: CGFloat) -> CGFloat {
        6 * fontScale
    }

    internal static func summaryLineSpacing(fontScale: CGFloat) -> CGFloat {
        6 * fontScale
    }

    internal static func summaryFontSize(fontScale: CGFloat) -> CGFloat {
        13 * fontScale
    }

    internal static func timeFontSize(fontScale: CGFloat) -> CGFloat {
        11 * fontScale
    }

    internal static func tagFontSize(fontScale: CGFloat) -> CGFloat {
        10 * fontScale
    }

    internal static func tagVerticalPadding(fontScale: CGFloat) -> CGFloat {
        3 * fontScale
    }

    internal static func tagHorizontalPadding(fontScale: CGFloat) -> CGFloat {
        6 * fontScale
    }

    internal static func tagMaxWidth(fontScale: CGFloat) -> CGFloat {
        (160 + tagColumnExtraWidth) * fontScale
    }

    internal static func selectionCornerRadius(fontScale: CGFloat) -> CGFloat {
        10 * fontScale
    }
}

internal struct ThreadCanvasDay: Identifiable, Hashable {
    internal let id: Int
    internal let date: Date
    internal let label: String
    internal let yOffset: CGFloat
    internal let height: CGFloat
}

internal struct ThreadCanvasNode: Identifiable, Hashable {
    internal let id: String
    internal let message: EmailMessage
    internal let threadID: String
    internal let jwzThreadID: String
    internal let frame: CGRect
    internal let dayIndex: Int
    internal let isManualAttachment: Bool
}

internal struct ThreadCanvasColumn: Identifiable, Hashable {
    internal let id: String
    internal let title: String
    internal let xOffset: CGFloat
    internal let nodes: [ThreadCanvasNode]
    internal let unreadCount: Int
    internal let latestDate: Date
    internal let folderID: String?
}

internal struct ThreadCanvasLayout {
    internal let days: [ThreadCanvasDay]
    internal let columns: [ThreadCanvasColumn]
    internal let contentSize: CGSize
    internal let folderOverlays: [ThreadCanvasFolderOverlay]
}

internal struct ThreadCanvasFolderOverlay: Identifiable, Hashable {
    internal let id: String
    internal let title: String
    internal let color: ThreadFolderColor
    internal let frame: CGRect
    internal let columnIDs: [String]
    internal let parentID: String?
    internal let depth: Int
}

internal enum ThreadCanvasDateHelper {
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter
    }()
    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter
    }()

    internal static func dayIndex(for date: Date, today: Date, calendar: Calendar, dayCount: Int) -> Int? {
        let startOfToday = calendar.startOfDay(for: today)
        let startOfDate = calendar.startOfDay(for: date)
        guard let diff = calendar.dateComponents([.day], from: startOfDate, to: startOfToday).day else {
            return nil
        }
        guard diff >= 0, diff < dayCount else {
            return nil
        }
        return diff
    }

    internal static func dayDate(for index: Int, today: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: -index, to: calendar.startOfDay(for: today)) ?? today
    }

    internal static func label(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    internal static func monthLabel(for date: Date) -> String {
        monthFormatter.string(from: date)
    }

    internal static func yearLabel(for date: Date) -> String {
        yearFormatter.string(from: date)
    }
}
