//
//  VYROApp.swift
//  Point d'entrée de l'application VYRO Studio.
//

import SwiftUI

@main
struct VYROApp: App {
    @AppStorage("vyro.onboarded") private var onboarded = false

    var body: some Scene {
        WindowGroup {
            Group {
                if onboarded { HomeView() } else { OnboardingView { onboarded = true } }
            }
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
        }
    }
}
