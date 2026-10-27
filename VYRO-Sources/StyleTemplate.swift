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
        guard let data = try? Data(contentsOf: url),
              let template = try? JSONDecoder().decode(StyleTemplate.self, from: data),
              template.app == "VYRO", template.duration > 0 else {
            errorMessage = "Ce fichier n'est pas un style VYRO."
            return
        }
        applyTemplate(template)
    }

    func applyTemplate(_ template: StyleTemplate) {
        let k = duration / template.duration
        var effects: [EffectModel] = []
        for var effect in template.effects {
            effect.id = UUID()
            effect.start *= k
            guard effect.start < duration - 0.05 else { continue }
            effect.duration = min(effect.duration, max(duration - effect.start, 0.1))
            effects.append(effect)
        }
        var sounds: [SoundMark] = []
        for var mark in template.sounds {
            mark.id = UUID()
            mark.time *= k
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
