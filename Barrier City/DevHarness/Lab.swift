//
//  Lab.swift
//  WheelchairXR
//
//  실현가능성 테스트용 1회성(non-streaming) LLM 호출 헬퍼. 프록시 /chat 경유.
//  구조화 출력이 필요하면 jsonMode=true (response_format=json_object).
//

import Foundation
import DialogueKitOpenAI

enum Lab {
    static func chat(system: String, user: String, jsonMode: Bool = false) async throws -> String {
        var req = URLRequest(url: AppConfig.proxy.chatURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if jsonMode { payload["response_format"] = ["type": "json_object"] }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = obj?["choices"] as? [[String: Any]]
        let msg = choices?.first?["message"] as? [String: Any]
        return (msg?["content"] as? String) ?? "(빈 응답)"
    }
}
