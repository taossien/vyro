//
//  StyleTemplate.swift
//  Un style de montage partageable : look, flou, transition, effets et sons.
//  Le fichier (JSON) s'applique à n'importe quel montage : les temps sont étirés à sa durée.
//

import Foundation

struct StyleTemplate: Codable {
    var app = "VYRO"
    var version = 1
    var name: String
    /// Durée du montage d'origine, pour étirer les temps sur un autre montage.
    var duration: Double
    var grade: ColorGrade?
    var motionBlur: Double?
    var transition: CutTransition?
    var effects: [EffectModel]
    var sounds: [SoundMark]

    /// Plafonds à l'import : un fichier reçu ne doit pas pouvoir bloquer l'app.
    static let maxFileBytes = 1_000_000
    static let maxItems = 400
}

extension EditorViewModel {
    /// Écrit le style courant dans un fichier temporaire à partager. nil s'il n'y a rien à partager.
    func styleTemplateFile(name: String = "Mon style VYRO") -> URL? {
        guard hasClip, duration > 0, !(effects.isEmpty && sounds.isEmpty) else { return nil }
        let template = StyleTemplate(
            name: name, duration: duration,
            grade: colorGrade.isNeutral ? nil : colorGrade,
            motionBlur: motionBlurStrength,
            transition: clips.dropFirst().compactMap(\.transition).first,
            effects: effects, sounds: sounds)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".vyrostyle.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(template) else { return nil }
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        return url
    }

    /// Applique un style reçu : même rythme, étiré à la durée de ce montage.
    func importStyleTemplate(from url: URL) {
        guard hasClip, duration > 0 else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= StyleTemplate.maxFileBytes else {
            errorMessage = "Ce fichier est trop gros pour être un style VYRO."
            return
        }
        guard let data = try? Data(contentsOf: url),
              let template = try? JSONDecoder().decode(StyleTemplate.self, from: data),
              template.app == "VYRO", template.duration > 0, template.duration.isFinite,
              template.effects.count <= StyleTemplate.maxItems, template.sounds.count <= StyleTemplate.maxItems else {
            errorMessage = "Ce fichier n'est pas un style VYRO."
            return
        }
        applyTemplate(template)
    }

    func applyTemplate(_ template: StyleTemplate) {
        let k = duration / template.duration
        // Si la musique donne des temps forts, chaque effet est recalé sur le plus proche
        // (à 0,3 s près) : le style retombe sur le rythme de CE montage, pas seulement étiré.
        let marks = beatMarks.count >= 2 ? rhythmMarks(every: 1) : []
        func snapped(_ time: Double) -> Double {
            guard let nearest = marks.min(by: { abs($0 - time) < abs($1 - time) }),
                  abs(nearest - time) <= 0.3 else { return time }
            return nearest
        }
        var effects: [EffectModel] = []
        for var effect in template.effects {
            effect.id = UUID()
            effect.start = snapped(effect.start * k)
            guard effect.start < duration - 0.05 else { continue }
            effect.duration = min(effect.duration, max(duration - effect.start, 0.1))
            effects.append(effect)
        }
        var sounds: [SoundMark] = []
        for var mark in template.sounds {
            mark.id = UUID()
            mark.time = snapped(mark.time * k)
            if mark.time < duration { sounds.append(mark) }
        }
        mutateAllForTemplate { clips in
            clips[0].effects = effects
            clips[0].colorGrade = template.grade
            clips[0].motionBlur = template.motionBlur
            clips[0].sounds = sounds.isEmpty ? nil : sounds
            for index in clips.indices { clips[index].transition = index > 0 ? template.transition : nil }
        }
    }
}
