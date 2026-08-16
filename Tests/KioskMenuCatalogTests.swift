import Foundation

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fatalError("FAIL: \(message) — expected \(expected), got \(actual)")
    }
}

@main
struct KioskMenuCatalogTests {
    static func main() {
        expect(KioskMenuCatalog.items(for: .best).count, 9, "best fills the 3x3 grid")
        expect(KioskMenuCatalog.items(for: .all).count, 9, "all fills the 3x3 grid")

        for category in KioskCategory.allCases where category != .best && category != .all {
            guard KioskMenuCatalog.items(for: category).count >= 6 else {
                fatalError("FAIL: \(category) must expose at least six items")
            }
        }

        let other = KioskMenuCatalog.items(for: .other)
        expect(other.first?.id, "rainbow-smoothie", "rainbow smoothie leads other")
        expect(other.first?.name, "레인보우 스무디", "story product uses approved name")
        expect(other.first?.price, 6500, "story product uses approved price")

        let coffeeIDs = Set(KioskMenuCatalog.items(for: .coffee).map(\.id))
        let teaIDs = Set(KioskMenuCatalog.items(for: .tea).map(\.id))
        guard coffeeIDs != teaIDs else {
            fatalError("FAIL: category switching must change visible products")
        }

        print("KioskMenuCatalogTests: PASS")
    }
}
