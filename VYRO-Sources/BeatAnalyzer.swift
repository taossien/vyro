//
//  BeatAnalyzer.swift
//  Détection des temps forts d'un morceau : énergie par tranche de 20 ms, flux positif,
//  seuil adaptatif local, espacement minimal. Hors ligne, sur l'appareil.
//

import Foundation
import AVFoundation

enum BeatAnalyzer {
    static let hopSeconds = 0.02
    private static let sampleRate = 22050.0
    private static let hop = 441

    /// Renvoie les instants (secondes du morceau) des temps forts détectés.
    static func analyze(url: URL) async throws -> [Double] {
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
            let energies = try readEnergies(asset: asset, track: track)
            return pickBeats(energies)
        }.value
    }

    private static func readEnergies(asset: AVAsset, track: AVAssetTrack) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else {
            throw PipelineError.exportFailed(reader.error?.localizedDescription ?? "lecture audio impossible")
        }

        var energies: [Float] = []
        var sum: Float = 0
        var count = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var samples = [Int16](repeating: 0, count: length / 2)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &samples)
            for sample in samples {
                let value = Float(sample) / 32768
                sum += value * value
                count += 1
                if count == hop {
                    energies.append((sum / Float(hop)).squareRoot())
                    sum = 0
                    count = 0
                }
            }
            CMSampleBufferInvalidate(buffer)
        }
        return energies
    }

    static func pickBeats(_ energies: [Float]) -> [Double] {
        guard energies.count > 10 else { return [] }
        let compressed = energies.map { log(1 + 30 * $0) }
        var flux = [Float](repeating: 0, count: compressed.count)
        for i in 1..<compressed.count { flux[i] = max(0, compressed[i] - compressed[i - 1]) }

        let radius = 25                       // 0,5 s de chaque côté
        let minGap = Int(0.25 / hopSeconds)   // jamais plus de 4 temps par seconde
        var beats: [Double] = []
        var lastIndex = -minGap
        for i in 2..<(flux.count - 2) {
            let lo = max(0, i - radius), hi = min(flux.count - 1, i + radius)
            var mean: Float = 0
            for j in lo...hi { mean += flux[j] }
            mean /= Float(hi - lo + 1)
            let threshold = mean * 1.6 + 0.01
            let isPeak = flux[i] > threshold
                && flux[i] >= flux[i - 1] && flux[i] >= flux[i + 1]
                && flux[i] >= flux[i - 2] && flux[i] >= flux[i + 2]
            if isPeak, i - lastIndex >= minGap {
                beats.append(Double(i) * hopSeconds)
                lastIndex = i
            }
        }
        return beats
    }
}
