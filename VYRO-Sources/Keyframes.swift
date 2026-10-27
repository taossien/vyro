//
//  Keyframes.swift
//  Images clés de mouvement : zoom, position, rotation, avec une courbe entre chaque.
//

import Foundation

struct Keyframe: Codable, Identifiable, Equatable {
    var id: UUID
    /// Temps du montage (secondes).
    var time: Double
    var scale: Double = 1
    /// Décalage en fraction de l'image (x vers la droite, y vers le bas).
    var x: Double = 0
    var y: Double = 0
    /// Degrés, sens horaire.
    var rotation: Double = 0
    /// Courbe vers l'image clé suivante : 0 lisse, 1 linéaire, 2 rapide puis doux, 3 maintenu.
    var ease: Int = 0

    static let easeNames = ["Lisse", "Linéaire", "Rapide", "Maintenu"]
}

enum KeyframeEngine {
    /// État interpolé à l'instant donné (nil = aucune image clé).
    static func value(at time: Double, _ frames: [Keyframe]) -> Keyframe? {
        guard !frames.isEmpty else { return nil }
        let sorted = frames.sorted { $0.time < $1.time }
        if time <= sorted[0].time { return sorted[0] }
        guard let last = sorted.last else { return nil }
        if time >= last.time { return last }
        guard let index = sorted.lastIndex(where: { $0.time <= time }), index + 1 < sorted.count else { return last }
        let a = sorted[index], b = sorted[index + 1]
        let span = max(b.time - a.time, 0.0001)
        let linear = min(max((time - a.time) / span, 0), 1)
        let u: Double
        switch a.ease {
        case 1: u = linear
        case 2: u = 1 - pow(1 - linear, 3)
        case 3: u = 0
        default: u = linear * linear * (3 - 2 * linear)
        }
        func mix(_ p: Double, _ q: Double) -> Double { p + (q - p) * u }
        var result = a
        result.scale = mix(a.scale, b.scale)
        result.x = mix(a.x, b.x)
        result.y = mix(a.y, b.y)
        result.rotation = mix(a.rotation, b.rotation)
        return result
    }
}
