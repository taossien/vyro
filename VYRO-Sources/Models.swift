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
        case zoom, shake, flash, glitch, speed, glow, sparkles, ring, chroma
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
    /// Découpe (secondes du fichier source). nil = début / fin du fichier.
    var trimIn: Double?
    var trimOut: Double?
    /// Musique de fond (fichier copié dans Media), volumes 0...1, départ dans le morceau (s).
    var musicFileName: String?
    var musicVolume: Double?
    var originalVolume: Double?
    var musicOffset: Double?
    /// Force du flou de mouvement (nil = 1, rendu cinéma).
    var motionBlur: Double?
    /// Étalonnage global (nil = image d'origine).
    var colorGrade: ColorGrade?
    /// Textes et sous-titres (globaux, temps du montage).
    var texts: [TextOverlay]?
    /// Images clés de mouvement (globales, temps du montage).
    var keyframes: [Keyframe]?
    /// Effets sonores posés sur le montage (globaux, temps du montage).
    var sounds: [SoundMark]?
    /// Image figée : durée (s) pendant laquelle l'image au point d'entrée (trimIn) est tenue.
    var hold: Double?
    /// Transition à l'entrée de ce clip (ignorée pour le premier clip).
    var transition: CutTransition?
}

/// Effet placé sur la coupure entre deux clips.
struct CutTransition: Codable, Equatable {
    /// 0 flash, 1 zoom, 2 glitch, 3 flou, 4 noir, 5 whip.
    var type: Int = 0
    var duration: Double = 0.3

    static let names = ["Flash", "Zoom", "Glitch", "Flou", "Noir", "Whip",
                        "Spin", "Glissé", "Strobe", "Flash zoom", "Tremble", "Glitch+", "Whip V", "Punch", "Roulis"]
}

/// Un texte affiché pendant un moment du montage.
struct TextOverlay: Codable, Identifiable, Equatable {
    var id: UUID
    var text: String = "TEXTE"
    var start: Double
    var duration: Double = 2
    /// Position verticale du centre (0 = haut, 1 = bas) et taille (fraction de la largeur).
    var y: Double = 0.78
    var size: Double = 0.09
    var colorIndex: Int = 0
    /// 0 simple, 1 contour, 2 fond, 3 néon.
    var style: Int = 1
    /// 0 aucune, 1 pop, 2 fondu, 3 pop avec rotation.
    var animation: Int = 1
    /// Police (indice dans fontNames), nil = la première.
    var font: Int?
    /// Vrai pour les textes créés par les sous-titres automatiques.
    var subtitle: Bool?
    /// Inclinaison en degrés (nil = 0).
    var rotation: Double?
    /// Karaoké : début de chaque mot (s, depuis le début du texte). Le mot en cours est surligné.
    var wordStarts: [Double]?

    var end: Double { start + duration }

    static let palette: [(name: String, r: Double, g: Double, b: Double)] = [
        ("Blanc", 1, 1, 1), ("Jaune", 1, 0.92, 0.2), ("Cyan", 0.2, 0.9, 1),
        ("Rose", 1, 0.3, 0.7), ("Menthe", 0.3, 1, 0.7), ("Orange", 1, 0.55, 0.15)
    ]
    static let fontNames = ["Impact", "Arrondi", "Serif", "Mono", "Condensé", "Futura"]
    static let styleNames = ["Simple", "Contour", "Fond", "Néon"]
    static let animationNames = ["Aucune", "Pop", "Fondu", "Tourne"]
}

/// Étalonnage couleur : réglages simples, inspirés des looks des créateurs.
struct ColorGrade: Codable, Equatable {
    var exposure: Double = 0       // -1...1 (IL)
    var contrast: Double = 1       // 0.5...1.6
    var saturation: Double = 1     // 0...2
    var warmth: Double = 0         // -1 (froid) ... 1 (chaud)
    var vignette: Double = 0       // 0...1

    static let neutral = ColorGrade()
    var isNeutral: Bool { self == ColorGrade.neutral }

    static let presets: [(name: String, grade: ColorGrade)] = [
        ("Neutre", .neutral),
        ("Néon", ColorGrade(exposure: 0, contrast: 1.25, saturation: 1.5, warmth: -0.2, vignette: 0.3)),
        ("Cinéma", ColorGrade(exposure: -0.1, contrast: 1.15, saturation: 0.9, warmth: 0.2, vignette: 0.4)),
        ("Sombre", ColorGrade(exposure: -0.4, contrast: 1.3, saturation: 1.1, warmth: -0.1, vignette: 0.5)),
        ("Vif", ColorGrade(exposure: 0.05, contrast: 1.15, saturation: 1.6, warmth: 0, vignette: 0)),
        ("Rétro", ColorGrade(exposure: 0, contrast: 1.1, saturation: 0.7, warmth: 0.5, vignette: 0.3))
    ]
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


/// Un effet sonore posé sur le montage (voir Sounds.swift pour le catalogue).
struct SoundMark: Codable, Identifiable, Equatable {
    var id: UUID
    /// Instant du coup (impact, fin du riser), en secondes du montage.
    var time: Double
    var kind: Int
    var volume: Double = 0.8
}
