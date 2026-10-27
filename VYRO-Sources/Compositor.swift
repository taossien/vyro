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
import UIKit

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
    let texts: [TextOverlay]
    let keyframes: [Keyframe]
    let cuts: [CutMark]

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
         grade: ColorGrade? = nil,
         texts: [TextOverlay] = [],
         keyframes: [Keyframe] = [],
         cuts: [CutMark] = []) {
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
        self.texts = texts
        self.keyframes = keyframes
        self.cuts = cuts
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
        var rotation: Double = 0
        var blur: Double = 0
        var dim: Double = 0
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
        var rotation = 0.0
        if let key = KeyframeEngine.value(at: time, instruction.keyframes) {
            scale *= key.scale
            dx += key.x
            dy += key.y
            rotation = key.rotation
        }
        var rgb = fx.rgbSplit
        var flash = fx.flash
        var blur = 0.0
        var dim = 0.0
        for cut in instruction.cuts {
            let half = max(cut.duration / 2, 0.02)
            let d = time - cut.time
            guard abs(d) < half else { continue }
            let w = 1 - abs(d) / half
            switch cut.type {
            case 0: flash = min(1, flash + pow(w, 1.5))
            case 1: scale *= 1 + 0.45 * w * w
            case 2:
                rgb += 0.025 * w
                let r = sin(floor(time * 20) * 12.9898) * 43758.5453
                dx += (r - floor(r) - 0.5) * 0.05 * w
            case 3: blur = max(blur, w)
            case 4: dim = max(dim, pow(w, 0.8))
            case 5: dx += (d < 0 ? -1.0 : 1.0) * 0.6 * w * w
            case 6:                                      // Spin : la caméra tourne et zoome
                rotation += (d < 0 ? -1.0 : 1.0) * 25 * w * w
                scale *= 1 + 0.5 * w
            case 7: dy += (d < 0 ? -1.0 : 1.0) * 0.6 * w * w
            case 8:                                      // Strobe : éclairs rapides
                if Int(floor(time * 30)) % 2 == 0 { flash = min(1, flash + w) }
            case 9:
                flash = min(1, flash + pow(w, 1.5))
                scale *= 1 + 0.3 * w * w
            case 10:                                     // Tremble
                let r1 = sin(floor(time * 30) * 12.9898) * 43758.5453
                let r2 = sin(floor(time * 30) * 78.233) * 12345.6789
                dx += (r1 - floor(r1) - 0.5) * 0.08 * w
                dy += (r2 - floor(r2) - 0.5) * 0.08 * w
                scale *= 1 + 0.12 * w
            case 11:                                     // Glitch+ : fort, décalé dans les deux axes
                rgb += 0.05 * w
                let r1 = sin(floor(time * 24) * 12.9898) * 43758.5453
                let r2 = sin(floor(time * 24) * 4.1414) * 9999.123
                dx += (r1 - floor(r1) - 0.5) * 0.1 * w
                dy += (r2 - floor(r2) - 0.5) * 0.04 * w
                scale *= 1.06
            case 12:
                dy += (d < 0 ? 1.0 : -1.0) * 0.6 * w * w
                blur = max(blur, 0.6 * w)
            case 13:                                     // Punch : gros zoom flou
                scale *= 1 + 0.7 * w * w
                blur = max(blur, 0.4 * w)
            default:                                     // Roulis
                rotation += (d < 0 ? 1.0 : -1.0) * 12 * w
                scale *= 1 + 0.25 * w
            }
        }
        return State(scale: scale, dx: dx, dy: dy, rgbSplit: rgb, flash: flash, glow: fx.glow,
                     rotation: rotation, blur: blur, dim: dim)
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

        if now.blur > 0.02 {
            image = image.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 28 * w / 1080 * now.blur])
                .cropped(to: rect)
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

        if now.dim > 0.002 {
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(min(now.dim, 1))))
                .cropped(to: rect)
            image = black.composited(over: image)
        }

        if let overlays = OverlayRenderer.image(effects: instruction.effects, time: time, canvas: size) {
            image = overlays.composited(over: image).cropped(to: rect)
        }

        for overlay in instruction.texts where time >= overlay.start && time <= overlay.end {
            let u = time - overlay.start
            var active: Int?
            if let starts = overlay.wordStarts {
                active = starts.lastIndex(where: { u >= $0 - 0.02 }) ?? 0
            }
            guard let label = TextRenderer.image(for: overlay, canvasWidth: w, active: active) else { continue }
            var scale = 1.0
            var alpha = 1.0
            var spin = 0.0
            switch overlay.animation {
            case 1:
                let k = min(u / 0.2, 1)
                scale = 0.6 + 0.4 * (1 - pow(1 - k, 3))
                alpha = min(u / 0.08, 1)
            case 2:
                alpha = min(u / 0.2, 1)
            case 3:
                let k = min(u / 0.3, 1)
                let eased = 1 - pow(1 - k, 3)
                scale = 0.5 + 0.5 * eased
                alpha = min(u / 0.08, 1)
                spin = -30 * (1 - eased)
            default: break
            }
            let remaining = overlay.end - time
            if remaining < 0.15 { alpha *= max(remaining / 0.15, 0) }
            let extent = label.extent
            var t = CGAffineTransform(translationX: -extent.width / 2, y: -extent.height / 2)
            t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
            let angle = (-(overlay.rotation ?? 0) + spin) * .pi / 180
            if angle != 0 { t = t.concatenating(CGAffineTransform(rotationAngle: CGFloat(angle))) }
            t = t.concatenating(CGAffineTransform(translationX: w / 2, y: h * (1 - overlay.y)))
            var placed = label.transformed(by: t)
            if alpha < 0.999 {
                placed = placed.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))
                ])
            }
            image = placed.composited(over: image).cropped(to: rect)
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
        if abs(s.rotation) > 0.001 {
            t = t.concatenating(CGAffineTransform(rotationAngle: CGFloat(-s.rotation * .pi / 180)))
        }
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

// MARK: - Texte

/// Dessine un texte (UIKit) en image Core Image, mise en cache pour ne pas le redessiner à chaque image.
enum TextRenderer {
    private static var cache: [String: CIImage] = [:]
    private static let lock = NSLock()

    private static func font(_ index: Int, size: CGFloat) -> UIFont {
        func design(_ d: UIFontDescriptor.SystemDesign) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: .heavy)
            if let descriptor = base.fontDescriptor.withDesign(d) { return UIFont(descriptor: descriptor, size: size) }
            return base
        }
        switch index {
        case 1: return design(.rounded)
        case 2: return design(.serif)
        case 3: return design(.monospaced)
        case 4: return UIFont(name: "AvenirNextCondensed-Heavy", size: size) ?? design(.default)
        case 5: return UIFont(name: "Futura-CondensedExtraBold", size: size) ?? design(.default)
        default: return UIFont.systemFont(ofSize: size, weight: .heavy)
        }
    }

    static func image(for overlay: TextOverlay, canvasWidth: CGFloat, active: Int? = nil) -> CIImage? {
        guard !overlay.text.isEmpty else { return nil }
        let key = [overlay.text, String(overlay.size), String(overlay.style),
                   String(overlay.colorIndex), String(overlay.font ?? 0), String(Int(canvasWidth)), String(active ?? -1)].joined(separator: "|")
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()

        let entry = TextOverlay.palette[min(max(overlay.colorIndex, 0), TextOverlay.palette.count - 1)]
        let color = UIColor(red: entry.r, green: entry.g, blue: entry.b, alpha: 1)
        let fontSize = max(canvasWidth * overlay.size, 8)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(overlay.font ?? 0, size: fontSize),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        switch overlay.style {
        case 1:
            attributes[.strokeColor] = UIColor.black
            attributes[.strokeWidth] = -7
        case 3:
            let shadow = NSShadow()
            shadow.shadowColor = color
            shadow.shadowBlurRadius = fontSize * 0.3
            shadow.shadowOffset = .zero
            attributes[.shadow] = shadow
        default: break
        }
        let string = NSMutableAttributedString(string: overlay.text, attributes: attributes)
        if let active {
            // Mot en cours : jaune (ou blanc si le texte est déjà jaune), un peu plus gros.
            let highlight = overlay.colorIndex == 1 ? UIColor.white : UIColor(red: 1, green: 0.92, blue: 0.2, alpha: 1)
            var location = 0
            for (index, word) in overlay.text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
                let length = (word as Substring).utf16.count
                if index == active, length > 0 {
                    string.addAttribute(.foregroundColor, value: highlight, range: NSRange(location: location, length: length))
                }
                location += length + 1
            }
        }
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let box = string.boundingRect(
            with: CGSize(width: canvasWidth * 0.9, height: .greatestFiniteMagnitude),
            options: options, context: nil
        )
        let pad = fontSize * 0.4
        let size = CGSize(width: ceil(box.width) + pad * 2, height: ceil(box.height) + pad * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            if overlay.style == 2 {
                UIColor.black.withAlphaComponent(0.6).setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: fontSize * 0.3).fill()
            }
            string.draw(with: CGRect(x: pad, y: pad, width: ceil(box.width) + 1, height: ceil(box.height) + 1),
                        options: options, context: nil)
        }
        guard let cg = rendered.cgImage else { return nil }
        let result = CIImage(cgImage: cg)
        lock.lock()
        if cache.count > 40 { cache.removeAll() }
        cache[key] = result
        lock.unlock()
        return result
    }
}
