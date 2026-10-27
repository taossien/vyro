//
//  Sounds.swift
//  Catalogue d'effets sonores (fichiers WAV générés par tools/make_sounds.py, sans droits).
//

import Foundation
import AVFoundation

enum SoundKind: Int, CaseIterable, Identifiable {
    case whoosh, whooshFast, impact, bass, riser, glitch

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .whoosh: return "Whoosh"
        case .whooshFast: return "Whoosh vif"
        case .impact: return "Impact"
        case .bass: return "Basse"
        case .riser: return "Riser"
        case .glitch: return "Glitch"
        }
    }

    var icon: String {
        switch self {
        case .whoosh, .whooshFast: return "wind"
        case .impact: return "burst.fill"
        case .bass: return "waveform.path.ecg"
        case .riser: return "chart.line.uptrend.xyaxis"
        case .glitch: return "square.stack.3d.down.right"
        }
    }

    var fileName: String {
        switch self {
        case .whoosh: return "sfx_whoosh"
        case .whooshFast: return "sfx_whoosh_fast"
        case .impact: return "sfx_impact"
        case .bass: return "sfx_bass"
        case .riser: return "sfx_riser"
        case .glitch: return "sfx_glitch"
        }
    }

    /// Durée du fichier : sert à caler les sons qui doivent finir sur le coup (riser) ou être centrés.
    var length: Double {
        switch self {
        case .whoosh: return 0.7
        case .whooshFast: return 0.35
        case .impact: return 0.9
        case .bass: return 1.3
        case .riser: return 1.6
        case .glitch: return 0.32
        }
    }

    /// Combien de temps avant l'instant choisi le son démarre.
    var lead: Double {
        switch self {
        case .whoosh: return 0.4
        case .whooshFast: return 0.2
        case .riser: return 1.6
        default: return 0
        }
    }

    var url: URL? { Bundle.main.url(forResource: fileName, withExtension: "wav") }
}
