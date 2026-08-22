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
        guard currentProfile != .inactive else { return }
        try? configure(currentProfile)
        try? session.setActive(true)
    }

    var effectsPlaybackIsActive: Bool {
        currentProfile == .playback && count(for: .effects) > 0
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
        }

        do {
            if previous != .inactive {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            }
            guard target != .inactive else {
                currentProfile = .inactive
                return
            }

            try configure(target)
            try session.setActive(true)
            currentProfile = target
            if target == .playback {
                resumeEffectsIfNeeded()
            }
        } catch {
            currentProfile = .inactive
            if previous != .inactive {
                try? configure(previous)
                do {
                    try session.setActive(true)
                    currentProfile = previous
                    if previous == .playback { resumeEffectsIfNeeded() }
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
            try session.setCategory(.playAndRecord, mode: .voiceChat)
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
}
