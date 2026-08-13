import Foundation

private func fail(_ message: String) -> Never {
    fatalError("FAIL: \(message)")
}

private func requireRange(_ needle: String, in source: String) -> Range<String.Index> {
    guard let range = source.range(of: needle) else {
        fail("missing \(needle)")
    }
    return range
}

@main
struct HandTrackingLifecycleContractTests {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fail("expected ImmersiveView and HandTrackingManager paths")
        }

        let immersive = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let tracker = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)

        let localStop = requireRange("handTracker.stopSession()", in: immersive)
        let ownershipGuard = requireRange("guard let immersiveSessionGeneration", in: immersive)
        let sharedClear = requireRange("handTracker.clearModelInput(model: model)", in: immersive)

        guard localStop.lowerBound < ownershipGuard.lowerBound else {
            fail("local ARKit session must stop before generation ownership guard")
        }
        guard ownershipGuard.lowerBound < sharedClear.lowerBound else {
            fail("shared model input must clear only after generation ownership guard")
        }

        _ = requireRange("func stopSession()", in: tracker)
        _ = requireRange("func clearModelInput(model: AppModel)", in: tracker)

    }
}
