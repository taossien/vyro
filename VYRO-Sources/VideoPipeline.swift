//
//  VideoPipeline.swift
//  Pipeline UNIQUE utilisé par l'aperçu et l'export : ce qu'on voit est ce qu'on exporte.
//  Composition (vitesse) + AVVideoComposition CoreImage (zoom, shake, stabilisation).
//

import Foundation
import AVFoundation

struct RenderPlan {
    var effects: [EffectModel]
    var speed: Double
    var speedPoints: [SpeedPointModel] = []
    var stabilization: StabilizationData?
    /// Réduction de la taille de sortie (1 = taille d'origine). Utilisé par les presets d'export.
    var outputScale: Double = 1
    /// Découpe en secondes du fichier source (trimOut nil = jusqu'à la fin).
    var trimIn: Double = 0
    var trimOut: Double?
    /// Musique de fond (nil = aucune), volumes 0...1, décalage de départ dans le morceau.
    var musicURL: URL?
    var musicVolume: Double = 0.8
    var musicOffset: Double = 0
    var originalVolume: Double = 1
    /// Force du flou de mouvement (0 = aucun, 1 = rendu cinéma).
    var motionBlur: Double = 1

    /// Faux si le plan ne modifie pas les images (aucun effet actif, pas de stabilisation).
    var needsRendering: Bool {
        stabilization != nil || outputScale < 0.999 || effects.contains { $0.enabled }
    }
}

struct BuiltPipeline {
    let composition: AVAsset
    /// nil quand aucun effet n'est actif : la lecture est alors directe.
    let videoComposition: AVVideoComposition?
    let duration: Double
    let renderSize: CGSize
    let timeMap: TimeMap
    let audioMix: AVAudioMix?
}

/// Presets d'export : la taille maximale du grand côté, jamais d'agrandissement.
enum ExportPreset: String, CaseIterable, Identifiable {
    case original, hd1080, hd720
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return "Original"
        case .hd1080: return "1080p"
        case .hd720: return "720p"
        }
    }
    var detail: String {
        switch self {
        case .original: return "Qualité maximale, taille du fichier source"
        case .hd1080: return "Idéal TikTok, Reels, Shorts"
        case .hd720: return "Fichier léger, envoi rapide"
        }
    }
    var longSide: Double? {
        switch self {
        case .original: return nil
        case .hd1080: return 1920
        case .hd720: return 1280
        }
    }
}

enum PipelineError: LocalizedError {
    case noVideoTrack
    case invalidDuration
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "Ce fichier ne contient pas de piste vidéo."
        case .invalidDuration: return "La durée de ce clip est invalide."
        case .exportFailed(let detail): return "L'export a échoué : " + detail
        }
    }
}

enum VideoPipeline {
    static let minSpeed = 0.25
    static let maxSpeed = 4.0
    /// Cadence de mise à jour des effets (identique à l'analyse de stabilisation).
    static let effectFPS = 30

    // MARK: Construction

    static func build(url: URL, plan: RenderPlan) async throws -> BuiltPipeline {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0 else { throw PipelineError.invalidDuration }

        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw PipelineError.noVideoTrack
        }
        let preferred = try await sourceVideo.load(.preferredTransform)
        let natural = try await sourceVideo.load(.naturalSize)
        let nominalRate = try await sourceVideo.load(.nominalFrameRate)
        let oriented = natural.applying(preferred)
        let renderSize = CGSize(width: abs(oriented.width).rounded(), height: abs(oriented.height).rounded())

        let timeMap = TimeMap.make(
            sourceDuration: duration.seconds,
            base: plan.speed,
            points: plan.speedPoints,
            trimIn: plan.trimIn,
            trimOut: plan.trimOut
        )
        let isTrimmed = plan.trimIn > 0.001 || (plan.trimOut.map { $0 < duration.seconds - 0.001 } ?? false)
        let isPlain = plan.speedPoints.isEmpty && abs(plan.speed - 1) < 0.001 && !isTrimmed
            && plan.musicURL == nil && abs(plan.originalVolume - 1) < 0.01

        // Vitesse normale : on traite le fichier tel quel. Sinon, on assemble des tronçons.
        let base: AVAsset
        var activeTrack: AVAssetTrack = sourceVideo
        var outputDuration = duration
        var audioMix: AVMutableAudioMix?
        if isPlain {
            base = asset
        } else {
            let composition = AVMutableComposition()
            guard let track = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { throw PipelineError.noVideoTrack }
            track.preferredTransform = preferred
            composition.naturalSize = renderSize

            let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
            let audio = sourceAudio == nil ? nil : composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )

            // Chaque tronçon est inséré à la suite puis étiré à sa durée de sortie.
            let scale: CMTimeScale = 6000
            var cursor = CMTime.zero
            for slice in timeMap.slices {
                let start = CMTime(seconds: slice.sourceStart, preferredTimescale: scale)
                var end = CMTime(seconds: slice.sourceEnd, preferredTimescale: scale)
                if end > duration { end = duration }
                let range = CMTimeRange(start: start, end: end)
                guard range.duration > .zero else { continue }

                try track.insertTimeRange(range, of: sourceVideo, at: cursor)
                if let sourceAudio, let audio {
                    try? audio.insertTimeRange(range, of: sourceAudio, at: cursor)
                }
                let target = CMTimeMultiplyByFloat64(range.duration, multiplier: 1.0 / slice.speed)
                composition.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: target)
                cursor = cursor + target
            }
            outputDuration = composition.duration

            // Volumes : son d'origine, puis musique (fondu de 0,5 s à la fin).
            var mixParameters: [AVMutableAudioMixInputParameters] = []
            if let audio {
                let parameters = AVMutableAudioMixInputParameters(track: audio)
                parameters.setVolume(Float(plan.originalVolume), at: .zero)
                mixParameters.append(parameters)
            }
            if let musicURL = plan.musicURL {
                let musicAsset = AVURLAsset(url: musicURL)
                if let musicTrack = try? await musicAsset.loadTracks(withMediaType: .audio).first,
                   let musicDuration = try? await musicAsset.load(.duration),
                   musicDuration.seconds.isFinite,
                   let musicCompositionTrack = composition.addMutableTrack(
                       withMediaType: .audio,
                       preferredTrackID: kCMPersistentTrackID_Invalid
                   ) {
                    let offset = CMTime(seconds: min(max(plan.musicOffset, 0), max(musicDuration.seconds - 0.5, 0)),
                                        preferredTimescale: 600)
                    let length = CMTimeMinimum(musicDuration - offset, outputDuration)
                    if length > .zero {
                        try? musicCompositionTrack.insertTimeRange(
                            CMTimeRange(start: offset, duration: length), of: musicTrack, at: .zero
                        )
                        let parameters = AVMutableAudioMixInputParameters(track: musicCompositionTrack)
                        let volume = Float(plan.musicVolume)
                        parameters.setVolume(volume, at: .zero)
                        let fade = CMTime(seconds: 0.5, preferredTimescale: 600)
                        if length > fade {
                            parameters.setVolumeRamp(
                                fromStartVolume: volume, toEndVolume: 0,
                                timeRange: CMTimeRange(start: length - fade, duration: fade)
                            )
                        }
                        mixParameters.append(parameters)
                    }
                }
            }
            if !mixParameters.isEmpty {
                let mix = AVMutableAudioMix()
                mix.inputParameters = mixParameters
                audioMix = mix
            }
            activeTrack = track
            base = composition
        }

        var videoComposition: AVMutableVideoComposition?
        var finalSize = renderSize
        if plan.outputScale < 0.999 {
            finalSize = CGSize(
                width: (renderSize.width * plan.outputScale / 2).rounded() * 2,
                height: (renderSize.height * plan.outputScale / 2).rounded() * 2
            )
        }
        if plan.needsRendering {
            videoComposition = makeVideoComposition(
                track: activeTrack,
                preferred: preferred,
                renderSize: renderSize,
                finalSize: finalSize,
                duration: outputDuration,
                frameRate: nominalRate,
                plan: plan,
                timeMap: timeMap
            )
        }

        return BuiltPipeline(
            composition: base,
            videoComposition: videoComposition,
            duration: outputDuration.seconds,
            renderSize: finalSize,
            timeMap: timeMap,
            audioMix: audioMix
        )
    }

    // MARK: Composition vidéo (rendu image par image par VYROCompositor)

    private static func makeVideoComposition(track: AVAssetTrack,
                                             preferred: CGAffineTransform,
                                             renderSize: CGSize,
                                             finalSize: CGSize,
                                             duration: CMTime,
                                             frameRate: Float,
                                             plan: RenderPlan,
                                             timeMap: TimeMap) -> AVMutableVideoComposition {
        let instruction = VYROInstruction(
            timeRange: CMTimeRange(start: .zero, duration: duration),
            trackID: track.trackID,
            orientation: FrameRenderer.orientation(for: preferred),
            baseSize: renderSize,
            finalSize: finalSize,
            effects: plan.effects,
            stabilization: plan.stabilization,
            timeMap: timeMap,
            motionBlur: plan.motionBlur
        )
        let composition = AVMutableVideoComposition()
        composition.renderSize = finalSize
        let fps = frameRate > 1 ? min(Int(frameRate.rounded()), 60) : 30
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        composition.instructions = [instruction]
        composition.customVideoCompositorClass = VYROCompositor.self
        return composition
    }

    // MARK: Export

    private static func naturalLongSide(url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return 0 }
        let size = try await track.load(.naturalSize)
        return Double(max(size.width, size.height))
    }

    /// Exporte le montage dans un fichier .mp4 temporaire, avec le MÊME pipeline que l'aperçu.
    static func export(url: URL,
                       plan: RenderPlan,
                       preset: ExportPreset = .original,
                       progress: @escaping (Double) -> Void) async throws -> URL {
        var plan = plan
        if let side = preset.longSide, let size = try? await naturalLongSide(url: url), size > side {
            plan.outputScale = side / size
        }
        let built = try await build(url: url, plan: plan)

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("VYRO-" + UUID().uuidString + ".mp4")
        try? FileManager.default.removeItem(at: output)

        guard let session = AVAssetExportSession(
            asset: built.composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw PipelineError.exportFailed("session indisponible")
        }
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        session.outputURL = output
        session.outputFileType = .mp4
        session.audioTimePitchAlgorithm = .spectral

        let poller = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        poller.cancel()

        guard session.status == .completed else {
            throw PipelineError.exportFailed(session.error?.localizedDescription ?? "erreur inconnue")
        }
        progress(1)
        return output
    }
}
