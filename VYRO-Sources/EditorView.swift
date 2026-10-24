//
//  EditorView.swift
//  Écran principal : aperçu, lecture, timeline d'effets, vitesse, stabilisation, export.
//

import SwiftUI
import AVFoundation

struct EditorView: View {
    @StateObject private var vm: EditorViewModel

    init(project: ProjectModel? = nil) {
        _vm = StateObject(wrappedValue: EditorViewModel(project: project))
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                preview
                    .frame(height: geo.size.height * 0.40)
                controls
                ScrollView {
                    VStack(spacing: 18) {
                        EffectTimeline(
                            effects: vm.effects,
                            duration: vm.duration,
                            playhead: vm.playhead,
                            selected: vm.selectedEffectID
                        )
                        addButtons
                        effectList
                        inspector
                        speedSection
                        stabilizationSection
                        infoBar
                    }
                    .padding()
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(vm.project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    vm.export()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(!vm.hasClip || vm.isExporting || vm.isAnalyzing)
                .accessibilityLabel("Exporter")

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
        .sheet(isPresented: $vm.showExportDone) {
            ExportDoneView(url: vm.exportedURL)
        }
        .overlay { busyOverlay }
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

    // MARK: Aperçu et lecture

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
                        #if DEBUG
                        Button("Charger un clip de test") { vm.loadDemoClip() }
                            .buttonStyle(.bordered)
                        #endif
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

            Text(preciseTimeString(vm.playhead))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .padding()
        .background(Theme.surface)
    }

    // MARK: Effets

    private var addButtons: some View {
        HStack(spacing: 12) {
            addButton(title: "Zoom", icon: "plus.magnifyingglass", color: Theme.accent) {
                vm.addZoom()
            }
            addButton(title: "Shake", icon: "waveform.path", color: Theme.accentBlue) {
                vm.addShake()
            }
        }
    }

    private func addButton(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(color.opacity(0.25))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(!vm.hasClip)
    }

    @ViewBuilder
    private var effectList: some View {
        if vm.effects.isEmpty {
            Text("Place la tête de lecture, puis ajoute un Zoom ou un Shake.")
                .font(.footnote)
                .foregroundColor(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 8) {
                ForEach(vm.effects) { effect in
                    HStack {
                        Button {
                            vm.selectEffect(id: effect.id)
                        } label: {
                            HStack {
                                Image(systemName: effect.systemImage)
                                    .foregroundColor(effect.type == .zoom ? Theme.accent : Theme.accentBlue)
                                Text(effect.title)
                                    .foregroundColor(Theme.textPrimary)
                                Spacer()
                                Text(preciseTimeString(effect.start) + " · " + String(format: "%.1f s", effect.duration))
                                    .font(.caption)
                                    .foregroundColor(Theme.textSecondary)
                            }
                        }
                        Button(role: .destructive) {
                            vm.removeEffect(id: effect.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Supprimer l'effet")
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(effect.id == vm.selectedEffectID ? Theme.accent.opacity(0.25) : Theme.surface)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let effect = vm.selectedEffect {
            let id = effect.id
            VStack(alignment: .leading, spacing: 10) {
                Text("Réglages · " + effect.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)

                sliderRow(
                    label: "Début",
                    value: binding(id, get: { $0.start }, set: { $0.start = $1 }),
                    range: 0...max(vm.duration - 0.1, 0.2),
                    display: preciseTimeString(effect.start)
                )
                sliderRow(
                    label: "Durée",
                    value: binding(id, get: { $0.duration }, set: { $0.duration = $1 }),
                    range: 0.1...3,
                    display: String(format: "%.1f s", effect.duration)
                )
                if effect.type == .zoom {
                    sliderRow(
                        label: "Zoom",
                        value: binding(id, get: { $0.intensity }, set: { $0.intensity = $1 }),
                        range: 1.05...2.0,
                        display: String(format: "x%.2f", effect.intensity)
                    )
                } else {
                    sliderRow(
                        label: "Force",
                        value: binding(id, get: { $0.intensity }, set: { $0.intensity = $1 }),
                        range: 0.005...0.06,
                        display: String(format: "%.1f %%", effect.intensity * 100)
                    )
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
        }
    }

    private func binding(_ id: UUID,
                         get: @escaping (EffectModel) -> Double,
                         set: @escaping (inout EffectModel, Double) -> Void) -> Binding<Double> {
        Binding(
            get: { vm.effects.first(where: { $0.id == id }).map(get) ?? 0 },
            set: { newValue in vm.updateEffect(id: id) { set(&$0, newValue) } }
        )
    }

    private func sliderRow(label: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>,
                           display: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 48, alignment: .leading)
            Slider(value: value, in: range)
                .tint(Theme.accent)
            Text(display)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 60, alignment: .trailing)
        }
    }

    // MARK: Vitesse et stabilisation

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Vitesse", systemImage: "speedometer")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text(String(format: "x%.2f", vm.speed))
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(Theme.accent)
            }
            Slider(
                value: Binding(get: { vm.speed }, set: { vm.setSpeed($0) }),
                in: VideoPipeline.minSpeed...VideoPipeline.maxSpeed,
                step: 0.05
            )
            .tint(Theme.accent)
            .disabled(!vm.hasClip)

            HStack(spacing: 8) {
                ForEach([0.5, 1.0, 2.0], id: \.self) { preset in
                    Button(String(format: "x%.1f", preset)) { vm.setSpeed(preset) }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Theme.accent.opacity(0.25)))
                        .foregroundColor(.white)
                        .disabled(!vm.hasClip)
                }
                Spacer()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
    }

    private var stabilizationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { vm.stabilizationEnabled },
                set: { vm.setStabilization($0) }
            )) {
                Label("Stabilisation", systemImage: "gyroscope")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
            }
            .tint(Theme.accent)
            .disabled(!vm.hasClip || vm.isAnalyzing)

            Text("Retire les tremblements en gardant les mouvements voulus. L'image est légèrement recadrée.")
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
    }

    private var infoBar: some View {
        HStack {
            Label(timeString(vm.duration), systemImage: "clock")
            Spacer()
            Label(sizeText, systemImage: "rectangle")
        }
        .font(.caption)
        .foregroundColor(Theme.textSecondary)
        #if DEBUG
        .overlay(alignment: .bottom) {
            Text(vm.debugInfo).font(.system(size: 9, design: .monospaced)).foregroundColor(.yellow).offset(y: 14)
        }
        #endif
    }

    private var sizeText: String {
        guard vm.hasClip, vm.renderSize.width > 0 else { return "—" }
        return "\(Int(vm.renderSize.width)) x \(Int(vm.renderSize.height))"
    }

    // MARK: Chargement

    @ViewBuilder
    private var busyOverlay: some View {
        if vm.isExporting || vm.isAnalyzing {
            ZStack {
                Color.black.opacity(0.65).ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView(value: vm.isExporting ? vm.exportProgress : vm.analysisProgress)
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                        .frame(width: 220)
                    Text(vm.isExporting ? "Export en cours…" : "Analyse du mouvement…")
                        .foregroundColor(.white)
                }
                .padding(24)
                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
            }
        }
    }
}

// MARK: - Timeline des effets

struct EffectTimeline: View {
    let effects: [EffectModel]
    let duration: Double
    let playhead: Double
    let selected: UUID?

    var body: some View {
        GeometryReader { geo in
            let total = max(duration, 0.01)
            let width = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8).fill(Theme.surface)
                ForEach(effects) { effect in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(effect.type == .zoom ? Theme.accent : Theme.accentBlue)
                        .opacity(effect.id == selected ? 1 : 0.6)
                        .frame(width: max(CGFloat(effect.duration / total) * width, 6), height: 22)
                        .offset(x: CGFloat(effect.start / total) * width)
                }
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: 36)
                    .offset(x: min(CGFloat(playhead / total) * width, width - 2))
            }
        }
        .frame(height: 36)
    }
}

// MARK: - Export terminé

struct ExportDoneView: View {
    let url: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(Theme.accent)
            Text("Export terminé")
                .font(.title2.weight(.bold))
                .foregroundColor(Theme.textPrimary)
            Text("Utilise « Enregistrer la vidéo » dans le menu de partage pour l'ajouter à ta photothèque.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundColor(Theme.textSecondary)
            if let url {
                ShareLink(item: url) {
                    Label("Partager / Enregistrer", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent))
                        .foregroundColor(.white)
                }
            }
            Button("Fermer") { dismiss() }
                .foregroundColor(Theme.textSecondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .presentationDetents([.medium])
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
