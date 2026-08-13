import SwiftUI

internal struct DayFetchSelection: Identifiable {
    internal let date: Date
    internal let coverage: DayFetchCoverage?
    internal let scope: DayFetchScope

    internal var id: Date { date }
}

internal struct DayCoverageCalendarView: View {
    internal let scope: DayFetchScope
    internal let coverages: [Date: DayFetchCoverage]
    internal let fetchingDate: Date?
    internal let onSelect: (DayFetchSelection) -> Void

    @State private var displayedMonth: Date
    private let calendar: Calendar

    internal init(scope: DayFetchScope,
                  coverages: [Date: DayFetchCoverage],
                  fetchingDate: Date?,
                  calendar: Calendar = .current,
                  onSelect: @escaping (DayFetchSelection) -> Void) {
        self.scope = scope
        self.coverages = coverages
        self.fetchingDate = fetchingDate
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

            legend
        }
        .padding(14)
        .frame(width: 330)
    }

    private func dayButton(for date: Date) -> some View {
        let start = calendar.startOfDay(for: date)
        let isFuture = start > calendar.startOfDay(for: Date())
        let coverage = coverages[start]
        let state = fetchingDate.map(calendar.startOfDay(for:)) == start ? DayCoverageState.fetching : coverage?.state ?? .unknown
        return Button {
            onSelect(DayFetchSelection(date: start, coverage: coverage, scope: scope))
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color(for: isFuture ? .unknown : state).opacity(isFuture ? 0.10 : 0.82))
                Text(String(calendar.component(.day, from: date)))
                    .font(.caption.weight(state == .fetching ? .bold : .medium))
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
        .help(accessibilityLabel(date: date,
                                 state: state,
                                 coverage: coverage,
                                 isFuture: isFuture))
        .accessibilityHint(isFuture
                           ? ""
                           : NSLocalizedString("dayfetch.calendar.day.hint",
                                               comment: "Hint for selecting a coverage calendar day"))
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
        VStack(alignment: .leading, spacing: 14) {
            Text(NSLocalizedString("dayfetch.confirm.title",
                                   comment: "Confirm a calendar day fetch title"))
                .font(.title3.bold())
            LabeledContent(NSLocalizedString("dayfetch.confirm.date",
                                             comment: "Day fetch confirmation date label")) {
                Text(selection.date.formatted(date: .long, time: .omitted))
            }
            LabeledContent(NSLocalizedString("dayfetch.confirm.scope",
                                             comment: "Day fetch confirmation scope label")) {
                Text(selection.scope.displayName)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent(NSLocalizedString("dayfetch.confirm.status",
                                             comment: "Day fetch confirmation status label")) {
                Text(localizedState(selection.coverage?.state ?? .unknown))
            }
            if let coverage = selection.coverage {
                LabeledContent(NSLocalizedString("dayfetch.confirm.prior_counts",
                                                 comment: "Day fetch confirmation prior counts label")) {
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("dayfetch.confirm.prior_counts.value",
                                          comment: "Day fetch confirmation prior counts value"),
                        coverage.expectedCount,
                        coverage.fetchedCount,
                        coverage.absentCount
                    ))
                }
                if let lastSuccessAt = coverage.lastSuccessAt {
                    LabeledContent(NSLocalizedString("dayfetch.confirm.as_of",
                                                     comment: "Day fetch confirmation success time label")) {
                        Text(lastSuccessAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            Text(NSLocalizedString("dayfetch.confirm.description",
                                   comment: "Day fetch confirmation explanatory copy"))
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(NSLocalizedString("dayfetch.confirm.cancel",
                                         comment: "Cancel day fetch"), action: onCancel)
                Button(NSLocalizedString("dayfetch.confirm.action",
                                         comment: "Confirm day fetch"), action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430)
    }

    private func localizedState(_ state: DayCoverageState) -> String {
        NSLocalizedString("dayfetch.state.\(state.rawValue)",
                          comment: "Coverage state in day fetch confirmation")
    }
}
