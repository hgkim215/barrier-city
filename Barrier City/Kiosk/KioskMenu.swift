//
//  KioskMenu.swift
//  Barrier City
//
//  키오스크 메뉴 정적 데이터. index 0(커피)만 기본 선택 —
//  나머지 카테고리는 상단 탭이라 앉은 사용자는 전환할 수 없다(장벽 ①).
//

enum KioskMenu {
    static let categories = ["커피", "디저트", "시즌 한정", "티·에이드"]

    static let coffee: [KioskMenuItem] = [
        KioskMenuItem(id: "americano",  name: "아메리카노",   price: 4000),
        KioskMenuItem(id: "latte",      name: "카페라떼",     price: 4500),
        KioskMenuItem(id: "vanilla",    name: "바닐라라떼",   price: 5000),
        KioskMenuItem(id: "espresso",   name: "에스프레소",   price: 3500),
        KioskMenuItem(id: "coldbrew",   name: "콜드브루",     price: 4800),
        KioskMenuItem(id: "cappuccino", name: "카푸치노",     price: 4500),
    ]

    /// 현재는 커피만 실제 데이터. 다른 카테고리는 전환 자체가 장벽이라 도달 불가지만,
    /// 실기에서 정말 닿아 전환한 경우를 위해 빈 배열 대신 안내용 최소 데이터를 둔다.
    static func items(for categoryIndex: Int) -> [KioskMenuItem] {
        categoryIndex == 0 ? coffee : [
            KioskMenuItem(id: "soldout", name: "품절", price: 0),
        ]
    }
}
