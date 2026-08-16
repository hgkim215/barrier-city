import Foundation

private func fail(_ message: String) -> Never {
    fatalError("FAIL: \(message)")
}

@main
struct ImmersiveSceneCatalogTests {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            fail("expected RealityKit asset directory path")
        }

        let assetDirectory = URL(
            fileURLWithPath: CommandLine.arguments[1],
            isDirectory: true)
        let outdoorAsset = assetDirectory
            .appendingPathComponent(ImmersiveSceneCatalog.outdoor)
            .appendingPathExtension("usda")

        guard FileManager.default.fileExists(atPath: outdoorAsset.path) else {
            fail("configured outdoor scene has no USDA asset: \(outdoorAsset.path)")
        }
    }
}
