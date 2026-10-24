//
//  StabilizationAnalyzer.swift
//  Analyse du mouvement de caméra (Vision) puis calcul d'une correction lissée.
//  On ne supprime que les tremblements : les mouvements lents voulus sont conservés.
//

import Foundation
import AVFoundation
import Vision
import CoreGraphics

enum StabilizationAnalyzer {
    static let fps = 30.0
    /// Rayon de lissage en images : au-delà, le mouvement est considéré comme voulu.
    static let smoothingRadius = 15
    static let maxCorrection = 0.06

    static func analyze(url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> StabilizationData {
        let asset = AVURLAsset(url: url)
        let seconds = try await asset.load(.duration).seconds
        guard seconds.isFinite, seconds > 0 else { throw PipelineError.invalidDuration }

        let count = max(2, Int(seconds * fps))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        let tolerance = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let times = (0..<count).map { CMTime(seconds: Double($0) / fps, preferredTimescale: 600) }

        var previous: CGImage?
        var previousGray: GrayImage?
        var previousIndex = -1

        // Mouvement mesuré entre l'image i-1 et l'image i, en fraction de la taille.
        var motionX = [Double](repeating: 0, count: count)
        var motionY = [Double](repeating: 0, count: count)
        var signVote = 0.0
        var votes = 0

        for try await result in generator.images(for: times) {
            try Task.checkCancellation()
            let image = try result.image
            let index = min(max(Int((result.requestedTime.seconds * fps).rounded()), 0), count - 1)
            let gray = GrayImage(image)

            if let previous, let previousGray, index == previousIndex + 1,
               let t = translation(from: previous, to: image) {
                motionX[index] = Double(t.dx) / Double(image.width)
                motionY[index] = Double(t.dy) / Double(image.height)

                // Calibrage du signe : on garde le sens qui rapproche réellement les deux images.
                if votes < 60, abs(t.dx) >= 1 || abs(t.dy) >= 1 {
                    let positive = previousGray.error(against: gray, tx: Int(t.dx.rounded()), ty: Int(t.dy.rounded()))
                    let negative = previousGray.error(against: gray, tx: -Int(t.dx.rounded()), ty: -Int(t.dy.rounded()))
                    signVote += negative - positive
                    votes += 1
                }
            }

            previous = image
            previousGray = gray
            previousIndex = index
            progress(Double(index + 1) / Double(count))
        }

        let sign = signVote >= 0 ? 1.0 : -1.0

        // Trajectoire cumulée de la caméra.
        var pathX = [Double](repeating: 0, count: count)
        var pathY = [Double](repeating: 0, count: count)
        for i in 1..<count {
            pathX[i] = pathX[i - 1] + sign * motionX[i]
            pathY[i] = pathY[i - 1] + sign * motionY[i]
        }

        // Correction = trajectoire - trajectoire lissée (on retire uniquement les tremblements).
        let smoothX = movingAverage(pathX, radius: smoothingRadius)
        let smoothY = movingAverage(pathY, radius: smoothingRadius)
        var dx = [Double](repeating: 0, count: count)
        var dy = [Double](repeating: 0, count: count)
        for i in 0..<count {
            dx[i] = min(max(pathX[i] - smoothX[i], -maxCorrection), maxCorrection)
            dy[i] = min(max(pathY[i] - smoothY[i], -maxCorrection), maxCorrection)
        }

        return StabilizationData(fps: fps, dx: dx, dy: dy)
    }

    // MARK: Vision

    /// Translation (en pixels) à appliquer à `floating` pour l'aligner sur `reference`.
    private static func translation(from reference: CGImage, to floating: CGImage) -> CGVector? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: floating, options: [:])
        let handler = VNImageRequestHandler(cgImage: reference, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else {
            return nil
        }
        let t = observation.alignmentTransform
        return CGVector(dx: t.tx, dy: t.ty)
    }

    private static func movingAverage(_ values: [Double], radius: Int) -> [Double] {
        let n = values.count
        var result = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - radius)
            let hi = min(n - 1, i + radius)
            var sum = 0.0
            for j in lo...hi { sum += values[j] }
            result[i] = sum / Double(hi - lo + 1)
        }
        return result
    }
}

// MARK: - Image en niveaux de gris (sert à vérifier le sens de la translation)

private struct GrayImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var data = [UInt8](repeating: 0, count: image.width * image.height)
        data.withUnsafeMutableBytes { buffer in
            if let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) {
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
        }
        pixels = data
    }

    /// Erreur moyenne entre cette image (référence) et `other` translatée de (tx, ty)
    /// en coordonnées Vision (axe Y vers le haut). Les lignes du tableau vont de haut en bas.
    func error(against other: GrayImage, tx: Int, ty: Int) -> Double {
        guard other.width == width, other.height == height else { return 0 }
        var total = 0
        var count = 0
        for row in stride(from: 0, to: height, by: 2) {
            let srcRow = row + ty
            if srcRow < 0 || srcRow >= height { continue }
            for col in stride(from: 0, to: width, by: 2) {
                let srcCol = col - tx
                if srcCol < 0 || srcCol >= width { continue }
                total += abs(Int(pixels[row * width + col]) - Int(other.pixels[srcRow * width + srcCol]))
                count += 1
            }
        }
        return count > 0 ? Double(total) / Double(count) : 0
    }
}
