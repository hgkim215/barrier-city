import Foundation

private func fail(_ message: String) -> Never {
    fatalError("FAIL: \(message)")
}

@main
struct SplashSequenceTests {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            fail("expected app Resources directory path")
        }

        let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard SplashSequence.resourceNames == ["Splash_1", "Splash_2"] else {
            fail("splash order must be Splash_1 then Splash_2")
        }
        guard SplashSequence.frameDuration == .milliseconds(500) else {
            fail("each splash must remain visible for exactly 0.5 seconds")
        }
        guard (0..<6).compactMap(SplashSequence.resourceName(atFrame:)) == [
            "Splash_1", "Splash_2", "Splash_1", "Splash_2", "Splash_1", "Splash_2",
        ] else {
            fail("splash frames must alternate continuously")
        }
        guard SplashSequence.resourceName(atFrame: -1) == nil else {
            fail("negative frame index must be rejected safely")
        }

        for name in SplashSequence.resourceNames {
            let file = resources.appendingPathComponent(name).appendingPathExtension("png")
            guard FileManager.default.fileExists(atPath: file.path) else {
                fail("missing splash resource: \(file.path)")
            }
            guard let data = try? Data(contentsOf: file),
                  data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
                fail("invalid PNG resource: \(file.path)")
            }
        }
    }
}
