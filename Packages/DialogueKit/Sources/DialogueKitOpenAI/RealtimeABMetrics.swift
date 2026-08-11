import Foundation

public struct RealtimeTransportAggregate: Sendable, Equatable {
    public internal(set) var sessionCount = 0
    public internal(set) var tokenSamples: [Int] = []
    public internal(set) var connectSamples: [Int] = []
    public internal(set) var readySamples: [Int] = []
    public internal(set) var turnSamples: [Int] = []
    public internal(set) var interruptionSamples: [Int] = []
    public internal(set) var errorCount = 0

    public var averageTokenMilliseconds: Int? { Self.average(tokenSamples) }
    public var averageConnectMilliseconds: Int? { Self.average(connectSamples) }
    public var averageReadyMilliseconds: Int? { Self.average(readySamples) }
    public var averageTurnMilliseconds: Int? { Self.average(turnSamples) }
    public var p95TurnMilliseconds: Int? { Self.p95(turnSamples) }
    public var averageInterruptionMilliseconds: Int? { Self.average(interruptionSamples) }
    public var p95InterruptionMilliseconds: Int? { Self.p95(interruptionSamples) }

    private static func average(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        return Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }

    private static func p95(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = max(1, Int(ceil(Double(sorted.count) * 0.95)))
        return sorted[rank - 1]
    }
}

public struct RealtimeABMetrics: Sendable, Equatable {
    private struct ActiveSession: Sendable, Equatable {
        let transport: RealtimeTransportKind
        var capturedToken = false
        var capturedConnect = false
        var capturedReady = false
        var completedTurns = 0
        var interruptions = 0
        var errors = 0
    }

    public private(set) var webSocket = RealtimeTransportAggregate()
    public private(set) var webRTC = RealtimeTransportAggregate()
    private var activeSession: ActiveSession?

    public init() {}

    public var hasMeasurements: Bool {
        webSocket.sessionCount > 0 || webRTC.sessionCount > 0
    }

    public mutating func beginSession(transport: RealtimeTransportKind) {
        activeSession = ActiveSession(transport: transport)
        updateAggregate(for: transport) { $0.sessionCount += 1 }
    }

    public mutating func ingest(_ snapshot: RealtimeMetricsSnapshot) {
        guard var activeSession,
              activeSession.transport == snapshot.transport else { return }

        updateAggregate(for: snapshot.transport) { aggregate in
            if !activeSession.capturedToken, let value = snapshot.tokenMilliseconds {
                aggregate.tokenSamples.append(value)
                activeSession.capturedToken = true
            }
            if !activeSession.capturedConnect, let value = snapshot.connectMilliseconds {
                aggregate.connectSamples.append(value)
                activeSession.capturedConnect = true
            }
            if !activeSession.capturedReady, let value = snapshot.readyMilliseconds {
                aggregate.readySamples.append(value)
                activeSession.capturedReady = true
            }
            if snapshot.completedTurns > activeSession.completedTurns,
               let value = snapshot.lastTurnMilliseconds {
                aggregate.turnSamples.append(value)
                activeSession.completedTurns = snapshot.completedTurns
            }
            if snapshot.interruptionCount > activeSession.interruptions,
               let value = snapshot.lastInterruptMilliseconds {
                aggregate.interruptionSamples.append(value)
                activeSession.interruptions = snapshot.interruptionCount
            }
            if snapshot.errorCount > activeSession.errors {
                aggregate.errorCount += snapshot.errorCount - activeSession.errors
                activeSession.errors = snapshot.errorCount
            }
        }
        self.activeSession = activeSession
    }

    public mutating func reset() {
        self = RealtimeABMetrics()
    }

    private mutating func updateAggregate(
        for transport: RealtimeTransportKind,
        _ update: (inout RealtimeTransportAggregate) -> Void
    ) {
        switch transport {
        case .webSocket:
            update(&webSocket)
        case .webRTC:
            update(&webRTC)
        }
    }
}
