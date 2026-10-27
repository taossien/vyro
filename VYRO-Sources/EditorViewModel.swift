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
    @Published var isAnalyzing = false
    @Published var debugInfo = ""
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var analysisProgress: Double = 0

    @Published var isExporting = false
    @Published var exportProgress: Double = 0
    @Published var exportedURL: URL?
    @Published var showExportDone = false

    /// Position de chaque clip dans le montage (temps de sortie).
    @Published private(set) var spans: [ClipSpan] = []
    private var stabilizationCache: [String: StabilizationData] = [:]
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var rebuildTask: Task<Void, Never>?
    private var undoStack: [[ClipModel]] = []
    private var redoStack: [[ClipModel]] = []
    private var lastUndoRecord = Date.distantPast
    private var statusObservation: NSKeyValueObservation?

    init(project: ProjectModel? = nil) {
        if let project = project {
            self.project = project
            let all = project.tracks.first?.clips ?? []
            if !all.isEmpty {
                let present = all.allSatisfy {
                    FileManager.default.fileExists(
                        atPath: ProjectStore.mediaDirectory.appendingPathComponent($0.mediaFileName).path)
                }
                if present {
                    openExisting()
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

    // MARK: - Accès aux clips

    var clips: [ClipModel] { project.tracks.first?.clips ?? [] }

    /// Indice du clip sous la tête de lecture.
    var currentIndex: Int {
        guard !clips.isEmpty else { return 0 }
        let found = spans.lastIndex { playhead >= $0.start - 0.0005 } ?? 0
        return min(found, clips.count - 1)
    }

    var currentClip: ClipModel? {
        let list = clips
        return list.indices.contains(currentIndex) ? list[currentIndex] : nil
    }

    private func mediaURL(_ clip: ClipModel) -> URL {
        ProjectStore.mediaDirectory.appendingPathComponent(clip.mediaFileName)
    }

    /// Effets : globaux, portés par le premier clip.
    var effects: [EffectModel] {
        project.tracks.first?.clips.first?.effects ?? []
    }

    /// Vitesse et stabilisation : propres au clip sous la tête de lecture.
    var speed: Double {
        min(max(currentClip?.speed ?? 1, VideoPipeline.minSpeed), VideoPipeline.maxSpeed)
    }

    var stabilizationEnabled: Bool {
        guard let clip = currentClip else { return false }
        return clip.stabilizationEnabled == true && stabilizationCache[clip.mediaFileName] != nil
    }

    var speedPoints: [SpeedPointModel] {
        (currentClip?.speedPoints ?? []).sorted { $0.time < $1.time }
    }

    /// Positions (temps du montage) des points de vitesse, pour la timeline.
    var speedMarks: [Double] {
        var marks: [Double] = []
        let list = clips
        for index in spans.indices where list.indices.contains(index) {
            for point in list[index].speedPoints ?? [] {
                marks.append(spans[index].start + spans[index].timeMap.outputTime(atSource: point.time))
            }
        }
        return marks
    }

    var selectedEffect: EffectModel? {
        effects.first { $0.id == selectedEffectID }
    }

    private var plan: RenderPlan {
        RenderPlan(
            clips: clips.map { clip in
                ClipPlan(
                    url: mediaURL(clip),
                    speed: min(max(clip.speed, VideoPipeline.minSpeed), VideoPipeline.maxSpeed),
                    speedPoints: (clip.speedPoints ?? []).sorted { $0.time < $1.time },
                    stabilization: clip.stabilizationEnabled == true ? stabilizationCache[clip.mediaFileName] : nil,
                    trimIn: clip.trimIn ?? 0,
                    trimOut: clip.trimOut,
                    transition: clip.transition,
                    hold: clip.hold
                )
            },
            effects: effects,
            musicURL: musicURL,
            musicVolume: musicVolume,
            musicOffset: musicOffset,
            originalVolume: originalVolume,
            motionBlur: motionBlurStrength,
            grade: colorGrade,
            texts: texts,
            keyframes: keyframes,
            sounds: soundPlans
        )
    }


    // MARK: - Effets sonores

    @Published var selectedSoundID: UUID?
    var sounds: [SoundMark] { (project.tracks.first?.clips.first?.sounds ?? []).sorted { $0.time < $1.time } }
    var selectedSound: SoundMark? { sounds.first { $0.id == selectedSoundID } }

    private var soundPlans: [SoundPlan] {
        sounds.compactMap { mark in
            guard let kind = SoundKind(rawValue: mark.kind), let url = kind.url else { return nil }
            return SoundPlan(url: url, start: mark.time - kind.lead, volume: mark.volume)
        }
    }

    func addSound(_ kind: SoundKind, at time: Double? = nil) {
        guard hasClip, duration > 0 else { return }
        let at = min(max(snap(time ?? playhead), 0), duration)
        let mark = SoundMark(id: UUID(), time: at, kind: kind.rawValue)
        mutateClip { $0.sounds = ($0.sounds ?? []) + [mark] }
        selectedSoundID = mark.id
        scheduleRebuild()
    }

    func updateSound(id: UUID, _ change: (inout SoundMark) -> Void) {
        mutateClip { clip in
            guard var list = clip.sounds, let index = list.firstIndex(where: { $0.id == id }) else { return }
            change(&list[index])
            list[index].time = min(max(list[index].time, 0), max(duration, 0))
            clip.sounds = list
        }
        scheduleRebuild()
    }

    func removeSound(id: UUID) {
        mutateClip { $0.sounds = ($0.sounds ?? []).filter { $0.id != id } }
        if selectedSoundID == id { selectedSoundID = nil }
        scheduleRebuild()
    }

    func clearSounds() {
        mutateClip { $0.sounds = nil }
        selectedSoundID = nil
        scheduleRebuild()
    }

    /// Pose le son choisi sur chaque temps fort de la musique (ou à intervalle régulier sans musique).
    func addSoundsOnBeats(_ kind: SoundKind, every: Int = 2) {
        guard hasClip, duration > 0 else { return }
        var marks = rhythmMarks(every: every)
        marks = marks.filter { $0 > 0.2 }
        let existing = sounds
        let created = marks.map { SoundMark(id: UUID(), time: $0, kind: kind.rawValue, volume: 0.7) }
            .filter { new in !existing.contains { $0.kind == new.kind && abs($0.time - new.time) < 0.2 } }
        guard !created.isEmpty else { return }
        mutateClip { $0.sounds = ($0.sounds ?? []) + created }
        scheduleRebuild()
    }

    // MARK: - Mouvement (images clés)

    @Published var selectedKeyframeID: UUID?
    var keyframes: [Keyframe] { (project.tracks.first?.clips.first?.keyframes ?? []).sorted { $0.time < $1.time } }
    var selectedKeyframe: Keyframe? { keyframes.first { $0.id == selectedKeyframeID } }

    /// Ajoute une image clé à la tête de lecture, avec l'état actuel (l'image ne change pas).
    func addKeyframe() {
        guard hasClip, duration > 0 else { return }
        let time = min(max(snap(playhead), 0), duration)
        var frame = KeyframeEngine.value(at: time, keyframes) ?? Keyframe(id: UUID(), time: time)
        frame.id = UUID()
        frame.time = time
        var list = keyframes.filter { abs($0.time - time) > 0.05 }
        list.append(frame)
        mutateClip { $0.keyframes = list }
        selectedKeyframeID = frame.id
        scheduleRebuild()
    }

    func updateKeyframe(id: UUID, _ change: (inout Keyframe) -> Void) {
        mutateClip { clip in
            guard var list = clip.keyframes, let index = list.firstIndex(where: { $0.id == id }) else { return }
            change(&list[index])
            list[index].time = min(max(list[index].time, 0), max(duration, 0))
            clip.keyframes = list
        }
        scheduleRebuild()
    }

    func removeKeyframe(id: UUID) {
        mutateClip { clip in
            let list = (clip.keyframes ?? []).filter { $0.id != id }
            clip.keyframes = list.isEmpty ? nil : list
        }
        if selectedKeyframeID == id { selectedKeyframeID = nil }
        scheduleRebuild()
    }

    func clearKeyframes() {
        mutateClip { $0.keyframes = nil }
        selectedKeyframeID = nil
        scheduleRebuild()
    }

    func selectKeyframe(id: UUID) {
        selectedKeyframeID = id
        if let frame = keyframes.first(where: { $0.id == id }) { seek(to: frame.time) }
    }

    // MARK: - Textes

    @Published var selectedTextID: UUID?
    var texts: [TextOverlay] { project.tracks.first?.clips.first?.texts ?? [] }
    var selectedText: TextOverlay? { texts.first { $0.id == selectedTextID } }

    func addText() {
        guard hasClip, duration > 0 else { return }
        let start = min(max(snap(playhead), 0), max(duration - 0.5, 0))
        let overlay = TextOverlay(id: UUID(), start: start, duration: min(2, max(duration - start, 0.5)))
        mutateClip { $0.texts = ($0.texts ?? []) + [overlay] }
        selectedTextID = overlay.id
        scheduleRebuild()
    }

    func updateText(id: UUID, _ change: (inout TextOverlay) -> Void) {
        mutateClip { clip in
            guard var list = clip.texts, let index = list.firstIndex(where: { $0.id == id }) else { return }
            change(&list[index])
            list[index].duration = max(list[index].duration, 0.3)
            list[index].start = max(list[index].start, 0)
            clip.texts = list
        }
        scheduleRebuild()
    }

    func removeText(id: UUID) {
        mutateClip { clip in
            let list = (clip.texts ?? []).filter { $0.id != id }
            clip.texts = list.isEmpty ? nil : list
        }
        if selectedTextID == id { selectedTextID = nil }
        scheduleRebuild()
    }

    // MARK: Sous-titres automatiques

    @Published var isTranscribing = false
    @Published var subtitleLanguage = "fr-FR"
    /// Vrai : un mot à la fois, façon édit TikTok.
    @Published var subtitleWordByWord = false
    /// Vrai : phrases courtes avec le mot prononcé surligné.
    @Published var subtitleKaraoke = false
    var subtitleCount: Int { texts.filter { $0.subtitle == true }.count }

    func generateSubtitles() {
        guard hasClip, !isTranscribing else { return }
        isTranscribing = true
        player?.pause()
        isPlaying = false
        let language = subtitleLanguage
        let karaoke = subtitleKaraoke && !subtitleWordByWord
        var voicePlan = plan
        voicePlan.musicURL = nil
        voicePlan.originalVolume = 1
        Task {
            defer { isTranscribing = false }
            do {
                guard await SubtitleGenerator.authorize() else { throw SubtitleError.notAuthorized }
                let built = try await VideoPipeline.build(plan: voicePlan)
                let audio = try await SubtitleGenerator.exportAudio(of: built.composition)
                defer { try? FileManager.default.removeItem(at: audio) }
                let words = try await SubtitleGenerator.transcribe(audio: audio, language: language)
                let chunks = SubtitleGenerator.chunk(words, maxWords: subtitleWordByWord ? 1 : 4)
                let size = (try? FileManager.default.attributesOfItem(atPath: audio.path)[.size] as? Int) ?? 0
                guard !chunks.isEmpty else {
                    throw SubtitleError.noSpeech("(son extrait : " + String(size / 1024) + " Ko, mots : " + String(words.count) + ")")
                }
                let created = chunks.map { chunk -> TextOverlay in
                    var overlay = TextOverlay(id: UUID(), text: chunk.text.uppercased(),
                                              start: chunk.start, duration: max(chunk.end - chunk.start, 0.3))
                    overlay.y = 0.8
                    overlay.size = 0.065
                    overlay.style = 1
                    overlay.font = 5
                    overlay.animation = 1
                    overlay.subtitle = true
                    if karaoke, chunk.wordStarts.count > 1 {
                        overlay.wordStarts = chunk.wordStarts
                        overlay.size = 0.075
                    }
                    return overlay
                }
                mutateClip { clip in
                    let others = (clip.texts ?? []).filter { $0.subtitle != true }
                    clip.texts = others + created
                }
                selectedTextID = nil
                scheduleRebuild()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func removeSubtitles() {
        mutateClip { clip in
            let others = (clip.texts ?? []).filter { $0.subtitle != true }
            clip.texts = others.isEmpty ? nil : others
        }
        if let id = selectedTextID, !texts.contains(where: { $0.id == id }) { selectedTextID = nil }
        scheduleRebuild()
    }

    /// Change le style de tous les sous-titres d'un coup.
    func updateAllSubtitles(_ change: (inout TextOverlay) -> Void) {
        mutateClip { clip in
            guard var list = clip.texts else { return }
            for index in list.indices where list[index].subtitle == true { change(&list[index]) }
            clip.texts = list
        }
        scheduleRebuild()
    }

    /// Copie un fichier vidéo choisi dans Fichiers puis l'ajoute au montage.
    func importVideoFile(from picked: URL) {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let destination = ProjectStore.mediaDirectory
            .appendingPathComponent(UUID().uuidString + "." + (picked.pathExtension.isEmpty ? "mp4" : picked.pathExtension))
        do {
            try FileManager.default.copyItem(at: picked, to: destination)
            loadClip(at: destination)
        } catch {
            errorMessage = "Impossible de copier cette vidéo : " + error.localizedDescription
        }
    }

    func selectText(id: UUID) {
        selectedTextID = id
        if let text = texts.first(where: { $0.id == id }) { seek(to: min(text.start + 0.05, max(duration - 0.05, 0))) }
    }

    var colorGrade: ColorGrade { project.tracks.first?.clips.first?.colorGrade ?? .neutral }

    func setColorGrade(_ grade: ColorGrade) {
        mutateClip { $0.colorGrade = grade.isNeutral ? nil : grade }
        scheduleRebuild()
    }

    var motionBlurStrength: Double { project.tracks.first?.clips.first?.motionBlur ?? 1 }

    func setMotionBlur(_ value: Double) {
        mutateClip { $0.motionBlur = value }
        scheduleRebuild()
    }

    // MARK: - Musique et rythme

    @Published private(set) var beats: [Double] = []      // temps du morceau
    @Published var isAnalyzingBeats = false
    @Published var snapToBeats = true

    private var clip: ClipModel? { project.tracks.first?.clips.first }
    var musicName: String? { clip?.musicFileName }
    var musicURL: URL? {
        clip?.musicFileName.map { ProjectStore.mediaDirectory.appendingPathComponent($0) }
    }
    var musicVolume: Double { clip?.musicVolume ?? 0.8 }
    var originalVolume: Double { clip?.originalVolume ?? 1 }
    var musicOffset: Double { clip?.musicOffset ?? 0 }

    /// Temps forts placés sur le montage (temps de sortie).
    var beatMarks: [Double] {
        beats.map { $0 - musicOffset }.filter { $0 >= 0 && $0 <= duration }
    }

    /// Aimante un instant sur le temps fort le plus proche (à 0,12 s près).
    func snap(_ time: Double) -> Double {
        guard snapToBeats, let nearest = beatMarks.min(by: { abs($0 - time) < abs($1 - time) }),
              abs(nearest - time) <= 0.12 else { return time }
        return nearest
    }

    /// Copie le morceau choisi dans le dossier Media puis détecte son rythme.
    func importMusic(from picked: URL) {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let name = UUID().uuidString + "." + (picked.pathExtension.isEmpty ? "m4a" : picked.pathExtension)
        let destination = ProjectStore.mediaDirectory.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: picked, to: destination)
        } catch {
            errorMessage = "Impossible de copier ce morceau : " + error.localizedDescription
            return
        }
        mutateClip {
            $0.musicFileName = name
            $0.musicOffset = nil
        }
        beats = []
        scheduleRebuild()
        analyzeBeats(fileName: name)
    }

    private func analyzeBeats(fileName: String) {
        if let cached = ProjectStore.loadBeats(for: fileName) { beats = cached; return }
        isAnalyzingBeats = true
        let url = ProjectStore.mediaDirectory.appendingPathComponent(fileName)
        Task {
            defer { isAnalyzingBeats = false }
            do {
                let found = try await BeatAnalyzer.analyze(url: url)
                ProjectStore.saveBeats(found, for: fileName)
                if musicName == fileName { beats = found }
                if found.isEmpty { errorMessage = "Aucun rythme net détecté dans ce morceau." }
            } catch {
                errorMessage = "Analyse du rythme impossible : " + error.localizedDescription
            }
        }
    }

    func removeMusic() {
        mutateClip { $0.musicFileName = nil; $0.musicOffset = nil }
        beats = []
        scheduleRebuild()
    }

    func setMusicVolume(_ value: Double) { mutateClip { $0.musicVolume = value }; scheduleRebuild() }
    func setOriginalVolume(_ value: Double) { mutateClip { $0.originalVolume = value }; scheduleRebuild() }
    func setMusicOffset(_ value: Double) { mutateClip { $0.musicOffset = value <= 0.001 ? nil : value }; scheduleRebuild() }

    /// Place un zoom sur un temps fort sur `every` (1 = tous, 2 = un sur deux...).
    func autoZoomOnBeats(every: Int) {
        guard hasClip, duration > 0 else { return }
        let marks = beatMarks.enumerated().filter { $0.offset % max(every, 1) == 0 }.map { $0.element }
        guard !marks.isEmpty else { return }
        mutateClip { clip in
            for time in marks where time < duration - 0.1 {
                clip.effects.append(.zoom(start: time, duration: 0.3, peak: 1.25))
            }
        }
        scheduleRebuild()
    }

    // MARK: - Découpe

    /// Début de la découpe, en secondes du fichier source.
    var trimIn: Double { currentClip?.trimIn ?? 0 }
    /// Fin de la découpe, en secondes du fichier source.
    var trimOut: Double { currentClip?.trimOut ?? sourceDuration }
    var fileDuration: Double { sourceDuration }
    var isTrimmed: Bool { trimIn > 0.001 || trimOut < sourceDuration - 0.001 }

    func setTrimIn(_ value: Double) {
        let v = min(max(value, 0), trimOut - 0.3)
        mutateCurrent { $0.trimIn = v <= 0.001 ? nil : v }
        scheduleRebuild()
    }

    func setTrimOut(_ value: Double) {
        let v = min(max(value, trimIn + 0.3), sourceDuration)
        mutateCurrent { $0.trimOut = v >= sourceDuration - 0.001 ? nil : v }
        scheduleRebuild()
    }

    func trimStartHere() { setTrimIn(playheadSourceTime) }
    func trimEndHere() { setTrimOut(playheadSourceTime) }

    func resetTrim() {
        mutateCurrent { $0.trimIn = nil; $0.trimOut = nil }
        scheduleRebuild()
    }

    /// Réglages globaux (effets, musique, flou) : portés par le premier clip.
    private func mutateClip(_ change: (inout ClipModel) -> Void) { mutate(at: 0, change) }

    /// Réglages propres au clip sous la tête de lecture.
    private func mutateCurrent(_ change: (inout ClipModel) -> Void) { mutate(at: currentIndex, change) }

    private func mutate(at index: Int, _ change: (inout ClipModel) -> Void) {
        mutateAll { clips in
            guard clips.indices.contains(index) else { return }
            change(&clips[index])
        }
    }

    /// Toute modification du montage passe ici : une seule étape d'annulation, puis sauvegarde.
    private func mutateAll(_ change: (inout [ClipModel]) -> Void) {
        guard !project.tracks.isEmpty, !project.tracks[0].clips.isEmpty else { return }
        let before = project.tracks[0].clips
        change(&project.tracks[0].clips)
        if project.tracks[0].clips != before { recordUndo(before) }
        persist()
    }

    /// Les changements rapprochés (glisser un curseur) forment une seule étape d'annulation.
    private func recordUndo(_ snapshot: [ClipModel]) {
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
        guard let previous = undoStack.popLast(), !project.tracks.isEmpty else { return }
        redoStack.append(project.tracks[0].clips)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast(), !project.tracks.isEmpty else { return }
        undoStack.append(project.tracks[0].clips)
        restore(next)
    }

    private func restore(_ snapshot: [ClipModel]) {
        project.tracks[0].clips = snapshot
        loadStabilizationCaches()
        if let id = selectedEffectID, !effects.contains(where: { $0.id == id }) { selectedEffectID = nil }
        lastUndoRecord = .distantPast
        refreshUndoState()
        persist()
        scheduleRebuild()
    }

    private func loadStabilizationCaches() {
        for clip in clips where clip.stabilizationEnabled == true && stabilizationCache[clip.mediaFileName] == nil {
            if let data = ProjectStore.loadStabilization(for: clip.mediaFileName) {
                stabilizationCache[clip.mediaFileName] = data
            }
        }
    }

    private func persist() {
        project.modificationDate = Date()
        try? ProjectStore.save(project)
    }

    // MARK: - Chargement

    /// Vidéo importée : premier clip du montage, ou clip ajouté à la suite.
    func loadClips(_ urls: [URL]) {
        Task { for url in urls { await addClip(url) } }
    }

    func loadClip(at url: URL) { loadClips([url]) }

    private func addClip(_ url: URL) async {
            do {
                let seconds = try await AVURLAsset(url: url).load(.duration).seconds
                guard seconds.isFinite, seconds > 0 else { throw PipelineError.invalidDuration }
                let clip = ClipModel(id: UUID(), mediaFileName: url.lastPathComponent, sourceOut: seconds)

                if hasClip, !clips.isEmpty {
                    let start = duration
                    mutateAll { $0.append(clip) }
                    playhead = start
                } else {
                    if project.tracks.isEmpty {
                        project.tracks = [TrackModel(id: UUID())]
                    }
                    project.tracks[0].clips = [clip]
                    stabilizationCache = [:]
                    undoStack.removeAll(); redoStack.removeAll(); refreshUndoState()
                    selectedEffectID = nil
                    playhead = 0
                    hasClip = true
                    persist()
                }
                await rebuild()
            } catch {
                errorMessage = "Impossible de lire ce clip : " + error.localizedDescription
            }
    }

    private func openExisting() {
        hasClip = true
        if let music = clip?.musicFileName { analyzeBeats(fileName: music) }
        loadStabilizationCaches()
        Task { await rebuild() }
    }

    // MARK: - Montage : scinder, supprimer, déplacer

    private func stripGlobals(_ clip: inout ClipModel) {
        clip.effects = []
        clip.musicFileName = nil
        clip.musicVolume = nil
        clip.originalVolume = nil
        clip.musicOffset = nil
        clip.motionBlur = nil
        clip.colorGrade = nil
        clip.texts = nil
        clip.keyframes = nil
        clip.sounds = nil
    }

    /// Réordonne / retire des clips en gardant les réglages globaux sur le premier.
    private func restructure(_ change: (inout [ClipModel]) -> Void) {
        mutateAll { clips in
            let globals = clips[0]
            change(&clips)
            guard !clips.isEmpty else { return }
            for index in clips.indices { stripGlobals(&clips[index]) }
            clips[0].effects = globals.effects
            clips[0].musicFileName = globals.musicFileName
            clips[0].musicVolume = globals.musicVolume
            clips[0].originalVolume = globals.originalVolume
            clips[0].musicOffset = globals.musicOffset
            clips[0].motionBlur = globals.motionBlur
            clips[0].colorGrade = globals.colorGrade
            clips[0].texts = globals.texts
            clips[0].keyframes = globals.keyframes
            clips[0].sounds = globals.sounds
        }
    }

    private func rebuildNow() {
        rebuildTask?.cancel()
        rebuildTask = Task { await rebuild() }
    }

    // MARK: - Styles prêts à l'emploi

    @Published private(set) var appliedStyleID: String?

    /// Applique un style : look, flou, transitions sur chaque coupure, effets sur les temps forts.
    /// Instants forts du montage : temps de la musique (un sur `every`), sinon coupures puis intervalle régulier.
    func rhythmMarks(every: Int) -> [Double] {
        var marks: [Double]
        let beats = beatMarks
        if beats.count >= 2 {
            marks = beats.enumerated().filter { $0.offset % max(every, 1) == 0 }.map { $0.element }
        } else {
            marks = spans.dropFirst().map { $0.start }
            var t = 1.5
            while t < duration - 0.3 {
                marks.append(t)
                t += 1.6 * Double(max(every, 1))
            }
        }
        marks = marks.filter { $0 > 0.2 && $0 < duration - 0.3 }.sorted()
        var spaced: [Double] = []
        for mark in marks where spaced.last.map({ mark - $0 > 0.35 }) ?? true { spaced.append(mark) }
        if spaced.count > 80 {
            let step = Double(spaced.count) / 80
            spaced = (0..<80).map { spaced[Int(Double($0) * step)] }
        }
        return spaced
    }

    func applyStyle(_ style: StylePreset) {
        guard hasClip, duration > 0 else { return }
        let spaced = rhythmMarks(every: style.beatEvery)
        var list: [EffectModel] = []
        for (index, mark) in spaced.enumerated() {
            list += style.effects(mark, index, max(duration - mark, 0.1))
        }
        mutateAll { clips in
            clips[0].effects = list
            clips[0].colorGrade = style.grade.isNeutral ? nil : style.grade
            clips[0].motionBlur = style.motionBlur
            clips[0].sounds = style.sound.map { kind in spaced.map { SoundMark(id: UUID(), time: $0, kind: kind.rawValue, volume: 0.7) } }
            for index in clips.indices { clips[index].transition = index > 0 ? style.transition : nil }
        }
        appliedStyleID = style.id
        selectedEffectID = nil
        scheduleRebuild()
    }

    /// Pour StyleTemplate (autre fichier) : applique le changement puis reconstruit.
    func mutateAllForTemplate(_ change: (inout [ClipModel]) -> Void) {
        mutateAll(change)
        appliedStyleID = nil
        selectedEffectID = nil
        scheduleRebuild()
    }

    func clearStyle() {
        mutateAll { clips in
            clips[0].effects = []
            clips[0].colorGrade = nil
            clips[0].motionBlur = nil
            clips[0].sounds = nil
            for index in clips.indices { clips[index].transition = nil }
        }
        appliedStyleID = nil
        selectedEffectID = nil
        scheduleRebuild()
    }

    var currentTransition: CutTransition? { currentClip?.transition }

    func setTransition(type: Int?) {
        guard currentIndex > 0 else { return }
        mutateCurrent { clip in
            if let type {
                var value = clip.transition ?? CutTransition()
                value.type = type
                clip.transition = value
            } else {
                clip.transition = nil
            }
        }
        scheduleRebuild()
    }

    func setTransitionDuration(_ value: Double) {
        guard currentIndex > 0 else { return }
        mutateCurrent { $0.transition?.duration = value }
        scheduleRebuild()
    }

    func selectClip(_ index: Int) {
        guard spans.indices.contains(index) else { return }
        seek(to: spans[index].start)
    }

    /// Coupe le clip sous la tête de lecture en deux.
    func splitAtPlayhead() {
        guard hasClip, let clip = currentClip, spans.indices.contains(currentIndex), clip.hold == nil else { return }
        let index = currentIndex
        let cut = playheadSourceTime
        let low = (clip.trimIn ?? 0) + 0.2
        let high = (clip.trimOut ?? clip.sourceOut) - 0.2
        guard cut > low, cut < high else {
            errorMessage = "Place la tête de lecture à l'intérieur du clip, à plus de 0,2 s des bords."
            return
        }
        var right = clip
        right.id = UUID()
        stripGlobals(&right)
        right.trimIn = cut
        right.transition = nil
        mutateAll { clips in
            clips[index].trimOut = cut
            clips.insert(right, at: index + 1)
        }
        rebuildNow()
    }

    // MARK: - Image figée et rediffusion

    /// Décale ce qui se trouve après `time` de `delta` secondes (un clip vient d'être inséré).
    private func shiftGlobals(_ clip: inout ClipModel, after time: Double, by delta: Double) {
        for i in clip.effects.indices where clip.effects[i].start >= time - 0.001 { clip.effects[i].start += delta }
        if var texts = clip.texts {
            for i in texts.indices {
                if texts[i].start >= time - 0.001 { texts[i].start += delta }
                else if texts[i].start + texts[i].duration > time { texts[i].duration += delta }
            }
            clip.texts = texts
        }
        if var frames = clip.keyframes {
            for i in frames.indices where frames[i].time >= time - 0.001 { frames[i].time += delta }
            clip.keyframes = frames
        }
        if var marks = clip.sounds {
            for i in marks.indices where marks[i].time >= time - 0.001 { marks[i].time += delta }
            clip.sounds = marks
        }
    }

    /// Fige l'image sous la tête de lecture (clip du milieu) ; la suite est décalée.
    func freezeAtPlayhead(hold: Double = 0.8) {
        insertAtPlayhead(rewind: 0, hold: hold)
    }

    /// Rejoue la fin du plan au ralenti, avec un flash et un petit zoom.
    func replayAtPlayhead() {
        insertAtPlayhead(rewind: 0.5, hold: nil)
    }

    private func insertAtPlayhead(rewind: Double, hold: Double?) {
        guard hasClip, let clip = currentClip, spans.indices.contains(currentIndex) else { return }
        guard clip.hold == nil else { errorMessage = "Place la tête de lecture sur un clip normal."; return }
        let index = currentIndex
        let cut = playheadSourceTime
        let time = playhead
        let low = (clip.trimIn ?? 0) + max(rewind, 0.2)
        let high = (clip.trimOut ?? clip.sourceOut) - 0.2
        guard cut > low, cut < high else {
            errorMessage = "Place la tête de lecture à l'intérieur du clip, à plus de 0,2 s des bords."
            return
        }
        var middle = clip
        middle.id = UUID()
        stripGlobals(&middle)
        var right = middle
        right.id = UUID()
        right.trimIn = cut
        right.transition = nil
        let delta: Double
        if let hold {
            middle.trimIn = cut
            middle.trimOut = cut + 0.02
            middle.hold = hold
            middle.transition = nil
            delta = hold
        } else {
            middle.trimIn = cut - rewind
            middle.trimOut = cut
            middle.speed = 0.5
            middle.speedPoints = nil
            middle.transition = CutTransition(type: 0, duration: 0.15)
            delta = rewind / 0.5
        }
        mutateAll { clips in
            clips[index].trimOut = cut
            clips.insert(middle, at: index + 1)
            clips.insert(right, at: index + 2)
            shiftGlobals(&clips[0], after: time, by: delta)
            if hold == nil {
                clips[0].effects.append(.zoom(start: time, duration: delta, peak: 1.12))
                clips[0].sounds = (clips[0].sounds ?? []) + [SoundMark(id: UUID(), time: time + 0.05, kind: SoundKind.whoosh.rawValue)]
            }
        }
        rebuildNow()
    }

    func deleteCurrentClip() {
        guard clips.count > 1, spans.indices.contains(currentIndex) else { return }
        let index = currentIndex
        let target = index < clips.count - 1 ? spans[index].start : spans[index - 1].start
        restructure { $0.remove(at: index) }
        playhead = target
        rebuildNow()
    }

    func moveCurrentClip(by delta: Int) {
        let index = currentIndex
        let destination = index + delta
        guard clips.indices.contains(destination), spans.count == clips.count else { return }
        var order = Array(clips.indices)
        order.insert(order.remove(at: index), at: destination)
        let start = order.prefix(destination).reduce(0.0) { $0 + spans[$1].duration }
        restructure { clips in
            let moved = clips.remove(at: index)
            clips.insert(moved, at: destination)
        }
        playhead = start
        rebuildNow()
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
        guard hasClip, !clips.isEmpty else { return }
        do {
            let built = try await VideoPipeline.build(plan: plan)
            let player = ensurePlayer()
            let wasPlaying = isPlaying
            let resume = min(playhead, max(built.duration - 0.05, 0))

            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
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
            spans = built.spans
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

    /// Smash : zoom très rapide qui claque, avec secousse et aberration.
    func addSmash() {
        guard hasClip, duration > 0 else { return }
        let start = min(max(snap(playhead), 0), max(duration - 0.1, 0))
        let room = max(duration - start, 0.1)
        mutateClip { clip in
            var zoom = EffectModel.zoom(start: start, duration: min(0.3, room), peak: 1.7)
            zoom.curve = 2
            clip.effects.append(zoom)
            clip.effects.append(.shake(start: start, duration: min(0.25, room), amplitude: 0.02))
            clip.effects.append(.chroma(start: start, duration: min(0.3, room)))
        }
        selectedEffectID = nil
        scheduleRebuild()
    }

    /// Hole : plongée lente dans l'image, halo et aberration qui montent.
    func addHole() {
        guard hasClip, duration > 0 else { return }
        let start = min(max(snap(playhead), 0), max(duration - 0.1, 0))
        let room = max(duration - start, 0.1)
        mutateClip { clip in
            var zoom = EffectModel.zoom(start: start, duration: min(1.1, room), peak: 2.1)
            zoom.curve = 1
            clip.effects.append(zoom)
            clip.effects.append(.glow(start: start, duration: min(1.1, room), strength: 0.7))
            clip.effects.append(.chroma(start: start, duration: min(1.1, room)))
        }
        selectedEffectID = nil
        scheduleRebuild()
    }

    func addFlash() {
        addEffect(.flash(start: playhead))
    }

    /// Un seul geste : zoom, secousse, flash et halo sur l'impact.
    func addImpact() {
        guard hasClip, duration > 0 else { return }
        let start = min(max(snap(playhead), 0), max(duration - 0.1, 0))
        let room = max(duration - start, 0.1)
        mutateClip { clip in
            var zoom = EffectModel.zoom(start: start, duration: min(0.55, room), peak: 1.35)
            zoom.curve = 2
            clip.effects.append(zoom)
            clip.effects.append(.shake(start: start, duration: min(0.4, room), amplitude: 0.015))
            clip.effects.append(.flash(start: start, duration: min(0.15, room), strength: 0.3))
            clip.effects.append(.glow(start: start, duration: min(0.5, room), strength: 0.6))
        }
        selectedEffectID = nil
        scheduleRebuild()
    }

    func addGlow() {
        addEffect(.glow(start: playhead))
    }

    func addSparkles() {
        addEffect(.sparkles(start: playhead))
    }

    func addRing() {
        addEffect(.ring(start: playhead))
    }

    func addChroma() {
        addEffect(.chroma(start: playhead))
    }

    func addGlitch() {
        addEffect(.glitch(start: playhead))
    }

    func addShake() {
        addEffect(.shake(start: playhead))
    }

    private func addEffect(_ effect: EffectModel) {
        guard hasClip, duration > 0 else { return }
        var effect = effect
        effect.start = min(max(snap(playhead), 0), max(duration - 0.1, 0))
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
        mutateCurrent { $0.speed = clamped }
        scheduleRebuild()
    }

    // MARK: - Rampes de vitesse

    /// Temps source correspondant à la tête de lecture.
    private var playheadSourceTime: Double {
        guard spans.indices.contains(currentIndex) else { return playhead }
        let span = spans[currentIndex]
        return span.timeMap.sourceTime(atOutput: max(playhead - span.start, 0))
    }

    private var sourceDuration: Double {
        currentClip?.sourceOut ?? 0
    }

    private func setSpeedPoints(_ points: [SpeedPointModel]) {
        let cleaned = points.sorted { $0.time < $1.time }
        mutateCurrent { $0.speedPoints = cleaned.isEmpty ? nil : cleaned }
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

    /// Hero time : accélère, ralenti net sur l'impact, repart vite.
    func addHeroTime() {
        addRamp([(-0.5, 1.0), (-0.3, 2.2), (-0.05, 0.2), (0.6, 0.2), (0.9, 1.8), (1.2, 1.0)])
    }

    /// Souffle long : ralenti doux qui s'installe puis revient.
    func addSoftSlow() {
        addRamp([(-0.4, 1.0), (0, 0.5), (1.0, 0.5), (1.4, 1.0)])
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
        guard hasClip, let target = currentClip else { return }
        let id = target.id
        let fileName = target.mediaFileName
        let url = mediaURL(target)

        func setFlag(_ value: Bool) {
            mutateAll { clips in
                if let index = clips.firstIndex(where: { $0.id == id }) { clips[index].stabilizationEnabled = value }
            }
        }

        if !enabled {
            setFlag(false)
            scheduleRebuild()
            return
        }

        if let cached = stabilizationCache[fileName] ?? ProjectStore.loadStabilization(for: fileName) {
            stabilizationCache[fileName] = cached
            setFlag(true)
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
                stabilizationCache[fileName] = data
                setFlag(true)
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

    func export(preset: ExportPreset = .original) {
        guard hasClip, !isExporting else { return }
        player?.pause()
        isPlaying = false
        isExporting = true
        exportProgress = 0
        let plan = self.plan
        Task {
            do {
                let output = try await VideoPipeline.export(plan: plan, preset: preset) { [weak self] value in
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
        if hasClip {
            persist()
            let snapshot = project
            Task.detached { await ProjectStore.updateThumbnail(for: snapshot) }
        }
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
