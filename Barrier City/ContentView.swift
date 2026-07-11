//
//  ContentView.swift
//  Barrier City
//

import SwiftUI

/// 창(2D) 콘텐츠: 휠체어 컨트롤 패널(시작/종료 + 시뮬 디버그 입력 + 진단).
struct ContentView: View {
    var body: some View {
        ControlPanelView()
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
