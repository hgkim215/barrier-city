@preconcurrency import AVFoundation
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
    }

    func stop() {
        guard hasAudioSessionClaim else { return }
        hasAudioSessionClaim = false
        AudioSessionCoordinator.shared.release(.realtimeConversation)
    }
}
