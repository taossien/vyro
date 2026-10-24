//
//  EditorViewModel.swift
//  Logique de l'éditeur : lecture, effets, vitesse, stabilisation, export.
//  L'aperçu et l'export passent par le même VideoPipeline.
//

import Foundation
import AVFoundation

@MainActor
final class EditorViewModel: ObservableObject {
    @Published var project: ProjectModel
    @Published private(set) var player: AVPlayer?
    @Published var duration: Double = 0
    @Published var playhead: Double = 0
    @Published var isPlaying = false
    @Published var isScrubbing = false
    @Published var hasClip = false
    @Published var showImporter = false
    @Published var errorMessage: String?
    @Published var renderSize: CGSize = .zero

    @Published var selectedEffectID: UUID?
    @Published var speed: Double = 1
    @Published var stabilizationEnabled = false
    @Published var isAnalyzing = false
    @Published var debugInfo = ""
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var analysisProgress: Double = 0

    @Published var isExporting = false
    @Published var exportProgress: Double = 0
    @Published var exportedURL: URL?
    @Published var showExportDone = false

    @Published private(set) var timeMap: TimeMap?
    private var clipURL: URL?
    private var stabilizationData: StabilizationData?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var rebuildTask: Task<Void, Never>?
    private var undoStack: [ClipModel] = []
    private var redoStack: [ClipModel] = []
    private var lastUndoRecord = Date.distantPast
    private var statusObservation: NSKeyValueObservation?

    init(project: ProjectModel? = nil) {
        if let project = project {
            self.project = project
            if let clip = project.tracks.first?.clips.first {
                let url = ProjectStore.mediaDirectory.appendingPathComponent(clip.mediaFileName)
                if FileManager.default.fileExists(atPath: url.path) {
                    openExisting(url: url, clip: clip)
                } else {
                    errorMessage = "Le média de ce projet est introuvable."
                }
            }
        } else {
            let number = ProjectStore.loadAll().count + 1
            self.project = ProjectModel(
                id: UUID(),
                name: "Montage " + String(number),
                creationDate: Date(),
                modificationDate: Date()
            )
        }
    }

    // MARK: - Accès au clip

    var effects: [EffectModel] {
        project.tracks.first?.clips.first?.effects ?? []
    }

    var speedPoints: [SpeedPointModel] {
        (project.tracks.first?.clips.first?.speedPoints ?? []).sorted { $0.time < $1.time }
    }

    /// Positions (temps du montage) des points de vitesse, pour la timeline.
    var speedMarks: [Double] {
        guard let timeMap else { return [] }
        return speedPoints.map { timeMap.outputTime(atSource: $0.time) }
    }

    var selectedEffect: EffectModel? {
        effects.first { $0.id == selectedEffectID }
    }

    private var plan: RenderPlan {
        RenderPlan(
            effects: effects,
            speed: speed,
            speedPoints: speedPoints,
            stabilization: stabilizationEnabled ? stabilizationData : nil
        )
    }

    private func mutateClip(_ change: (inout ClipModel) -> Void) {
        guard !project.tracks.isEmpty, !project.tracks[0].clips.isEmpty else { return }
        let before = project.tracks[0].clips[0]
        change(&project.tracks[0].clips[0])
        if project.tracks[0].clips[0] != before { recordUndo(before) }
        persist()
    }

    /// Les changements rapprochés (glisser un curseur) forment une seule étape d'annulation.
    private func recordUndo(_ snapshot: ClipModel) {
        let now = Date()
        if now.timeIntervalSince(lastUndoRecord) > 0.6 || undoStack.isEmpty {
            undoStack.append(snapshot)
            if undoStack.count > 50 { undoStack.removeFirst() }
        }
        lastUndoRecord = now
        redoStack.removeAll()
        refreshUndoState()
    }

    private func refreshUndoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func undo() {
        guard let previous = undoStack.popLast(), !project.tracks.isEmpty, !project.tracks[0].clips.isEmpty else { return }
        redoStack.append(project.tracks[0].clips[0])
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast(), !project.tracks.isEmpty, !project.tracks[0].clips.isEmpty else { return }
        undoStack.append(project.tracks[0].clips[0])
        restore(next)
    }

    private func restore(_ clip: ClipModel) {
        project.tracks[0].clips[0] = clip
        speed = min(max(clip.speed, VideoPipeline.minSpeed), VideoPipeline.maxSpeed)
        stabilizationEnabled = clip.stabilizationEnabled == true
        if stabilizationEnabled, stabilizationData == nil {
            stabilizationData = ProjectStore.loadStabilization(for: clip.mediaFileName)
            if stabilizationData == nil { stabilizationEnabled = false }
        }
        if let id = selectedEffectID, !clip.effects.contains(where: { $0.id == id }) { selectedEffectID = nil }
        lastUndoRecord = .distantPast
        refreshUndoState()
        persist()
        scheduleRebuild()
    }

    private func persist() {
        project.modificationDate = Date()
        try? ProjectStore.save(project)
    }

    // MARK: - Chargement

    /// Nouveau clip importé : remplace le clip du projet.
    func loadClip(at url: URL) {
        clipURL = url
        Task {
            do {
                let seconds = try await AVURLAsset(url: url).load(.duration).seconds
                guard seconds.isFinite, seconds > 0 else { throw PipelineError.invalidDuration }

                if project.tracks.isEmpty {
                    project.tracks = [TrackModel(id: UUID())]
                }
                project.tracks[0].clips = [
                    ClipModel(id: UUID(), mediaFileName: url.lastPathComponent, sourceOut: seconds)
                ]
                speed = 1
                stabilizationEnabled = false
                stabilizationData = nil
                undoStack.removeAll(); redoStack.removeAll(); refreshUndoState()
                selectedEffectID = nil
                hasClip = true
                persist()
                await rebuild()
            } catch {
                errorMessage = "Impossible de lire ce clip : " + error.localizedDescription
            }
        }
    }

    private func openExisting(url: URL, clip: ClipModel) {
        clipURL = url
        speed = min(max(clip.speed, VideoPipeline.minSpeed), VideoPipeline.maxSpeed)
        hasClip = true
        if clip.stabilizationEnabled == true,
           let data = ProjectStore.loadStabilization(for: clip.mediaFileName) {
            stabilizationData = data
            stabilizationEnabled = true
        }
        Task { await rebuild() }
    }

    // MARK: - Pipeline aperçu

    private func ensurePlayer() -> AVPlayer {
        if let player { return player }
        let created = AVPlayer()
        player = created
        observeTime(of: created)
        return created
    }

    /// Reconstruit l'aperçu à partir du plan courant (effets, vitesse, stabilisation).
    private func rebuild() async {
        guard let url = clipURL else { return }
        do {
            let built = try await VideoPipeline.build(url: url, plan: plan)
            let player = ensurePlayer()
            let wasPlaying = isPlaying
            let resume = min(playhead, max(built.duration - 0.05, 0))

            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            item.audioTimePitchAlgorithm = .spectral
            observeEnd(of: item)
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                let nsError = item.error as NSError?
                let detail = (nsError?.localizedDescription ?? "erreur inconnue")
                    + " [" + String(nsError?.domain ?? "") + " " + String(nsError?.code ?? 0) + "] "
                    + String(describing: nsError?.userInfo[NSUnderlyingErrorKey])
                Task { @MainActor in self?.errorMessage = "Lecture impossible : " + detail }
            }

            player.replaceCurrentItem(with: item)
            duration = built.duration
            timeMap = built.timeMap
            renderSize = built.renderSize
            playhead = resume
            _ = await player.seek(
                to: CMTime(seconds: resume, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            if wasPlaying { player.play() }
        } catch {
            errorMessage = "Impossible de préparer l'aperçu : " + error.localizedDescription
        }
    }

    /// Évite de reconstruire à chaque cran d'un slider.
    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await rebuild()
        }
    }

    #if DEBUG
    /// Génère un clip synthétique (build Debug uniquement) pour tester sans photothèque.
    func loadDemoClip() {
        Task {
            do {
                loadClip(at: try await DemoClip.generate())
            } catch {
                errorMessage = "Clip de test impossible : " + error.localizedDescription
            }
        }
    }
    #endif

    // MARK: - Lecture

    func togglePlayback() {
        guard let player, hasClip else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, playhead >= duration - 0.05 { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        playhead = seconds
        player?.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    // MARK: - Effets

    func addZoom() {
        addEffect(.zoom(start: playhead))
    }

    func addShake() {
        addEffect(.shake(start: playhead))
    }

    private func addEffect(_ effect: EffectModel) {
        guard hasClip, duration > 0 else { return }
        var effect = effect
        effect.start = min(max(playhead, 0), max(duration - 0.1, 0))
        effect.duration = min(effect.duration, max(duration - effect.start, 0.1))
        mutateClip { $0.effects.append(effect) }
        selectedEffectID = effect.id
        scheduleRebuild()
    }

    func duplicateEffect(id: UUID) {
        guard let original = effects.first(where: { $0.id == id }), duration > 0 else { return }
        var copy = original
        copy.id = UUID()
        copy.start = min(original.end, max(duration - 0.1, 0))
        copy.duration = min(original.duration, max(duration - copy.start, 0.1))
        if copy.type == .shake { copy.parameters["seed"] = Double(Int.random(in: 1...9999)) }
        mutateClip { $0.effects.append(copy) }
        selectedEffectID = copy.id
        scheduleRebuild()
    }

    func removeEffect(id: UUID) {
        mutateClip { $0.effects.removeAll { $0.id == id } }
        if selectedEffectID == id { selectedEffectID = nil }
        scheduleRebuild()
    }

    func selectEffect(id: UUID) {
        selectedEffectID = id
        if let effect = effects.first(where: { $0.id == id }) {
            seek(to: effect.start)
        }
    }

    func updateEffect(id: UUID, _ change: (inout EffectModel) -> Void) {
        mutateClip { clip in
            guard let index = clip.effects.firstIndex(where: { $0.id == id }) else { return }
            change(&clip.effects[index])
            clip.effects[index].duration = max(clip.effects[index].duration, 0.1)
            clip.effects[index].start = max(clip.effects[index].start, 0)
        }
        scheduleRebuild()
    }

    // MARK: - Vitesse

    func setSpeed(_ value: Double) {
        let clamped = min(max(value, VideoPipeline.minSpeed), VideoPipeline.maxSpeed)
        speed = clamped
        mutateClip { $0.speed = clamped }
        scheduleRebuild()
    }

    // MARK: - Rampes de vitesse

    /// Temps source correspondant à la tête de lecture.
    private var playheadSourceTime: Double {
        timeMap?.sourceTime(atOutput: playhead) ?? playhead * speed
    }

    private var sourceDuration: Double {
        project.tracks.first?.clips.first?.sourceOut ?? 0
    }

    private func setSpeedPoints(_ points: [SpeedPointModel]) {
        let cleaned = points.sorted { $0.time < $1.time }
        mutateClip { $0.speedPoints = cleaned.isEmpty ? nil : cleaned }
        scheduleRebuild()
    }

    /// Ajoute (ou remplace) un point de vitesse à la tête de lecture.
    func addSpeedPoint(speed value: Double) {
        guard hasClip else { return }
        let time = playheadSourceTime
        var points = speedPoints.filter { abs($0.time - time) > 0.03 }
        points.append(SpeedPointModel(id: UUID(), time: time, speed: TimeMap.clamp(value)))
        setSpeedPoints(points)
    }

    /// Slow-mo "punch" : normal, ralenti net sur l'impact, retour à la normale.
    func addSlowMoPunch() {
        addRamp([(-0.25, 1.0), (0, 0.25), (0.5, 0.25), (0.8, 1.0)])
    }

    /// Accélération courte : normal, burst rapide, retour à la normale.
    func addSpeedBurst() {
        addRamp([(-0.2, 1.0), (0, 2.5), (0.6, 2.5), (0.8, 1.0)])
    }

    private func addRamp(_ shape: [(offset: Double, speed: Double)]) {
        guard hasClip else { return }
        let center = playheadSourceTime
        let total = sourceDuration
        let first = center + shape[0].offset
        let last = center + shape[shape.count - 1].offset
        // On remplace les points existants dans la zone de la rampe.
        var points = speedPoints.filter { $0.time < first - 0.03 || $0.time > last + 0.03 }
        for item in shape {
            let time = min(max(center + item.offset, 0.05), max(total - 0.05, 0.05))
            if !points.contains(where: { abs($0.time - time) < 0.03 }) {
                points.append(SpeedPointModel(id: UUID(), time: time, speed: item.speed))
            }
        }
        setSpeedPoints(points)
    }

    func updateSpeedPoint(id: UUID, speed value: Double) {
        var points = speedPoints
        guard let index = points.firstIndex(where: { $0.id == id }) else { return }
        points[index].speed = TimeMap.clamp(value)
        setSpeedPoints(points)
    }

    func removeSpeedPoint(id: UUID) {
        setSpeedPoints(speedPoints.filter { $0.id != id })
    }

    func clearSpeedPoints() {
        setSpeedPoints([])
    }

    // MARK: - Stabilisation

    func setStabilization(_ enabled: Bool) {
        guard hasClip, let url = clipURL else { return }
        if !enabled {
            stabilizationEnabled = false
            mutateClip { $0.stabilizationEnabled = false }
            scheduleRebuild()
            return
        }

        let fileName = url.lastPathComponent
        if let cached = stabilizationData ?? ProjectStore.loadStabilization(for: fileName) {
            stabilizationData = cached
            stabilizationEnabled = true
            mutateClip { $0.stabilizationEnabled = true }
            scheduleRebuild()
            return
        }

        isAnalyzing = true
        analysisProgress = 0
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try await StabilizationAnalyzer.analyze(url: url) { [weak self] value in
                        Task { @MainActor in self?.analysisProgress = value }
                    }
                }.value
                ProjectStore.saveStabilization(data, for: fileName)
                stabilizationData = data
                stabilizationEnabled = true
                mutateClip { $0.stabilizationEnabled = true }
                #if DEBUG
                debugInfo = DemoClip.report(for: data)
                #endif
                await rebuild()
            } catch {
                errorMessage = "Stabilisation impossible : " + error.localizedDescription
            }
            isAnalyzing = false
        }
    }

    // MARK: - Export

    func export() {
        guard hasClip, let url = clipURL, !isExporting else { return }
        player?.pause()
        isPlaying = false
        isExporting = true
        exportProgress = 0
        let plan = self.plan
        Task {
            do {
                let output = try await VideoPipeline.export(url: url, plan: plan) { [weak self] value in
                    Task { @MainActor in self?.exportProgress = value }
                }
                exportedURL = output
                showExportDone = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isExporting = false
        }
    }

    // MARK: - Cycle de vie

    /// À appeler quand l'éditeur disparaît : libère les ressources et sauvegarde.
    func stop() {
        rebuildTask?.cancel()
        player?.pause()
        isPlaying = false
        if let observer = timeObserver, let player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        if hasClip { persist() }
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
                self.playhead = self.duration
            }
        }
    }

    private func observeTime(of player: AVPlayer) {
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, self.isPlaying, !self.isScrubbing else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.playhead = seconds }
            }
        }
    }
}
