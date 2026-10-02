import Foundation
import SwiftUI

internal struct DayFetchSelection: Identifiable {
    internal let range: DateInterval
    internal let dayStarts: [Date]
    internal let coveragesByDay: [Date: DayFetchCoverage]
    internal let scope: DayFetchScope

    internal var id: String {
        "\(scope.key)|\(range.start.timeIntervalSinceReferenceDate)|\(range.end.timeIntervalSinceReferenceDate)"
    }

    internal var firstDate: Date { dayStarts[0] }
    internal var lastDate: Date { dayStarts[dayStarts.count - 1] }
    internal var dayCount: Int { dayStarts.count }
    internal var isSingleDay: Bool { dayCount == 1 }

    internal init?(startDate: Date,
                   endDate: Date,
                   coverages: [Date: DayFetchCoverage],
                   scope: DayFetchScope,
                   calendar: Calendar = .current) {
        let normalizedStart = calendar.startOfDay(for: min(startDate, endDate))
        let normalizedEnd = calendar.startOfDay(for: max(startDate, endDate))
        guard let endExclusive = calendar.date(byAdding: .day, value: 1, to: normalizedEnd),
              normalizedStart < endExclusive else {
            return nil
        }

        var days: [Date] = []
        var day = normalizedStart
        while day < endExclusive {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else {
                return nil
            }
            day = next
        }
        guard !days.isEmpty else { return nil }

        self.range = DateInterval(start: normalizedStart, end: endExclusive)
        self.dayStarts = days
        self.coveragesByDay = Dictionary(uniqueKeysWithValues: days.compactMap { day in
            coverages[day].map { (day, $0) }
        })
        self.scope = scope
    }
}

internal struct DayCoverageCalendarView: View {
    internal let scope: DayFetchScope
    internal let coverages: [Date: DayFetchCoverage]
    internal let fetchingDate: Date?
    internal let isFetchInProgress: Bool
    internal let onSelect: (DayFetchSelection) -> Void

    @State private var displayedMonth: Date
    @State private var selectionAnchor: Date?
    @State private var selectedRange: ClosedRange<Date>?
    private let calendar: Calendar

    internal init(scope: DayFetchScope,
                  coverages: [Date: DayFetchCoverage],
                  fetchingDate: Date?,
                  isFetchInProgress: Bool,
                  calendar: Calendar = .current,
                  onSelect: @escaping (DayFetchSelection) -> Void) {
        self.scope = scope
        self.coverages = coverages
        self.fetchingDate = fetchingDate
        self.isFetchInProgress = isFetchInProgress
        self.calendar = calendar
        self.onSelect = onSelect
        let month = calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
        _displayedMonth = State(initialValue: month)
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(scope.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .accessibilityLabel(String.localizedStringWithFormat(
                    NSLocalizedString("dayfetch.calendar.scope.accessibility",
                                      comment: "Calendar active mailbox scope accessibility label"),
                    scope.displayName
                ))

            HStack {
                Button {
                    changeMonth(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(NSLocalizedString("dayfetch.calendar.previous_month",
                                                      comment: "Previous coverage calendar month"))

                Spacer()
                Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
                Spacer()

                Button {
                    changeMonth(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(!canAdvanceMonth)
                .accessibilityLabel(NSLocalizedString("dayfetch.calendar.next_month",
                                                      comment: "Next coverage calendar month"))
            }

            Text(selectionInstruction)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("bettermail.day-coverage.selection-instructions")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 5) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }

                ForEach(Array(monthCells.enumerated()), id: \.offset) { _, date in
                    if let date {
                        dayButton(for: date)
                    } else {
                        Color.clear.frame(height: 30)
                    }
                }
            }

            selectionControls
            Divider()
            legend
        }
        .padding(14)
        .frame(width: 350)
    }

    private func dayButton(for date: Date) -> some View {
        let start = calendar.startOfDay(for: date)
        let isFuture = start > calendar.startOfDay(for: Date())
        let coverage = coverages[start]
        let state = fetchingDate.map(calendar.startOfDay(for:)) == start ? DayCoverageState.fetching : coverage?.state ?? .unknown
        let isSelected = selectedRange?.contains(start) == true
        return Button {
            selectDay(start)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color(for: isFuture ? .unknown : state).opacity(isFuture ? 0.10 : 0.82))
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 2.5)
                        .padding(1)
                }
                Text(String(calendar.component(.day, from: date)))
                    .font(.caption.weight(state == .fetching || isSelected ? .bold : .medium))
                    .foregroundStyle(isFuture ? Color.secondary.opacity(0.55) : foregroundColor(for: state))
                if state == .fetching {
                    ProgressView()
                        .controlSize(.mini)
                        .offset(x: 9, y: -9)
                }
            }
            .frame(height: 30)
        }
        .buttonStyle(.plain)
        .disabled(isFuture || state == .fetching)
        .accessibilityLabel(accessibilityLabel(date: date,
                                               state: state,
                                               coverage: coverage,
                                               isFuture: isFuture))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(accessibilityLabel(date: date,
                                 state: state,
                                 coverage: coverage,
                                 isFuture: isFuture))
        .accessibilityHint(accessibilityHint(isFuture: isFuture, isSelected: isSelected))
    }

    private var selectionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selectedRange {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.checkmark")
                        .foregroundStyle(.tint)
                    Text(selectionDescription(for: selectedRange))
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }

            HStack {
                Button(NSLocalizedString("dayfetch.calendar.selection.clear",
                                         comment: "Clear coverage calendar date range selection")) {
                    clearSelection()
                }
                .buttonStyle(.borderless)
                .disabled(selectedRange == nil)
                .accessibilityIdentifier("bettermail.day-coverage.clear-selection")

                Spacer()

                Button {
                    reviewSelection()
                } label: {
                    Text(reviewButtonTitle)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedRange == nil || isFetchInProgress)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("bettermail.day-coverage.review-selection")
            }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(NSLocalizedString("dayfetch.calendar.legend.title",
                                   comment: "Coverage calendar legend title"))
                .font(.caption.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 6)],
                      alignment: .leading,
                      spacing: 5) {
                legendItem(.unknown, key: "dayfetch.state.unknown")
                legendItem(.fetching, key: "dayfetch.state.fetching")
                legendItem(.partial, key: "dayfetch.state.partial")
                legendItem(.verified, key: "dayfetch.state.verified")
                legendItem(.failed, key: "dayfetch.state.failed")
            }
        }
    }

    private func legendItem(_ state: DayCoverageState, key: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color(for: state)).frame(width: 8, height: 8)
            Text(NSLocalizedString(key, comment: "Coverage calendar state legend label"))
                .font(.caption2)
        }
    }

    private var monthCells: [Date?] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth),
              let dayRange = calendar.range(of: .day, in: .month, for: displayedMonth) else {
            return []
        }
        let weekday = calendar.component(.weekday, from: monthInterval.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let days = dayRange.compactMap { day -> Date? in
            calendar.date(byAdding: .day, value: day - 1, to: monthInterval.start)
        }
        return Array(repeating: nil, count: leading) + days.map(Optional.some)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let startIndex = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        return Array(symbols[startIndex...] + symbols[..<startIndex])
    }

    private var canAdvanceMonth: Bool {
        guard let currentMonth = calendar.dateInterval(of: .month, for: Date())?.start else { return false }
        return displayedMonth < currentMonth
    }

    private func changeMonth(by value: Int) {
        guard let next = calendar.date(byAdding: .month, value: value, to: displayedMonth) else { return }
        displayedMonth = next
    }

    private func selectDay(_ day: Date) {
        let normalizedDay = calendar.startOfDay(for: day)
        if let anchor = selectionAnchor {
            selectedRange = min(anchor, normalizedDay)...max(anchor, normalizedDay)
            selectionAnchor = nil
        } else {
            selectionAnchor = normalizedDay
            selectedRange = normalizedDay...normalizedDay
        }
    }

    private func clearSelection() {
        selectionAnchor = nil
        selectedRange = nil
    }

    private func reviewSelection() {
        guard let selectedRange,
              let selection = DayFetchSelection(startDate: selectedRange.lowerBound,
                                                endDate: selectedRange.upperBound,
                                                coverages: coverages,
                                                scope: scope,
                                                calendar: calendar) else {
            return
        }
        onSelect(selection)
    }

    private var selectionInstruction: String {
        if selectionAnchor != nil {
            return NSLocalizedString("dayfetch.calendar.selection.choose_end",
                                     comment: "Coverage calendar instruction after choosing range start")
        }
        if selectedRange != nil {
            return NSLocalizedString("dayfetch.calendar.selection.start_over",
                                     comment: "Coverage calendar instruction after choosing a complete range")
        }
        return NSLocalizedString("dayfetch.calendar.selection.choose_start",
                                 comment: "Coverage calendar initial range selection instruction")
    }

    private var reviewButtonTitle: String {
        guard let selectedRange else {
            return NSLocalizedString("dayfetch.calendar.selection.review",
                                     comment: "Review coverage fetch selection button")
        }
        let dayCount = selectedDayCount(for: selectedRange)
        if dayCount == 1 {
            return NSLocalizedString("dayfetch.calendar.selection.review_one",
                                     comment: "Review a one-day coverage fetch selection button")
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("dayfetch.calendar.selection.review_count",
                              comment: "Review coverage fetch selection button with day count"),
            dayCount
        )
    }

    private func selectionDescription(for range: ClosedRange<Date>) -> String {
        if range.lowerBound == range.upperBound {
            return range.lowerBound.formatted(date: .long, time: .omitted)
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("dayfetch.calendar.selection.range",
                              comment: "Selected coverage date range summary"),
            range.lowerBound.formatted(date: .abbreviated, time: .omitted),
            range.upperBound.formatted(date: .abbreviated, time: .omitted),
            selectedDayCount(for: range)
        )
    }

    private func selectedDayCount(for range: ClosedRange<Date>) -> Int {
        max(1, (calendar.dateComponents([.day], from: range.lowerBound, to: range.upperBound).day ?? 0) + 1)
    }

    private func accessibilityHint(isFuture: Bool, isSelected: Bool) -> String {
        guard !isFuture else { return "" }
        if isSelected {
            return NSLocalizedString("dayfetch.calendar.day.selected.hint",
                                     comment: "Hint for a selected coverage calendar day")
        }
        return NSLocalizedString("dayfetch.calendar.day.hint",
                                 comment: "Hint for selecting a coverage calendar day")
    }

    private func color(for state: DayCoverageState) -> Color {
        switch state {
        case .unknown: return Color.gray
        case .fetching: return Color.blue
        case .partial: return Color.orange
        case .verified: return Color.green
        case .failed: return Color.red
        }
    }

    private func foregroundColor(for state: DayCoverageState) -> Color {
        state == .unknown ? .primary : .white
    }

    private func accessibilityLabel(date: Date,
                                    state: DayCoverageState,
                                    coverage: DayFetchCoverage?,
                                    isFuture: Bool) -> String {
        if isFuture {
            return String.localizedStringWithFormat(
                NSLocalizedString("dayfetch.calendar.day.future.accessibility",
                                  comment: "Future calendar day accessibility label"),
                date.formatted(date: .long, time: .omitted)
            )
        }
        var parts = [date.formatted(date: .long, time: .omitted), localizedState(state)]
        if let coverage {
            parts.append(String.localizedStringWithFormat(
                NSLocalizedString("dayfetch.calendar.day.counts.accessibility",
                                  comment: "Coverage counts accessibility detail"),
                coverage.expectedCount,
                coverage.absentCount
            ))
            if let success = coverage.lastSuccessAt {
                parts.append(String.localizedStringWithFormat(
                    NSLocalizedString("dayfetch.calendar.day.as_of.accessibility",
                                      comment: "Coverage success time accessibility detail"),
                    success.formatted(date: .omitted, time: .shortened)
                ))
            }
        }
        return parts.joined(separator: ", ")
    }

    private func localizedState(_ state: DayCoverageState) -> String {
        NSLocalizedString("dayfetch.state.\(state.rawValue)",
                          comment: "Coverage calendar state name")
    }
}

internal struct DayFetchConfirmationSheet: View {
    internal let selection: DayFetchSelection
    internal let onConfirm: () -> Void
    internal let onCancel: () -> Void

    internal var body: some View {
        Form {
            Section {
                LabeledContent(dateLabel) {
                    Text(dateSummary)
                        .multilineTextAlignment(.trailing)
                }
                if !selection.isSingleDay {
                    LabeledContent(NSLocalizedString("dayfetch.confirm.days",
                                                     comment: "Multi-day fetch day count label")) {
                        Text(String(selection.dayCount))
                    }
                }
                LabeledContent(NSLocalizedString("dayfetch.confirm.scope",
                                                 comment: "Day fetch confirmation scope label")) {
                    Text(selection.scope.displayName)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent(NSLocalizedString("dayfetch.confirm.status",
                                                 comment: "Day fetch confirmation status label")) {
                    Text(coverageStatusSummary)
                        .multilineTextAlignment(.trailing)
                }
                if !selection.coveragesByDay.isEmpty {
                    LabeledContent(NSLocalizedString("dayfetch.confirm.prior_counts",
                                                     comment: "Day fetch confirmation prior counts label")) {
                        Text(String.localizedStringWithFormat(
                            NSLocalizedString("dayfetch.confirm.prior_counts.value",
                                              comment: "Day fetch confirmation prior counts value"),
                            priorExpectedCount,
                            priorFetchedCount,
                            priorAbsentCount
                        ))
                    }
                    if let lastSuccessAt {
                        LabeledContent(NSLocalizedString("dayfetch.confirm.as_of",
                                                         comment: "Day fetch confirmation success time label")) {
                            Text(lastSuccessAt.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }
            } header: {
                Text(confirmationTitle)
            } footer: {
                Text(confirmationDescription)
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("dayfetch.confirm.cancel",
                                         comment: "Cancel day fetch"), action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(confirmButtonTitle, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .presentationSizing(.form)
    }

    private var dateLabel: String {
        selection.isSingleDay
            ? NSLocalizedString("dayfetch.confirm.date", comment: "Day fetch confirmation date label")
            : NSLocalizedString("dayfetch.confirm.date_range", comment: "Multi-day fetch confirmation range label")
    }

    private var dateSummary: String {
        guard !selection.isSingleDay else {
            return selection.firstDate.formatted(date: .long, time: .omitted)
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("dayfetch.confirm.date_range.value",
                              comment: "Multi-day fetch confirmation range value"),
            selection.firstDate.formatted(date: .long, time: .omitted),
            selection.lastDate.formatted(date: .long, time: .omitted)
        )
    }

    private var confirmationTitle: String {
        selection.isSingleDay
            ? NSLocalizedString("dayfetch.confirm.title", comment: "Confirm a calendar day fetch title")
            : NSLocalizedString("dayfetch.confirm.range.title", comment: "Confirm a calendar date range fetch title")
    }

    private var confirmationDescription: String {
        selection.isSingleDay
            ? NSLocalizedString("dayfetch.confirm.description", comment: "Day fetch confirmation explanatory copy")
            : NSLocalizedString("dayfetch.confirm.range.description", comment: "Multi-day fetch confirmation explanatory copy")
    }

    private var confirmButtonTitle: String {
        guard !selection.isSingleDay else {
            return NSLocalizedString("dayfetch.confirm.action", comment: "Confirm day fetch")
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("dayfetch.confirm.range.action",
                              comment: "Confirm multi-day fetch with day count"),
            selection.dayCount
        )
    }

    private var coverageStatusSummary: String {
        let counts = Dictionary(grouping: selection.dayStarts) { day in
            selection.coveragesByDay[day]?.state ?? .unknown
        }.mapValues(\.count)
        let summaries = DayCoverageState.allCases.compactMap { state -> String? in
            guard let count = counts[state], count > 0 else { return nil }
            return String.localizedStringWithFormat(
                NSLocalizedString("dayfetch.confirm.status_count",
                                  comment: "Coverage status count in multi-day confirmation"),
                count,
                localizedState(state)
            )
        }
        return ListFormatter.localizedString(byJoining: summaries)
    }

    private var priorExpectedCount: Int {
        selection.coveragesByDay.values.reduce(0) { $0 + $1.expectedCount }
    }

    private var priorFetchedCount: Int {
        selection.coveragesByDay.values.reduce(0) { $0 + $1.fetchedCount }
    }

    private var priorAbsentCount: Int {
        selection.coveragesByDay.values.reduce(0) { $0 + $1.absentCount }
    }

    private var lastSuccessAt: Date? {
        selection.coveragesByDay.values.compactMap(\.lastSuccessAt).max()
    }

    private func localizedState(_ state: DayCoverageState) -> String {
        NSLocalizedString("dayfetch.state.\(state.rawValue)",
                          comment: "Coverage state in day fetch confirmation")
    }
}
