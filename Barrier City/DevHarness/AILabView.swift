//
//  AILabView.swift
//  WheelchairXR
//
//  AI 실현가능성 Lab — 기능별 탭 + 각 탭에 "테스트 방법/확인 포인트" 명시.
//  ⑥ 엔딩 디브리핑 · ② 난이도 디렉터 · ⑤ 자연어 도움 요청 · 팩트 내레이터(Could)
//  전부 iPhone 시뮬레이터에서 검증 가능.
//

import SwiftUI

struct AILabView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case debrief = "⑥디브리핑", difficulty = "②난이도", help = "⑤도움요청", fact = "팩트"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .debrief

    var body: some View {
        VStack(spacing: 14) {
            Text("AI 실현가능성 Lab").font(.title3).bold()

            Picker("기능", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 460)

            switch tab {
            case .debrief:    DebriefTest()
            case .difficulty: DifficultyTest()
            case .help:       HelpRequestTest()
            case .fact:       FactNarratorTest()
            }
        }
        .padding(20)
        .frame(maxWidth: 480)
    }
}

// MARK: - 공통 UI

/// 테스트 방법/확인 포인트 안내 박스
private struct HowTo: View {
    let how: String
    let expect: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(how, systemImage: "hand.tap")
                .font(.footnote)
            Label(expect, systemImage: "checkmark.seal")
                .font(.footnote).foregroundStyle(.green)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct ResultBox: View {
    let busy: Bool
    let text: String
    var body: some View {
        Text(busy ? "처리 중…" : (text.isEmpty ? "위 버튼을 눌러 테스트하세요." : text))
            .font(.callout)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .padding(12)
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .textSelection(.enabled)
    }
}

// MARK: - ⑥ 엔딩 디브리핑
private struct DebriefTest: View {
    @State private var out = ""
    @State private var busy = false
    private let sys = "너는 장애 인식 체험의 엔딩 내레이터다. 주어진 행동 로그(JSON)를 바탕으로 2~3문장의 개인 맞춤 성찰 엔딩을 한국어로 써라. 동정·시혜 금지, 환경과 사회의 책임 관점으로."
    private let caseA = #"{"막힌지점":"입구 경사로","스트로크실패":2,"도움요청":1,"NPC태도":"정중","주문완료":true,"포기":false}"#
    private let caseB = #"{"막힌지점":"좁은 테이블 통로","스트로크실패":9,"도움요청":0,"NPC태도":"무례","주문완료":false,"포기":true}"#

    var body: some View {
        VStack(spacing: 10) {
            Text("⑥ 개인화 엔딩 디브리핑").font(.headline)
            HowTo(how: "‘사례 A(정중·완주)’와 ‘사례 B(무례·포기)’를 각각 눌러 두 엔딩을 비교.",
                  expect: "행동 로그가 다르면 성찰 문장이 서로 달라야(개인화). 동정조가 아닌 ‘환경·사회 책임’ 톤이면 성공.")
            HStack {
                Button("사례 A (정중·완주)") { run(caseA) }.buttonStyle(.borderedProminent)
                Button("사례 B (무례·포기)") { run(caseB) }.buttonStyle(.bordered)
            }.disabled(busy)
            ResultBox(busy: busy, text: out)
        }
    }
    private func run(_ t: String) {
        Task { busy = true; defer { busy = false }
            do { out = try await Lab.chat(system: sys, user: t) }
            catch { out = "에러: \(error.localizedDescription)" } }
    }
}

// MARK: - ② 난이도 디렉터
private struct DifficultyTest: View {
    @State private var out = ""
    @State private var busy = false
    private let sys = "카페 접근성 체험의 난이도 파라미터를 정하라. 반드시 JSON만 출력: {\"crowd\":0~1, \"tableGap\":0~1(작을수록 어려움), \"npcPatience\":0~1, \"obstacles\":[\"door\",\"ramp\",\"threshold\",\"highCounter\" 중]}. 주어진 난이도에 맞게 일관되게."

    var body: some View {
        VStack(spacing: 10) {
            Text("② 난이도·시나리오 디렉터").font(.headline)
            HowTo(how: "‘하 / 중 / 상’을 각각 눌러 생성된 JSON 파라미터를 비교.",
                  expect: "항상 유효한 JSON{crowd,tableGap,npcPatience,obstacles}이 나오고, 난이도↑일수록 tableGap↓·obstacles↑면 성공(구조화 출력 신뢰).")
            HStack {
                Button("하") { run("난이도: 쉬움") }
                Button("중") { run("난이도: 보통") }
                Button("상") { run("난이도: 어려움") }
            }.buttonStyle(.bordered).disabled(busy)
            ResultBox(busy: busy, text: out)
        }
    }
    private func run(_ level: String) {
        Task { busy = true; defer { busy = false }
            do { out = try await Lab.chat(system: sys, user: level, jsonMode: true) }
            catch { out = "에러: \(error.localizedDescription)" } }
    }
}

// MARK: - ⑤ 자연어 도움 요청
private struct HelpRequestTest: View {
    @State private var out = ""
    @State private var busy = false
    private let sys = "사용자 발화를 분류하라. 반드시 JSON만: {\"kind\":\"helpRequest|orderComplete|leave|smalltalk|unknown\", \"politeness\":0~3}."
    private let polite = "저기 죄송한데, 경사로 좀 밀어주실 수 있을까요?"
    private let rude = "야 이거 좀 밀어"

    var body: some View {
        VStack(spacing: 10) {
            Text("⑤ 자연어 도움 요청").font(.headline)
            HowTo(how: "‘정중하게 / 무례하게’ 발화를 각각 눌러 분류·분기를 비교.",
                  expect: "둘 다 helpRequest로 인식 + 정중=🙆도움 / 무례=🙅거절로 갈리면 성공(의도+정중함 인식).")
            HStack {
                Button("정중하게") { run(polite) }.buttonStyle(.borderedProminent)
                Button("무례하게") { run(rude) }.buttonStyle(.bordered)
            }.disabled(busy)
            ResultBox(busy: busy, text: out)
        }
    }
    private func run(_ utterance: String) {
        Task { busy = true; defer { busy = false }
            do {
                let json = try await Lab.chat(system: sys, user: utterance, jsonMode: true)
                let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
                let kind = (obj?["kind"] as? String) ?? "unknown"
                let pol = (obj?["politeness"] as? Int) ?? 0
                var v = "발화: \(utterance)\n분류: \(kind), 정중함 \(pol)"
                if kind == "helpRequest" { v += pol >= 2 ? "\n→ 🙆 행인이 도와줍니다." : "\n→ 🙅 행인이 못 본 척 합니다." }
                out = v
            } catch { out = "에러: \(error.localizedDescription)" } }
    }
}

// MARK: - 팩트 내레이터 (grounded)
private struct FactNarratorTest: View {
    @State private var out = ""
    @State private var busy = false
    private let sys = "너는 접근성 사실 내레이터다. 아래 '사실'에 근거해서만 한국어 1~2문장으로 설명하라. 주어지지 않은 정보는 추측하지 말고 모른다고 하라."
    private let facts = """
    [사실]
    - 휠체어 경사로 법정 최대 기울기: 1/12 (약 4.8도).
    - 표준 출입문 통과 최소 유효폭: 0.8m.
    - 휠체어 회전에 필요한 최소 공간: 지름 1.5m.
    [상황]
    지금 이 경사로 기울기는 약 10도, 출입문 유효폭은 0.7m이다.
    """

    var body: some View {
        VStack(spacing: 10) {
            Text("팩트 기반 내레이터 (Could)").font(.headline)
            HowTo(how: "‘이 경사로/문 설명’ 버튼을 눌러 설명을 생성.",
                  expect: "주어진 법정 기준(1/12·0.8m 등)에 근거해 ‘기준 초과’를 지적하고, 없는 수치는 지어내지 않으면 성공(grounding).")
            Button("이 경사로/문 설명") {
                Task { busy = true; defer { busy = false }
                    do { out = try await Lab.chat(system: sys, user: facts) }
                    catch { out = "에러: \(error.localizedDescription)" } }
            }.buttonStyle(.borderedProminent).disabled(busy)
            ResultBox(busy: busy, text: out)
        }
    }
}
