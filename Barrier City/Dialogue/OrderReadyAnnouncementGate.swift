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
