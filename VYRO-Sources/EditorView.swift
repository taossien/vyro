//
//  EditorView.swift
//  Éditeur : aperçu tactile, timeline visuelle, barre d'outils en bas,
//  réglages qui n'apparaissent que pour l'outil choisi.
//

import SwiftUI
import AVFoundation
import UIKit
import UniformTypeIdentifiers

struct EditorView: View {
    @StateObject private var vm: EditorViewModel
    @State private var panel: ToolPanel?

    enum ToolPanel { case speed, stabilization, trim, music, render, look, text }
    @State private var showMusicPicker = false

    init(project: ProjectModel? = nil) {
        _vm = StateObject(wrappedValue: EditorViewModel(project: project))
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                preview
                    .frame(height: geo.size.height * 0.33)
                transport
                if vm.hasClip { clipStrip }
                EditorTimeline(vm: vm, onSelectEffect: { id in
                    panel = nil
                    vm.selectEffect(id: id)
                }, onSelectText: { id in
                    vm.selectedEffectID = nil
                    panel = .text
                    vm.selectText(id: id)
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
                .accessibilityLabel("Ajouter un clip")
            }
        }
        .sheet(isPresented: $vm.showImporter) {
            MediaImporter { url in
                vm.loadClip(at: url)
            }
        }
        .fileImporter(isPresented: $showMusicPicker, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result { vm.importMusic(from: url) }
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

    // MARK: Clips du montage

    private var clipStrip: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(vm.spans.enumerated()), id: \.offset) { index, span in
                        let current = index == vm.currentIndex
                        Button { vm.selectClip(index) } label: {
                            Text(String(index + 1) + " · " + String(format: "%.1f s", span.duration))
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(current ? Theme.accent : Color.white.opacity(0.08)))
                                .foregroundColor(current ? .white : Theme.textSecondary)
                        }
                    }
                }
            }
            Group {
                Button { haptic(); vm.splitAtPlayhead() } label: { Image(systemName: "scissors") }
                    .accessibilityLabel("Scinder le clip ici")
                Button { vm.moveCurrentClip(by: -1) } label: { Image(systemName: "arrow.left") }
                    .disabled(vm.currentIndex == 0)
                    .accessibilityLabel("Déplacer le clip vers la gauche")
                Button { vm.moveCurrentClip(by: 1) } label: { Image(systemName: "arrow.right") }
                    .disabled(vm.currentIndex >= vm.clips.count - 1)
                    .accessibilityLabel("Déplacer le clip vers la droite")
                Button(role: .destructive) { vm.deleteCurrentClip() } label: { Image(systemName: "trash") }
                    .disabled(vm.clips.count < 2)
                    .accessibilityLabel("Supprimer le clip")
                Button { vm.showImporter = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Ajouter un clip")
            }
            .font(.system(size: 16))
            .foregroundColor(Theme.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.surface)
    }

    // MARK: Barre d'outils

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 0) {
            toolButton("Impact", icon: "burst.fill", color: .yellow, active: false) {
                haptic()
                panel = nil
                vm.addImpact()
            }
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
            toolButton("Halo", icon: "sun.max.fill", color: .orange, active: vm.selectedEffect?.type == .glow) {
                haptic()
                panel = nil
                vm.addGlow()
            }
            toolButton("Couper", icon: "scissors", color: .orange, active: panel == .trim || vm.isTrimmed) {
                vm.selectedEffectID = nil
                panel = panel == .trim ? nil : .trim
            }
            toolButton("Vitesse", icon: "speedometer", color: .yellow, active: panel == .speed) {
                vm.selectedEffectID = nil
                panel = panel == .speed ? nil : .speed
            }
            toolButton("Stable", icon: "gyroscope", color: .green, active: panel == .stabilization || vm.stabilizationEnabled) {
                vm.selectedEffectID = nil
                panel = panel == .stabilization ? nil : .stabilization
            }
            toolButton("Texte", icon: "textformat", color: .white, active: panel == .text || !vm.texts.isEmpty) {
                vm.selectedEffectID = nil
                panel = panel == .text ? nil : .text
                if panel == .text, vm.texts.isEmpty { vm.addText() }
            }
            toolButton("Look", icon: "camera.filters", color: .purple, active: panel == .look || !vm.colorGrade.isNeutral) {
                vm.selectedEffectID = nil
                panel = panel == .look ? nil : .look
            }
            toolButton("Rendu", icon: "sparkles", color: .cyan, active: panel == .render) {
                vm.selectedEffectID = nil
                panel = panel == .render ? nil : .render
            }
            toolButton("Musique", icon: "music.note", color: .mint, active: panel == .music || vm.musicName != nil) {
                vm.selectedEffectID = nil
                panel = panel == .music ? nil : .music
            }
        }
        .padding(.horizontal, 8)
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
            .frame(width: 66)
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
        } else if panel == .render {
            panelContainer(title: "Rendu", icon: "sparkles") { renderPanel }
        } else if panel == .text {
            panelContainer(title: "Texte", icon: "textformat") { textPanel }
        } else if panel == .look {
            panelContainer(title: "Look", icon: "camera.filters") { lookPanel }
        } else if panel == .music {
            panelContainer(title: "Musique", icon: "music.note") { musicPanel }
        } else if panel == .trim {
            panelContainer(title: "Découpe", icon: "scissors") { trimPanel }
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
            } else if effect.type == .glow {
                sliderRow(
                    label: "Halo",
                    value: binding(id, get: { $0.intensity }, set: { $0.intensity = $1 }),
                    range: 0.2...2.0,
                    display: String(format: "%.0f %%", effect.intensity * 100)
                )
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
            Picker("Courbe", selection: Binding(
                get: { effect.curve },
                set: { value in vm.updateEffect(id: id) { $0.curve = value } }
            )) {
                Text("Punch").tag(0)
                Text("Doux").tag(1)
                Text("Claque").tag(2)
                Text("Linéaire").tag(3)
            }
            .pickerStyle(.segmented)
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

    // MARK: Rendu

    private var renderPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            sliderRow(label: "Flou",
                      value: Binding(get: { vm.motionBlurStrength }, set: { vm.setMotionBlur($0) }),
                      range: 0...2,
                      display: vm.motionBlurStrength < 0.05 ? "Aucun" : String(format: "x%.1f", vm.motionBlurStrength))
            Text("Flou de mouvement : les zooms et secousses rapides deviennent fluides, comme avec l'obturateur d'une caméra. 1 correspond au rendu cinéma, 0 le désactive.")
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
        }
    }

    // MARK: Texte et sous-titres

    private func chip(_ title: String, selected: Bool, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(selected ? tint.opacity(0.9) : Color.white.opacity(0.08)))
                .foregroundColor(selected ? .black : Theme.textSecondary)
        }
    }

    private var textPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(vm.texts.enumerated()), id: \.element.id) { index, item in
                        chip("T" + String(index + 1), selected: item.id == vm.selectedTextID) { vm.selectText(id: item.id) }
                    }
                    chip("+ Ajouter", selected: false) { vm.addText() }
                }
            }
            if let item = vm.selectedText {
                let id = item.id
                TextField("Ton texte", text: Binding(
                    get: { vm.selectedText?.text ?? "" },
                    set: { value in vm.updateText(id: id) { $0.text = value } }
                ))
                .textFieldStyle(.roundedBorder)
                sliderRow(label: "Début",
                          value: Binding(get: { item.start }, set: { v in vm.updateText(id: id) { $0.start = v } }),
                          range: 0...max(vm.duration - 0.3, 0.5), display: String(format: "%.1f s", item.start))
                sliderRow(label: "Durée",
                          value: Binding(get: { item.duration }, set: { v in vm.updateText(id: id) { $0.duration = v } }),
                          range: 0.3...max(min(vm.duration, 10), 1), display: String(format: "%.1f s", item.duration))
                sliderRow(label: "Taille",
                          value: Binding(get: { item.size }, set: { v in vm.updateText(id: id) { $0.size = v } }),
                          range: 0.04...0.2, display: String(format: "%.0f %%", item.size * 500))
                sliderRow(label: "Hauteur",
                          value: Binding(get: { 1 - item.y }, set: { v in vm.updateText(id: id) { $0.y = 1 - v } }),
                          range: 0.05...0.95, display: String(format: "%.0f %%", (1 - item.y) * 100))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(TextOverlay.fontNames.enumerated()), id: \.offset) { index, name in
                            chip(name, selected: (item.font ?? 0) == index, tint: .mint) { vm.updateText(id: id) { $0.font = index } }
                        }
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(TextOverlay.styleNames.enumerated()), id: \.offset) { index, name in
                            chip(name, selected: item.style == index) { vm.updateText(id: id) { $0.style = index } }
                        }
                        ForEach(Array(TextOverlay.animationNames.enumerated()), id: \.offset) { index, name in
                            chip(name, selected: item.animation == index, tint: .yellow) { vm.updateText(id: id) { $0.animation = index } }
                        }
                    }
                }
                HStack(spacing: 10) {
                    ForEach(Array(TextOverlay.palette.enumerated()), id: \.offset) { index, entry in
                        Button { vm.updateText(id: id) { $0.colorIndex = index } } label: {
                            Circle()
                                .fill(Color(red: entry.r, green: entry.g, blue: entry.b))
                                .frame(width: 28, height: 28)
                                .overlay(Circle().stroke(Color.white, lineWidth: item.colorIndex == index ? 3 : 0))
                        }
                    }
                    Spacer()
                    Button(role: .destructive) { vm.removeText(id: id) } label: { Image(systemName: "trash") }
                }
            }
        }
    }

    // MARK: Look (étalonnage)

    private var lookPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(ColorGrade.presets.enumerated()), id: \.offset) { _, preset in
                        let selected = vm.colorGrade == preset.grade
                        Button { haptic(); vm.setColorGrade(preset.grade) } label: {
                            Text(preset.name)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(selected ? Color.purple : Color.white.opacity(0.08)))
                                .foregroundColor(selected ? .white : Theme.textSecondary)
                        }
                    }
                }
            }
            sliderRow(label: "Lumière",
                      value: Binding(get: { vm.colorGrade.exposure }, set: { var g = vm.colorGrade; g.exposure = $0; vm.setColorGrade(g) }),
                      range: -1...1, display: String(format: "%+.1f", vm.colorGrade.exposure))
            sliderRow(label: "Contraste",
                      value: Binding(get: { vm.colorGrade.contrast }, set: { var g = vm.colorGrade; g.contrast = $0; vm.setColorGrade(g) }),
                      range: 0.5...1.6, display: String(format: "%.2f", vm.colorGrade.contrast))
            sliderRow(label: "Couleurs",
                      value: Binding(get: { vm.colorGrade.saturation }, set: { var g = vm.colorGrade; g.saturation = $0; vm.setColorGrade(g) }),
                      range: 0...2, display: String(format: "%.0f %%", vm.colorGrade.saturation * 100))
            sliderRow(label: "Chaleur",
                      value: Binding(get: { vm.colorGrade.warmth }, set: { var g = vm.colorGrade; g.warmth = $0; vm.setColorGrade(g) }),
                      range: -1...1, display: String(format: "%+.1f", vm.colorGrade.warmth))
            sliderRow(label: "Vignette",
                      value: Binding(get: { vm.colorGrade.vignette }, set: { var g = vm.colorGrade; g.vignette = $0; vm.setColorGrade(g) }),
                      range: 0...1, display: String(format: "%.0f %%", vm.colorGrade.vignette * 100))
        }
    }

    // MARK: Musique

    private var musicPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if vm.musicName == nil {
                Text("Ajoute un morceau : VYRO détecte son rythme, l'affiche sur la timeline et aimante tes effets dessus.")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
                actionButton("Choisir un morceau", icon: "music.note.list", tint: .mint) { showMusicPicker = true }
            } else {
                if vm.isAnalyzingBeats {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Détection du rythme…").font(.caption).foregroundColor(Theme.textSecondary)
                    }
                } else {
                    Text(String(format: "%d temps forts détectés", vm.beats.count))
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                }
                sliderRow(label: "Musique",
                          value: Binding(get: { vm.musicVolume }, set: { vm.setMusicVolume($0) }),
                          range: 0...1,
                          display: String(format: "%.0f %%", vm.musicVolume * 100))
                sliderRow(label: "Origine",
                          value: Binding(get: { vm.originalVolume }, set: { vm.setOriginalVolume($0) }),
                          range: 0...1,
                          display: String(format: "%.0f %%", vm.originalVolume * 100))
                sliderRow(label: "Départ",
                          value: Binding(get: { vm.musicOffset }, set: { vm.setMusicOffset($0) }),
                          range: 0...max((vm.beats.last ?? 30), 5),
                          display: preciseTimeString(vm.musicOffset))
                Toggle("Aimanter les effets sur le rythme", isOn: $vm.snapToBeats)
                    .font(.footnote)
                    .foregroundColor(Theme.textPrimary)
                    .tint(Theme.accent)
                HStack(spacing: 10) {
                    actionButton("Zoom / temps", icon: "wand.and.stars", tint: .mint) { vm.autoZoomOnBeats(every: 1) }
                    actionButton("Zoom / 2 temps", icon: "wand.and.stars", tint: .mint) { vm.autoZoomOnBeats(every: 2) }
                }
                HStack(spacing: 10) {
                    actionButton("Changer", icon: "arrow.triangle.2.circlepath", tint: Theme.accent) { showMusicPicker = true }
                    actionButton("Retirer", icon: "trash", tint: .red) { vm.removeMusic() }
                }
            }
        }
    }

    // MARK: Découpe

    private var trimPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            sliderRow(
                label: "Début",
                value: Binding(get: { vm.trimIn }, set: { vm.setTrimIn($0) }),
                range: 0...max(vm.fileDuration, 0.5),
                display: preciseTimeString(vm.trimIn)
            )
            sliderRow(
                label: "Fin",
                value: Binding(get: { vm.trimOut }, set: { vm.setTrimOut($0) }),
                range: 0...max(vm.fileDuration, 0.5),
                display: preciseTimeString(vm.trimOut)
            )
            HStack(spacing: 10) {
                actionButton("Début ici", icon: "arrow.right.to.line", tint: .orange) { vm.trimStartHere() }
                actionButton("Fin ici", icon: "arrow.left.to.line", tint: .orange) { vm.trimEndHere() }
            }
            if vm.isTrimmed {
                Button("Tout restaurer") { vm.resetTrim() }
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.orange)
            }
            Text("Les effets restent à leur position dans le montage : replace-les après une découpe.")
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
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
    var onSelectText: (UUID) -> Void

    private let laneHeight: CGFloat = 22
    private let laneSpacing: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let total = max(vm.duration, 0.01)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10).fill(Theme.surface)

                VStack(spacing: laneSpacing) {
                    effectLane([.zoom], color: Theme.accent, icon: "plus.magnifyingglass", width: width, total: total)
                    effectLane([.shake], color: Theme.accentBlue, icon: "waveform.path", width: width, total: total)
                    effectLane([.glitch], color: .pink, icon: "square.stack.3d.down.right", width: width, total: total)
                    effectLane([.flash, .glow], color: Color(white: 0.85), icon: "bolt.fill", width: width, total: total)
                    speedLane(width: width, total: total)
                    textLane(width: width, total: total)
                }
                .padding(.vertical, 8)

                ForEach(Array(vm.beatMarks.enumerated()), id: \.offset) { _, beat in
                    Rectangle()
                        .fill(Color.mint.opacity(0.35))
                        .frame(width: 1, height: geo.size.height)
                        .offset(x: CGFloat(beat / total) * width)
                        .allowsHitTesting(false)
                }

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
        .frame(height: laneHeight * 6 + laneSpacing * 5 + 16)
    }

    private func effectLane(_ types: [EffectModel.EffectType], color: Color, icon: String, width: CGFloat, total: Double) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.04))
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(color.opacity(0.5))
                .padding(.leading, 6)
            ForEach(vm.effects.filter { types.contains($0.type) }) { effect in
                EffectBlock(
                    effect: effect,
                    total: total,
                    width: width,
                    color: color,
                    selected: effect.id == vm.selectedEffectID,
                    onSelect: { onSelectEffect(effect.id) },
                    onMove: { newStart in vm.updateEffect(id: effect.id) { $0.start = vm.snap(newStart) } }
                )
            }
        }
        .frame(height: laneHeight)
        .clipped()
    }

    private func textLane(width: CGFloat, total: Double) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.04))
            Image(systemName: "textformat")
                .font(.system(size: 10))
                .foregroundColor(Color.white.opacity(0.4))
                .padding(.leading, 6)
            ForEach(vm.texts) { item in
                TextBlock(
                    item: item,
                    total: total,
                    width: width,
                    selected: item.id == vm.selectedTextID,
                    onSelect: { onSelectText(item.id) },
                    onMove: { newStart in vm.updateText(id: item.id) { $0.start = vm.snap(newStart) } }
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
            ForEach(Array(vm.spans.enumerated()), id: \.offset) { _, span in
                ForEach(Array(span.timeMap.slices.enumerated()), id: \.offset) { _, slice in
                    Rectangle()
                        .fill(slice.speed < 0.99 ? Theme.accentBlue : (slice.speed > 1.01 ? Color.orange : Color.clear))
                        .opacity(0.55)
                        .frame(width: max(CGFloat((slice.outputEnd - slice.outputStart) / total) * width, 1), height: laneHeight - 8)
                        .offset(x: CGFloat((span.start + slice.outputStart) / total) * width)
                }
            }
            // Limites entre les clips.
            ForEach(Array(vm.spans.dropFirst().enumerated()), id: \.offset) { _, span in
                Rectangle()
                    .fill(Color.white.opacity(0.8))
                    .frame(width: 2, height: laneHeight)
                    .offset(x: CGFloat(span.start / total) * width - 1)
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

/// Bloc de texte sur la timeline : toucher pour régler, glisser pour déplacer.
struct TextBlock: View {
    let item: TextOverlay
    let total: Double
    let width: CGFloat
    let selected: Bool
    let onSelect: () -> Void
    let onMove: (Double) -> Void

    @State private var dragX: CGFloat = 0

    var body: some View {
        let blockWidth = max(CGFloat(item.duration / total) * width, 24)
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.white.opacity(selected ? 0.95 : 0.6))
            .overlay(
                Text(item.text)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.black)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
            )
            .frame(width: blockWidth, height: 18)
            .offset(x: CGFloat(item.start / total) * width + dragX)
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { dragX = $0.translation.width }
                    .onEnded { value in
                        let newStart = item.start + Double(value.translation.width / width) * total
                        dragX = 0
                        onMove(min(max(newStart, 0), max(total - item.duration, 0)))
                        onSelect()
                    }
            )
            .onTapGesture(perform: onSelect)
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
            .frame(width: blockWidth, height: 18)
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
