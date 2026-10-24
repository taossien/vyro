//
//  Theme.swift
//  Identité visuelle VYRO : interface sombre, accents violets et bleus.
//

import SwiftUI

enum Theme {
    static let background = Color(red: 0.07, green: 0.07, blue: 0.10)
    static let surface = Color(red: 0.12, green: 0.12, blue: 0.16)
    static let accent = Color(red: 0.58, green: 0.34, blue: 0.98)
    static let accentBlue = Color(red: 0.25, green: 0.55, blue: 1.00)
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.65)
}

/// Formate un temps en secondes vers "m:ss".
func timeString(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// Formate un temps en secondes vers "m:ss.d" (dixièmes), pour le placement précis des effets.
func preciseTimeString(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00.0" }
    let tenths = Int((seconds * 10).rounded())
    return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
}
