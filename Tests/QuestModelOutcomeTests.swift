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
        let firstAdvance = model.advance(on: .enteredIndoor)
        expect(firstAdvance,
               .advanced(completed: first, next: second),
               "first event advances")
        expect(firstAdvance.completesExperience, false,
               "an intermediate mission cannot trigger the ending")
        expect(model.currentIndex, 1, "current index after first event")

        _ = model.advance(on: .kioskFailed)
        let staffOrder = model.steps[2]
        let drinkWait = model.steps[3]
        expect(model.advance(on: .npcHelpDone),
               .advanced(completed: staffOrder, next: drinkWait),
               "NPC event advances to drink wait")
        expect(model.currentIndex, 3, "NPC completion is not experience completion")
        expect(model.currentStep, drinkWait, "drink wait remains pending")
        expect(model.advance(on: .npcHelpDone), .ignored, "duplicate completion ignored")

        let collectDrink = model.steps[4]
        expect(model.advance(on: .drinkReady),
               .advanced(completed: drinkWait, next: collectDrink),
               "drink ready advances to collection")
        let takeSeat = model.steps[5]
        expect(model.advance(on: .drinkCollected),
               .advanced(completed: collectDrink, next: takeSeat),
               "collection advances to seating")
        let completion = model.advance(on: .seatedAtTable)
        expect(completion,
               .advanced(completed: takeSeat, next: nil),
               "seating completes the experience")
        expect(completion.completesExperience, true,
               "the final mission triggers the ending exactly once")
        expect(model.currentStep, nil, "all post-order steps completed")
        expect(model.advance(on: .seatedAtTable).completesExperience, false,
               "a duplicate final event cannot trigger another ending")

        model.reset()
        expect(model.currentIndex, 0, "reset")
    }
}
