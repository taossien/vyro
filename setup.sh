#!/bin/bash
# ============================================================
#  VYRO — Phase 1 : squelette fonctionnel MVP
#  Crée tous les fichiers Swift, le README, le .gitignore,
#  puis fait le commit et le push sur GitHub.
#
#  UTILISATION :
#    1. cd ~/Desktop && git clone https://github.com/taossien/vyro.git
#    2. cd vyro
#    3. Crée un fichier setup.sh avec CE contenu, puis :
#    bash setup.sh
# ============================================================
set -e

echo "VYRO — création des fichiers de la Phase 1..."

mkdir -p VYRO-Sources

# ------------------------------------------------------------
# .gitignore
# ------------------------------------------------------------
cat > .gitignore <<'VYRO_EOF'
# Xcode
DerivedData/
build/
*.xcuserstate
xcuserdata/
*.xcworkspace/xcuserdata/
.DS_Store
VYRO_EOF

# ------------------------------------------------------------
# README.md
# ------------------------------------------------------------
cat > README.md <<'VYRO_EOF'
# VYRO — Make every frame hit.

Éditeur vidéo mobile spécialisé gaming edit. iPhone / Swift / SwiftUI / AVFoundation.

## Phase 1 — Squelette fonctionnel MVP

Ce dépôt contient le code source Swift de la Phase 1 (dossier VYRO-Sources/) :
interface sombre VYRO, écran d'accueil avec liste de projets, éditeur avec
import de clip (Photos), lecture AVPlayer avec tête de lecture, modèle de
projet versionné (schemaVersion) et sauvegarde locale JSON.

## Mise en place dans Xcode (une seule fois)

1. Ouvrir Xcode, File > New > Project, iOS > App, Next.
   - Product Name : VYRO
   - Interface : SwiftUI — Language : Swift
   - Storage : None
2. Choisir l'emplacement : LE dossier vyro cloné (le projet est créé DANS ce dossier).
   ATTENTION : décocher "Create Git repository" (il existe déjà).
3. Dans le navigateur Xcode (colonne de gauche) :
   - Supprimer ContentView.swift ET VYROApp.swift du template, Move to Trash.
   - Glisser le dossier VYRO-Sources dans le navigateur :
     - "Copy items if needed" : DECOCHE (les fichiers restent versionnés par git),
     - Cocher la target VYRO.
4. Target VYRO, General, Minimum Deployments : iOS 16.0.
5. Brancher l'iPhone, sélectionner ton appareil comme destination, Cmd+R.

## Premier commit du projet Xcode

    cd vyro
    git add VYRO.xcodeproj VYRO-Sources README.md .gitignore
    git commit -m "Ajout projet Xcode + squelette Phase 1"
    git push

## Validation Phase 1 (checklist)

- [ ] L'app se lance sans planter.
- [ ] Le bouton + crée un projet et ouvre l'éditeur.
- [ ] L'icône d'import ouvre la photothèque filtrée sur les vidéos.
- [ ] Un clip importé s'affiche dans l'aperçu et se lit.
- [ ] La tête de lecture suit la lecture ; le slider permet de naviguer.
- [ ] La durée s'affiche ; l'heure se met à jour.
- [ ] Le projet apparaît dans la liste d'accueil après retour.
- [ ] Un clip illisible affiche un message d'erreur compréhensible.

## Structure du code

- VYROApp.swift        : Point d'entrée SwiftUI, thème sombre
- Theme.swift          : Couleurs et identité visuelle VYRO
- Models.swift         : Project / Track / Clip / Effect / Keyframe (Codable, versionné)
- ProjectStore.swift   : Sauvegarde/chargement JSON + gestion des médias
- MediaImporter.swift  : Sélecteur PHPicker (vidéos uniquement), copie locale
- EditorViewModel.swift: Logique : AVPlayer, durée, tête de lecture, erreurs
- EditorView.swift     : Éditeur : aperçu, contrôles de lecture, import
- HomeView.swift       : Accueil : liste des projets, création

## Prochaines phases

Phase 2 : zoom exportable (pipeline AVVideoComposition partagé préview/export).
VYRO_EOF

# ------------------------------------------------------------
# VYRO-Sources/VYROApp.swift
# ------------------------------------------------------------
cat > VYRO-Sources/VYROApp.swift <<'VYRO_EOF'
//
//  VYROApp.swift
//  Point d'entrée de l'application VYRO Studio.
//

import SwiftUI

@main
struct VYROApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}
VYRO_EOF

# ------------------------------------------------------------
# VYRO-Sources/Theme.swift
# ------------------------------------------------------------
cat > VYRO-Sources/Theme.swift <<'VYRO_EOF'
//
//  Theme.swift
//  Identité visuelle VYRO : interface sombre, accents violets et bleus.
//

import SwiftUI

enum Theme {
    static let background = Color(red: 0.07, green: 0.07, blue: 0.10)
    static let surface = Color(red: 0.12, green: 0.12, blue: 0.16)
    static let accent = Color(red: 0.58, green: 0.34, blue: 0.98)
    static let accentBlue = Color(red: 0.25, green: 0.55, blue: 1.00)
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.65)
}

/// Formate un temps en secondes vers "m:ss".
func timeString(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
VYRO_EOF

# ------------------------------------------------------------
# VYRO-Sources/Models.swift
# ------------------------------------------------------------
cat > VYRO-Sources/Models.swift <<'VYRO_EOF'
//
//  Models.swift
//  Modèle de données versionné du projet VYRO.
//  Conceptuel en Phase 1 : il structure déjà les clips et effets à venir.
//

import Foundation

/// Version du schéma de sauvegarde. Incrémenter à chaque évolution incompatible.
enum Schema {
    static let version = 1
}

struct KeyframeModel: Codable, Identifiable, Equatable {
    enum Interpolation: String, Codable {
        case linear, easeIn, easeOut, easeInOut, bezier
    }

    var id: UUID
    var parameterName: String
    var time: Double
    var value: Double
    var interpolation: Interpolation = .linear
}

struct EffectModel: Codable, Identifiable, Equatable {
    enum EffectType: String, Codable {
        case zoom, shake, flash, glitch, speed
    }

    var id: UUID
    var type: EffectType
    var enabled: Bool = true
    var order: Int = 0
    var parameters: [String: Double] = [:]
    var keyframes: [KeyframeModel] = []
    var effectVersion: Int = 1
}

struct ClipModel: Codable, Identifiable, Equatable {
    var id: UUID
    /// Nom du fichier copié dans le dossier Media local (jamais un chemin temporaire).
    var mediaFileName: String
    var timelineStart: Double = 0
    var sourceIn: Double = 0
    var sourceOut: Double = 0
    var speed: Double = 1.0
    var effects: [EffectModel] = []
}

struct TrackModel: Codable, Identifiable, Equatable {
    enum TrackType: String, Codable {
        case video, audio
    }

    var id: UUID
    var type: TrackType = .video
    var order: Int = 0
    var clips: [ClipModel] = []
}

struct ProjectModel: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var creationDate: Date
    var modificationDate: Date
    var frameRate: Double = 30
    var canvasWidth: Int = 1080
    var canvasHeight: Int = 1920
    var tracks: [TrackModel] = []
    var schemaVersion: Int = Schema.version
}
VYRO_EOF

# ------------------------------------------------------------
# VYRO-Sources/ProjectStore.swift
# ------------------------------------------------------------
cat > VYRO-Sources/ProjectStore.swift <<'VYRO_EOF'
//
//  ProjectStore.swift
//  Sauvegarde/chargement des projets (JSON) et gestion des fichiers médias.
//

import Foundation

enum ProjectStore {
    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var projectsDirectory: URL {
        let dir = documentsDirectory.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var mediaDirectory: URL {
        let dir = documentsDirectory.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func save(_ project: ProjectModel) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        let url = projectsDirectory.appendingPathComponent(project.id.uuidString + ".json")
        try data.write(to: url, options: .atomic)
    }

    static func delete(id: UUID) {
        let url = projectsDirectory.appendingPathComponent(id.uuidString + ".json")
        try? FileManager.default.removeItem(at: url)
    }

    static func loadAll() -> [ProjectModel] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ProjectModel? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(ProjectModel.self, from: data)
            }
            .sorted { $0.modificationDate > $1.modificationDate }
    }
}
VYRO_EOF

# ------------------------------------------------------------
# VYRO-Sources/MediaImporter.swift
# ------------------------------------------------------------
cat > VYRO-Sources/MediaImporter.swift <<'VYRO_EOF'
//
//  MediaImporter.swift
//  Sélecteur de vidéos (PHPicker) et copie locale durable du fichier.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct MediaImporter: UIViewControllerRepresentable {
    var onPicked: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: MediaImporter

        init(_ parent: MediaImporter) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController,
                    didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard let provider = results.first?.itemProvider,
                  provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
            else { return }

            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                guard let url = url else {
                    print("VYRO import erreur: " + (error?.localizedDescription ?? "inconnue"))
                    return
                }
                // L'URL temporaire n'est valide que dans ce bloc : on copie immédiatement.
                let destination = ProjectStore.mediaDirectory
                    .appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.copyItem(at: url, to: destination)
                    DispatchQueue.main.async { self.parent.onPicked(destination) }
                } catch {
                    print("VYRO copie média erreur: " + error.localizedDescription)
                }
            }
        }
    }
}
VYRO_EOF

# ------------------------------------------------------------
# VYRO-Sources/EditorViewModel.swift
# ------------------------------------------------------------
cat > VYRO-Sources/EditorViewModel.swift <<'VYRO_EOF'
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
VYRO_EOF

# ------------------------------------------------------------
# VYRO-Sources/EditorView.swift
# ------------------------------------------------------------
cat > VYRO-Sources/EditorView.swift <<'VYRO_EOF'
//
//  EditorView.swift
//  Écran principal : aperçu vidéo, contrôles de lecture, import.
//

import SwiftUI
import AVFoundation

struct EditorView: View {
    @StateObject private var vm: EditorViewModel

    init(project: ProjectModel? = nil) {
        _vm = StateObject(wrappedValue: EditorViewModel(project: project))
    }

    var body: some View {
        VStack(spacing: 0) {
            preview
            controls
            Spacer()
            infoBar
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(vm.project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    vm.showImporter = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel("Importer un clip")
            }
        }
        .sheet(isPresented: $vm.showImporter) {
            MediaImporter { url in
                vm.loadClip(at: url)
            }
        }
        .alert(
            "Erreur",
            isPresented: Binding(
                get: { vm.errorMessage != nil },
                set: { if !$0 { vm.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .onDisappear { vm.stop() }
    }

    private var preview: some View {
        GeometryReader { geo in
            ZStack {
                if let player = vm.player {
                    PlayerContainerView(player: player)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "film")
                            .font(.system(size: 44))
                            .foregroundColor(Theme.textSecondary)
                        Text("Importe un clip pour commencer")
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(Color.black)
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button {
                vm.togglePlayback()
            } label: {
                Image(systemName: vm.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(Theme.accent)
            }
            .disabled(!vm.hasClip)
            .accessibilityLabel(vm.isPlaying ? "Pause" : "Lecture")

            Slider(
                value: Binding(
                    get: { vm.playhead },
                    set: { vm.seek(to: $0) }
                ),
                in: 0...max(vm.duration, 0.1),
                onEditingChanged: { editing in vm.isScrubbing = editing }
            )
            .tint(Theme.accent)
            .disabled(!vm.hasClip)

            Text(timeString(vm.playhead))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .frame(minWidth: 40, alignment: .trailing)
        }
        .padding()
        .background(Theme.surface)
    }

    private var infoBar: some View {
        HStack {
            Label(timeString(vm.duration), systemImage: "clock")
            Spacer()
            Label(vm.hasClip ? "1080 x 1920" : "—", systemImage: "rectangle")
        }
        .font(.caption)
        .foregroundColor(Theme.textSecondary)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

// MARK: - Vue UIKit contenant l'AVPlayerLayer

struct PlayerContainerView: UIViewRepresentable {
    var player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerUIView {
        let view = PlayerContainerUIView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerContainerUIView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

final class PlayerContainerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
VYRO_EOF

# ------------------------------------------------------------
# VYRO-Sources/HomeView.swift
# ------------------------------------------------------------
cat > VYRO-Sources/HomeView.swift <<'VYRO_EOF'
//
//  HomeView.swift
//  Écran d'accueil : logo VYRO, liste des projets, création.
//

import SwiftUI

struct HomeView: View {
    @State private var projects: [ProjectModel] = []
    @State private var showNewProject = false

    var body: some View {
        NavigationStack {
            Group {
                if projects.isEmpty {
                    VStack(spacing: 14) {
                        Text("VYRO")
                            .font(.system(size: 52, weight: .black, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Theme.accent, Theme.accentBlue],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                        Text("Aucun projet pour l'instant.")
                            .foregroundColor(Theme.textSecondary)
                    }
                } else {
                    List {
                        ForEach(projects) { project in
                            NavigationLink {
                                EditorView(project: project)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(project.name)
                                        .foregroundColor(Theme.textPrimary)
                                    Text(project.modificationDate
                                        .formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundColor(Theme.textSecondary)
                                }
                            }
                            .listRowBackground(Theme.surface)
                        }
                        .onDelete(perform: deleteProjects)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("VYRO")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showNewProject = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .accessibilityLabel("Nouveau projet")
                }
            }
            .navigationDestination(isPresented: $showNewProject) {
                EditorView(project: nil)
            }
            .onAppear {
                projects = ProjectStore.loadAll()
            }
        }
    }

    private func deleteProjects(at offsets: IndexSet) {
        for index in offsets {
            ProjectStore.delete(id: projects[index].id)
        }
        projects.remove(atOffsets: offsets)
    }
}
VYRO_EOF

# ------------------------------------------------------------
# Commit et push
# ------------------------------------------------------------
git add VYRO-Sources README.md .gitignore
git commit -m "Phase 1 — squelette fonctionnel MVP : app sombre, accueil, import, lecture, modèle versionné"
if git push origin main; then
    echo ""
    echo "OK : VYRO Phase 1 poussee sur GitHub."
else
    echo ""
    echo "ATTENTION : le push a echoue (authentification ?). Lance 'git push' manuellement"
    echo "apres t'etre identifie (ou connecte ton compte GitHub dans Xcode :"
    echo "Xcode > Settings > Accounts)."
fi

echo ""
echo "Prochaine etape : ouvre le README.md pour les instructions Xcode."