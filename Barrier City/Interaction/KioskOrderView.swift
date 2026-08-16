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
    private let warmYellow = Color(red: 1.00, green: 0.79, blue: 0.03)
    private let warningRed = Color(red: 0.88, green: 0.08, blue: 0.08)
    private let menuColumns = Array(
        repeating: GridItem(.flexible(), spacing: 10),
        count: 3)

    var body: some View {
        let im = InteractionModel.shared

        ZStack {
            warmYellow

            VStack(spacing: 0) {
                header
                categories(interactionModel: im)

                Rectangle()
                    .fill(.black)
                    .frame(height: 3)

                menuGrid(interactionModel: im)
                orderSummary(interactionModel: im)
            }

            if im.kioskBarrierVisible {
                Color.black.opacity(0.36)
                    .contentShape(Rectangle())

                barrierCard(interactionModel: im)
                    .padding(.horizontal, 36)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: 540, height: 960)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(.black, lineWidth: 3)
        }
        .animation(.easeOut(duration: 0.22), value: im.kioskBarrierVisible)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("BARRIER CAFE 키오스크 메뉴")
    }

    private var header: some View {
        ZStack {
            Text("BARRIER CAFE")
                .font(.system(size: 31, weight: .black, design: .rounded))
                .foregroundStyle(.black)

            HStack {
                Image(systemName: "house.fill")
                    .font(.system(size: 27, weight: .black))
                    .foregroundStyle(.black)
                    .frame(width: 56, height: 56)
                    .accessibilityLabel("홈")

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
                .foregroundStyle(isSelected ? .white : .black)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(
                    isSelected ? Color.black : warmYellow,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.black, lineWidth: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(im.kioskInputEnabled)
        .hoverEffect(.highlight)
        .accessibilityLabel("\(category.title) 카테고리")
        .accessibilityHint(
            im.kioskInputEnabled
                ? (category == .other ? "선택하면 접근성 장벽 안내가 열립니다" : "메뉴를 표시합니다")
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
        .scrollIndicators(.hidden)
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
                            .background(warningRed, in: Capsule())
                            .padding(6)
                    }
                }
                .frame(height: 84)

                Text(item.name)
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)

                Text(priceText(item.price))
                    .font(.system(size: 17, weight: .black, design: .rounded))
                    .foregroundStyle(warningRed)
            }
            .padding(9)
            .frame(maxWidth: .infinity)
            .background(Color(white: 0.98), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.black, lineWidth: isSelected ? 3 : 1.5)
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
                    .foregroundStyle(.black)
                    .lineLimit(1)

                HStack(spacing: 12) {
                    Text(selectedItem == nil ? "0개" : "1개")
                    Text(selectedItem.map { priceText($0.price) } ?? "0원")
                }
                .font(.system(size: 20, weight: .black, design: .rounded))
                .foregroundStyle(selectedItem == nil ? Color.black : warningRed)
            }

            Spacer(minLength: 8)

            Button("주문하기") {}
                .font(.system(size: 19, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 142, height: 58)
                .background(.black, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .buttonStyle(.plain)
                .disabled(true)
                .accessibilityHint("결제 기능은 제공되지 않습니다")
        }
        .padding(.horizontal, 20)
        .frame(height: 108)
        .background(warmYellow)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.black)
                .frame(height: 3)
        }
    }

    private func barrierCard(interactionModel im: InteractionModel) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "hand.raised.slash.fill")
                .font(.system(size: 42, weight: .black))
                .foregroundStyle(warningRed)
                .accessibilityHidden(true)

            Text("높아서 선택할 수 없습니다")
                .font(.system(size: 27, weight: .black, design: .rounded))
                .foregroundStyle(.black)
                .multilineTextAlignment(.center)

            Text("앉은 자세에서는 기타 카테고리에 손이 닿지 않습니다. 카페 직원에게 직접 주문해 보세요.")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                Button("직원에게 직접 주문하기") {
                    KioskPrimaryActionCoordinator.activate(
                        interactionModel: im,
                        eventSink: GuideFlowModel.shared.handleQuestEvent)
                }
                .font(.system(size: 20, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(.black, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityHint("키오스크 입력을 종료하고 직원 주문 미션으로 이동합니다")

                Button("닫기") {
                    _ = im.dismissKioskBarrier()
                }
                .font(.system(size: 19, weight: .black, design: .rounded))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.black, lineWidth: 2)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityHint("장벽 안내를 닫고 메뉴로 돌아갑니다")
            }
        }
        .padding(24)
        .background(warmYellow, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.black, lineWidth: 3)
        }
        .shadow(color: .black.opacity(0.28), radius: 20, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("키오스크 접근성 장벽 안내")
    }

    private func priceText(_ price: Int) -> String {
        "\(price.formatted())원"
    }
}

#Preview(windowStyle: .automatic) {
    KioskOrderView()
        .padding()
}
