//
//  EditorViewModel.swift
//  Logique de l'éditeur : AVPlayer, durée, tête de lecture, erreurs.
//  Séparée de la vue pour rester testable et évolutive.
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

    private var timeObserver: Any?

    init(project: ProjectModel? = nil) {
        if let project = project {
            self.project = project
            if let fileName = project.tracks.first?.clips.first?.mediaFileName {
                let url = ProjectStore.mediaDirectory.appendingPathComponent(fileName)
                loadClip(at: url)
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

    func loadClip(at url: URL) {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let current = player ?? AVPlayer()
        current.replaceCurrentItem(with: item)
        player = current
        observeTime(of: current)

        Task {
            do {
                let seconds = try await asset.load(.duration).seconds
                duration = max(seconds, 0)

                if project.tracks.isEmpty {
                    project.tracks = [TrackModel(id: UUID())]
                }
                project.tracks[0].clips = [
                    ClipModel(
                        id: UUID(),
                        mediaFileName: url.lastPathComponent,
                        sourceOut: duration
                    )
                ]
                project.modificationDate = Date()
                hasClip = true
                try? ProjectStore.save(project)
            } catch {
                errorMessage = "Impossible de lire ce clip : " + error.localizedDescription
            }
        }
    }

    func togglePlayback() {
        guard let player, hasClip else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
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

    /// À appeler quand l'éditeur disparaît : libère les ressources et sauvegarde.
    func stop() {
        player?.pause()
        isPlaying = false
        if let observer = timeObserver, let player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        project.modificationDate = Date()
        try? ProjectStore.save(project)
    }

    private func observeTime(of player: AVPlayer) {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
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
