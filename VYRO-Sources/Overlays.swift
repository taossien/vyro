//
//  Overlays.swift
//  Effets dessinés par-dessus l'image : étincelles et anneau lumineux.
//  Tout est déterministe (graine fixe) : même instant, même dessin, à l'aperçu comme à l'export.
//

import Foundation
import CoreGraphics
import CoreImage

enum OverlayRenderer {
    /// Dessin à demi-résolution : ces effets sont doux, la moitié suffit et coûte quatre fois moins.
    private static let quality: CGFloat = 0.5
    private static let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    static func image(effects: [EffectModel], time: Double, canvas: CGSize) -> CIImage? {
        let active = effects.filter {
            ($0.type == .sparkles || $0.type == .ring) && $0.enabled && $0.duration > 0
                && time >= $0.start && time <= $0.end
        }
        guard !active.isEmpty else { return nil }
        let width = max(Int(canvas.width * quality), 8)
        let height = max(Int(canvas.height * quality), 8)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: quality, y: quality)
        for effect in active {
            let u = (time - effect.start) / effect.duration
            switch effect.type {
            case .sparkles: drawSparkles(effect, u: u, canvas: canvas, in: context)
            default: drawRing(effect, u: u, canvas: canvas, in: context)
            }
        }
        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(scaleX: 1 / quality, y: 1 / quality))
    }

    private static func color(_ index: Int, alpha: CGFloat) -> CGColor {
        let palette = TextOverlay.palette
        let entry = palette[min(max(index, 0), palette.count - 1)]
        return CGColor(red: entry.r, green: entry.g, blue: entry.b, alpha: alpha)
    }

    private static func drawRing(_ effect: EffectModel, u: Double, canvas: CGSize, in context: CGContext) {
        let eased = 1 - pow(1 - u, 3)
        let radius = canvas.width * (0.12 + 0.55 * eased)
        let fade = pow(1 - u, 0.8)
        let base = canvas.width * 0.011 * effect.intensity * (1 - 0.6 * u)
        let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        let rect = CGRect(x: center.x - radius, y: center.y - radius * effect.tilt,
                          width: radius * 2, height: radius * 2 * effect.tilt)
        // Trois passes : halo large, halo moyen, trait net presque blanc.
        let passes: [(CGFloat, CGFloat, Bool)] = [(4.2, 0.14, false), (2.2, 0.3, false), (1, 1, true)]
        for (factor, alpha, core) in passes {
            context.setLineWidth(max(base * factor, 1))
            context.setStrokeColor(core ? CGColor(red: 1, green: 1, blue: 1, alpha: alpha * fade)
                                        : color(effect.colorIndex, alpha: alpha * fade))
            context.strokeEllipse(in: rect)
        }
    }

    private static func drawSparkles(_ effect: EffectModel, u: Double, canvas: CGSize, in context: CGContext) {
        let seed = UInt32(truncatingIfNeeded: Int(effect.parameters["seed"] ?? 1))
        let count = max(Int(36 * effect.intensity), 4)
        for index in 0..<count {
            let phase = (EffectEngine.hash(seed: seed, index: index, channel: 3) + 1) / 2 * 0.55
            let life = (u - phase) / 0.45
            guard life > 0, life < 1 else { continue }
            let px = 0.5 + 0.42 * EffectEngine.hash(seed: seed, index: index, channel: 0)
            let py = 0.5 + 0.38 * EffectEngine.hash(seed: seed, index: index, channel: 1)
            let variety = 0.5 + (EffectEngine.hash(seed: seed, index: index, channel: 2) + 1) / 2
            let twinkle = sin(.pi * life)
            let size = canvas.width * 0.03 * variety * twinkle
            guard size > 0.5 else { continue }
            let x = canvas.width * px
            let y = canvas.height * (py + 0.06 * life)
            starPath(context, at: CGPoint(x: x, y: y), size: size)
            context.setFillColor(color(effect.colorIndex, alpha: 0.85 * twinkle))
            context.fillPath()
            starPath(context, at: CGPoint(x: x, y: y), size: size * 0.45)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: twinkle))
            context.fillPath()
        }
    }

    /// Étoile à quatre branches fines.
    private static func starPath(_ context: CGContext, at p: CGPoint, size s: CGFloat) {
        let k = s * 0.16
        context.beginPath()
        context.move(to: CGPoint(x: p.x, y: p.y + s))
        context.addLine(to: CGPoint(x: p.x + k, y: p.y + k))
        context.addLine(to: CGPoint(x: p.x + s, y: p.y))
        context.addLine(to: CGPoint(x: p.x + k, y: p.y - k))
        context.addLine(to: CGPoint(x: p.x, y: p.y - s))
        context.addLine(to: CGPoint(x: p.x - k, y: p.y - k))
        context.addLine(to: CGPoint(x: p.x - s, y: p.y))
        context.addLine(to: CGPoint(x: p.x - k, y: p.y + k))
        context.closePath()
    }
}
