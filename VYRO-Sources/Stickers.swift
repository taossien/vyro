//
//  Stickers.swift
//  Calques image (logo, sticker, PNG) et masques (flou / noir) posés sur la vidéo.
//

import Foundation
import CoreImage
import UIKit

/// Calque posé sur l'image pendant une durée : une image importée ou un masque pour cacher
/// une partie de l'écran (interface du jeu, chiffres de dégâts…).
struct StickerOverlay: Codable, Identifiable, Equatable {
    var id: UUID
    /// Fichier image dans Media (nil pour un masque).
    var fileName: String?
    /// 0 image, 1 masque flou, 2 masque noir.
    var kind: Int = 0
    var start: Double
    var duration: Double = 2
    /// Centre (0...1), y = 0 en haut.
    var x: Double = 0.5
    var y: Double = 0.5
    /// Largeur en fraction de la largeur de l'écran.
    var size: Double = 0.3
    /// Hauteur / largeur (calculé pour une image, réglable pour un masque).
    var aspect: Double = 1
    var rotation: Double?
    var opacity: Double?

    var end: Double { start + duration }

    static let kindNames = ["Image", "Masque flou", "Masque noir"]
}

enum StickerRenderer {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CIImage] = [:]

    private static func cached(_ name: String) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        return cache[name]
    }

    private static func store(_ name: String, _ image: CIImage) {
        lock.lock(); defer { lock.unlock() }
        if cache.count > 24 { cache.removeAll() }
        cache[name] = image
    }

    private static func load(_ name: String) -> CIImage? {
        if let hit = cached(name) { return hit }
        let url = ProjectStore.mediaDirectory.appendingPathComponent(name)
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        store(name, image)
        return image
    }

    /// Enregistre une image importée (réduite à 1024 px, orientation corrigée). Renvoie (fichier, hauteur/largeur).
    static func save(_ data: Data) -> (name: String, aspect: Double)? {
        guard let source = UIImage(data: data), source.size.width > 0 else { return nil }
        let longSide = max(source.size.width, source.size.height)
        let k = min(1, 1024 / longSide)
        let target = CGSize(width: (source.size.width * k).rounded(), height: (source.size.height * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let flat = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let png = flat.pngData() else { return nil }
        let name = "sticker-" + UUID().uuidString + ".png"
        do {
            try png.write(to: ProjectStore.mediaDirectory.appendingPathComponent(name), options: .atomic)
        } catch { return nil }
        return (name, Double(target.height / target.width))
    }

    /// Pose le calque sur `base` (coordonnées Core Image : origine en bas à gauche).
    static func apply(_ s: StickerOverlay, over base: CIImage, time: Double, canvas: CGSize) -> CIImage {
        let w = canvas.width, h = canvas.height
        let rect = CGRect(origin: .zero, size: canvas)
        let u = time - s.start
        let remaining = s.end - time
        var alpha = (s.opacity ?? 1) * min(max(u / 0.1, 0), 1)
        if remaining < 0.1 { alpha *= max(remaining / 0.1, 0) }
        guard alpha > 0.002 else { return base }

        let width = CGFloat(s.size) * w
        let cx = CGFloat(s.x) * w
        let cy = h * (1 - CGFloat(s.y))

        if s.kind == 0 {
            guard let name = s.fileName, let image = load(name), image.extent.width > 0 else { return base }
            let k = width / image.extent.width
            var t = CGAffineTransform(translationX: -image.extent.midX, y: -image.extent.midY)
            t = t.concatenating(CGAffineTransform(scaleX: k, y: k))
            let angle = -(s.rotation ?? 0) * .pi / 180
            if angle != 0 { t = t.concatenating(CGAffineTransform(rotationAngle: CGFloat(angle))) }
            t = t.concatenating(CGAffineTransform(translationX: cx, y: cy))
            var placed = image.transformed(by: t)
            if alpha < 0.999 {
                placed = placed.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))
                ])
            }
            return placed.composited(over: base).cropped(to: rect)
        }

        let height = max(width * CGFloat(s.aspect), 4)
        let area = CGRect(x: cx - width / 2, y: cy - height / 2, width: width, height: height).intersection(rect)
        guard !area.isNull, area.width > 1, area.height > 1 else { return base }
        if s.kind == 1 {
            let radius = max(14, w * 0.03)
            let blurred = base.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: area)
            return blurred.composited(over: base).cropped(to: rect)
        }
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(min(alpha, 1)))).cropped(to: area)
        return black.composited(over: base).cropped(to: rect)
    }
}
