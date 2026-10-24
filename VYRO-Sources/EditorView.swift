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
