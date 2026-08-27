@preconcurrency import AVFoundation
import DialogueKitOpenAI
import Foundation

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

    private var hasAudioSessionClaim = false

    func start() async throws {
#if targetEnvironment(simulator)
        guard DevelopmentOptions.simulatorMicrophoneEnabled else {
            throw Error.simulatorUnavailable
        }
#endif
        guard !hasAudioSessionClaim else { return }
        let permissionGranted = await AVAudioApplication.requestRecordPermission()
        guard permissionGranted else {
            throw Error.permissionDenied
        }
        try Task.checkCancellation()
        try AudioSessionCoordinator.shared.acquire(.realtimeConversation)
        hasAudioSessionClaim = true
        // AVAudioSession이 완전히 .playAndRecord로 구성·활성화된 뒤에만 WebRTC의
        // 오디오 유닛을 켠다 — 그 전에 켜면 preconnect 때 초기화된(혹은 아직 앱이
        // 구성하지 않은 세션 기준의) 유닛을 그대로 쓰게 돼 마이크/음성이 죽는다.
        RealtimeWebRTCClient.setPlatformAudioSessionActive(true)
    }

    func stop() {
        guard hasAudioSessionClaim else { return }
        hasAudioSessionClaim = false
        // 세션 카테고리를 바꾸거나 비활성화하기 전에 WebRTC의 오디오 유닛부터
        // 끈다 — AVAudioEngine을 세션 전환 전에 멈춰야 하는 것과 같은 순서다.
        RealtimeWebRTCClient.setPlatformAudioSessionActive(false)
        AudioSessionCoordinator.shared.release(.realtimeConversation)
    }
}
