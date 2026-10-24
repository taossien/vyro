//
//  Effects.swift
//  Effets déterministes : le même instant donne toujours exactement la même image,
//  dans l'aperçu comme à l'export (aucun hasard non reproductible).
//

import Foundation
import CoreGraphics

// MARK: - Accès pratique aux paramètres d'un effet

extension EffectModel {
    /// Zoom "punch" : intensité = échelle maximale (1.4 = 140 %).
    static func zoom(start: Double, duration: Double = 0.6, peak: Double = 1.4) -> EffectModel {
        EffectModel(
            id: UUID(),
            type: .zoom,
            parameters: ["start": start, "duration": duration, "intensity": peak]
        )
    }

    /// Secousse : intensité = amplitude en fraction de la taille de l'image (0.02 = 2 %).
    /// Le seed fixe la secousse, elle est donc identique à chaque lecture et à l'export.
    static func shake(start: Double, duration: Double = 0.5, amplitude: Double = 0.02) -> EffectModel {
        EffectModel(
            id: UUID(),
            type: .shake,
            parameters: [
                "start": start,
                "duration": duration,
                "intensity": amplitude,
                "seed": Double(Int.random(in: 1...9999))
            ]
        )
    }

    /// Flash blanc : intensité = blancheur maximale (1 = écran tout blanc), retombée rapide.
    static func flash(start: Double, duration: Double = 0.25, strength: Double = 0.8) -> EffectModel {
        EffectModel(
            id: UUID(),
            type: .flash,
            parameters: ["start": start, "duration": duration, "intensity": strength]
        )
    }

    var start: Double {
        get { parameters["start"] ?? 0 }
        set { parameters["start"] = newValue }
    }

    var duration: Double {
        get { parameters["duration"] ?? 0.5 }
        set { parameters["duration"] = newValue }
    }

    var intensity: Double {
        get { parameters["intensity"] ?? (type == .zoom ? 1.4 : (type == .flash ? 0.8 : 0.02)) }
        set { parameters["intensity"] = newValue }
    }

    var end: Double { start + duration }

    var title: String {
        switch type {
        case .zoom: return "Zoom"
        case .shake: return "Shake"
        case .flash: return "Flash"
        case .glitch: return "Glitch"
        case .speed: return "Vitesse"
        }
    }

    var systemImage: String {
        switch type {
        case .zoom: return "plus.magnifyingglass"
        case .shake: return "waveform.path"
        case .flash: return "bolt.fill"
        case .glitch: return "square.stack.3d.down.right"
        case .speed: return "speedometer"
        }
    }
}

// MARK: - Transformation d'une image à un instant donné

struct FrameTransform {
    /// Échelle autour du centre (1 = inchangé).
    var scale: Double = 1
    /// Décalage en fraction de la largeur / hauteur de l'image.
    var dx: Double = 0
    var dy: Double = 0
    /// Agrandissement supplémentaire pour que le décalage ne révèle jamais de bords noirs.
    var margin: Double = 0
    /// Blancheur ajoutée (0 = rien, 1 = écran blanc).
    var flash: Double = 0
}

enum EffectEngine {
    static let shakeFrequency = 18.0

    static func transform(at time: Double, effects: [EffectModel]) -> FrameTransform {
        var result = FrameTransform()
        for effect in effects where effect.enabled && effect.duration > 0 {
            guard time >= effect.start, time <= effect.end else { continue }
            let u = (time - effect.start) / effect.duration
            switch effect.type {
            case .zoom:
                result.scale += (effect.intensity - 1) * zoomEnvelope(u)
            case .shake:
                let decay = (1 - u) * (1 - u)
                let seed = UInt32(truncatingIfNeeded: Int(effect.parameters["seed"] ?? 1))
                let x = time * shakeFrequency
                result.dx += effect.intensity * decay * noise(seed: seed, x: x, channel: 0)
                result.dy += effect.intensity * decay * noise(seed: seed, x: x, channel: 1)
                result.margin += 2 * effect.intensity * decay
            case .flash:
                result.flash = min(1, result.flash + effect.intensity * (1 - u) * (1 - u))
            default:
                break
            }
        }
        return result
    }

    /// Montée rapide (25 % du temps) puis retour doux : l'effet "punch" des gaming edits.
    static func zoomEnvelope(_ u: Double) -> Double {
        let attack = 0.25
        if u < attack {
            let k = u / attack
            return 1 - (1 - k) * (1 - k)
        }
        let k = (u - attack) / (1 - attack)
        return 1 - k * k * (3 - 2 * k)
    }

    /// Bruit de valeur lissé, déterministe, dans [-1, 1].
    static func noise(seed: UInt32, x: Double, channel: UInt32) -> Double {
        let i = Int(floor(x))
        let f = x - floor(x)
        let s = f * f * (3 - 2 * f)
        let a = hash(seed: seed, index: i, channel: channel)
        let b = hash(seed: seed, index: i + 1, channel: channel)
        return a + (b - a) * s
    }

    private static func hash(seed: UInt32, index: Int, channel: UInt32) -> Double {
        var h = seed &* 374_761_393
        h = h &+ UInt32(truncatingIfNeeded: index) &* 668_265_263
        h = h &+ channel &* 2_246_822_519
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Double(h) / Double(UInt32.max) * 2 - 1
    }
}

// MARK: - Données de stabilisation

/// Correction de mouvement précalculée (une valeur par image analysée),
/// en fraction de la largeur / hauteur. Sauvegardée à côté du média.
struct StabilizationData: Codable, Equatable {
    var fps: Double
    var dx: [Double]
    var dy: [Double]

    /// Zoom de recadrage constant, calculé sur la correction maximale du clip,
    /// pour masquer les bords révélés sans variation de cadrage pendant la lecture.
    var cropScale: Double {
        let peak = max(dx.map { abs($0) }.max() ?? 0, dy.map { abs($0) }.max() ?? 0)
        return 1 + 2 * peak + 0.005
    }

    func correction(atSourceTime time: Double) -> (dx: Double, dy: Double) {
        guard !dx.isEmpty, dx.count == dy.count else { return (0, 0) }
        let position = min(max(time * fps, 0), Double(dx.count - 1))
        let i0 = Int(floor(position))
        let i1 = min(i0 + 1, dx.count - 1)
        let f = position - Double(i0)
        return (dx[i0] + (dx[i1] - dx[i0]) * f, dy[i0] + (dy[i1] - dy[i0]) * f)
    }
}
