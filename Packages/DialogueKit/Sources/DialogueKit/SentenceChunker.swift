import Foundation

/// 스트리밍 LLM 토큰을 모아 완성된 문장 단위로 방출한다.
public struct SentenceChunker: Sendable {
    private var buffer = ""
    private static let terminators: Set<Character> = [".", "!", "?", "…", "。"]
    public init() {}

    public mutating func feed(_ token: String) -> [String] {
        var out: [String] = []
        for char in token {
            buffer.append(char)
            if SentenceChunker.terminators.contains(char) || char == "\n" {
                let trimmed = buffer.hasSuffix("\n") ? String(buffer.dropLast()) : buffer
                if !trimmed.trimmingCharacters(in: .whitespaces).isEmpty { out.append(trimmed) }
                buffer = ""
            }
        }
        return out
    }

    public mutating func flush() -> String? {
        defer { buffer = "" }
        let rest = buffer
        return rest.trimmingCharacters(in: .whitespaces).isEmpty ? nil : rest
    }
}
