private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

@MainActor
private final class MutationRecorder {
    var count = 0
}

@main
struct OrderReadyAnnouncementCancellationTests {
    @MainActor
    static func main() async {
        let recorder = MutationRecorder()
        let task = Task { @MainActor in
            OrderReadyAnnouncementExecutionGate.performIfNotCancelled {
                recorder.count += 1
            }
        }

        task.cancel()
        let didPerform = await task.value

        expect(!didPerform, "cancelled task does not report initial mutation")
        expect(recorder.count == 0, "cancelled task never runs initial mutation")
        print("PASS: OrderReadyAnnouncementCancellationTests")
    }
}
