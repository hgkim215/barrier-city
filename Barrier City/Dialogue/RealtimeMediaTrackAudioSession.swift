@preconcurrency import AVFoundation
import DialogueKitOpenAI
import Foundation
import OSLog

/// WebRTC의 네이티브 오디오 장치가 마이크와 출력을 소유하는 동안 앱의 다른 오디오와
/// AVAudioSession 변경이 충돌하지 않도록 기존 코디네이터에 수명주기를 등록한다.
@MainActor
final class RealtimeMediaTrackAudioSession {
    enum Error: LocalizedError {
        case simulatorUnavailable
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .simulatorUnavailable:
                "시뮬레이터 마이크 입력이 비활성화되어 있습니다."
            case .permissionDenied:
                "마이크 권한이 필요합니다."
            }
        }
    }

    private static let logger = Logger(
        subsystem: "com.Television.Barrier-City",
        category: "RealtimeAudio")

    private var hasAudioSessionClaim = false
    private static var didRegisterLifecycle = false

    func start() async throws {
#if targetEnvironment(simulator)
        guard DevelopmentOptions.simulatorMicrophoneEnabled else {
            throw Error.simulatorUnavailable
        }
#endif
        guard !hasAudioSessionClaim else { return }
        let permissionGranted = await AVAudioApplication.requestRecordPermission()
        guard permissionGranted else {
            Self.logger.error("[MIC] 녹음 권한 거부됨 - 설정에서 마이크를 허용해야 한다")
            throw Error.permissionDenied
        }
        try Task.checkCancellation()
        Self.registerLifecycleIfNeeded()
        do {
            try AudioSessionCoordinator.shared.acquire(.realtimeConversation)
        } catch {
            // 여기서 실패하면 마이크가 아예 안 열린다. 조용히 던지지 말고 남긴다.
            Self.logger.error(
                "[MIC] 오디오 세션 획득 실패 \(error.localizedDescription, privacy: .public) \(RealtimeWebRTCClient.platformAudioDiagnostics, privacy: .public)")
            throw error
        }
        hasAudioSessionClaim = true
    }

    func stop() {
        guard hasAudioSessionClaim else { return }
        hasAudioSessionClaim = false
        AudioSessionCoordinator.shared.release(.realtimeConversation)
    }

    /// WebRTC의 오디오 유닛 on/off를 이 인스턴스가 직접 켜고 끄지 않고
    /// AudioSessionCoordinator의 realtimeConversation 프로필 전환에 묶는다. 이
    /// 대화(NPCDialogueController)와 주문 완료 안내(orderReadyRealtimeSession)처럼
    /// 서로 다른 RealtimeMediaTrackAudioSession 인스턴스가 있을 수 있는데, 각자
    /// 직접 켜고 끄면 참조 카운트가 없어 하나가 먼저 stop()해도 다른 하나의
    /// 오디오까지 무음이 된다. activityCounts로 이미 참조 카운트되는 프로필
    /// 전환 시점(마지막 참조가 빠질 때만 off)에 걸면 이 문제가 없다.
    private static func registerLifecycleIfNeeded() {
        guard !didRegisterLifecycle else { return }
        didRegisterLifecycle = true
        let logger = Self.logger
        AudioSessionCoordinator.shared.registerRealtimeConversationLifecycle { isActive in
            // AVAudioSession이 완전히 .playAndRecord로 구성·활성화된 뒤에만 켜고,
            // 세션을 건드리기 전에 꺼야 한다 — AVAudioEngine을 세션 전환 전에
            // 멈춰야 하는 것과 같은 순서다(AudioSessionCoordinator.transition이
            // 이 순서를 보장한다).
            RealtimeWebRTCClient.setPlatformAudioSessionActive(isActive)
            // 실기에서 마이크가 안 잡히는 원인을 가리기 위한 상태 스냅샷.
            // 카테고리/입력 라우트/WebRTC 오디오 유닛 상태를 한 줄로 남긴다.
            logger.notice(
                "[MIC] audioUnit active=\(isActive, privacy: .public) \(RealtimeWebRTCClient.platformAudioDiagnostics, privacy: .public)")
        }
    }
}
