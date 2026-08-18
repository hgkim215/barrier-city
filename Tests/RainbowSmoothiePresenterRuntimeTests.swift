import Foundation
import RealityKit

private func fail(_ message: String) -> Never {
    fatalError("FAIL: \(message)")
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fail(message) }
}

private func expectNear(_ actual: Float, _ expected: Float, _ message: String) {
    guard abs(actual - expected) < 0.0001 else {
        fail("\(message) expected \(expected), got \(actual)")
    }
}

private func describe(_ value: SIMD3<Float>) -> String {
    String(
        format: "(%.6f, %.6f, %.6f)",
        value.x,
        value.y,
        value.z)
}

@main
@MainActor
struct RainbowSmoothiePresenterRuntimeTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fail("expected RealityKit asset directory path")
        }

        let assetDirectory = URL(
            fileURLWithPath: CommandLine.arguments[1],
            isDirectory: true)
        let indoorMap = try Entity.load(
            contentsOf: assetDirectory.appendingPathComponent("Indoor.usda"))
        let smoothie = try Entity.load(
            contentsOf: assetDirectory.appendingPathComponent("RainbowSmoothie.usdz"))
        let presenter = RainbowSmoothiePresenter()
        guard let barTable = indoorMap.findEntity(named: ImmersiveSceneCatalog.barTable) else {
            fail("Indoor preserves BarTable")
        }
        let barBounds = barTable.visualBounds(relativeTo: indoorMap)

        expect(
            presenter.install(smoothie: smoothie, in: indoorMap),
            "real assets install")
        guard let anchor = indoorMap.findEntity(named: "BarTableServingAnchor") else {
            fail("installed hierarchy preserves BarTable serving anchor")
        }

        let anchorPosition = anchor.position(relativeTo: indoorMap)
        let smoothieBounds = smoothie.visualBounds(relativeTo: indoorMap)
        let targetSurfaceY = barBounds.max.y + ServingPlacementTuning.surfaceClearance
        print("BarTable Indoor bounds min=\(describe(barBounds.min)) max=\(describe(barBounds.max))")
        print("Serving anchor Indoor position=\(describe(anchorPosition))")
        print("Smoothie Indoor bounds min=\(describe(smoothieBounds.min)) max=\(describe(smoothieBounds.max))")

        expect(anchor.parent === barTable, "anchor remains parented under BarTable")
        expect(presenter.smoothieEntity === smoothie, "presenter owns the supplied entity")
        expect(!smoothie.isEnabled, "installed smoothie starts hidden")
        expectNear(anchorPosition.y, targetSurfaceY, "anchor uses the visible counter top")
        expectNear(smoothieBounds.min.y, targetSurfaceY, "smoothie rests on the visible counter top")
        expectNear(
            smoothieBounds.extents.y,
            ServingPlacementTuning.targetSmoothieHeight,
            "smoothie height is normalized in the Indoor frame")

        presenter.reset()
        expect(
            !presenter.install(smoothie: Entity(), in: indoorMap),
            "empty smoothie bounds are rejected")
        expect(!presenter.isInstalled, "failed empty install leaves presenter reset")
        expect(
            indoorMap.findEntity(named: "BarTableServingAnchor") == nil,
            "failed empty install leaves no serving anchor")
        print("PASS: RainbowSmoothiePresenterRuntimeTests")
    }
}
