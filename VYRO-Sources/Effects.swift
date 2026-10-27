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

    /// Glitch : saccades horizontales brusques, intensité = amplitude (fraction de la largeur).
    static func glitch(start: Double, duration: Double = 0.4, amount: Double = 0.04) -> EffectModel {
        EffectModel(
            id: UUID(),
            type: .glitch,
            parameters: [
                "start": start,
                "duration": duration,
                "intensity": amount,
                "seed": Double(Int.random(in: 1...9999))
            ]
        )
    }

    /// Halo lumineux (bloom) : intensité = force du halo, retombée progressive.
    static func glow(start: Double, duration: Double = 0.5, strength: Double = 0.9) -> EffectModel {
        EffectModel(
            id: UUID(),
            type: .glow,
            parameters: ["start": start, "duration": duration, "intensity": strength]
        )
    }

    /// Courbe du zoom : 0 = punch, 1 = doux, 2 = claque (montée instantanée).
    var curve: Int {
        get { Int(parameters["curve"] ?? 0) }
        set { parameters["curve"] = Double(newValue) }
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
        get { parameters["intensity"] ?? (type == .zoom ? 1.4 : (type == .flash ? 0.8 : (type == .glitch ? 0.04 : (type == .glow ? 0.9 : 0.02)))) }
        set { parameters["intensity"] = newValue }
    }

    var end: Double { start + duration }

    var title: String {
        switch type {
        case .zoom: return "Zoom"
        case .shake: return "Shake"
        case .flash: return "Flash"
        case .glitch: return "Glitch"
        case .glow: return "Halo"
        case .speed: return "Vitesse"
        }
    }

    var systemImage: String {
        switch type {
        case .zoom: return "plus.magnifyingglass"
        case .shake: return "waveform.path"
        case .flash: return "bolt.fill"
        case .glitch: return "square.stack.3d.down.right"
        case .glow: return "sun.max.fill"
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
    /// Séparation des couleurs (aberration chromatique), en fraction de la largeur.
    var rgbSplit: Double = 0
    /// Force du halo lumineux (0 = aucun).
    var glow: Double = 0
}

enum EffectEngine {
    static let shakeFrequency = 18.0
    static let glitchRate = 15.0

    static func transform(at time: Double, effects: [EffectModel]) -> FrameTransform {
        var result = FrameTransform()
        for effect in effects where effect.enabled && effect.duration > 0 {
            guard time >= effect.start, time <= effect.end else { continue }
            let u = (time - effect.start) / effect.duration
            switch effect.type {
            case .zoom:
                result.scale += (effect.intensity - 1) * zoomEnvelope(u, curve: effect.curve)
            case .shake:
                let falloff = decay(u, curve: effect.curve)
                let seed = UInt32(truncatingIfNeeded: Int(effect.parameters["seed"] ?? 1))
                let x = time * shakeFrequency
                result.dx += effect.intensity * falloff * noise(seed: seed, x: x, channel: 0)
                result.dy += effect.intensity * falloff * noise(seed: seed, x: x, channel: 1)
                result.margin += 2 * effect.intensity * falloff
                result.rgbSplit += effect.intensity * 0.15 * falloff
            case .glitch:
                let seed = UInt32(truncatingIfNeeded: Int(effect.parameters["seed"] ?? 1))
                let step = Int(floor(time * glitchRate))
                // Une saccade sur deux environ : le reste du temps l'image est nette.
                let active = hash(seed: seed, index: step, channel: 2) > -0.1
                if active {
                    let falloff = effect.curve == 0 ? 1 - 0.6 * u : decay(u, curve: effect.curve)
                    result.dx += effect.intensity * falloff * hash(seed: seed, index: step, channel: 0)
                    result.dy += effect.intensity * 0.25 * falloff * hash(seed: seed, index: step, channel: 1)
                    result.margin += 2 * effect.intensity * falloff
                    result.rgbSplit += effect.intensity * 0.35 * falloff
                }
            case .glow:
                result.glow += effect.intensity * decay(u, curve: effect.curve)
            case .flash:
                result.flash = min(1, result.flash + effect.intensity * decay(u, curve: effect.curve))
            default:
                break
            }
        }
        return result
    }

    /// Retombée d'un effet qui démarre à son maximum : 0 punch, 1 doux (monte puis redescend),
    /// 2 claque (chute très rapide), 3 linéaire.
    static func decay(_ u: Double, curve: Int) -> Double {
        switch curve {
        case 1:
            let k = u < 0.5 ? u * 2 : (1 - u) * 2
            return k * k * (3 - 2 * k)
        case 2: return pow(1 - u, 4)
        case 3: return 1 - u
        default: return (1 - u) * (1 - u)
        }
    }

    /// Montée rapide (25 % du temps) puis retour doux : l'effet "punch" des gaming edits.
    static func zoomEnvelope(_ u: Double, curve: Int = 0) -> Double {
        if curve == 3 {                                   // linéaire : triangle
            return u < 0.5 ? u * 2 : (1 - u) * 2
        }
        if curve == 1 {                                   // doux : montée et descente lissées
            let k = u < 0.5 ? u * 2 : (1 - u) * 2
            return k * k * (3 - 2 * k)
        }
        let attack = curve == 2 ? 0.06 : 0.25
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

    static func hash(seed: UInt32, index: Int, channel: UInt32) -> Double {
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
