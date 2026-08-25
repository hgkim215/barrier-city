private func fail(_ message: String) -> Never {
    fatalError("FAIL: \(message)")
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail(message) }
}

@main
struct WheelchairCollisionPolicyTests {
    static func main() {
        expect(
            WheelchairCollisionPolicy.shouldPlayImpactFeedback(
                obstacleKind: .environment,
                impactSpeed: 0.8,
                wasAlreadyBlocked: false),
            "a real first impact with static environment must keep feedback")
        expect(
            !WheelchairCollisionPolicy.shouldPlayImpactFeedback(
                obstacleKind: .npc,
                impactSpeed: 0.8,
                wasAlreadyBlocked: false),
            "dynamic NPC contact must stop silently without camera kick")
        expect(
            !WheelchairCollisionPolicy.shouldPlayImpactFeedback(
                obstacleKind: .environment,
                impactSpeed: 0.1,
                wasAlreadyBlocked: false),
            "slow wall contact must not chatter")
        expect(
            !WheelchairCollisionPolicy.shouldPlayImpactFeedback(
                obstacleKind: .environment,
                impactSpeed: 0.8,
                wasAlreadyBlocked: true),
            "continued contact must not replay impact feedback")

        print("All WheelchairCollisionPolicy tests passed.")
    }
}
