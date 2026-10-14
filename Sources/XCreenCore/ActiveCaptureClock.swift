import Foundation

/// Counts only successful, eligible capture time. Gaps never turn into
/// manufactured capture time: each observation contributes at most one second.
public struct ActiveCaptureClock: Codable, Sendable {
    public static let batchSeconds: TimeInterval = 300
    public static let imageIntervalSeconds: TimeInterval = 10

    public private(set) var activeSeconds: TimeInterval = 0
    public private(set) var lastEligibleAt: Date?

    public init() {}

    @discardableResult
    public mutating func recordEligibleSample(at timestamp: Date) -> TimeInterval {
        defer { lastEligibleAt = timestamp }
        guard let lastEligibleAt else { return 0 }
        let elapsed = timestamp.timeIntervalSince(lastEligibleAt)
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        let advance = min(1, elapsed)
        activeSeconds += advance
        return advance
    }

    public var isComplete: Bool { activeSeconds >= Self.batchSeconds }
    public var imageCountDue: Int { Int(activeSeconds / Self.imageIntervalSeconds) }

    /// Preserve accumulated eligible time but ensure time spent paused is never
    /// charged to the next eligible observation (including after a restart).
    public mutating func pause() { lastEligibleAt = nil }
    /// True when the next sample starts a new run instead of adding time.
    public var isPaused: Bool { lastEligibleAt == nil }

    public mutating func reset() {
        activeSeconds = 0
        lastEligibleAt = nil
    }
}
