//
//  Barrier_CityApp.swift
//  Barrier City
//
//  Created by mac on 6/25/26.
//

import SwiftUI

@main
struct Barrier_CityApp: App {

    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup(id: AppSceneID.start) {
            ContentView()
                .environment(appModel)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1200, height: 680)

        WindowGroup(id: AppSceneID.debugControl, for: DebugWindowRoute.self) { _ in
            ControlPanelView()
                .environment(appModel)
        }
        .windowResizability(.contentSize)

        WindowGroup(id: AppSceneID.npcDialogueTest) {
            DialogueTurnView(controller: appModel.npcDialogue)
        }
        .windowResizability(.contentSize)

        WindowGroup(id: AppSceneID.splash) {
            SplashOverlayView()
                // 볼륨은 사용자가 '바닥' 쪽을 볼 때와 리사이즈 중에 반투명
                // 베이스플레이트를 띄운다. 스플래시는 이미지 한 장만 보여주므로
                // 그 판이 그대로 노출돼 거슬린다. (Scene이 아니라 View 모디파이어)
                .volumeBaseplateVisibility(.hidden)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 0.6, height: 0.6, depth: 0.01, in: .meters)

        ImmersiveSpace(id: AppSceneID.wheelchair) {
            ImmersiveView()
                .environment(appModel)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}
