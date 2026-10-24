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

    /// Faux si le plan ne modifie pas les images (aucun effet actif, pas de stabilisation).
    var needsRendering: Bool {
        stabilization != nil || effects.contains { $0.enabled }
    }
}

struct BuiltPipeline {
    let composition: AVAsset
    /// nil quand aucun effet n'est actif : la lecture est alors directe.
    let videoComposition: AVVideoComposition?
    let duration: Double
    let renderSize: CGSize
    let timeMap: TimeMap
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
            points: plan.speedPoints
        )
        let isPlain = plan.speedPoints.isEmpty && abs(plan.speed - 1) < 0.001

        // Vitesse normale : on traite le fichier tel quel. Sinon, on assemble des tronçons.
        let base: AVAsset
        var activeTrack: AVAssetTrack = sourceVideo
        var outputDuration = duration
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
            activeTrack = track
            base = composition
        }

        var videoComposition: AVMutableVideoComposition?
        if plan.needsRendering {
            videoComposition = makeVideoComposition(
                track: activeTrack,
                preferred: preferred,
                renderSize: renderSize,
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
            renderSize: renderSize,
            timeMap: timeMap
        )
    }

    // MARK: Instructions (une par changement de cadrage, à cadence fixe)

    private struct FrameKey: Equatable {
        var scale: Double
        var dx: Double
        var dy: Double
        var flash: Double
    }

    private static func makeVideoComposition(track: AVAssetTrack,
                                             preferred: CGAffineTransform,
                                             renderSize: CGSize,
                                             duration: CMTime,
                                             frameRate: Float,
                                             plan: RenderPlan,
                                             timeMap: TimeMap) -> AVMutableVideoComposition {
        let step = CMTimeValue(600 / effectFPS)            // 1/30 s en unités de 1/600 s
        let count = max(1, Int((duration.seconds * Double(effectFPS) - 1e-6).rounded(.up)))
        let stabilizationCrop = plan.stabilization?.cropScale ?? 1

        // Cadrage de chaque pas de 1/30 s ; les pas identiques sont fusionnés.
        var segments: [(start: Int, key: FrameKey)] = []
        for i in 0..<count {
            let time = Double(i) / Double(effectFPS)
            let fx = EffectEngine.transform(at: time, effects: plan.effects)
            var scale = fx.scale * (1 + fx.margin)
            var dx = fx.dx
            var dy = fx.dy
            if let stabilization = plan.stabilization {
                let c = stabilization.correction(atSourceTime: timeMap.sourceTime(atOutput: time))
                scale *= stabilizationCrop
                dx += c.dx
                dy -= c.dy      // Vision : axe Y vers le haut ; calque : vers le bas
            }
            let key = FrameKey(scale: scale, dx: dx, dy: dy, flash: (fx.flash * 50).rounded() / 50)
            if segments.last?.key != key { segments.append((i, key)) }
        }

        var instructions: [AVVideoCompositionInstructionProtocol] = []
        for (index, segment) in segments.enumerated() {
            let start = CMTime(value: CMTimeValue(segment.start) * step, timescale: 600)
            let end = index + 1 < segments.count
                ? CMTime(value: CMTimeValue(segments[index + 1].start) * step, timescale: 600)
                : duration
            guard end > start else { continue }

            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(
                layerTransform(segment.key, preferred: preferred, size: renderSize),
                at: .zero
            )
            if segment.key.flash > 0 { layer.setOpacity(Float(1 - segment.key.flash), at: .zero) }
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.backgroundColor = CGColor(gray: 1, alpha: 1)   // le flash révèle ce fond blanc
            instruction.timeRange = CMTimeRange(start: start, end: end)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
        }

        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        let fps = frameRate > 1 ? min(Int(frameRate.rounded()), 60) : 30
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        composition.instructions = instructions
        return composition
    }

    /// Orientation d'origine, puis zoom autour du centre, puis décalage (fractions de l'image).
    private static func layerTransform(_ key: FrameKey,
                                       preferred: CGAffineTransform,
                                       size: CGSize) -> CGAffineTransform {
        let w = size.width
        let h = size.height
        let s = CGFloat(key.scale)
        var t = preferred
        t = t.concatenating(CGAffineTransform(translationX: -w / 2, y: -h / 2))
        t = t.concatenating(CGAffineTransform(scaleX: s, y: s))
        t = t.concatenating(CGAffineTransform(translationX: w / 2 + CGFloat(key.dx) * w,
                                              y: h / 2 + CGFloat(key.dy) * h))
        return t
    }

    // MARK: Export

    /// Exporte le montage dans un fichier .mp4 temporaire, avec le MÊME pipeline que l'aperçu.
    static func export(url: URL,
                       plan: RenderPlan,
                       progress: @escaping (Double) -> Void) async throws -> URL {
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
