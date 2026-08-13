import Foundation

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else { fatalError("FAIL: \(message)") }
}

@main
@MainActor
struct QuestModelOutcomeTests {
    static func main() {
        let model = QuestModel()
        expect(model.advance(on: .kioskFailed), .ignored, "out-of-order event")
        expect(model.currentIndex, 0, "ignored event does not advance")

        let first = model.steps[0]
        let second = model.steps[1]
        expect(model.advance(on: .enteredIndoor),
               .advanced(completed: first, next: second),
               "first event advances")
        expect(model.currentIndex, 1, "current index after first event")

        _ = model.advance(on: .kioskFailed)
        let last = model.steps[2]
        expect(model.advance(on: .npcHelpDone),
               .advanced(completed: last, next: nil),
               "last event returns no next step")
        expect(model.currentStep, nil, "quest completed")
        expect(model.advance(on: .npcHelpDone), .ignored, "duplicate completion ignored")

        model.reset()
        expect(model.currentIndex, 0, "reset")
        print("QuestModelOutcomeTests: PASS")
    }
}
