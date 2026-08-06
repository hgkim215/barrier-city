import Foundation

private func fail(_ message: String) -> Never {
    fatalError("FAIL: \(message)")
}

@main
struct LoopingGuidePlaybackContractTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fail("expected LoopingGuideVideoView.swift path")
        }
        let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        guard let stopStart = source.range(of: "    func stop() {")?.lowerBound,
              let stopEnd = source.range(of: "\n    }", range: stopStart..<source.endIndex)?.upperBound else {
            fail("could not locate LoopingGuidePlayback.stop()")
        }
        let stopBody = String(source[stopStart..<stopEnd])

        if stopBody.contains("removeAllItems") {
            fail("stop must not remove queue items while AVPlayerLooper is active")
        }
        guard stopBody.contains("disableLooping") else {
            fail("stop must disable AVPlayerLooper before release")
        }
        guard stopBody.contains("looper = nil") else {
            fail("stop must release AVPlayerLooper")
        }

        print("LoopingGuidePlaybackContractTests: PASS")
    }
}
