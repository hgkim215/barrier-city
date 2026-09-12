import SwiftUI

private extension KioskCategory {
    var title: String {
        switch self {
        case .best: "베스트"
        case .coffee: "커피"
        case .tea: "티"
        case .ade: "에이드"
        case .nonCoffee: "논커피"
        case .decaf: "디카페인"
        case .other: "기타"
        case .all: "전체"
        }
    }
}

private extension KioskMenuTint {
    var color: Color {
        switch self {
        case .brown: Color(red: 0.46, green: 0.27, blue: 0.12)
        case .orange: Color(red: 0.95, green: 0.43, blue: 0.08)
        case .pink: Color(red: 0.95, green: 0.22, blue: 0.48)
        case .green: Color(red: 0.12, green: 0.62, blue: 0.30)
        case .cyan: Color(red: 0.00, green: 0.62, blue: 0.78)
        case .purple: Color(red: 0.48, green: 0.28, blue: 0.80)
        case .yellow: Color(red: 0.95, green: 0.67, blue: 0.02)
        case .mint: Color(red: 0.05, green: 0.65, blue: 0.55)
        }
    }
}

struct KioskOrderView: View {
    private let menuColumns = Array(
        repeating: GridItem(.flexible(), spacing: 10),
        count: 3)

    var body: some View {
        let im = InteractionModel.shared

        ZStack {
            KioskTheme.background

            VStack(spacing: 0) {
                header
                categories(interactionModel: im)

                Rectangle()
                    .fill(KioskTheme.border)
                    .frame(height: 1)

                menuGrid(interactionModel: im)
                orderSummary(interactionModel: im)
            }
        }
        .frame(width: 540, height: 960)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(KioskTheme.border, lineWidth: 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("BARRIER CAFE 키오스크 메뉴")
    }

    private var header: some View {
        ZStack {
            Text("BARRIER CAFE")
                .font(.system(size: 31, weight: .black, design: .rounded))
                .foregroundStyle(KioskTheme.ink)

            HStack {
                // 실제 동작이 없는 장식 아이콘. 버튼으로 오인되지 않게 VoiceOver에서 숨긴다.
                Image(systemName: "house.fill")
                    .font(.system(size: 27, weight: .black))
                    .foregroundStyle(KioskTheme.ink)
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)

                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 86)
    }

    private func categories(interactionModel im: InteractionModel) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
            spacing: 8
        ) {
            ForEach(KioskCategory.allCases, id: \.self) { category in
                categoryButton(category, interactionModel: im)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    private func categoryButton(
        _ category: KioskCategory,
        interactionModel im: InteractionModel
    ) -> some View {
        let isSelected = im.kioskSelectedCategory == category

        return Button {
            withAnimation(.easeOut(duration: 0.20)) {
                _ = im.selectKioskCategory(category)
            }
        } label: {
            Text(category.title)
                .font(.system(size: 17, weight: .black, design: .rounded))
                .foregroundStyle(isSelected ? KioskTheme.surface : KioskTheme.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(
                    isSelected ? KioskTheme.ink : KioskTheme.surface,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? KioskTheme.ink : KioskTheme.border, lineWidth: 1.5)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(im.kioskInputEnabled)
        .hoverEffect(.highlight)
        .accessibilityLabel("\(category.title) 카테고리")
        .accessibilityHint(
            im.kioskInputEnabled
                ? "선택하면 접근성 장벽 안내가 열립니다"
                : "키오스크 가까이에서 선택할 수 있습니다")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func menuGrid(interactionModel im: InteractionModel) -> some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: menuColumns, spacing: 10) {
                ForEach(KioskMenuCatalog.items(for: im.kioskSelectedCategory)) { item in
                    menuCard(item, interactionModel: im)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .scrollIndicators(.visible)
        .frame(maxHeight: .infinity)
    }

    private func menuCard(
        _ item: KioskMenuItem,
        interactionModel im: InteractionModel
    ) -> some View {
        let isSelected = im.kioskSelectedMenuID == item.id

        return Button {
            _ = im.selectKioskMenu(id: item.id)
        } label: {
            VStack(spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(item.tint.color.opacity(0.14))

                    Image(systemName: item.symbol)
                        .font(.system(size: 42, weight: .bold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(item.tint.color)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if isSelected {
                        Text("선택")
                            .font(.system(size: 12, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(KioskTheme.accent, in: Capsule())
                            .padding(6)
                    }
                }
                .frame(height: 84)

                Text(item.name)
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .foregroundStyle(KioskTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)

                Text(priceText(item.price))
                    .font(.system(size: 17, weight: .black, design: .rounded))
                    .foregroundStyle(KioskTheme.accent)
            }
            .padding(9)
            .frame(maxWidth: .infinity)
            .background(KioskTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? KioskTheme.accent : KioskTheme.border, lineWidth: isSelected ? 3 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(im.kioskInputEnabled)
        .hoverEffect(.highlight)
        .accessibilityLabel("\(item.name), \(priceText(item.price))")
        .accessibilityHint(im.kioskInputEnabled ? "상품 선택" : "키오스크 가까이에서 선택할 수 있습니다")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func orderSummary(interactionModel im: InteractionModel) -> some View {
        let selectedItem = KioskMenuCatalog
            .items(for: im.kioskSelectedCategory)
            .first { $0.id == im.kioskSelectedMenuID }

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(selectedItem?.name ?? "선택한 상품")
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundStyle(KioskTheme.ink)
                    .lineLimit(1)

                HStack(spacing: 12) {
                    Text(selectedItem == nil ? "0개" : "1개")
                    Text(selectedItem.map { priceText($0.price) } ?? "0원")
                }
                .font(.system(size: 20, weight: .black, design: .rounded))
                .foregroundStyle(selectedItem == nil ? KioskTheme.ink : KioskTheme.accent)
            }

            Spacer(minLength: 8)

            // 결제는 제공하지 않는다. 눌러도 되는 것처럼 보이지 않게 비활성 표현을 준다.
            Button("주문하기") {}
                .buttonStyle(.plain)
                .disabled(true)
                .font(.system(size: 19, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 142, height: 58)
                .background(
                    KioskTheme.ink.opacity(0.32),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHint("결제 기능은 제공되지 않습니다")
        }
        .padding(.horizontal, 20)
        .frame(height: 108)
        .background(KioskTheme.background)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(KioskTheme.border)
                .frame(height: 1)
        }
    }

    private func priceText(_ price: Int) -> String {
        "\(price.formatted())원"
    }
}

#Preview(windowStyle: .automatic) {
    KioskOrderView()
        .padding()
}
