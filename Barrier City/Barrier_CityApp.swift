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
