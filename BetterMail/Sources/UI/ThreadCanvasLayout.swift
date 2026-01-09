import Foundation
import CoreGraphics

struct ThreadCanvasLayoutMetrics {
    static let dayCount = 7
    static let minZoom: CGFloat = 0.7
    static let maxZoom: CGFloat = 1.6

    let zoom: CGFloat

    var clampedZoom: CGFloat {
        min(max(zoom, Self.minZoom), Self.maxZoom)
    }

    var dayHeight: CGFloat {
        120 * clampedZoom
    }

    var columnWidth: CGFloat {
        260 * clampedZoom
    }

    var columnSpacing: CGFloat {
        24 * clampedZoom
    }

    var dayLabelWidth: CGFloat {
        96 * clampedZoom
    }

    var contentPadding: CGFloat {
        20 * clampedZoom
    }

    var nodeHeight: CGFloat {
        64 * clampedZoom
    }

    var nodeHorizontalInset: CGFloat {
        12 * clampedZoom
    }

    var nodeVerticalSpacing: CGFloat {
        30 * clampedZoom
    }

    var nodeCornerRadius: CGFloat {
        12 * clampedZoom
    }

    var fontScale: CGFloat {
        min(max(clampedZoom, 0.85), 1.2)
    }

    var nodeWidth: CGFloat {
        max(columnWidth - (nodeHorizontalInset * 2), 140)
    }
}

struct ThreadCanvasDay: Identifiable, Hashable {
    let id: Int
    let date: Date
    let label: String
    let yOffset: CGFloat
    let height: CGFloat
}

struct ThreadCanvasNode: Identifiable, Hashable {
    let id: String
    let message: EmailMessage
    let threadID: String
    let frame: CGRect
    let dayIndex: Int
    let isManualOverride: Bool
}

struct ThreadCanvasColumn: Identifiable, Hashable {
    let id: String
    let title: String
    let xOffset: CGFloat
    let nodes: [ThreadCanvasNode]
    let latestDate: Date
}

struct ThreadCanvasLayout {
    let days: [ThreadCanvasDay]
    let columns: [ThreadCanvasColumn]
    let contentSize: CGSize
}

enum ThreadCanvasDateHelper {
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static func dayIndex(for date: Date, today: Date, calendar: Calendar) -> Int? {
        let startOfToday = calendar.startOfDay(for: today)
        let startOfDate = calendar.startOfDay(for: date)
        guard let diff = calendar.dateComponents([.day], from: startOfDate, to: startOfToday).day else {
            return nil
        }
        guard diff >= 0, diff < ThreadCanvasLayoutMetrics.dayCount else {
            return nil
        }
        return diff
    }

    static func dayDate(for index: Int, today: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: -index, to: calendar.startOfDay(for: today)) ?? today
    }

    static func label(for date: Date) -> String {
        dayFormatter.string(from: date)
    }
}
