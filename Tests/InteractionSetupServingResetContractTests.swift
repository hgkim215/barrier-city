import Foundation

private func fail(_ message: String) -> Never {
    fatalError("FAIL: \(message)")
}

@main
struct InteractionSetupServingResetContractTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fail("expected InteractionSetup.swift path")
        }

        let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        guard let installStart = source.range(of: "    static func install(")?.lowerBound,
              let panelSection = source.range(
                of: "        // 1) 문 선택 패널",
                range: installStart..<source.endIndex)?.lowerBound else {
            fail("could not locate InteractionSetup.install reset section")
        }
        let resetSection = source[installStart..<panelSection]

        guard let servingReset = resetSection.range(
            of: "appModel.rainbowSmoothieServing.resetForOutdoor()") else {
            fail("fresh immersive install must reset smoothie serving")
        }
        guard let clerkReset = resetSection.range(
            of: "appModel.npcClerk.resetForOutdoor()") else {
            fail("fresh immersive install must reset the clerk")
        }
        guard servingReset.lowerBound < clerkReset.lowerBound else {
            fail("fresh immersive install must reset serving before the clerk")
        }
    }
}
