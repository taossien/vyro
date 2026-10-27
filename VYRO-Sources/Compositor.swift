//
//  Compositor.swift
//  Moteur de rendu image par image (Core Image, GPU) : cadrage, flou de mouvement,
//  séparation des couleurs, flash. Utilisé par l'aperçu ET l'export.
//  Chaque image est une fonction pure du temps : même instant, même image.
//

import Foundation
import AVFoundation
import CoreImage
import CoreVideo

// MARK: - Instruction : tout ce qu'il faut pour dessiner n'importe quelle image du montage

final class VYROInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let trackID: CMPersistentTrackID
    let orientation: CGImagePropertyOrientation
    /// Taille du clip une fois orienté, taille du montage, taille de sortie.
    let sourceSize: CGSize
    let canvasSize: CGSize
    let finalSize: CGSize
    /// Début du clip dans le montage (secondes) : les effets sont globaux, la stabilisation est locale.
    let clipOffset: Double
    let effects: [EffectModel]
    let stabilization: StabilizationData?
    let timeMap: TimeMap
    /// 0 = pas de flou de mouvement, 1 = obturateur 180° (rendu cinéma), 2 = très marqué.
    let motionBlur: Double
    let grade: ColorGrade?

    init(timeRange: CMTimeRange,
         trackID: CMPersistentTrackID,
         orientation: CGImagePropertyOrientation,
         sourceSize: CGSize,
         canvasSize: CGSize,
         finalSize: CGSize,
         clipOffset: Double,
         effects: [EffectModel],
         stabilization: StabilizationData?,
         timeMap: TimeMap,
         motionBlur: Double,
         grade: ColorGrade? = nil) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.requiredSourceTrackIDs = [NSNumber(value: trackID)]
        self.orientation = orientation
        self.sourceSize = sourceSize
        self.canvasSize = canvasSize
        self.finalSize = finalSize
        self.clipOffset = clipOffset
        self.effects = effects
        self.stabilization = stabilization
        self.timeMap = timeMap
        self.motionBlur = motionBlur
        self.grade = grade
        super.init()
    }
}

// MARK: - Compositeur AVFoundation

final class VYROCompositor: NSObject, AVVideoCompositing {
    private static let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]
    var sourcePixelBufferAttributes: [String: Any]? { Self.attributes }
    var requiredPixelBufferAttributesForRenderContext: [String: Any] { Self.attributes }

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "vyro.compositor", qos: .userInitiated)
    private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            autoreleasepool {
                guard let instruction = request.videoCompositionInstruction as? VYROInstruction,
                      let source = request.sourceFrame(byTrackID: instruction.trackID),
                      let output = request.renderContext.newPixelBuffer() else {
                    request.finish(with: NSError(domain: "VYRO", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "image source indisponible"
                    ]))
                    return
                }
                let image = FrameRenderer.render(
                    source: CIImage(cvPixelBuffer: source),
                    time: request.compositionTime.seconds,
                    instruction: instruction
                )
                context.render(image, to: output,
                               bounds: CGRect(origin: .zero, size: instruction.finalSize),
                               colorSpace: colorSpace)
                request.finish(withComposedVideoFrame: output)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}

// MARK: - Rendu d'une image

enum FrameRenderer {
    /// État d'une image : cadrage (repère "calque", y vers le bas), séparation des couleurs, flash.
    struct State {
        var scale: Double
        var dx: Double
        var dy: Double
        var rgbSplit: Double
        var flash: Double
        var glow: Double
    }

    static func orientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (t.a, t.b, t.c, t.d) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        default: return .up
        }
    }

    static func state(at time: Double, instruction: VYROInstruction) -> State {
        let fx = EffectEngine.transform(at: time, effects: instruction.effects)
        var scale = fx.scale * (1 + fx.margin)
        var dx = fx.dx
        var dy = fx.dy
        if let stabilization = instruction.stabilization {
            let c = stabilization.correction(atSourceTime: instruction.timeMap.sourceTime(atOutput: max(time - instruction.clipOffset, 0)))
            scale *= stabilization.cropScale
            dx += c.dx
            dy -= c.dy      // Vision : axe Y vers le haut ; calque : vers le bas
        }
        return State(scale: scale, dx: dx, dy: dy, rgbSplit: fx.rgbSplit, flash: fx.flash, glow: fx.glow)
    }

    static func render(source: CIImage, time: Double, instruction: VYROInstruction) -> CIImage {
        let size = instruction.canvasSize
        let w = size.width, h = size.height
        let rect = CGRect(origin: .zero, size: size)

        var base = source.oriented(instruction.orientation)
        base = base.transformed(by: CGAffineTransform(translationX: -base.extent.minX, y: -base.extent.minY))
        // Clip de format différent : il remplit le montage (cadrage centré).
        let sw = max(base.extent.width, 1), sh = max(base.extent.height, 1)
        if abs(sw - w) > 0.5 || abs(sh - h) > 0.5 {
            let fill = max(w / sw, h / sh)
            base = base.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
            base = base.transformed(by: CGAffineTransform(translationX: (w - sw * fill) / 2, y: (h - sh * fill) / 2))
        }

        let now = state(at: time, instruction: instruction)
        var image = place(base, now, size: size).clampedToExtent().cropped(to: rect)

        // Flou de mouvement : l'obturateur reste ouvert 1/60 s (x force), on mesure le déplacement.
        if instruction.motionBlur > 0.01 {
            let half = (1.0 / 120.0) * instruction.motionBlur
            let a = state(at: time - half, instruction: instruction)
            let b = state(at: time + half, instruction: instruction)
            let vx = (b.dx - a.dx) * Double(w)
            let vy = -(b.dy - a.dy) * Double(h)           // repère Core Image : y vers le haut
            let length = (vx * vx + vy * vy).squareRoot()
            if length > 1.0 {
                image = image.clampedToExtent()
                    .applyingFilter("CIMotionBlur", parameters: [
                        kCIInputRadiusKey: min(length / 2, 80),
                        kCIInputAngleKey: atan2(vy, vx)
                    ])
                    .cropped(to: rect)
            }
            let ds = abs(b.scale - a.scale)
            let amount = ds * Double(min(w, h)) * 0.2
            if amount > 0.5 {
                image = image.clampedToExtent()
                    .applyingFilter("CIZoomBlur", parameters: [
                        kCIInputCenterKey: CIVector(x: w / 2, y: h / 2),
                        kCIInputAmountKey: min(amount, 14)
                    ])
                    .cropped(to: rect)
            }
        }

        if now.rgbSplit > 0.0005 {
            image = rgbSplit(image, offset: CGFloat(now.rgbSplit) * w, rect: rect)
        }

        if let grade = instruction.grade, !grade.isNeutral {
            image = applyGrade(image, grade, rect: rect)
        }

        if now.glow > 0.02 {
            image = image.clampedToExtent()
                .applyingFilter("CIBloom", parameters: [
                    kCIInputRadiusKey: 18 * w / 1080 * max(now.glow, 0.5),
                    kCIInputIntensityKey: min(now.glow, 2) * 0.5
                ])
                .cropped(to: rect)
        }

        if now.flash > 0.002 {
            let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(min(now.flash, 1))))
                .cropped(to: rect)
            image = white.composited(over: image)
        }

        let finalSize = instruction.finalSize
        if abs(finalSize.width - w) > 0.5 || abs(finalSize.height - h) > 0.5 {
            image = image.transformed(by: CGAffineTransform(scaleX: finalSize.width / w, y: finalSize.height / h))
        }
        return image
    }

    /// Exposition, contraste, saturation, chaleur (gains rouge/bleu), vignette.
    private static func applyGrade(_ input: CIImage, _ g: ColorGrade, rect: CGRect) -> CIImage {
        var image = input
        if abs(g.exposure) > 0.001 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: g.exposure])
        }
        image = image.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: g.contrast,
            kCIInputSaturationKey: g.saturation
        ])
        if abs(g.warmth) > 0.001 {
            let w = CGFloat(g.warmth) * 0.15
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 + w, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - w, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
        }
        if g.vignette > 0.01 {
            image = image.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: g.vignette * 1.5,
                kCIInputRadiusKey: 1.5
            ])
        }
        return image.cropped(to: rect)
    }

    /// Zoom autour du centre puis décalage (fractions de l'image, dy vers le bas).
    private static func place(_ image: CIImage, _ s: State, size: CGSize) -> CIImage {
        let w = size.width, h = size.height
        var t = CGAffineTransform(translationX: -w / 2, y: -h / 2)
        t = t.concatenating(CGAffineTransform(scaleX: CGFloat(s.scale), y: CGFloat(s.scale)))
        t = t.concatenating(CGAffineTransform(translationX: w / 2 + CGFloat(s.dx) * w,
                                              y: h / 2 - CGFloat(s.dy) * h))
        return image.transformed(by: t)
    }

    /// Aberration chromatique : le rouge part d'un côté, le bleu de l'autre.
    private static func rgbSplit(_ image: CIImage, offset: CGFloat, rect: CGRect) -> CIImage {
        func channel(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
            image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
        }
        let red = channel(1, 0, 0).transformed(by: CGAffineTransform(translationX: offset, y: 0)).clampedToExtent()
        let green = channel(0, 1, 0)
        let blue = channel(0, 0, 1).transformed(by: CGAffineTransform(translationX: -offset, y: 0)).clampedToExtent()
        let rg = red.cropped(to: rect).applyingFilter("CILightenBlendMode", parameters: [
            kCIInputBackgroundImageKey: green
        ])
        return blue.cropped(to: rect).applyingFilter("CILightenBlendMode", parameters: [
            kCIInputBackgroundImageKey: rg
        ]).cropped(to: rect)
    }
}
