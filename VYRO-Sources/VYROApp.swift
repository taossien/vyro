//
//  VYROApp.swift
//  Point d'entrée de l'application VYRO Studio.
//

import SwiftUI

@main
struct VYROApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}
