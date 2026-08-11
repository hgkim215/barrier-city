import Darwin
import DialogueKitOpenAI
import Foundation
import Observation
import OSLog

enum SpatialPerformanceScenario: String, CaseIterable, Identifiable {
    case baseline = "S1 기본"
    case arkit = "S2 ARKit"
    case physics = "S3 물리"
    case realtime = "S4 음성"
    case integrated = "S6 통합"
    case lifecycle = "S7 수명주기"

    var id: Self { self }

    var guidance: String {
        switch self {
        case .baseline:
            "손 추적과 대화를 끄고 이동 없이 측정"
        case .arkit:
            "손 추적을 켜고 손 가림·복구와 HUD 추종 반복"
        case .physics:
            "직진·회전·경사로·충돌을 반복"
        case .realtime:
            "NPC 대화를 10턴 진행하고 끼어들기 반복"
        case .integrated:
            "손 추적·주행·HUD·Realtime 대화를 동시에 수행"
        case .lifecycle:
            "몰입 공간과 대화를 반복 종료·재시작"
        }
    }
}

struct SpatialPerformanceSnapshot: Equatable {
    var scenario: SpatialPerformanceScenario = .baseline
    var elapsedSeconds: Double = 0
    var sampleCount = 0
    var averageFPS: Float = 0
    var minimumFPS: Float = 0
    var averageFrameMilliseconds: Float = 0
    var maximumFrameMilliseconds: Float = 0
    var averagePhysicsMilliseconds: Float = 0
    var maximumPhysicsMilliseconds: Float = 0
    var averageRaycastsPerFrame: Float = 0
    var peakResidentMemoryMB: Double = 0
    var thermalState = "nominal"
    var handUpdateDelta = 0
    var handTrackedDelta = 0
    var worldTrackingFallbackDelta = 0
    var realtimeErrorDelta = 0
}

/// 실기기 시나리오를 1Hz로 표본화한다. 최종 렌더 판정은 Instruments trace로 수행하고,
/// 이 객체는 반복 실행의 조건과 앱 내부 기준선을 같은 형식으로 남기는 용도다.
@Observable
@MainActor
final class SpatialPerformanceRecorder {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BarrierCity",
        category: "SpatialPerformance"
    )

    var selectedScenario: SpatialPerformanceScenario = .baseline
    private(set) var isRunning = false
    private(set) var snapshot = SpatialPerformanceSnapshot()

    @ObservationIgnored private var samplingTask: Task<Void, Never>?
    @ObservationIgnored private var startedAt: ContinuousClock.Instant?
    @ObservationIgnored private var fpsTotal: Float = 0
    @ObservationIgnored private var frameTimeTotal: Float = 0
    @ObservationIgnored private var physicsTimeTotal: Float = 0
    @ObservationIgnored private var raycastTotal: Float = 0
    @ObservationIgnored private var initialHandUpdates = 0
    @ObservationIgnored private var initialHandTracked = 0
    @ObservationIgnored private var initialWorldFallbacks = 0
    @ObservationIgnored private var initialRealtimeErrors = 0

    func start(model: AppModel) {
        stop(model: model)
        snapshot = SpatialPerformanceSnapshot(scenario: selectedScenario)
        isRunning = true
        startedAt = .now
        fpsTotal = 0
        frameTimeTotal = 0
        physicsTimeTotal = 0
        raycastTotal = 0
        initialHandUpdates = model.handUpdates
        initialHandTracked = model.handTracked
        initialWorldFallbacks = model.worldTrackingFallbacks
        initialRealtimeErrors = model.npcDialogue.realtimeMetrics.errorCount

        Self.logger.info("event=start scenario=\(self.selectedScenario.rawValue, privacy: .public)")
        samplingTask = Task { @MainActor [weak self, weak model] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self, let model else { return }
                self.sample(model: model)
            }
        }
    }

    func stop(model: AppModel) {
        guard isRunning else {
            samplingTask?.cancel()
            samplingTask = nil
            return
        }
        sample(model: model)
        isRunning = false
        samplingTask?.cancel()
        samplingTask = nil
        Self.logger.info(
            "event=stop scenario=\(self.snapshot.scenario.rawValue, privacy: .public) elapsed_s=\(self.snapshot.elapsedSeconds, privacy: .public) avg_fps=\(self.snapshot.averageFPS, privacy: .public) min_fps=\(self.snapshot.minimumFPS, privacy: .public) max_frame_ms=\(self.snapshot.maximumFrameMilliseconds, privacy: .public) max_physics_ms=\(self.snapshot.maximumPhysicsMilliseconds, privacy: .public) peak_memory_mb=\(self.snapshot.peakResidentMemoryMB, privacy: .public) thermal=\(self.snapshot.thermalState, privacy: .public)"
        )
    }

    private func sample(model: AppModel) {
        guard isRunning, let startedAt else { return }
        let motion = model.motion
        let elapsed = startedAt.duration(to: .now)
        snapshot.elapsedSeconds = Self.seconds(elapsed)
        snapshot.thermalState = Self.thermalDescription(ProcessInfo.processInfo.thermalState)
        snapshot.peakResidentMemoryMB = max(
            snapshot.peakResidentMemoryMB,
            Self.residentMemoryMB()
        )
        snapshot.handUpdateDelta = max(0, model.handUpdates - initialHandUpdates)
        snapshot.handTrackedDelta = max(0, model.handTracked - initialHandTracked)
        snapshot.worldTrackingFallbackDelta = max(
            0,
            model.worldTrackingFallbacks - initialWorldFallbacks
        )
        snapshot.realtimeErrorDelta = max(
            0,
            model.npcDialogue.realtimeMetrics.errorCount - initialRealtimeErrors
        )

        guard motion.frameRate > 0 else { return }
        snapshot.sampleCount += 1
        fpsTotal += motion.frameRate
        frameTimeTotal += motion.frameTimeMilliseconds
        physicsTimeTotal += motion.physicsUpdateMilliseconds
        raycastTotal += motion.raycastsPerFrame
        let divisor = Float(snapshot.sampleCount)
        snapshot.averageFPS = fpsTotal / divisor
        snapshot.minimumFPS = snapshot.sampleCount == 1
            ? motion.frameRate
            : min(snapshot.minimumFPS, motion.frameRate)
        snapshot.averageFrameMilliseconds = frameTimeTotal / divisor
        snapshot.maximumFrameMilliseconds = max(
            snapshot.maximumFrameMilliseconds,
            motion.frameTimeMilliseconds
        )
        snapshot.averagePhysicsMilliseconds = physicsTimeTotal / divisor
        snapshot.maximumPhysicsMilliseconds = max(
            snapshot.maximumPhysicsMilliseconds,
            motion.physicsUpdateMilliseconds
        )
        snapshot.averageRaycastsPerFrame = raycastTotal / divisor
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func thermalDescription(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_048_576
    }
}
