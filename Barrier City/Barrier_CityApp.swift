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
        WindowGroup(id: "control") {
            ContentView()
                .environment(appModel)
        }
        .windowResizability(.contentSize)

        WindowGroup(id: "npc-dialogue-test") {
            DialogueTurnView(controller: appModel.npcDialogue)
        }
        .windowResizability(.contentSize)

        WindowGroup(id: "splash") {
            SplashOverlayView()
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 0.4, height: 0.4, depth: 0.01, in: .meters)

        ImmersiveSpace(id: "wheelchair") {
            ImmersiveView()
                .environment(appModel)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}
