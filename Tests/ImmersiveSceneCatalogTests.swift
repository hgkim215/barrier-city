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

        let indoorAsset = assetDirectory
            .appendingPathComponent(ImmersiveSceneCatalog.indoor)
            .appendingPathExtension("usda")
        let smoothieAsset = assetDirectory
            .appendingPathComponent(ImmersiveSceneCatalog.rainbowSmoothie)
            .appendingPathExtension("usdz")
        guard FileManager.default.fileExists(atPath: smoothieAsset.path) else {
            fail("configured smoothie has no USDZ asset: \(smoothieAsset.path)")
        }
        guard let indoorSource = try? String(contentsOf: indoorAsset, encoding: .utf8),
              indoorSource.contains("\"\(ImmersiveSceneCatalog.barTable)\"") else {
            fail("Indoor scene does not preserve the named BarTable contract")
        }
    }
}
