//
//  EditorView.swift
//  Éditeur : aperçu tactile, timeline visuelle, barre d'outils en bas,
//  réglages qui n'apparaissent que pour l'outil choisi.
//

import SwiftUI
import AVFoundation
import UIKit

struct EditorView: View {
    @StateObject private var vm: EditorViewModel
    @State private var panel: ToolPanel?

    enum ToolPanel { case speed, stabilization }

    init(project: ProjectModel? = nil) {
        _vm = StateObject(wrappedValue: EditorViewModel(project: project))
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                preview
                    .frame(height: geo.size.height * 0.40)
                transport
                EditorTimeline(vm: vm, onSelectEffect: { id in
                    panel = nil
                    vm.selectEffect(id: id)
                })
                .padding(.horizontal, 12)
                .padding(.top, 8)
                contextPanel
                    .frame(maxHeight: .infinity, alignment: .top)
                toolbar
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(vm.project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    ForEach(ExportPreset.allCases) { preset in
                        Button {
                            vm.export(preset: preset)
                        } label: {
                            Label(preset.title + " : " + preset.detail, systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(!vm.hasClip || vm.isExporting || vm.isAnalyzing)
                .accessibilityLabel("Exporter")

                Button {
                    vm.showImporter = true
                } label: {
                    Image(systemName: "plus.rectangle.on.rectangle")
                }
                .accessibilityLabel("Changer de vidéo")
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

    // MARK: Aperçu (toucher pour lancer / mettre en pause)

    private var preview: some View {
        GeometryReader { geo in
            ZStack {
                if let player = vm.player, vm.hasClip {
                    PlayerContainerView(player: player)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { vm.togglePlayback() }
                    if !vm.isPlaying {
                        Image(systemName: "play.fill")
                            .font(.system(size: 34))
                            .foregroundColor(.white.opacity(0.85))
                            .padding(22)
                            .background(Circle().fill(Color.black.opacity(0.35)))
                            .allowsHitTesting(false)
                    }
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "film")
                            .font(.system(size: 44))
                            .foregroundColor(Theme.textSecondary)
                        Button {
                            vm.showImporter = true
                        } label: {
                            Label("Importer une vidéo", systemImage: "square.and.arrow.down")
                                .font(.headline)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 12)
                                .background(Capsule().fill(Theme.accent))
                                .foregroundColor(.white)
                        }
                        #if DEBUG
                        Button("Charger un clip de test") { vm.loadDemoClip() }
                            .font(.footnote)
                            .foregroundColor(Theme.textSecondary)
                        #endif
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(Color.black)
        }
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button {
                vm.togglePlayback()
            } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.accent))
                    .foregroundColor(.white)
            }
            .disabled(!vm.hasClip)
            .accessibilityLabel(vm.isPlaying ? "Pause" : "Lecture")

            Text(preciseTimeString(vm.playhead) + " / " + preciseTimeString(vm.duration))
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(Theme.textSecondary)

            Spacer()

            Button { vm.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!vm.canUndo)
                .accessibilityLabel("Annuler")
            Button { vm.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!vm.canRedo)
                .accessibilityLabel("Rétablir")
        }
        .font(.system(size: 18))
        .foregroundColor(Theme.textPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.surface)
    }

    // MARK: Barre d'outils

    private var toolbar: some View {
        HStack(spacing: 0) {
            toolButton("Zoom", icon: "plus.magnifyingglass", color: Theme.accent, active: vm.selectedEffect?.type == .zoom) {
                haptic()
                panel = nil
                vm.addZoom()
            }
            toolButton("Shake", icon: "waveform.path", color: Theme.accentBlue, active: vm.selectedEffect?.type == .shake) {
                haptic()
                panel = nil
                vm.addShake()
            }
            toolButton("Glitch", icon: "square.stack.3d.down.right", color: .pink, active: vm.selectedEffect?.type == .glitch) {
                haptic()
                panel = nil
                vm.addGlitch()
            }
            toolButton("Flash", icon: "bolt.fill", color: .white, active: vm.selectedEffect?.type == .flash) {
                haptic()
                panel = nil
                vm.addFlash()
            }
            toolButton("Vitesse", icon: "speedometer", color: .yellow, active: panel == .speed) {
                vm.selectedEffectID = nil
                panel = panel == .speed ? nil : .speed
            }
            toolButton("Stabiliser", icon: "gyroscope", color: .green, active: panel == .stabilization || vm.stabilizationEnabled) {
                vm.selectedEffectID = nil
                panel = panel == .stabilization ? nil : .stabilization
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Theme.surface.ignoresSafeArea(edges: .bottom))
    }

    private func toolButton(_ title: String, icon: String, color: Color, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 21))
                    .foregroundColor(active ? color : Theme.textPrimary)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundColor(active ? color : Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(!vm.hasClip)
    }

    private func haptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: Panneau contextuel

    @ViewBuilder
    private var contextPanel: some View {
        if let effect = vm.selectedEffect {
            panelContainer(title: effect.title, icon: effect.systemImage) { effectPanel(effect) }
        } else if panel == .speed {
            panelContainer(title: "Vitesse", icon: "speedometer") { speedPanel }
        } else if panel == .stabilization {
            panelContainer(title: "Stabilisation", icon: "gyroscope") { stabilizationPanel }
        } else {
            hint
        }
    }

    private var hint: some View {
        VStack(spacing: 6) {
            Text(vm.hasClip ? "Place la tête de lecture sur l'impact, puis touche un outil." : "Importe une vidéo pour commencer.")
                .font(.footnote)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if vm.hasClip {
                Text("Glisse un effet sur la timeline pour le déplacer.")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary.opacity(0.7))
            }
        }
        .padding(.top, 18)
        .padding(.horizontal, 24)
    }

    private func panelContainer<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button {
                    panel = nil
                    vm.selectedEffectID = nil
                } label: {
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(Theme.textSecondary)
                }
                .accessibilityLabel("Fermer")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            ScrollView {
                content()
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .background(Theme.surface.opacity(0.6))
    }

    // MARK: Réglages d'un effet

    private func effectPanel(_ effect: EffectModel) -> some View {
        let id = effect.id
        return VStack(spacing: 12) {
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
                Picker("Courbe", selection: Binding(
                    get: { effect.curve },
                    set: { value in vm.updateEffect(id: id) { $0.curve = value } }
                )) {
                    Text("Punch").tag(0)
                    Text("Doux").tag(1)
                    Text("Claque").tag(2)
                }
                .pickerStyle(.segmented)
            } else if effect.type == .flash {
                sliderRow(
                    label: "Blanc",
                    value: binding(id, get: { $0.intensity }, set: { $0.intensity = $1 }),
                    range: 0.2...1.0,
                    display: String(format: "%.0f %%", effect.intensity * 100)
                )
            } else {
                sliderRow(
                    label: "Force",
                    value: binding(id, get: { $0.intensity }, set: { $0.intensity = $1 }),
                    range: 0.005...0.06,
                    display: String(format: "%.1f %%", effect.intensity * 100)
                )
            }
            HStack(spacing: 10) {
                actionButton("Dupliquer", icon: "plus.square.on.square", tint: Theme.accent) {
                    vm.duplicateEffect(id: id)
                }
                actionButton("Supprimer", icon: "trash", tint: .red) {
                    vm.removeEffect(id: id)
                }
            }
        }
    }

    private func actionButton(_ title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.22)))
                .foregroundColor(.white)
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

    // MARK: Vitesse

    private var speedPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                rampButton("Slow-mo punch", icon: "tortoise.fill") { vm.addSlowMoPunch() }
                rampButton("Burst x2.5", icon: "hare.fill") { vm.addSpeedBurst() }
            }

            if vm.speedPoints.isEmpty {
                Text("Place la tête de lecture sur l'impact puis choisis une rampe : la vitesse change en douceur autour de ce moment.")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)

                sliderRow(
                    label: "Globale",
                    value: Binding(get: { vm.speed }, set: { vm.setSpeed($0) }),
                    range: VideoPipeline.minSpeed...VideoPipeline.maxSpeed,
                    display: String(format: "x%.2f", vm.speed)
                )
                HStack(spacing: 8) {
                    ForEach([0.5, 1.0, 2.0], id: \.self) { preset in
                        Button(String(format: "x%.1f", preset)) { vm.setSpeed(preset) }
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Theme.accent.opacity(0.25)))
                            .foregroundColor(.white)
                    }
                }
            } else {
                HStack {
                    Text("Rampe active : elle remplace la vitesse globale.")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                    Spacer()
                    Button("Tout effacer") { vm.clearSpeedPoints() }
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.yellow)
                }
                ForEach(vm.speedPoints) { point in
                    HStack {
                        Text(preciseTimeString(point.time))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 56, alignment: .leading)
                        Slider(
                            value: Binding(
                                get: { point.speed },
                                set: { vm.updateSpeedPoint(id: point.id, speed: $0) }
                            ),
                            in: TimeMap.minSpeed...TimeMap.maxSpeed
                        )
                        .tint(Color.yellow)
                        Text(String(format: "x%.2f", point.speed))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 50, alignment: .trailing)
                        Button {
                            vm.removeSpeedPoint(id: point.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(Theme.textSecondary)
                        }
                        .accessibilityLabel("Supprimer le point de vitesse")
                    }
                }
                rampButton("Ajouter un point ici", icon: "plus.circle") {
                    vm.addSpeedPoint(speed: 1)
                }
            }
        }
    }

    private func rampButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.2)))
                .foregroundColor(.white)
        }
    }

    // MARK: Stabilisation

    private var stabilizationPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { vm.stabilizationEnabled },
                set: { vm.setStabilization($0) }
            )) {
                Text("Stabiliser la vidéo")
                    .foregroundColor(Theme.textPrimary)
            }
            .tint(Theme.accent)
            .disabled(vm.isAnalyzing)

            Text("Retire les tremblements en gardant les mouvements voulus. L'image est légèrement recadrée. L'analyse prend quelques secondes, une seule fois.")
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
            #if DEBUG
            if !vm.debugInfo.isEmpty {
                Text(vm.debugInfo)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.yellow)
            }
            #endif
        }
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

// MARK: - Timeline : pistes Zoom / Shake / Vitesse, tête de lecture glissable

struct EditorTimeline: View {
    @ObservedObject var vm: EditorViewModel
    var onSelectEffect: (UUID) -> Void

    private let laneHeight: CGFloat = 26
    private let laneSpacing: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let total = max(vm.duration, 0.01)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10).fill(Theme.surface)

                VStack(spacing: laneSpacing) {
                    effectLane(.zoom, color: Theme.accent, icon: "plus.magnifyingglass", width: width, total: total)
                    effectLane(.shake, color: Theme.accentBlue, icon: "waveform.path", width: width, total: total)
                    effectLane(.glitch, color: .pink, icon: "square.stack.3d.down.right", width: width, total: total)
                    effectLane(.flash, color: Color(white: 0.85), icon: "bolt.fill", width: width, total: total)
                    speedLane(width: width, total: total)
                }
                .padding(.vertical, 8)

                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: geo.size.height)
                    .offset(x: min(max(CGFloat(vm.playhead / total) * width - 1, 0), width - 2))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard vm.hasClip else { return }
                        vm.isScrubbing = true
                        let fraction = min(max(Double(value.location.x / width), 0), 1)
                        vm.seek(to: fraction * total)
                    }
                    .onEnded { _ in vm.isScrubbing = false }
            )
        }
        .frame(height: laneHeight * 5 + laneSpacing * 4 + 16)
    }

    private func effectLane(_ type: EffectModel.EffectType, color: Color, icon: String, width: CGFloat, total: Double) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.04))
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(color.opacity(0.5))
                .padding(.leading, 6)
            ForEach(vm.effects.filter { $0.type == type }) { effect in
                EffectBlock(
                    effect: effect,
                    total: total,
                    width: width,
                    color: color,
                    selected: effect.id == vm.selectedEffectID,
                    onSelect: { onSelectEffect(effect.id) },
                    onMove: { newStart in vm.updateEffect(id: effect.id) { $0.start = newStart } }
                )
            }
        }
        .frame(height: laneHeight)
        .clipped()
    }

    private func speedLane(width: CGFloat, total: Double) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.04))
            Image(systemName: "speedometer")
                .font(.system(size: 10))
                .foregroundColor(Color.yellow.opacity(0.5))
                .padding(.leading, 6)
            if let map = vm.timeMap {
                ForEach(Array(map.slices.enumerated()), id: \.offset) { _, slice in
                    Rectangle()
                        .fill(slice.speed < 0.99 ? Theme.accentBlue : (slice.speed > 1.01 ? Color.orange : Color.clear))
                        .opacity(0.55)
                        .frame(width: max(CGFloat((slice.outputEnd - slice.outputStart) / total) * width, 1), height: laneHeight - 8)
                        .offset(x: CGFloat(slice.outputStart / total) * width)
                }
            }
            ForEach(Array(vm.speedMarks.enumerated()), id: \.offset) { _, mark in
                Image(systemName: "diamond.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.yellow)
                    .offset(x: CGFloat(mark / total) * width - 4.5)
            }
        }
        .frame(height: laneHeight)
        .clipped()
    }
}

/// Bloc d'effet : on le touche pour le régler, on le glisse pour le déplacer.
struct EffectBlock: View {
    let effect: EffectModel
    let total: Double
    let width: CGFloat
    let color: Color
    let selected: Bool
    let onSelect: () -> Void
    let onMove: (Double) -> Void

    @State private var dragX: CGFloat = 0

    var body: some View {
        let blockWidth = max(CGFloat(effect.duration / total) * width, 16)
        RoundedRectangle(cornerRadius: 6)
            .fill(color.opacity(selected ? 1 : 0.7))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white, lineWidth: selected ? 2 : 0))
            .frame(width: blockWidth, height: 22)
            .offset(x: CGFloat(effect.start / total) * width + dragX)
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { dragX = $0.translation.width }
                    .onEnded { value in
                        let newStart = effect.start + Double(value.translation.width / width) * total
                        dragX = 0
                        onMove(min(max(newStart, 0), max(total - effect.duration, 0)))
                        onSelect()
                    }
            )
            .onTapGesture(perform: onSelect)
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
