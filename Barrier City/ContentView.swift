//
//  ContentView.swift
//  Barrier City
//

import SwiftUI

/// 앱 실행 직후 표시하는 릴리스용 시작 화면.
struct ContentView: View {
    var body: some View {
        StartScreenView()
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
