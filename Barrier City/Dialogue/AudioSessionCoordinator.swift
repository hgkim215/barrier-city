//
//  AudioSessionCoordinator.swift
//  Barrier City
//
//  앱의 모든 AVAudioSession 변경을 직렬화한다.
//

@preconcurrency import AVFoundation
import Foundation

@MainActor
final class AudioSessionCoordinator {
    enum Activity: Hashable {
        case effects
        case playback
        case recording
        case realtimeConversation
    }

    enum CoordinationError: LocalizedError {
        case conflictingInputActivity

        var errorDescription: String? {
            switch self {
            case .conflictingInputActivity:
                "다른 마이크 입력이 사용 중입니다."
            }
        }
    }

    static let shared = AudioSessionCoordinator()

    private enum Profile: String {
        case inactive
        case playback
        case recording
        case realtimeConversation
    }

    private let session = AVAudioSession.sharedInstance()
    private var activityCounts: [Activity: Int] = [:]
    private var currentProfile: Profile = .inactive
    private var suspendEffectsHandler: (@MainActor () -> Void)?
    private var resumeEffectsHandler: (@MainActor () -> Void)?
    private var effectsAreSuspended = false
    private var suspendPlaybackHandler: (@MainActor () -> Void)?
    private var resumePlaybackHandler: (@MainActor () -> Void)?
    private var playbackIsSuspended = false
    private var realtimeConversationLifecycleHandler: (@MainActor (Bool) -> Void)?

    private init() {
        // AVPlayer(예: 튜토리얼 무음 안내 영상) 같은 이 코디네이터를 거치지 않는 다른
        // AVFoundation 재생 객체가 세션 카테고리/옵션을 우리 모르게 재구성해버릴 수 있다.
        // 그 경우 RealityKit 오디오는 내부적으로는 재생 중(isPlaying=true)이어도 실제
        // 출력은 끊겨 들리지 않는다. 라우트 변경을 감지해 우리가 원하는 프로필로 되돌린다.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reassertProfileIfNeeded()
            }
        }
    }

    /// 외부(AVPlayer 등)가 세션을 건드려 라우트가 바뀌었을 때, 우리가 활성 상태로
    /// 알고 있는 프로필을 다시 적용해 되찾아온다.
    private func reassertProfileIfNeeded() {
        // .playAndRecord/.voiceChat 진입 자체가 실기기 route change를 만들 수 있다.
        // 이 알림에 반응해 다시 category/active를 적용하면 WebRTC가 막 시작한 VPIO
        // AudioUnit을 무효화하므로 realtime 중에는 WebRTC가 라우트를 소유하게 둔다.
        guard currentProfile != .inactive,
              currentProfile != .realtimeConversation else { return }
        try? configure(currentProfile)
        try? session.setActive(true)
    }

    var effectsPlaybackIsActive: Bool {
        currentProfile == .playback && count(for: .effects) > 0
    }

    var realtimeConversationIsActive: Bool {
        currentProfile == .realtimeConversation
    }

    func registerEffectsLifecycle(
        suspend: @escaping @MainActor () -> Void,
        resume: @escaping @MainActor () -> Void
    ) {
        suspendEffectsHandler = suspend
        resumeEffectsHandler = resume
        if currentProfile == .playback, count(for: .effects) > 0 {
            resumeEffectsIfNeeded()
        }
    }

    func registerPlaybackLifecycle(
        suspend: @escaping @MainActor () -> Void,
        resume: @escaping @MainActor () -> Void
    ) {
        suspendPlaybackHandler = suspend
        resumePlaybackHandler = resume
        if currentProfile == .playback, count(for: .playback) > 0 {
            resumePlaybackIfNeeded()
        }
    }

    /// realtimeConversation 프로필에 실제로 들고 나는 시점에만 호출된다 —
    /// activityCounts로 이미 참조 카운트되므로, 이 대화와 주문 완료 안내처럼
    /// 서로 다른 RealtimeMediaTrackAudioSession 인스턴스가 겹쳐도 마지막 참조가
    /// 빠질 때만 꺼진다(개별 인스턴스가 직접 켜고 끄면 하나가 먼저 끝나 하나를
    /// 무음으로 만들 수 있다).
    func registerRealtimeConversationLifecycle(
        _ handler: @escaping @MainActor (Bool) -> Void
    ) {
        realtimeConversationLifecycleHandler = handler
    }

    func acquire(_ activity: Activity) throws {
        let conflictsWithActiveInput =
            activity == .recording && count(for: .realtimeConversation) > 0
            || activity == .realtimeConversation && count(for: .recording) > 0
        if conflictsWithActiveInput {
            throw CoordinationError.conflictingInputActivity
        }

        activityCounts[activity, default: 0] += 1
        do {
            try reconcileProfile()
            if currentProfile == .realtimeConversation {
                // realtime보다 우선순위가 낮은 재생 요청이 대화 도중 새로 들어와도
                // 세션 프로필은 바뀌지 않으므로, 여기서 명시적으로 정지 상태를 맞춘다.
                suspendEffectsIfNeeded()
                suspendPlaybackIfNeeded()
            }
        } catch {
            decrement(activity)
            try? reconcileProfile()
            throw error
        }
    }

    func release(_ activity: Activity) {
        guard count(for: activity) > 0 else { return }
        decrement(activity)
        try? reconcileProfile()
    }

    private func count(for activity: Activity) -> Int {
        activityCounts[activity, default: 0]
    }

    private func decrement(_ activity: Activity) {
        let remaining = max(0, count(for: activity) - 1)
        if remaining == 0 {
            activityCounts.removeValue(forKey: activity)
        } else {
            activityCounts[activity] = remaining
        }
    }

    private var desiredProfile: Profile {
        if count(for: .realtimeConversation) > 0 { return .realtimeConversation }
        if count(for: .recording) > 0 { return .recording }
        if count(for: .playback) > 0 || count(for: .effects) > 0 { return .playback }
        return .inactive
    }

    private func reconcileProfile() throws {
        let target = desiredProfile
        guard target != currentProfile else { return }
        try transition(to: target)
    }

    private func transition(to target: Profile) throws {
        let previous = currentProfile
        if previous == .playback, target != .playback {
            suspendEffectsIfNeeded()
            suspendPlaybackIfNeeded()
        }
        if previous == .realtimeConversation, target != .realtimeConversation {
            realtimeConversationLifecycleHandler?(false)
        }

        do {
            guard target != .inactive else {
                if previous != .inactive {
                    try session.setActive(false, options: .notifyOthersOnDeactivation)
                }
                currentProfile = .inactive
                return
            }

            try configure(target)
            try session.setActive(true)
            currentProfile = target
            if target == .playback {
                resumeEffectsIfNeeded()
                resumePlaybackIfNeeded()
            }
            if target == .realtimeConversation, previous != .realtimeConversation {
                realtimeConversationLifecycleHandler?(true)
            }
        } catch {
            currentProfile = .inactive
            if previous != .inactive {
                try? configure(previous)
                do {
                    try session.setActive(true)
                    currentProfile = previous
                    if previous == .playback {
                        resumeEffectsIfNeeded()
                        resumePlaybackIfNeeded()
                    }
                    if previous == .realtimeConversation { realtimeConversationLifecycleHandler?(true) }
                } catch { /* 원래 전환 오류를 호출자에게 전달한다. */ }
            }
            throw error
        }
    }

    private func configure(_ profile: Profile) throws {
        switch profile {
        case .inactive:
            break
        case .playback:
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        case .recording:
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        case .realtimeConversation:
            // .defaultToSpeaker가 없으면 헤드폰이 안 붙어 있을 때 .playAndRecord가
            // (전화 수화기에 해당하는) 조용한 receiver 경로로 나간다. 시뮬레이터는
            // Mac 스피커로만 재생해 이 라우팅 차이 자체가 없어 이 문제가 드러나지
            // 않았지만, 실기기(Vision Pro)에는 진짜 receiver/speaker 구분이 있어
            // 음성 출력이 작고 답답하게 들리고, 그 출력 라우트가 WebRTC의 에코
            // 제거(AEC) 기준 신호와도 어긋나 마이크 입력까지 불안정해진다.
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
            )
        }
    }

    private func suspendEffectsIfNeeded() {
        guard count(for: .effects) > 0, !effectsAreSuspended else { return }
        suspendEffectsHandler?()
        effectsAreSuspended = true
    }

    private func resumeEffectsIfNeeded() {
        guard count(for: .effects) > 0, currentProfile == .playback else {
            return
        }
        resumeEffectsHandler?()
        effectsAreSuspended = false
    }

    private func suspendPlaybackIfNeeded() {
        guard count(for: .playback) > 0, !playbackIsSuspended else { return }
        suspendPlaybackHandler?()
        playbackIsSuspended = true
    }

    private func resumePlaybackIfNeeded() {
        guard count(for: .playback) > 0, currentProfile == .playback else { return }
        resumePlaybackHandler?()
        playbackIsSuspended = false
    }
}
