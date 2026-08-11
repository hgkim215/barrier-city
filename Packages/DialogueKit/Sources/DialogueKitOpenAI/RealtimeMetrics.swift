import Foundation

public enum RealtimeTransportKind: String, Sendable, Equatable {
    case webSocket = "websocket"
    case webRTC = "webrtc"
}

public struct RealtimeMetricsSnapshot: Sendable, Equatable {
    public let transport: RealtimeTransportKind
    public internal(set) var tokenMilliseconds: Int?
    public internal(set) var connectMilliseconds: Int?
    public internal(set) var readyMilliseconds: Int?
    public internal(set) var lastTurnMilliseconds: Int?
    public internal(set) var lastInterruptMilliseconds: Int?
    public internal(set) var completedTurns = 0
    public internal(set) var interruptionCount = 0
    public internal(set) var errorCount = 0

    public init(transport: RealtimeTransportKind) {
        self.transport = transport
    }

    public var hasMeasurements: Bool {
        tokenMilliseconds != nil
            || connectMilliseconds != nil
            || readyMilliseconds != nil
            || completedTurns > 0
            || interruptionCount > 0
            || errorCount > 0
    }
}

/// Realtime 이벤트의 경과 시간만 보관한다. transcript, 오디오, 토큰 값은 수집하지 않는다.
public struct RealtimeMetricsRecorder: Sendable {
    public private(set) var snapshot: RealtimeMetricsSnapshot

    private var sessionStartedAt: ContinuousClock.Instant?
    private var speechStoppedAt: ContinuousClock.Instant?
    private var localInterruptionStartedAt: ContinuousClock.Instant?

    public init(transport: RealtimeTransportKind) {
        snapshot = RealtimeMetricsSnapshot(transport: transport)
    }

    public mutating func beginSession(at now: ContinuousClock.Instant = .now) {
        snapshot = RealtimeMetricsSnapshot(transport: snapshot.transport)
        sessionStartedAt = now
        speechStoppedAt = nil
        localInterruptionStartedAt = nil
    }

    public mutating func recordToken(milliseconds: Int) {
        snapshot.tokenMilliseconds = max(0, milliseconds)
    }

    public mutating func recordSessionCreated(at now: ContinuousClock.Instant = .now) {
        guard let sessionStartedAt else { return }
        snapshot.connectMilliseconds = Self.milliseconds(sessionStartedAt.duration(to: now))
    }

    public mutating func recordSessionReady(at now: ContinuousClock.Instant = .now) {
        guard let sessionStartedAt else { return }
        snapshot.readyMilliseconds = Self.milliseconds(sessionStartedAt.duration(to: now))
    }

    public mutating func recordSpeechStopped(at now: ContinuousClock.Instant = .now) {
        speechStoppedAt = now
    }

    @discardableResult
    public mutating func recordFirstOutput(at now: ContinuousClock.Instant = .now) -> Bool {
        guard let speechStoppedAt else { return false }
        snapshot.lastTurnMilliseconds = Self.milliseconds(speechStoppedAt.duration(to: now))
        snapshot.completedTurns += 1
        self.speechStoppedAt = nil
        return true
    }

    public mutating func recordLocalInterruptionStart(
        at now: ContinuousClock.Instant = .now
    ) {
        guard localInterruptionStartedAt == nil else { return }
        localInterruptionStartedAt = now
    }

    @discardableResult
    public mutating func recordInterruptionCompleted(
        at now: ContinuousClock.Instant = .now
    ) -> Bool {
        guard let localInterruptionStartedAt else { return false }
        snapshot.lastInterruptMilliseconds = Self.milliseconds(
            localInterruptionStartedAt.duration(to: now)
        )
        snapshot.interruptionCount += 1
        self.localInterruptionStartedAt = nil
        return true
    }

    public mutating func cancelPendingInterruption() {
        localInterruptionStartedAt = nil
    }

    public mutating func recordError() {
        snapshot.errorCount += 1
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let seconds = Double(components.seconds)
        let fractionalSeconds = Double(components.attoseconds) / 1_000_000_000_000_000_000
        return max(0, Int(((seconds + fractionalSeconds) * 1_000).rounded()))
    }
}
