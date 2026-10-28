//
//  VideoPipeline.swift
//  Pipeline UNIQUE utilisé par l'aperçu et l'export : ce qu'on voit est ce qu'on exporte.
//  Composition multi-clips (découpe, vitesse) + AVVideoComposition CoreImage (zoom, shake, stabilisation).
//

import Foundation
import AVFoundation

/// Un clip du montage : un fichier, sa découpe, sa vitesse, sa stabilisation.
struct ClipPlan {
    var url: URL
    var speed: Double = 1
    var speedPoints: [SpeedPointModel] = []
    var stabilization: StabilizationData?
    var trimIn: Double = 0
    var trimOut: Double?
    /// Transition à l'entrée de ce clip.
    var transition: CutTransition?
    /// Image figée : durée tenue (s). Remplace vitesse et découpe.
    var hold: Double?
}

/// Coupure à décorer d'une transition (temps du montage).
struct CutMark {
    let time: Double
    let type: Int
    let duration: Double
}

/// Un son à insérer : fichier, instant de départ dans le montage, volume.
struct SoundPlan {
    let url: URL
    let start: Double
    let volume: Double
}

struct RenderPlan {
    var clips: [ClipPlan]
    /// Effets globaux, positionnés sur la durée totale du montage.
    var effects: [EffectModel]
    /// Réduction de la taille de sortie (1 = taille d'origine). Utilisé par les presets d'export.
    var outputScale: Double = 1
    /// Cadence forcée (nil = celle des clips). 60 rend zooms et secousses bien plus fluides.
    var fps: Int?
    /// Aperçu : taille maximale du grand côté (nil = pas de limite). Calculer à 1280 px suffit sur un écran de téléphone.
    var maxSide: Double?
    /// Musique de fond (nil = aucune), volumes 0...1, décalage de départ dans le morceau.
    var musicURL: URL?
    var musicVolume: Double = 0.8
    var musicOffset: Double = 0
    var originalVolume: Double = 1
    /// Force du flou de mouvement (0 = aucun, 1 = rendu cinéma).
    var motionBlur: Double = 1
    var grade: ColorGrade?
    var texts: [TextOverlay] = []
    var stickers: [StickerOverlay] = []
    var keyframes: [Keyframe] = []
    var sounds: [SoundPlan] = []
    /// La musique baisse quand des sous-titres (donc une voix) sont affichés.
    var duckMusic = true
    /// Égalise le volume du son d'origine entre les clips (un clip trop faible ou trop fort).
    var normalizeAudio = true

    /// Faux si le plan ne modifie pas les images (aucun effet actif, pas de stabilisation, un seul clip).
    var needsRendering: Bool {
        clips.count > 1
            || clips.contains { $0.stabilization != nil }
            || abs(outputScale - 1) > 0.001
            || !(grade?.isNeutral ?? true)
            || !stickers.isEmpty
            || texts.contains { !$0.text.isEmpty }
            || !keyframes.isEmpty
            || effects.contains { $0.enabled }
    }
}

/// Position d'un clip dans le montage final.
struct ClipSpan {
    let start: Double
    let end: Double
    let timeMap: TimeMap
    var duration: Double { end - start }
}

struct BuiltPipeline {
    let composition: AVAsset
    /// nil quand aucun effet n'est actif : la lecture est alors directe.
    let videoComposition: AVVideoComposition?
    let duration: Double
    let renderSize: CGSize
    let spans: [ClipSpan]
    let audioMix: AVAudioMix?
}

/// Presets d'export : la taille maximale du grand côté, jamais d'agrandissement.
enum ExportPreset: String, CaseIterable, Identifiable {
    case original, uhd4k, hd1080, smooth60, hd720
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return "Original"
        case .uhd4k: return "4K 60 i/s"
        case .hd1080: return "1080p"
        case .smooth60: return "1080p 60 i/s"
        case .hd720: return "720p"
        }
    }
    var detail: String {
        switch self {
        case .original: return "Qualité maximale, taille d'origine"
        case .uhd4k: return "Ultra HD (HEVC), fichier très lourd"
        case .hd1080: return "TikTok, Reels, Shorts"
        case .smooth60: return "Effets ultra fluides, fichier plus lourd"
        case .hd720: return "Envoi rapide, fichier léger"
        }
    }
    var fps: Int? { (self == .smooth60 || self == .uhd4k) ? 60 : nil }
    var longSide: Double? {
        switch self {
        case .original: return nil
        case .uhd4k: return 3840
        case .hd1080, .smooth60: return 1920
        case .hd720: return 1280
        }
    }
}

enum PipelineError: LocalizedError {
    case noVideoTrack
    case invalidDuration
    case noClip
    case exportFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "Ce fichier ne contient pas de piste vidéo."
        case .invalidDuration: return "La durée de ce clip est invalide."
        case .noClip: return "Le montage ne contient aucun clip."
        case .exportFailed(let detail): return "L'export a échoué : " + detail
        case .cancelled: return "Export annulé."
        }
    }
}

enum VideoPipeline {
    static let minSpeed = 0.25
    static let maxSpeed = 4.0
    /// Cadence de mise à jour des effets (identique à l'analyse de stabilisation).
    static let effectFPS = 30

    /// Un clip chargé : piste, orientation, taille orientée.
    private struct Loaded {
        let plan: ClipPlan
        let asset: AVURLAsset
        let duration: CMTime
        let video: AVAssetTrack
        let audio: AVAssetTrack?
        let preferred: CGAffineTransform
        let orientedSize: CGSize
        let frameRate: Float
    }

    private static func load(_ clip: ClipPlan) async throws -> Loaded {
        let asset = AVURLAsset(url: clip.url)
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0 else { throw PipelineError.invalidDuration }
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw PipelineError.noVideoTrack
        }
        let preferred = try await video.load(.preferredTransform)
        let natural = try await video.load(.naturalSize)
        let rate = try await video.load(.nominalFrameRate)
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let oriented = natural.applying(preferred)
        let size = CGSize(width: abs(oriented.width).rounded(), height: abs(oriented.height).rounded())
        return Loaded(plan: clip, asset: asset, duration: duration, video: video, audio: audio,
                      preferred: preferred, orientedSize: size, frameRate: rate)
    }

    // MARK: Construction

    static func build(plan: RenderPlan) async throws -> BuiltPipeline {
        guard !plan.clips.isEmpty else { throw PipelineError.noClip }
        var loaded: [Loaded] = []
        for clip in plan.clips { loaded.append(try await load(clip)) }

        // Le format du montage est celui du premier clip.
        let canvas = loaded[0].orientedSize
        var finalSize = canvas
        var sizeScale = plan.outputScale
        let longSide = max(canvas.width, canvas.height)
        if let limit = plan.maxSide, longSide * sizeScale > limit { sizeScale = limit / longSide }
        if abs(sizeScale - 1) > 0.001 {
            finalSize = CGSize(
                width: (canvas.width * sizeScale / 2).rounded() * 2,
                height: (canvas.height * sizeScale / 2).rounded() * 2
            )
        }
        let frameRate = plan.fps.map { Float($0) } ?? (loaded.map(\.frameRate).max() ?? 30)

        func timeMap(for item: Loaded) -> TimeMap {
            if let hold = item.plan.hold {
                let start = min(max(item.plan.trimIn, 0), max(item.duration.seconds - 0.1, 0))
                // Au moins une image (1/30 s) : un morceau plus court qu'une image pouvait manquer à l'export.
                let length = min(1.0 / 30, max(item.duration.seconds - start, 0.005))
                let seconds = max(hold, 0.1)
                return TimeMap(slices: [TimeMap.Slice(sourceStart: start, sourceEnd: start + length,
                                                      outputStart: 0, outputEnd: seconds, speed: length / seconds)])
            }
            return TimeMap.make(
                sourceDuration: item.duration.seconds,
                base: item.plan.speed,
                points: item.plan.speedPoints,
                trimIn: item.plan.trimIn,
                trimOut: item.plan.trimOut
            )
        }
        func isTrimmed(_ item: Loaded) -> Bool {
            item.plan.trimIn > 0.001 || (item.plan.trimOut.map { $0 < item.duration.seconds - 0.001 } ?? false)
        }

        // Un seul clip sans aucune modification : on lit le fichier tel quel.
        if loaded.count == 1 {
            let item = loaded[0]
            let map = timeMap(for: item)
            let isPlain = item.plan.hold == nil && item.plan.speedPoints.isEmpty && abs(item.plan.speed - 1) < 0.001 && !isTrimmed(item)
                && plan.musicURL == nil && plan.sounds.isEmpty && abs(plan.originalVolume - 1) < 0.01
            if isPlain {
                var videoComposition: AVMutableVideoComposition?
                if plan.needsRendering {
                    videoComposition = makeVideoComposition(
                        instructions: [VYROInstruction(
                            timeRange: CMTimeRange(start: .zero, duration: item.duration),
                            trackID: item.video.trackID,
                            orientation: FrameRenderer.orientation(for: item.preferred),
                            sourceSize: item.orientedSize,
                            canvasSize: finalSize,
                            finalSize: finalSize,
                            clipOffset: 0,
                            effects: plan.effects,
                            stabilization: item.plan.stabilization,
                            timeMap: map,
                            motionBlur: plan.motionBlur,
                            grade: plan.grade,
                            texts: plan.texts,
                            keyframes: plan.keyframes,
                            stickers: plan.stickers
                        )],
                        finalSize: finalSize, frameRate: frameRate)
                }
                return BuiltPipeline(
                    composition: item.asset,
                    videoComposition: videoComposition,
                    duration: item.duration.seconds,
                    renderSize: finalSize,
                    spans: [ClipSpan(start: 0, end: item.duration.seconds, timeMap: map)],
                    audioMix: nil
                )
            }
        }

        // Montage : chaque tronçon de chaque clip est inséré à la suite puis étiré à sa durée de sortie.
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw PipelineError.noVideoTrack }
        composition.naturalSize = canvas
        let audio = loaded.contains { $0.audio != nil } ? composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) : nil

        let scale: CMTimeScale = 6000
        var cursor = CMTime.zero
        var spans: [ClipSpan] = []
        var bounds: [(start: CMTime, item: Loaded)] = []
        for item in loaded {
            let map = timeMap(for: item)
            let clipStart = cursor
            for slice in map.slices {
                let start = CMTime(seconds: slice.sourceStart, preferredTimescale: scale)
                var end = CMTime(seconds: slice.sourceEnd, preferredTimescale: scale)
                if end > item.duration { end = item.duration }
                let range = CMTimeRange(start: start, end: end)
                guard range.duration > .zero else { continue }

                try track.insertTimeRange(range, of: item.video, at: cursor)
                if item.plan.hold == nil, let source = item.audio, let audio {
                    try? audio.insertTimeRange(range, of: source, at: cursor)
                }
                let target = CMTimeMultiplyByFloat64(range.duration, multiplier: 1.0 / slice.speed)
                composition.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: target)
                cursor = cursor + target
            }
            spans.append(ClipSpan(start: clipStart.seconds, end: cursor.seconds, timeMap: map))
            bounds.append((clipStart, item))
        }
        let outputDuration = CMTimeMaximum(composition.duration, cursor)

        // Volumes : son d'origine, puis musique (fondu de 0,5 s à la fin).
        var audioMix: AVMutableAudioMix?
        var mixParameters: [AVMutableAudioMixInputParameters] = []
        if let audio {
            let parameters = AVMutableAudioMixInputParameters(track: audio)
            parameters.setVolume(Float(plan.originalVolume), at: .zero)
            if plan.normalizeAudio, bounds.count > 1 {
                var levels: [Double?] = []
                for entry in bounds { levels.append(await loudness(of: entry.item.plan.url)) }
                let known = levels.compactMap { $0 }.sorted()
                if known.count > 1 {
                    let target = known[known.count / 2]
                    for (index, entry) in bounds.enumerated() {
                        let gain = levels[index].map { min(max(target / max($0, 0.0005), 0.6), 1.6) } ?? 1
                        parameters.setVolume(Float(plan.originalVolume * gain), at: entry.start)
                    }
                }
            }
            mixParameters.append(parameters)
        }
        if let musicURL = plan.musicURL {
            let musicAsset = AVURLAsset(url: musicURL)
            if let musicTrack = try? await musicAsset.loadTracks(withMediaType: .audio).first,
               let musicDuration = try? await musicAsset.load(.duration),
               musicDuration.seconds.isFinite,
               let musicCompositionTrack = composition.addMutableTrack(
                   withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
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
                    if plan.duckMusic {
                        let duck = volume * 0.45
                        let limit = max(length.seconds - 0.5, 0)
                        var merged: [(start: Double, end: Double)] = []
                        for item in plan.texts.filter({ $0.subtitle == true }).sorted(by: { $0.start < $1.start }) {
                            if let last = merged.last, item.start - last.end < 0.6 {
                                merged[merged.count - 1].end = max(last.end, item.end)
                            } else {
                                merged.append((item.start, item.end))
                            }
                        }
                        var cursor = 0.0
                        for item in merged {
                            let a = max(item.start - 0.15, cursor)
                            let b = min(item.end, limit - 0.3)
                            guard b - a > 0.4 else { continue }
                            parameters.setVolumeRamp(
                                fromStartVolume: volume, toEndVolume: duck,
                                timeRange: CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 600),
                                                       duration: CMTime(seconds: 0.15, preferredTimescale: 600)))
                            parameters.setVolumeRamp(
                                fromStartVolume: duck, toEndVolume: volume,
                                timeRange: CMTimeRange(start: CMTime(seconds: b, preferredTimescale: 600),
                                                       duration: CMTime(seconds: 0.3, preferredTimescale: 600)))
                            cursor = b + 0.3
                        }
                    }
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
        // Effets sonores : les sons qui ne se chevauchent pas partagent une piste (4 pistes suffisent en général).
        var lanes: [(track: AVMutableCompositionTrack, parameters: AVMutableAudioMixInputParameters, end: CMTime)] = []
        for sound in plan.sounds.sorted(by: { $0.start < $1.start }).prefix(60) {
            let asset = AVURLAsset(url: sound.url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let length = try? await asset.load(.duration), length.seconds.isFinite,
                  sound.start < outputDuration.seconds
            else { continue }
            // Un son qui commencerait avant 0 est tronqué à son début.
            let skip = max(-sound.start, 0)
            let at = CMTime(seconds: max(sound.start, 0), preferredTimescale: 600)
            let usable = CMTimeMinimum(length - CMTime(seconds: skip, preferredTimescale: 600), outputDuration - at)
            guard usable > .zero else { continue }
            var index = lanes.firstIndex { $0.end <= at }
            if index == nil {
                guard let created = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { continue }
                lanes.append((created, AVMutableAudioMixInputParameters(track: created), .zero))
                index = lanes.count - 1
            }
            guard let lane = index else { continue }
            try? lanes[lane].track.insertTimeRange(
                CMTimeRange(start: CMTime(seconds: skip, preferredTimescale: 600), duration: usable), of: source, at: at
            )
            lanes[lane].parameters.setVolume(Float(sound.volume), at: at)
            lanes[lane].end = at + usable
        }
        for lane in lanes { mixParameters.append(lane.parameters) }
        if !mixParameters.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = mixParameters
            audioMix = mix
        }

        var cuts: [CutMark] = []
        for index in 1..<max(loaded.count, 1) where index < spans.count {
            if let transition = loaded[index].plan.transition {
                cuts.append(CutMark(time: spans[index].start, type: transition.type, duration: transition.duration))
            }
        }

        // Une instruction par clip, collées bout à bout.
        var instructions: [VYROInstruction] = []
        for (index, entry) in bounds.enumerated() {
            let end = index + 1 < bounds.count ? bounds[index + 1].start : outputDuration
            guard end > entry.start else { continue }
            instructions.append(VYROInstruction(
                timeRange: CMTimeRange(start: entry.start, end: end),
                trackID: track.trackID,
                orientation: FrameRenderer.orientation(for: entry.item.preferred),
                sourceSize: entry.item.orientedSize,
                canvasSize: finalSize,
                finalSize: finalSize,
                clipOffset: entry.start.seconds,
                effects: plan.effects,
                stabilization: entry.item.plan.stabilization,
                timeMap: spans[index].timeMap,
                motionBlur: plan.motionBlur,
                grade: plan.grade,
                texts: plan.texts,
                keyframes: plan.keyframes,
                cuts: cuts,
                stickers: plan.stickers
            ))
        }

        var videoComposition: AVMutableVideoComposition?
        if plan.needsRendering {
            videoComposition = makeVideoComposition(instructions: instructions, finalSize: finalSize, frameRate: frameRate)
        }

        return BuiltPipeline(
            composition: composition,
            videoComposition: videoComposition,
            duration: outputDuration.seconds,
            renderSize: finalSize,
            spans: spans,
            audioMix: audioMix
        )
    }

    // MARK: Composition vidéo (rendu image par image par VYROCompositor)

    private static func makeVideoComposition(instructions: [VYROInstruction],
                                             finalSize: CGSize,
                                             frameRate: Float) -> AVMutableVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.renderSize = finalSize
        let fps = frameRate > 1 ? min(Int(frameRate.rounded()), 60) : 30
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        composition.instructions = instructions
        composition.customVideoCompositorClass = VYROCompositor.self
        return composition
    }

    // MARK: Export

    private static var loudnessCache: [URL: Double] = [:]
    private static let loudnessLock = NSLock()

    /// Niveau moyen (RMS) du son d'un fichier, mesuré sur ses 20 premières secondes. nil sans son.
    static func loudness(of url: URL) async -> Double? {
        if let hit = cachedLoudness(url) { return hit }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 20, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 1
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var sum = 0.0
        var count = 0.0
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var data = [Int16](repeating: 0, count: length / 2)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &data)
            for value in data {
                let v = Double(value) / 32768
                sum += v * v
            }
            count += Double(data.count)
        }
        guard count > 4800 else { return nil }
        let rms = (sum / count).squareRoot()
        guard rms > 0.0005 else { return nil }
        storeLoudness(rms, for: url)
        return rms
    }

    private static func cachedLoudness(_ url: URL) -> Double? {
        loudnessLock.lock()
        defer { loudnessLock.unlock() }
        return loudnessCache[url]
    }

    private static func storeLoudness(_ value: Double, for url: URL) {
        loudnessLock.lock()
        loudnessCache[url] = value
        loudnessLock.unlock()
    }

    private static func naturalLongSide(url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return 0 }
        let size = try await track.load(.naturalSize)
        return Double(max(size.width, size.height))
    }

    /// Supprime les exports précédents restés dans le dossier temporaire (un export 4K pèse des centaines de Mo).
    private static func removeOldExports() {
        let directory = FileManager.default.temporaryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("VYRO-") && file.pathExtension == "mp4" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Exporte le montage dans un fichier .mp4 temporaire, avec le MÊME pipeline que l'aperçu.
    static func export(plan: RenderPlan,
                       preset: ExportPreset = .original,
                       progress: @escaping (Double) -> Void) async throws -> URL {
        removeOldExports()
        var plan = plan
        plan.fps = preset.fps
        if let side = preset.longSide, let first = plan.clips.first,
           let size = try? await naturalLongSide(url: first.url), (size > side || preset == .uhd4k) {
            plan.outputScale = side / size
        }
        let built = try await build(plan: plan)

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("VYRO-" + UUID().uuidString + ".mp4")
        try? FileManager.default.removeItem(at: output)

        guard let session = AVAssetExportSession(
            asset: built.composition,
            presetName: preset == .uhd4k ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
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

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { continuation.resume() }
            }
        } onCancel: {
            session.cancelExport()
        }
        poller.cancel()

        if Task.isCancelled || session.status == .cancelled {
            try? FileManager.default.removeItem(at: output)
            throw PipelineError.cancelled
        }
        guard session.status == .completed else {
            throw PipelineError.exportFailed(session.error?.localizedDescription ?? "erreur inconnue")
        }
        progress(1)
        return output
    }
}
