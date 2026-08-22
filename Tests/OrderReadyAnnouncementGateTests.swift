private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

@main
struct OrderReadyAnnouncementGateTests {
    static func main() {
        var immediate = OrderReadyAnnouncementGate()
        expect(immediate.request(isChannelBusy: false) == .speakNow, "idle channel speaks now")
        expect(immediate.request(isChannelBusy: false) == .ignored, "immediate request is exactly once")

        var queued = OrderReadyAnnouncementGate()
        expect(queued.request(isChannelBusy: true) == .queued, "busy channel queues")
        expect(!queued.takePendingIfAvailable(isChannelBusy: true), "busy channel cannot drain")
        expect(queued.takePendingIfAvailable(isChannelBusy: false), "idle channel drains once")
        expect(!queued.takePendingIfAvailable(isChannelBusy: false), "drained queue does not repeat")

        queued.reset()
        expect(queued.request(isChannelBusy: false) == .speakNow, "new session can announce")
        print("PASS: OrderReadyAnnouncementGateTests")
    }
}
