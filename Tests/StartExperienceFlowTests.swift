import Foundation

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fatalError("FAIL: \(message) — expected \(expected), got \(actual)")
    }
}

@main
struct StartExperienceFlowTests {
    static func main() {
        let opened = StartExperienceFlow.resolve(.immersiveOpened)
        expect(opened.windowAction, .dismissStartWindow,
               "a successful immersive open dismisses the start window")
        expect(opened.errorMessage, nil,
               "a successful immersive open has no error")

        let cancelled = StartExperienceFlow.resolve(.immersiveOpenCancelled)
        expect(cancelled.windowAction, .none,
               "a cancelled immersive open keeps the start window visible")
        expect(cancelled.errorMessage, "몰입 공간 열기가 취소되었습니다.",
               "a cancelled immersive open explains why the start window remains")

        let failed = StartExperienceFlow.resolve(.immersiveOpenFailed)
        expect(failed.windowAction, .none,
               "a failed immersive open keeps the start window visible")
        expect(failed.errorMessage, "몰입 공간을 열 수 없습니다. 잠시 후 다시 시도해 주세요.",
               "a failed immersive open gives the retry message")

        let ended = StartExperienceFlow.resolve(.immersiveEnded)
        expect(ended.windowAction, .openStartWindow,
               "ending an immersive session restores the start window")
        expect(ended.errorMessage, nil,
               "ending an immersive session is not an error")

        print("StartExperienceFlowTests: PASS")
    }
}
