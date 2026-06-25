//
//  KnowledgeBase.swift
//  WheelchairXR
//
//  RAG용 휠체어 접근성 지식베이스 + 검색(임베딩 시맨틱 → 실패 시 키워드 폴백).
//  ⚠️ 데모용 큐레이션. 실제 배포 전 한국 장애인등편의법 등 공식 기준으로 검수 필요.
//

import Foundation
import DialogueKitOpenAI

struct KBChunk: Identifiable, Sendable {
    let id: Int
    let text: String
    var embedding: [Float]? = nil
}

@MainActor
@Observable
final class KnowledgeBase {
    private(set) var chunks: [KBChunk] = KnowledgeBase.seed
    private(set) var mode: String = "(미초기화)"   // "시맨틱(임베딩)" 또는 "키워드 폴백"

    private var embeddingsURL: URL {
        AppConfig.proxy.chatURL.deletingLastPathComponent().appending(path: "embeddings")
    }

    /// KB를 임베딩으로 1회 준비(가능하면). 실패해도 키워드 검색으로 동작.
    func warmUp() async {
        guard chunks.first?.embedding == nil else { return }
        do {
            let vectors = try await embed(chunks.map(\.text))
            for i in chunks.indices where i < vectors.count { chunks[i].embedding = vectors[i] }
            mode = "시맨틱(임베딩)"
        } catch {
            mode = "키워드 폴백"   // /embeddings 권한·라우트 없으면 자동 폴백
        }
    }

    /// 질문에 대한 top-k 근거 청크 반환.
    func retrieve(_ query: String, k: Int = 3) async -> [KBChunk] {
        // 시맨틱 시도
        if chunks.first?.embedding != nil, let q = try? await embed([query]).first {
            mode = "시맨틱(임베딩)"
            return chunks
                .compactMap { c -> (KBChunk, Float)? in c.embedding.map { (c, Self.cosine(q, $0)) } }
                .sorted { $0.1 > $1.1 }
                .prefix(k).map(\.0)
        }
        // 키워드 폴백
        mode = "키워드 폴백"
        let terms = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
        return chunks
            .map { c in (c, terms.reduce(0) { $0 + (c.text.contains($1) ? 1 : 0) }) }
            .sorted { $0.1 > $1.1 }
            .prefix(k).map(\.0)
    }

    // MARK: - 임베딩

    private func embed(_ inputs: [String]) async throws -> [[Float]] {
        var req = URLRequest(url: embeddingsURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "text-embedding-3-small", "input": inputs,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let arr = (obj?["data"] as? [[String: Any]]) ?? []
        return arr.map { (($0["embedding"] as? [Double]) ?? []).map(Float.init) }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let d = (na.squareRoot() * nb.squareRoot())
        return d == 0 ? 0 : dot / d
    }

    // MARK: - 지식베이스 (휠체어 접근성 사실·팁, 한국어)
    static let seed: [KBChunk] = [
        "휠체어 경사로의 법정 최대 기울기는 1/12(약 4.8도)다. 이보다 가파르면 혼자 오르기 어렵고 위험하다.",
        "휠체어가 통과하려면 출입문 유효폭이 최소 0.8m 이상이어야 한다. 0.7m 이하는 통과가 막힌다.",
        "휠체어가 제자리에서 회전하려면 지름 약 1.5m의 공간이 필요하다. 좁은 통로에서는 방향 전환이 불가능하다.",
        "문턱(단차)은 2cm 이하를 권장한다. 그 이상이면 앞바퀴가 걸려 넘기 어렵다.",
        "휠체어 이용자를 도울 때는 먼저 '도와드릴까요?'라고 물어보고 동의를 받아야 한다. 동의 없이 갑자기 미는 것은 위험하고 무례하다.",
        "휠체어 이용자와 대화할 때는 가능하면 눈높이를 맞춰 앉거나 몸을 낮춘다. 위에서 내려다보며 말하지 않는다.",
        "경사로가 없을 때의 대안: 휴대용 경사판, 직원 호출 벨, 다른 출입구 안내 등이 있다. 들어 옮기는 것은 최후 수단이며 반드시 동의와 충분한 인력이 필요하다.",
        "장애인 전용 주차구역은 출입구에서 가깝고 폭이 넓어 휠체어 승하차가 가능하도록 설계된다. 비장애인 주차는 불법이다.",
        "전동 휠체어는 배터리로 움직여 평지 이동은 수월하지만, 무거워 들어 옮기기 어렵고 경사·문턱 같은 환경 장벽엔 여전히 취약하다.",
        "수동 휠체어는 양손으로 바퀴 테(핸드림)를 밀어 움직인다. 경사로나 카펫에서는 더 큰 힘이 들고 팔이 쉽게 피로해진다.",
        "접근성 화장실은 넓은 회전 공간, 손잡이(grab bar), 낮은 세면대를 갖춰야 한다. 일반 칸은 휠체어가 들어가지 못한다.",
        "엘리베이터 버튼·점자블록·낮은 카운터는 휠체어 이용자의 자립적 이용을 돕는 기본 편의시설이다.",
        "표현 시 '휠체어에 갇힌'이 아니라 '휠체어를 이용하는' 사람으로 말한다. 휠체어는 구속이 아니라 이동을 돕는 도구다.",
        "주문대·계산대가 시야보다 높으면 휠체어 이용자는 메뉴를 보거나 결제하기 어렵다. 낮은 보조 카운터가 필요하다.",
    ].enumerated().map { KBChunk(id: $0.offset, text: $0.element) }
}
