//
//  TimeMap.swift
//  Correspondance temps de sortie <-> temps du fichier source, avec rampes de vitesse.
//  Sert à construire la composition ET à retrouver l'image source d'un instant du montage.
//

import Foundation

struct TimeMap {
    struct Slice {
        var sourceStart: Double
        var sourceEnd: Double
        var outputStart: Double
        var outputEnd: Double
        var speed: Double
    }

    static let minSpeed = 0.1
    static let maxSpeed = 4.0
    /// Pas de découpe dans les zones de rampe (secondes du fichier source).
    static let rampStep = 0.05

    private(set) var slices: [Slice]

    var outputDuration: Double { slices.last?.outputEnd ?? 0 }
    var sourceDuration: Double { slices.last?.sourceEnd ?? 0 }

    // MARK: Vitesse à un instant source

    static func speed(atSource time: Double, base: Double, points: [SpeedPointModel]) -> Double {
        let sorted = points.sorted { $0.time < $1.time }
        guard let first = sorted.first, let last = sorted.last else { return clamp(base) }
        if time <= first.time { return clamp(first.speed) }
        if time >= last.time { return clamp(last.speed) }
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i], b = sorted[i + 1]
            if time >= a.time, time <= b.time {
                let span = b.time - a.time
                let k = span > 0 ? (time - a.time) / span : 0
                return clamp(a.speed + (b.speed - a.speed) * k)
            }
        }
        return clamp(base)
    }

    static func clamp(_ speed: Double) -> Double {
        min(max(speed, minSpeed), maxSpeed)
    }

    // MARK: Construction

    static func make(sourceDuration fileDuration: Double,
                     base: Double,
                     points: [SpeedPointModel],
                     trimIn: Double = 0,
                     trimOut: Double? = nil) -> TimeMap {
        let lo = min(max(trimIn, 0), max(fileDuration - 0.1, 0))
        let sourceDuration = min(max(trimOut ?? fileDuration, lo + 0.1), fileDuration)
        // Toutes les valeurs servent à calculer la vitesse (même hors découpe) ; seules celles
        // de la zone gardée créent des tronçons.
        let all = points.sorted { $0.time < $1.time }
        let sorted = all.filter { $0.time > lo && $0.time < sourceDuration }

        // Bornes des tronçons : début, chaque point, fin.
        var bounds: [Double] = [lo]
        for point in sorted where point.time - (bounds.last ?? 0) > 0.001 { bounds.append(point.time) }
        if sourceDuration - (bounds.last ?? 0) > 0.001 { bounds.append(sourceDuration) } else { bounds[bounds.count - 1] = sourceDuration }

        var raw: [(start: Double, end: Double, speed: Double)] = []
        for i in 0..<(bounds.count - 1) {
            let a = bounds[i], b = bounds[i + 1]
            let sa = speed(atSource: a, base: base, points: all)
            let sb = speed(atSource: b, base: base, points: all)
            if abs(sa - sb) < 0.001 {
                raw.append((a, b, sa))
            } else {
                let count = max(1, Int(((b - a) / rampStep).rounded(.up)))
                let step = (b - a) / Double(count)
                for k in 0..<count {
                    let s = a + Double(k) * step
                    let e = k == count - 1 ? b : s + step
                    raw.append((s, e, speed(atSource: (s + e) / 2, base: base, points: all)))
                }
            }
        }

        var slices: [Slice] = []
        var cursor = 0.0
        for item in raw {
            let out = (item.end - item.start) / item.speed
            slices.append(Slice(sourceStart: item.start, sourceEnd: item.end,
                                outputStart: cursor, outputEnd: cursor + out, speed: item.speed))
            cursor += out
        }
        return TimeMap(slices: slices)
    }

    // MARK: Conversions

    func sourceTime(atOutput time: Double) -> Double {
        guard let last = slices.last else { return time }
        if time <= 0 { return slices.first?.sourceStart ?? 0 }
        if time >= last.outputEnd { return last.sourceEnd }
        let slice = slices[index(where: { $0.outputEnd > time }) ?? slices.count - 1]
        return slice.sourceStart + (time - slice.outputStart) * slice.speed
    }

    func outputTime(atSource time: Double) -> Double {
        guard let last = slices.last else { return time }
        if time <= (slices.first?.sourceStart ?? 0) { return 0 }
        if time >= last.sourceEnd { return last.outputEnd }
        let slice = slices[index(where: { $0.sourceEnd > time }) ?? slices.count - 1]
        return slice.outputStart + (time - slice.sourceStart) / slice.speed
    }

    private func index(where predicate: (Slice) -> Bool) -> Int? {
        var lo = 0, hi = slices.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if predicate(slices[mid]) { found = mid; hi = mid - 1 } else { lo = mid + 1 }
        }
        return found
    }
}
