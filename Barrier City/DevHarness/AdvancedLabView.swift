//
//  AdvancedLabView.swift
//  WheelchairXR
//
//  AI 고급 검사 Lab — ① 정량 평가(Eval) ② 멀티턴 적응 대화 ③ RAG 휠체어 Q&A.
//  전부 iPhone 시뮬레이터에서 검증 가능.
//

import SwiftUI
import DialogueKit
import DialogueKitOpenAI

struct AdvancedLabView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case eval = "①Eval", multi = "②멀티턴", rag = "③RAG"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .eval

    var body: some View {
        VStack(spacing: 14) {
            Text("AI 고급 검사 Lab").font(.title3).bold()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).frame(maxWidth: 460)

            switch tab {
            case .eval:  EvalView()
            case .multi: MultiTurnView()
            case .rag:   RAGView()
            }
        }
        .padding(20)
        .frame(maxWidth: 520)
    }
}

// MARK: - ① 정량 평가 (의도 정확도 + 지연 + LLM-judge 품질)

private struct EvalView: View {
    struct Case { let text: String; let expect: String }
    private let intentSet: [Case] = [
        .init(text: "아메리카노 한 잔 주세요", expect: "orderComplete"),
        .init(text: "따뜻한 라떼로 주문할게요", expect: "orderComplete"),
        .init(text: "경사로 좀 밀어주실 수 있을까요?", expect: "helpRequest"),
        .init(text: "문 좀 잡아주시겠어요?", expect: "helpRequest"),
        .init(text: "도와주세요, 턱을 못 넘겠어요", expect: "helpRequest"),
        .init(text: "그냥 나갈게요", expect: "leave"),
        .init(text: "이만 가보겠습니다", expect: "leave"),
        .init(text: "오늘 날씨 정말 좋네요", expect: "smalltalk"),
        .init(text: "여기 인테리어 예쁘네요", expect: "smalltalk"),
        .init(text: "음 그게 저기 좀 그래서", expect: "unknown"),
    ]
    private let judgeSamples = ["아메리카노 주세요", "야 빨리 안 줘?", "키오스크가 너무 높아서 주문하기 어려워요"]

    @State private var running = false
    @State private var log = ""
    @State private var accuracy = ""
    @State private var latency = ""
    @State private var judge = ""

    var body: some View {
        VStack(spacing: 10) {
            Text("① 정량 평가 (Eval)").font(.headline)
            Text("의도 분류 정확도·평균 지연 + LLM-judge가 NPC 응답을 페르소나·공감·간결로 1~5점 채점.")
                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)

            Button(running ? "평가 중…" : "평가 실행 (10문항 + 3채점)") { Task { await run() } }
                .buttonStyle(.borderedProminent).disabled(running)

            if !accuracy.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(accuracy).bold()
                    Text(latency)
                    Text(judge)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView { Text(log).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 160)
                .background(Color.gray.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func run() async {
        running = true; defer { running = false }
        log = ""; accuracy = ""; latency = ""; judge = ""
        var correct = 0
        var totalMs: Double = 0
        let sys = "사용자 발화를 분류하라. 반드시 JSON만: {\"kind\":\"helpRequest|orderComplete|leave|smalltalk|unknown\"}."
        for c in intentSet {
            let t0 = Date()
            let kind = (try? await classify(sys: sys, user: c.text)) ?? "오류"
            let ms = Date().timeIntervalSince(t0) * 1000
            totalMs += ms
            let ok = (kind == c.expect)
            if ok { correct += 1 }
            log += "\(ok ? "✓" : "✗") \(c.text)\n   기대 \(c.expect) / 예측 \(kind) (\(Int(ms))ms)\n"
        }
        accuracy = "의도 정확도: \(correct)/\(intentSet.count) (\(Int(Double(correct)/Double(intentSet.count)*100))%)"
        latency = "평균 지연: \(Int(totalMs/Double(intentSet.count)))ms"

        // LLM-judge
        var pSum = 0, eSum = 0, bSum = 0, n = 0
        let persona = "너는 바쁘지만 친절한 카페 직원이다. 1~2문장으로 한국어로만 응대."
        let jsys = "다음 [직원] 응답을 평가하라. 반드시 JSON만: {\"persona\":1-5,\"empathy\":1-5,\"brevity\":1-5}. persona=직원답고 일관, empathy=공감/친절, brevity=간결."
        for s in judgeSamples {
            guard let reply = try? await Lab.chat(system: persona, user: s) else { continue }
            guard let j = try? await Lab.chat(system: jsys, user: "[손님] \(s)\n[직원] \(reply)", jsonMode: true) else { continue }
            let obj = try? JSONSerialization.jsonObject(with: Data(j.utf8)) as? [String: Any]
            pSum += (obj?["persona"] as? Int) ?? 0
            eSum += (obj?["empathy"] as? Int) ?? 0
            bSum += (obj?["brevity"] as? Int) ?? 0
            n += 1
            log += "🧑‍🍳 \(s) → \(reply)\n   채점 \(j)\n"
        }
        if n > 0 {
            judge = "응답 품질(평균/5): 페르소나 \(pSum/n) · 공감 \(eSum/n) · 간결 \(bSum/n)"
        }
    }

    private func classify(sys: String, user: String) async throws -> String {
        let j = try await Lab.chat(system: sys, user: user, jsonMode: true)
        let obj = try? JSONSerialization.jsonObject(with: Data(j.utf8)) as? [String: Any]
        return (obj?["kind"] as? String) ?? "unknown"
    }
}

// MARK: - ② 멀티턴 적응 대화 (rapport·톤·기억)

private struct MultiTurnView: View {
    @State private var orchestrator = MultiTurnView.makeOrchestrator()
    @State private var history: [Message] = []
    @State private var transcript: [(String, String)] = []   // (화자, 내용)
    @State private var input = ""
    @State private var rapport: Float = AccessibilityAttitude.ableist.initialRapport
    @State private var tone = "dismissive"
    @State private var rapportTrend: [Float] = []
    @State private var busy = false

    var body: some View {
        VStack(spacing: 10) {
            Text("② 멀티턴 적응 대화").font(.headline)
            Text("같은 직원과 여러 턴 대화. 태도에 따라 호감도·톤이 변하고 이전 맥락을 기억하는지 확인.")
                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)

            Text("호감도 \(String(format: "%.2f", rapport)) · 톤 \(tone)   |  추이: \(rapportTrend.map { String(format: "%.1f", $0) }.joined(separator: " → "))")
                .font(.caption).foregroundStyle(rapport >= 0 ? .green : .red)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(transcript.enumerated()), id: \.offset) { _, line in
                        Text("\(line.0 == "나" ? "🙋" : "🧑‍🍳") \(line.0): \(line.1)")
                            .font(.callout).foregroundStyle(line.0 == "나" ? .blue : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(height: 200).background(Color.gray.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                TextField("직원에게 말하기…", text: $input).textFieldStyle(.roundedBorder)
                Button("전송") { Task { await send(input) } }.disabled(busy || input.isEmpty)
            }
            HStack {
                Button("정중 예시") { Task { await send("안녕하세요, 아메리카노 한 잔 부탁드려요") } }
                Button("무례 예시") { Task { await send("야 빨리 아메리카노 줘") } }
                Button("초기화") { reset() }
            }.font(.caption).disabled(busy)
        }
    }

    private func send(_ text: String) async {
        let utterance = text.trimmingCharacters(in: .whitespaces)
        guard !utterance.isEmpty, !busy else { return }
        busy = true; defer { busy = false }
        input = ""
        transcript.append(("나", utterance))
        let result = await orchestrator.handle(utterance: utterance, history: history)
        let reply = result.spokenSentences.joined(separator: " ")
        history.append(Message(role: .user, content: utterance))
        if !reply.isEmpty {
            transcript.append(("직원", reply + (result.event.map { "  [\($0)]" } ?? "")))
            history.append(Message(role: .assistant, content: reply))
        }
        rapport = await orchestrator.climate.rapport
        tone = await orchestrator.climate.tone.rawValue
        rapportTrend.append(rapport)
    }

    private func reset() {
        orchestrator = MultiTurnView.makeOrchestrator()
        history = []
        transcript = []
        rapport = AccessibilityAttitude.ableist.initialRapport
        tone = "dismissive"
        rapportTrend = []
    }

    static func makeOrchestrator() -> DialogueOrchestrator {
        DialogueOrchestrator(
            persona: NPCPersona(id: "staff", role: "cafe staff",
                englishSystemBase: "You are a busy cafe employee near an ordering kiosk that is too high for wheelchair users. Remember the conversation.",
                accessibilityAttitude: .ableist),
            llm: OpenAILLMClient(config: AppConfig.proxy),
            guardian: SafetyGuard(bannedKeywords: [], maxTurns: 30),
            cache: DialogueCache(lines: [.timeout: CannedLine(text: "잠시만요…", audioKey: "t")]),
            turnLimit: 30)
    }
}

// MARK: - ③ RAG 휠체어 Q&A (검색 근거 기반 정확한 답)

private struct RAGView: View {
    @State private var kb = KnowledgeBase()
    @State private var question = ""
    @State private var answer = ""
    @State private var sources = ""
    @State private var busy = false
    private let presets = [
        "경사로가 얼마나 가파르면 위험해요?",
        "휠체어 탄 사람을 도와줄 때 어떻게 해야 하나요?",
        "문이 얼마나 넓어야 휠체어가 들어가요?",
        "전동이랑 수동 휠체어 뭐가 달라요?",
    ]

    var body: some View {
        VStack(spacing: 10) {
            Text("③ RAG 휠체어 Q&A").font(.headline)
            Text("실제 접근성 지식베이스에서 관련 근거를 검색(임베딩) → 그 근거로만 답변(환각 방지). 검색 모드: \(kb.mode)")
                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                TextField("휠체어 관련 질문…", text: $question).textFieldStyle(.roundedBorder)
                Button("질문") { Task { await ask(question) } }.disabled(busy || question.isEmpty)
            }
            VStack(spacing: 4) {
                ForEach(presets, id: \.self) { p in
                    Button(p) { Task { await ask(p) } }.font(.caption).disabled(busy)
                }
            }

            if busy { Text("검색·생성 중…").font(.caption) }
            if !answer.isEmpty {
                Text("💬 \(answer)").font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(Color.green.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if !sources.isEmpty {
                Text("📎 검색된 근거:\n\(sources)").font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { await kb.warmUp() }
    }

    private func ask(_ q: String) async {
        let query = q.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !busy else { return }
        busy = true; defer { busy = false }
        answer = ""; sources = ""; question = ""
        let top = await kb.retrieve(query, k: 3)
        sources = top.map { "• \($0.text)" }.joined(separator: "\n")
        let context = top.map(\.text).joined(separator: "\n")
        let sys = "너는 휠체어 접근성 도우미다. 아래 [근거]에 있는 내용에만 기반해 한국어로 친절하고 정확하게 답하라. 근거에 없으면 모른다고 말하라. 지어내지 마라."
        do {
            answer = try await Lab.chat(system: sys, user: "[근거]\n\(context)\n\n[질문] \(query)")
        } catch {
            answer = "에러: \(error.localizedDescription)"
        }
    }
}
