import DialogueKit

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

@main
struct CafeOrderDialogueContextTests {
    static func main() {
        let expectedContexts: [(CafeOrderPhase, RainbowSmoothieFulfillmentContext)] = [
            (.notOrdered, .orderingAllowed),
            (.preparing, .preparing),
            (.readyAtCounter, .readyAtCounter),
            (.failed, .failed),
        ]

        for (phase, expectedContext) in expectedContexts {
            expect(
                phase.dialogueFulfillmentContext == expectedContext,
                "\(phase) maps to \(expectedContext)"
            )
        }

        print("PASS: CafeOrderDialogueContextTests")
    }
}
