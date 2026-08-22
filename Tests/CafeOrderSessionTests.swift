import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

@main
@MainActor
struct CafeOrderSessionTests {
    static func main() {
        let session = CafeOrderSession()
        let firstGeneration = session.beginIndoorSession()
        expect(session.phase == .notOrdered, "Indoor entry starts without an order")
        expect(session.acceptOrder() == firstGeneration, "first order is accepted")
        expect(session.phase == .preparing, "accepted order starts preparation")
        expect(session.acceptOrder() == nil, "duplicate order is rejected")
        expect(session.markReady(generation: firstGeneration), "current preparation becomes ready")
        expect(session.phase == .readyAtCounter, "ready phase is stored")

        let secondGeneration = session.beginIndoorSession()
        expect(secondGeneration != firstGeneration, "new Indoor session advances generation")
        expect(!session.markReady(generation: firstGeneration), "stale generation cannot become ready")
        expect(session.phase == .notOrdered, "stale completion does not mutate new session")
        expect(session.markFailed(generation: secondGeneration), "current session records asset failure")
        expect(session.phase == .failed, "failed phase is stored")
        expect(session.acceptOrder() == nil, "failed service rejects order completion")

        session.resetForOutdoor()
        expect(session.phase == .notOrdered, "Outdoor reset returns to initial phase")
        print("PASS: CafeOrderSessionTests")
    }
}
