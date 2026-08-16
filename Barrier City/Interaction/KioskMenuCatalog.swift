import Foundation

enum KioskMenuTint: Equatable {
    case brown, orange, pink, green, cyan, purple, yellow, mint
}

struct KioskMenuItem: Identifiable, Equatable {
    let id: String
    let name: String
    let price: Int
    let symbol: String
    let tint: KioskMenuTint
    let categories: Set<KioskCategory>
}

enum KioskMenuCatalog {
    private static let allGridIDs = [
        "americano",
        "earl-grey",
        "lemon-ade",
        "chocolate-latte",
        "decaf-americano",
        "cafe-mocha",
        "green-tea",
        "grapefruit-ade",
        "rainbow-smoothie",
    ]

    private static let catalog: [KioskMenuItem] = [
        .init(id: "americano", name: "아메리카노", price: 4500, symbol: "cup.and.saucer.fill", tint: .brown, categories: [.best, .coffee]),
        .init(id: "cafe-latte", name: "카페라떼", price: 5000, symbol: "mug.fill", tint: .orange, categories: [.best, .coffee]),
        .init(id: "vanilla-latte", name: "바닐라라떼", price: 5500, symbol: "mug.fill", tint: .yellow, categories: [.best, .coffee]),
        .init(id: "earl-grey", name: "얼그레이", price: 4800, symbol: "leaf.fill", tint: .purple, categories: [.best, .tea]),
        .init(id: "peach-tea", name: "복숭아티", price: 5200, symbol: "drop.fill", tint: .pink, categories: [.best, .tea]),
        .init(id: "lemon-ade", name: "레몬에이드", price: 5500, symbol: "bubbles.and.sparkles.fill", tint: .yellow, categories: [.best, .ade]),
        .init(id: "chocolate-latte", name: "초콜릿라떼", price: 5500, symbol: "mug.fill", tint: .brown, categories: [.best, .nonCoffee]),
        .init(id: "decaf-americano", name: "디카페인 아메리카노", price: 5000, symbol: "cup.and.saucer.fill", tint: .mint, categories: [.best, .decaf]),
        .init(id: "decaf-latte", name: "디카페인 라떼", price: 5500, symbol: "mug.fill", tint: .mint, categories: [.best, .decaf]),

        .init(id: "cafe-mocha", name: "카페모카", price: 5500, symbol: "mug.fill", tint: .brown, categories: [.coffee]),
        .init(id: "cold-brew", name: "콜드브루", price: 5000, symbol: "snowflake", tint: .brown, categories: [.coffee]),
        .init(id: "espresso", name: "에스프레소", price: 4000, symbol: "cup.and.saucer.fill", tint: .brown, categories: [.coffee]),
        .init(id: "caramel-macchiato", name: "카라멜 마키아토", price: 5800, symbol: "mug.fill", tint: .orange, categories: [.coffee]),
        .init(id: "flat-white", name: "플랫화이트", price: 5200, symbol: "cup.and.saucer.fill", tint: .orange, categories: [.coffee]),

        .init(id: "green-tea", name: "녹차", price: 4500, symbol: "leaf.fill", tint: .green, categories: [.tea]),
        .init(id: "chamomile", name: "캐모마일", price: 4800, symbol: "camera.macro", tint: .yellow, categories: [.tea, .decaf]),
        .init(id: "rooibos", name: "루이보스", price: 4800, symbol: "leaf.fill", tint: .orange, categories: [.tea, .decaf]),
        .init(id: "hibiscus", name: "히비스커스", price: 4800, symbol: "camera.macro", tint: .pink, categories: [.tea, .decaf]),
        .init(id: "yuja-tea", name: "유자차", price: 5200, symbol: "sun.max.fill", tint: .yellow, categories: [.tea]),
        .init(id: "jasmine-tea", name: "자스민티", price: 4800, symbol: "leaf.fill", tint: .green, categories: [.tea]),

        .init(id: "grapefruit-ade", name: "자몽에이드", price: 5500, symbol: "bubbles.and.sparkles.fill", tint: .pink, categories: [.ade]),
        .init(id: "green-grape-ade", name: "청포도에이드", price: 5500, symbol: "bubbles.and.sparkles.fill", tint: .green, categories: [.ade]),
        .init(id: "peach-ade", name: "복숭아에이드", price: 5500, symbol: "bubbles.and.sparkles.fill", tint: .orange, categories: [.ade]),
        .init(id: "blue-lemon-ade", name: "블루레몬에이드", price: 5800, symbol: "bubbles.and.sparkles.fill", tint: .cyan, categories: [.ade]),
        .init(id: "yuja-ade", name: "유자에이드", price: 5500, symbol: "bubbles.and.sparkles.fill", tint: .yellow, categories: [.ade]),

        .init(id: "sweet-potato-latte", name: "고구마라떼", price: 5500, symbol: "mug.fill", tint: .purple, categories: [.nonCoffee]),
        .init(id: "matcha-latte", name: "말차라떼", price: 5500, symbol: "leaf.fill", tint: .green, categories: [.nonCoffee]),
        .init(id: "milk-tea", name: "밀크티", price: 5500, symbol: "mug.fill", tint: .brown, categories: [.nonCoffee]),
        .init(id: "strawberry-latte", name: "딸기라떼", price: 5800, symbol: "takeoutbag.and.cup.and.straw.fill", tint: .pink, categories: [.nonCoffee]),
        .init(id: "banana-milk", name: "바나나우유", price: 5000, symbol: "takeoutbag.and.cup.and.straw.fill", tint: .yellow, categories: [.nonCoffee]),

        .init(id: "decaf-vanilla-latte", name: "디카페인 바닐라라떼", price: 6000, symbol: "mug.fill", tint: .mint, categories: [.decaf]),

        .init(
            id: "rainbow-smoothie",
            name: "레인보우 스무디",
            price: 6500,
            symbol: "rainbow",
            tint: .pink,
            categories: [.other]),
        .init(id: "strawberry-smoothie", name: "딸기 스무디", price: 6000, symbol: "takeoutbag.and.cup.and.straw.fill", tint: .pink, categories: [.other]),
        .init(id: "mango-smoothie", name: "망고 스무디", price: 6000, symbol: "takeoutbag.and.cup.and.straw.fill", tint: .yellow, categories: [.other]),
        .init(id: "chocolate-frappe", name: "초콜릿 프라페", price: 6200, symbol: "snowflake", tint: .brown, categories: [.other]),
        .init(id: "cream-frappe", name: "크림 프라페", price: 6200, symbol: "snowflake", tint: .orange, categories: [.other]),
        .init(id: "mint-choco-frappe", name: "민트초코 프라페", price: 6500, symbol: "snowflake", tint: .mint, categories: [.other]),
        .init(id: "yogurt-smoothie", name: "요거트 스무디", price: 6000, symbol: "takeoutbag.and.cup.and.straw.fill", tint: .cyan, categories: [.other]),
        .init(id: "blueberry-smoothie", name: "블루베리 스무디", price: 6000, symbol: "takeoutbag.and.cup.and.straw.fill", tint: .purple, categories: [.other]),
        .init(id: "banana-smoothie", name: "바나나 스무디", price: 6000, symbol: "takeoutbag.and.cup.and.straw.fill", tint: .yellow, categories: [.other]),
    ]

    static func items(for category: KioskCategory) -> [KioskMenuItem] {
        switch category {
        case .best:
            Array(catalog.filter { $0.categories.contains(.best) }.prefix(9))
        case .all:
            allGridIDs.compactMap { id in catalog.first { $0.id == id } }
        default:
            catalog.filter { $0.categories.contains(category) }
        }
    }
}
