@preconcurrency import AVFoundation
import Foundation

/// WebRTC의 네이티브 오디오 장치가 마이크와 출력을 소유하는 동안 앱의 다른 오디오와
/// AVAudioSession 변경이 충돌하지 않도록 기존 코디네이터에 수명주기를 등록한다.
@MainActor
final class RealtimeMediaTrackAudioSession {
    private var hasAudioSessionClaim = false

    func start() async throws {
#if targetEnvironment(simulator)
        guard DevelopmentOptions.simulatorMicrophoneEnabled else {
            throw RealtimeAudioIO.AudioError.simulatorUnavailable
        }
#endif
        guard !hasAudioSessionClaim else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            throw RealtimeAudioIO.AudioError.permissionDenied
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
