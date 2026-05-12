//
//  Run_MapApp.swift
//  Run_Map
//
//  Created by Christian Kremer on 24.03.25.
//

import SwiftUI

@main
struct Run_MapApp: App {
    init() {
        RunMapHealthKitBackgroundService.shared.start()
        MonthlyRecapNotificationScheduler.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
