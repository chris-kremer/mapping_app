//
//  Run_MapApp.swift
//  Run_Map
//
//  Created by Christian Kremer on 24.03.25.
//

import SwiftUI

@main
struct Run_MapApp: App {
    var body: some Scene {
        WindowGroup {
            // Hosted unit tests must not open the user's real archive or start sync.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil {
                Color.clear
            } else {
                ContentView()
            }
        }
    }
}
