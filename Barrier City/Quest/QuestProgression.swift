//
//  QuestProgression.swift
//  Barrier City
//
//  퀘스트 단계 진행 판정(순수 함수, import 없음 → 단독 테스트 가능).
//  QuestModel이 이벤트-단계 매칭 여부를 넘겨 다음 인덱스를 받는다.
//

enum QuestProgression {
    /// 현재 단계에서 이벤트가 완료 조건과 일치하면 다음 인덱스로.
    /// - currentIndex: 현재 단계 인덱스(0-based). stepCount 이상이면 이미 종료.
    /// - stepCount: 전체 단계 수.
    /// - eventMatchesCurrent: 들어온 이벤트가 현재 단계의 완료 이벤트와 같은가.
    /// - returns: 진행 후 인덱스. 불일치·종료 상태면 currentIndex 그대로.
    static func nextIndex(currentIndex: Int, stepCount: Int,
                          eventMatchesCurrent: Bool) -> Int {
        guard currentIndex >= 0, currentIndex < stepCount else { return currentIndex }
        guard eventMatchesCurrent else { return currentIndex }
        return currentIndex + 1
    }
}
