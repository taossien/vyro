//
//  SelfCheck.swift
//  Vérifications automatiques des calculs de temps (build Debug uniquement, au lancement).
//  Un échec s'affiche dans la console Xcode avec le préfixe "SELFCHECK ÉCHEC".
//

import Foundation

#if DEBUG
enum SelfCheck {
    @discardableResult
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String) { if !ok { failures.append(name) } }
        func near(_ a: Double, _ b: Double, _ eps: Double = 0.001) -> Bool { abs(a - b) < eps }

        // Vitesse constante x2 : la sortie dure moitié moins.
        let fast = TimeMap.make(sourceDuration: 10, base: 2, points: [])
        check(near(fast.outputDuration, 5), "x2 durée de sortie")
        check(near(fast.sourceTime(atOutput: 2.5), 5), "x2 sortie vers source")
        check(near(fast.outputTime(atSource: 5), 2.5), "x2 source vers sortie")

        // Découpe 2...8 à vitesse normale.
        let trimmed = TimeMap.make(sourceDuration: 10, base: 1, points: [], trimIn: 2, trimOut: 8)
        check(near(trimmed.outputDuration, 6), "découpe durée")
        check(near(trimmed.sourceTime(atOutput: 0), 2), "découpe début")
        check(near(trimmed.sourceTime(atOutput: 6), 8), "découpe fin")
        check(near(trimmed.outputTime(atSource: 5), 3), "découpe source vers sortie")

        // Découpe hors limites : bornée au fichier.
        let wild = TimeMap.make(sourceDuration: 10, base: 1, points: [], trimIn: -5, trimOut: 100)
        check(near(wild.outputDuration, 10), "découpe hors limites")

        // Rampe de vitesse : continuité, monotonie et aller-retour.
        let points = [SpeedPointModel(id: UUID(), time: 2, speed: 1),
                      SpeedPointModel(id: UUID(), time: 6, speed: 3)]
        let ramp = TimeMap.make(sourceDuration: 10, base: 1, points: points)
        var contiguous = true
        for i in 1..<max(ramp.slices.count, 1) {
            let a = ramp.slices[i - 1], b = ramp.slices[i]
            if !near(a.outputEnd, b.outputStart, 1e-6) || !near(a.sourceEnd, b.sourceStart, 1e-6) { contiguous = false }
        }
        check(contiguous, "rampe tronçons contigus")
        check(near(ramp.sourceDuration, 10), "rampe couvre toute la source")
        var monotonic = true, roundTrip = true, last = -1.0
        var t = 0.0
        while t <= 10 {
            let out = ramp.outputTime(atSource: t)
            if out < last - 1e-9 { monotonic = false }
            last = out
            if !near(ramp.sourceTime(atOutput: out), t, 0.01) { roundTrip = false }
            t += 0.25
        }
        check(monotonic, "rampe monotone")
        check(roundTrip, "rampe aller-retour")
        check(ramp.outputDuration < 10 && ramp.outputDuration > 10.0 / 3, "rampe durée plausible")

        // Bornes de vitesse.
        check(near(TimeMap.clamp(99), TimeMap.maxSpeed), "vitesse max")
        check(near(TimeMap.clamp(0), TimeMap.minSpeed), "vitesse min")

        if failures.isEmpty {
            print("SELFCHECK OK : calculs de temps")
            return true
        }
        print("SELFCHECK ÉCHEC : " + failures.joined(separator: ", "))
        return false
    }
}
#endif
