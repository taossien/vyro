//
//  DemoClip.swift
//  Clip de test synthétique (build Debug uniquement) : décor fixe, objet qui avance,
//  et un tremblement de caméra connu pour vérifier la stabilisation.
//

#if DEBUG
import AVFoundation
import UIKit

enum DemoClip {
    static func generate() async throws -> URL {
        let width = 540
        let height = 960
        let fps = 30
        let seconds = 6
        let url = ProjectStore.mediaDirectory.appendingPathComponent(UUID().uuidString + ".mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<(fps * seconds) {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let pixelBuffer = buffer else { break }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                draw(frame: frame, fps: fps, width: width, height: height, in: context)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? PipelineError.exportFailed("clip de test")
        }
        return url
    }

    /// Compare la correction calculée au tremblement connu du clip de test.
    /// Attendu : corrélation dx ≈ -1 et dy ≈ +1 (si le sens est correct).
    static func report(for data: StabilizationData) -> String {
        let n = data.dx.count
        guard n > 40 else { return "Stabilisation : trop peu d'images (" + String(n) + ")" }
        func jitterX(_ t: Double) -> Double { 9 * sin(t * 23) + 5 * sin(t * 41 + 1) }
        func jitterY(_ t: Double) -> Double { 8 * sin(t * 29 + 2) + 4 * sin(t * 47) }
        func highPass(_ v: [Double]) -> [Double] {
            (0..<v.count).map { i in
                let lo = max(0, i - 15), hi = min(v.count - 1, i + 15)
                let mean = v[lo...hi].reduce(0, +) / Double(hi - lo + 1)
                return v[i] - mean
            }
        }
        func corr(_ a: [Double], _ b: [Double]) -> Double {
            let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
            var sab = 0.0, saa = 0.0, sbb = 0.0
            for i in 0..<a.count {
                sab += (a[i] - ma) * (b[i] - mb); saa += (a[i] - ma) * (a[i] - ma); sbb += (b[i] - mb) * (b[i] - mb)
            }
            return sab / max(sqrt(saa * sbb), 1e-9)
        }
        let jx = highPass((0..<n).map { jitterX(Double($0) / 30) })
        let jy = highPass((0..<n).map { jitterY(Double($0) / 30) })
        let maxX = data.dx.map { abs($0) }.max() ?? 0
        let maxY = data.dy.map { abs($0) }.max() ?? 0
        return String(format: "Stab n=%d max=%.3f/%.3f corrX=%.2f corrY=%.2f", n, maxX, maxY,
                      corr(data.dx, jx), corr(data.dy, jy))
    }

    private static func draw(frame: Int, fps: Int, width: Int, height: Int, in ctx: CGContext) {
        let t = Double(frame) / Double(fps)
        // Origine en haut à gauche.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.09, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Tremblement de caméra : toute la scène bouge de quelques pixels.
        let jitterX = 9 * sin(t * 23) + 5 * sin(t * 41 + 1)
        let jitterY = 8 * sin(t * 29 + 2) + 4 * sin(t * 47)
        ctx.translateBy(x: CGFloat(jitterX), y: CGFloat(jitterY))

        // Décor fixe : grille + repères colorés.
        ctx.setStrokeColor(CGColor(red: 0.3, green: 0.3, blue: 0.5, alpha: 1))
        ctx.setLineWidth(2)
        for x in stride(from: -60, through: width + 60, by: 60) {
            ctx.move(to: CGPoint(x: x, y: -60)); ctx.addLine(to: CGPoint(x: x, y: height + 60))
        }
        for y in stride(from: -60, through: height + 60, by: 60) {
            ctx.move(to: CGPoint(x: -60, y: y)); ctx.addLine(to: CGPoint(x: width + 60, y: y))
        }
        ctx.strokePath()

        let markers: [(CGRect, CGColor)] = [
            (CGRect(x: 60, y: 120, width: 90, height: 90), CGColor(red: 0.58, green: 0.34, blue: 0.98, alpha: 1)),
            (CGRect(x: 380, y: 300, width: 100, height: 60), CGColor(red: 0.25, green: 0.55, blue: 1, alpha: 1)),
            (CGRect(x: 120, y: 700, width: 120, height: 120), CGColor(red: 1, green: 0.4, blue: 0.4, alpha: 1))
        ]
        for (rect, color) in markers {
            ctx.setFillColor(color)
            ctx.fill(rect)
        }

        // Objet en mouvement voulu (ne doit PAS être "corrigé" par la stabilisation).
        let progress = CGFloat(t / 6)
        ctx.setFillColor(CGColor(red: 1, green: 0.9, blue: 0.2, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 40 + progress * 380, y: 480, width: 70, height: 70))
    }
}
#endif
