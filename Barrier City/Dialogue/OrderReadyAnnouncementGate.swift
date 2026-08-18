import Foundation

enum OrderReadyAnnouncementContent {
    static let line = "주문하신 레인보우 스무디 나왔습니다. 카운터에서 가져가 주세요."
}

enum OrderReadyAnnouncementExecutionGate {
    @discardableResult
    static func performIfNotCancelled(_ operation: () -> Void) -> Bool {
        guard !Task.isCancelled else { return false }
        operation()
        return true
    }
}

/// 대기열과 실행 task에서만 계산되는 준비 안내의 UI 표시 상태.
/// 별도 Boolean을 저장하지 않아 안내 생명주기와 공간 UI가 어긋나지 않게 한다.
struct OrderReadyAnnouncementPresentationState: Equatable {
    let isPresented: Bool

    init(hasPendingAnnouncement: Bool, hasActiveTask: Bool) {
        isPresented = hasPendingAnnouncement || hasActiveTask
    }

    func interactionAttachmentIsVisible(
        isNormallyVisible: Bool,
        isGuideLocked: Bool,
        allowsConversation: Bool
    ) -> Bool {
        isNormallyVisible
            && (isPresented || (!isGuideLocked && allowsConversation))
    }

    func showsTalkButton(
        isEncounterActive: Bool,
        clerkPhaseAllowsButton: Bool
    ) -> Bool {
        !isPresented && !isEncounterActive && clerkPhaseAllowsButton
    }
}

/// 음성이 즉시 실패하거나 캐시에서 바로 끝나도 3초 동안 자막을 보장한다.
enum OrderReadyAnnouncementPresentationTiming {
    static let minimumVisibleDuration: Duration = .seconds(3)

    @MainActor
    static func perform(
        present: () -> Void,
        speak: @escaping @MainActor () async -> Void,
        waitForMinimumVisibility: @escaping @Sendable () async throws -> Void
    ) async -> Bool {
        guard OrderReadyAnnouncementExecutionGate.performIfNotCancelled(present) else {
            return false
        }

        let speechTask = Task { @MainActor in
            await speak()
        }
        return await withTaskCancellationHandler {
            do {
                try await waitForMinimumVisibility()
            } catch {
                speechTask.cancel()
                return false
            }
            await speechTask.value
            return !Task.isCancelled
        } onCancel: {
            speechTask.cancel()
        }
    }
}

struct OrderReadyAnnouncementGate {
    enum RequestResult: Equatable {
        case speakNow
        case queued
        case ignored
    }

    private var pending = false
    private var consumed = false

    var hasPendingAnnouncement: Bool { pending && !consumed }

    mutating func request(isChannelBusy: Bool) -> RequestResult {
        guard !consumed, !pending else { return .ignored }
        if isChannelBusy {
            pending = true
            return .queued
        }
        consumed = true
        return .speakNow
    }

    mutating func takePendingIfAvailable(isChannelBusy: Bool) -> Bool {
        guard pending, !consumed, !isChannelBusy else { return false }
        pending = false
        consumed = true
        return true
    }

    mutating func reset() {
        pending = false
        consumed = false
    }
}
