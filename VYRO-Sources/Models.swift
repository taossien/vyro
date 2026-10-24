//
//  Models.swift
//  Modèle de données versionné du projet VYRO.
//  Conceptuel en Phase 1 : il structure déjà les clips et effets à venir.
//

import Foundation

/// Version du schéma de sauvegarde. Incrémenter à chaque évolution incompatible.
enum Schema {
    static let version = 1
}

struct KeyframeModel: Codable, Identifiable, Equatable {
    enum Interpolation: String, Codable {
        case linear, easeIn, easeOut, easeInOut, bezier
    }

    var id: UUID
    var parameterName: String
    var time: Double
    var value: Double
    var interpolation: Interpolation = .linear
}

struct EffectModel: Codable, Identifiable, Equatable {
    enum EffectType: String, Codable {
        case zoom, shake, flash, glitch, speed
    }

    var id: UUID
    var type: EffectType
    var enabled: Bool = true
    var order: Int = 0
    var parameters: [String: Double] = [:]
    var keyframes: [KeyframeModel] = []
    var effectVersion: Int = 1
}

/// Point de vitesse d'une rampe : à `time` (secondes du fichier source), le clip joue à `speed`.
/// Entre deux points la vitesse varie linéairement (time remapping).
struct SpeedPointModel: Codable, Identifiable, Equatable {
    var id: UUID
    var time: Double
    var speed: Double
}

struct ClipModel: Codable, Identifiable, Equatable {
    var id: UUID
    /// Nom du fichier copié dans le dossier Media local (jamais un chemin temporaire).
    var mediaFileName: String
    var timelineStart: Double = 0
    var sourceIn: Double = 0
    var sourceOut: Double = 0
    var speed: Double = 1.0
    var effects: [EffectModel] = []
    /// Optionnels : les projets sauvegardés avant la Phase 5 restent lisibles.
    var stabilizationEnabled: Bool?
    var speedPoints: [SpeedPointModel]?
}

struct TrackModel: Codable, Identifiable, Equatable {
    enum TrackType: String, Codable {
        case video, audio
    }

    var id: UUID
    var type: TrackType = .video
    var order: Int = 0
    var clips: [ClipModel] = []
}

struct ProjectModel: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var creationDate: Date
    var modificationDate: Date
    var frameRate: Double = 30
    var canvasWidth: Int = 1080
    var canvasHeight: Int = 1920
    var tracks: [TrackModel] = []
    var schemaVersion: Int = Schema.version
}
