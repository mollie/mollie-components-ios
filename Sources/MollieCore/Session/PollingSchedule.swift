import Foundation

/// Cadence and overall time budget for `SessionPoller`.
///
/// `intervals` is consumed one entry per poll; once exhausted, the last
/// entry is used for every subsequent poll. The poller stops with
/// `MollieError.timeout(operation: "session-polling")` if the cumulative
/// elapsed time exceeds `totalBudget`.
package struct PollingSchedule {
    package let intervals: [TimeInterval]
    package let totalBudget: TimeInterval

    package init(intervals: [TimeInterval], totalBudget: TimeInterval) {
        // Fail-fast: an empty interval list would deadlock the poll loop
        // (no fallback sleep) — assert at construction so callers cannot
        // ship a schedule that never re-polls.
        precondition(!intervals.isEmpty, "PollingSchedule.intervals must not be empty")
        self.intervals = intervals
        self.totalBudget = totalBudget
    }

    package static let `default` = PollingSchedule(
        intervals: [0.5, 1.0, 2.0, 4.0, 8.0, 16.0],
        totalBudget: 30
    )
}
