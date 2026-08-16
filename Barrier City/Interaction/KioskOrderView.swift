import SwiftUI

private struct CafeMenuItem: Identifiable {
    let id: String
    let name: String
    let price: String
    let symbol: String
    let tint: Color
    let badge: String?
}

struct KioskOrderView: View {
    private let menuItems: [CafeMenuItem] = [
        .init(id: "americano", name: "아메리카노", price: "₩ 4,500", symbol: "cup.and.saucer.fill", tint: .brown, badge: "BEST"),
        .init(id: "cafe-latte", name: "카페라떼", price: "₩ 5,000", symbol: "mug.fill", tint: .orange, badge: nil),
        .init(id: "cafe-mocha", name: "카페모카", price: "₩ 5,500", symbol: "mug.fill", tint: .brown, badge: "NEW"),
        .init(id: "espresso", name: "에스프레소", price: "₩ 4,000", symbol: "cup.and.saucer.fill", tint: .brown, badge: nil),
        .init(id: "iced-tea", name: "아이스티", price: "₩ 4,800", symbol: "snowflake", tint: .cyan, badge: nil),
        .init(id: "hot-choco", name: "핫초코", price: "₩ 5,000", symbol: "mug.fill", tint: .brown, badge: nil),
        .init(id: "grapefruit", name: "자몽티", price: "₩ 5,200", symbol: "drop.fill", tint: .pink, badge: nil),
        .init(id: "matcha", name: "말차라떼", price: "₩ 5,500", symbol: "leaf.fill", tint: .green, badge: "추천"),
        .init(id: "peach", name: "복숭아티", price: "₩ 5,200", symbol: "drop.fill", tint: .orange, badge: nil),
    ]

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        let im = InteractionModel.shared

        ZStack(alignment: .bottom) {
            Color(red: 0.96, green: 0.94, blue: 0.90)

            VStack(spacing: 0) {
                header
                categoryTabs

                ScrollView(.vertical) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(menuItems) { item in
                            menuCard(item, interactionModel: im)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                }
                .scrollIndicators(.hidden)

                orderStrip
            }

            if im.kioskBarrierVisible {
                barrierCard(interactionModel: im)
                    .padding(18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: 540, height: 960)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.7), lineWidth: 2)
        }
        .animation(.easeOut(duration: 0.22), value: im.kioskBarrierVisible)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("BARRIER CAFE 키오스크 메뉴")
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color(red: 1.0, green: 0.62, blue: 0.10))
                    .frame(width: 58, height: 58)
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 27, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("BARRIER")
                    .font(.system(size: 32, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Text("CAFE")
                    .font(.system(size: 19, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(red: 1.0, green: 0.64, blue: 0.12))
            }

            Spacer()

            HStack(spacing: 7) {
                Image(systemName: "thermometer.medium")
                Text("24°")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            .background(.black.opacity(0.28), in: Capsule())
        }
        .padding(.horizontal, 22)
        .frame(height: 112)
        .background(Color(red: 0.28, green: 0.21, blue: 0.18))
    }

    private var categoryTabs: some View {
        HStack(spacing: 8) {
            categoryTab("베스트", selected: true)
            categoryTab("커피", selected: false)
            categoryTab("에이드", selected: false)
            categoryTab("기타", selected: false)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(red: 0.34, green: 0.27, blue: 0.23))
    }

    private func categoryTab(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: 20, weight: .bold, design: .rounded))
            .foregroundStyle(selected ? Color(red: 0.95, green: 0.47, blue: 0.06) : .white.opacity(0.82))
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(selected ? Color.white : Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private func menuCard(_ item: CafeMenuItem, interactionModel im: InteractionModel) -> some View {
        Button {
            _ = im.selectKioskMenu(id: item.id)
        } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(item.tint.opacity(0.10))

                    Image(systemName: item.symbol)
                        .font(.system(size: 46, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(item.tint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if let badge = item.badge {
                        Text(badge)
                            .font(.system(size: 11, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(red: 0.94, green: 0.38, blue: 0.05), in: Capsule())
                            .padding(7)
                    }
                }
                .frame(height: 100)

                Text(item.name)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.16, green: 0.13, blue: 0.11))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(item.price)
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(red: 0.94, green: 0.42, blue: 0.03))
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(im.kioskInputEnabled)
        .hoverEffect(.highlight)
        .accessibilityLabel("\(item.name), \(item.price)")
        .accessibilityHint(im.kioskInputEnabled ? "선택" : "키오스크 가까이에서 선택할 수 있습니다")
    }

    private var orderStrip: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("선택 메뉴")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.secondary)
                Text("아직 선택된 메뉴가 없습니다")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(red: 0.23, green: 0.18, blue: 0.15))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("합계")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.secondary)
                Text("₩ 0")
                    .font(.system(size: 24, weight: .black, design: .rounded))
            }

            Label("주문", systemImage: "cart.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(Color(red: 0.29, green: 0.19, blue: 0.11).opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal, 20)
        .frame(height: 96)
        .background(.white)
    }

    private func barrierCard(interactionModel im: InteractionModel) -> some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "hand.raised.slash.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color(red: 0.95, green: 0.42, blue: 0.04))
                    .frame(width: 52, height: 52)
                    .background(Color.orange.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 6) {
                    Text("손이 닿지 않습니다")
                        .font(.system(size: 25, weight: .black, design: .rounded))
                        .foregroundStyle(Color(red: 0.18, green: 0.13, blue: 0.10))
                    Text("앉은 자세에서는 이 메뉴를 선택할 수 없습니다.")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color(red: 0.34, green: 0.28, blue: 0.24))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            Button("직원에게 도움 받기") {
                if im.requestKioskStaffHelp() {
                    GuideFlowModel.shared.handleQuestEvent(.kioskFailed)
                }
            }
            .font(.system(size: 21, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(Color(red: 0.48, green: 0.27, blue: 0.10), in: RoundedRectangle(cornerRadius: 15))
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
        }
        .padding(20)
        .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.orange.opacity(0.45), lineWidth: 2)
        }
        .shadow(color: .black.opacity(0.22), radius: 20, y: 10)
        .accessibilityElement(children: .contain)
    }
}

#Preview(windowStyle: .automatic) {
    KioskOrderView()
        .padding()
}
