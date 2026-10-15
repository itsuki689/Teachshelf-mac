import Foundation

public enum PlanTimeEdge: String, CaseIterable, Sendable { case start, end }

/// Minute-precision editing within one civil day; 1440 is its exclusive end.
public struct PlanTimeRange: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public var duration: Int { end - start }

    public init?(start: Int, end: Int) {
        guard start >= 0, start < end, end <= 1440 else { return nil }
        self.start = start; self.end = end
    }

    public func resized(_ edge: PlanTimeEdge, to minute: Int, snapping: Int = 10) -> PlanTimeRange {
        let step = min(1440, max(1, snapping))
        let rounded = Int((Double(max(0, min(1440, minute))) / Double(step)).rounded()) * step
        switch edge {
        case .start:
            return PlanTimeRange(start: max(0, min((end - 1) / step * step, rounded)), end: end)!
        case .end:
            return PlanTimeRange(start: start, end: min(1440, max((start / step + 1) * step, rounded)))!
        }
    }

    public func shifted(by minutes: Int) -> PlanTimeRange? {
        guard (-1440...1440).contains(minutes) else { return nil }
        return PlanTimeRange(start: start + minutes, end: end + minutes)
    }

    public func moved(to minute: Int, snapping: Int = 10) -> PlanTimeRange {
        let step = min(1440, max(1, snapping))
        let rounded = Int((Double(max(0, min(1440, minute))) / Double(step)).rounded()) * step
        let begin = max(0, min((1440 - duration) / step * step, rounded))
        return PlanTimeRange(start: begin, end: begin + duration)!
    }
}
