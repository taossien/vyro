//
//  Styles.swift
//  Styles prêts à l'emploi : un geste applique look, effets sur le rythme, transitions et flou.
//

import Foundation

struct StylePreset: Identifiable {
    let id: String
    let name: String
    let icon: String
    let blurb: String
    let grade: ColorGrade
    let motionBlur: Double
    let transition: CutTransition?
    /// Un effet tous les N temps forts de la musique.
    let beatEvery: Int
    /// Effet sonore posé sur chaque temps fort retenu.
    let sound: SoundKind?
    /// Effets posés sur un temps fort (temps, numéro, durée restante).
    let effects: (_ time: Double, _ index: Int, _ room: Double) -> [EffectModel]

    static let all: [StylePreset] = [
        StylePreset(
            id: "neon", name: "Néon", icon: "sparkles",
            blurb: "Couleurs électriques, zooms et glitch sur le rythme",
            grade: ColorGrade.presets[1].grade, motionBlur: 1,
            transition: CutTransition(type: 2, duration: 0.25), beatEvery: 2, sound: .whooshFast,
            effects: { time, index, room in
                var list = [EffectModel.zoom(start: time, duration: min(0.3, room), peak: 1.25)]
                list.append(.glow(start: time, duration: min(0.4, room), strength: 0.5))
                if index % 3 == 2 { list.append(.glitch(start: time, duration: min(0.25, room), amount: 0.05)) }
                if index % 2 == 0 { list.append(.ring(start: time, duration: min(0.6, room), strength: 0.8)) }
                return list
            }),
        StylePreset(
            id: "cinema", name: "Cinéma", icon: "film",
            blurb: "Doux et sombre, zooms lents, passages par le noir",
            grade: ColorGrade.presets[2].grade, motionBlur: 0.8,
            transition: CutTransition(type: 4, duration: 0.5), beatEvery: 4, sound: .bass,
            effects: { time, _, room in
                var zoom = EffectModel.zoom(start: time, duration: min(0.9, room), peak: 1.12)
                zoom.curve = 1
                return [zoom]
            }),
        StylePreset(
            id: "rapide", name: "Ultra rapide", icon: "bolt.fill",
            blurb: "Un effet à chaque temps : secousses, flashs, balayages",
            grade: ColorGrade.presets[4].grade, motionBlur: 1.2,
            transition: CutTransition(type: 5, duration: 0.2), beatEvery: 1, sound: .glitch,
            effects: { time, index, room in
                var list = [EffectModel.zoom(start: time, duration: min(0.2, room), peak: 1.2)]
                list.append(.shake(start: time, duration: min(0.2, room), amplitude: 0.012))
                if index % 2 == 1 { list.append(.flash(start: time, duration: min(0.1, room), strength: 0.25)) }
                return list
            }),
        StylePreset(
            id: "sombre", name: "Sombre", icon: "moon.stars.fill",
            blurb: "Froid et contrasté : zooms secs, flou et bords colorés sur le pic",
            grade: ColorGrade(exposure: -0.15, contrast: 1.35, saturation: 0.85, warmth: -0.45, vignette: 0.6), motionBlur: 1.6,
            transition: CutTransition(type: 5, duration: 0.3), beatEvery: 4, sound: .impact,
            effects: { time, _, room in
                var zoom = EffectModel.zoom(start: time, duration: min(0.35, room), peak: 1.3)
                zoom.curve = 2
                return [zoom, .chroma(start: time, duration: min(0.45, room), amount: 0.014),
                        .glitch(start: time + 0.1, duration: min(0.2, room), amount: 0.035)]
            }),
        StylePreset(
            id: "lueur", name: "Lueur", icon: "sun.max.fill",
            blurb: "Couleurs vives bleu/violet, halos et flashs doux sur le rythme",
            grade: ColorGrade(exposure: 0.05, contrast: 1.2, saturation: 1.5, warmth: -0.25, vignette: 0.3), motionBlur: 0.8,
            transition: CutTransition(type: 0, duration: 0.25), beatEvery: 2, sound: .whoosh,
            effects: { time, index, room in
                var list = [EffectModel.glow(start: time, duration: min(0.6, room), strength: 0.8)]
                list.append(.sparkles(start: time, duration: min(0.9, room), amount: 1))
                if index % 2 == 1 { list.append(.ring(start: time, duration: min(0.7, room), strength: 1)) }
                if index % 2 == 0 { list.append(.flash(start: time, duration: min(0.1, room), strength: 0.2)) }
                list.append(.zoom(start: time, duration: min(0.4, room), peak: 1.12))
                return list
            }),
        StylePreset(
            id: "impact", name: "Impact", icon: "burst.fill",
            blurb: "Le grand classique gaming : zoom, secousse, flash et halo",
            grade: ColorGrade.presets[3].grade, motionBlur: 1,
            transition: CutTransition(type: 0, duration: 0.2), beatEvery: 2, sound: .impact,
            effects: { time, _, room in
                var zoom = EffectModel.zoom(start: time, duration: min(0.55, room), peak: 1.35)
                zoom.curve = 2
                return [
                    zoom,
                    .shake(start: time, duration: min(0.4, room), amplitude: 0.015),
                    .flash(start: time, duration: min(0.15, room), strength: 0.3),
                    .glow(start: time, duration: min(0.5, room), strength: 0.6)
                ]
            })
    ]
}
