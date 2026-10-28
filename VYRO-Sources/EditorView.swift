//
//  EditorView.swift
//  Éditeur : aperçu tactile, timeline visuelle, barre d'outils en bas,
//  réglages qui n'apparaissent que pour l'outil choisi.
//

import SwiftUI
import AVFoundation
import UIKit
import UniformTypeIdentifiers
import Photos
import PhotosUI

struct EditorView: View {
    @StateObject private var vm: EditorViewModel
    @State private var panel: ToolPanel?
    @State private var stickerPick: PhotosPickerItem?

    enum ToolPanel { case speed, stabilization, trim, music, render, look, text, motion, transition, style, sounds }
    @AppStorage("vyro.advanced") private var advanced = false
    @State private var showFilePicker = false
    @State private var showTemplatePicker = false
    @State private var templateURL: URL?
    @State private var pickingMusic = true

    init(project: ProjectModel? = nil) {
        _vm = StateObject(wrappedValue: EditorViewModel(project: project))
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                preview
                    .frame(height: geo.size.height * ((panel != nil || vm.selectedEffectID != nil) ? 0.3 : 0.42))
                transport
                if vm.hasClip { clipStrip }
                EditorTimeline(vm: vm, onSelectEffect: { id in
                    panel = nil
                    vm.selectEffect(id: id)
                }, onSelectText: { id in
                    vm.selectedEffectID = nil
                    panel = .text
                    vm.selectText(id: id)
                }, onSelectKeyframe: { id in
                    vm.selectedEffectID = nil
                    panel = .motion
                    vm.selectKeyframe(id: id)
                }, onSelectSound: { id in
                    vm.selectedEffectID = nil
                    panel = .sounds
                    vm.selectedSoundID = id
                }, advanced: advanced)
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
                Button {
                    advanced.toggle()
                    if !advanced { panel = nil; vm.selectedEffectID = nil }
                } label: {
                    Image(systemName: advanced ? "slider.horizontal.3" : "wand.and.stars")
                }
                .accessibilityLabel(advanced ? "Passer en mode simple" : "Passer en mode avancé")
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
            MediaImporter(onStart: { vm.isImporting = true }) { urls in
                vm.loadClips(urls)
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.audio, .movie, .mpeg4Movie, .quickTimeMovie]) { result in
            guard case .success(let url) = result else { return }
            if pickingMusic { vm.importMusic(from: url) } else { vm.importVideoFile(from: url) }
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
                    if panel == .text, let sticker = vm.selectedSticker, vm.renderSize.width > 0 {
                        stickerHandle(sticker, in: geo.size)
                    }
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
                        Button("Depuis Fichiers") { pickingMusic = false; showFilePicker = true }
                            .font(.footnote)
                            .foregroundColor(Theme.textSecondary)
                        #if DEBUG
                        Button("Charger un clip de test") { vm.loadDemoClip() }
                            .font(.footnote)
                            .foregroundColor(Theme.textSecondary)
                        #endif
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(name: "preview")
            .background(Color.black)
        }
    }

    /// Cadre pointillé du calque sélectionné : on le glisse du doigt pour le placer.
    private func stickerHandle(_ item: StickerOverlay, in size: CGSize) -> some View {
        let rs = vm.renderSize
        let k = min(size.width / rs.width, size.height / rs.height)
        let vw = rs.width * k, vh = rs.height * k
        let ox = (size.width - vw) / 2, oy = (size.height - vh) / 2
        let bw = max(item.size * vw, 24)
        let bh = max(item.aspect * bw, 24)
        let id = item.id
        return Rectangle()
            .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .background(Color.orange.opacity(0.08))
            .frame(width: bw, height: bh)
            .contentShape(Rectangle())
            .position(x: ox + item.x * vw, y: oy + item.y * vh)
            .gesture(
                DragGesture(coordinateSpace: .named("preview"))
                    .onChanged { value in
                        let x = min(max((value.location.x - ox) / vw, 0), 1)
                        let y = min(max((value.location.y - oy) / vh, 0), 1)
                        vm.updateSticker(id: id) { $0.x = x; $0.y = y }
                    }
            )
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
                            Text((vm.clips.indices.contains(index) && index > 0 && vm.clips[index].transition != nil ? "⚡" : "")
                                + String(index + 1) + " · " + String(format: "%.1f s", span.duration))
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
                Button { haptic(); vm.freezeAtPlayhead() } label: { Image(systemName: "pause.rectangle") }
                    .accessibilityLabel("Figer l'image ici")
                Button { haptic(); vm.replayAtPlayhead() } label: { Image(systemName: "gobackward") }
                    .accessibilityLabel("Rejouer au ralenti")
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
            toolButton("Style", icon: "wand.and.stars", color: Theme.accent, active: panel == .style || vm.appliedStyleID != nil) {
                vm.selectedEffectID = nil
                panel = panel == .style ? nil : .style
            }
            toolButton("Sons", icon: "speaker.wave.3.fill", color: .mint, active: panel == .sounds || !vm.sounds.isEmpty) {
                vm.selectedEffectID = nil
                panel = panel == .sounds ? nil : .sounds
            }
            if advanced {
            toolButton("Zoom", icon: "plus.magnifyingglass", color: Theme.accent, active: vm.selectedEffect?.type == .zoom) {
                haptic()
                panel = nil
                vm.addZoom()
            }
            toolButton("Smash", icon: "arrow.up.left.and.arrow.down.right", color: .red, active: false) {
                haptic()
                panel = nil
                vm.addSmash()
            }
            toolButton("Coupe auto", icon: "scissors.badge.ellipsis", color: .green, active: false) {
                haptic()
                panel = nil
                vm.autoCutOnBeats()
            }
            toolButton("Hole", icon: "scope", color: .purple, active: false) {
                haptic()
                panel = nil
                vm.addHole()
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
            toolButton("Étincelles", icon: "sparkles", color: .cyan, active: vm.selectedEffect?.type == .sparkles) {
                haptic()
                panel = nil
                vm.addSparkles()
            }
            toolButton("Anneau", icon: "circle.dashed", color: .mint, active: vm.selectedEffect?.type == .ring) {
                haptic()
                panel = nil
                vm.addRing()
            }
            toolButton("Aberration", icon: "circle.lefthalf.filled.righthalf.striped.horizontal", color: .red, active: vm.selectedEffect?.type == .chroma) {
                haptic()
                panel = nil
                vm.addChroma()
            }
            }
            toolButton("Couper", icon: "scissors", color: .orange, active: panel == .trim || vm.isTrimmed) {
                vm.selectedEffectID = nil
                panel = panel == .trim ? nil : .trim
            }
            toolButton("Vitesse", icon: "speedometer", color: .yellow, active: panel == .speed) {
                vm.selectedEffectID = nil
                panel = panel == .speed ? nil : .speed
            }
            if advanced {
            toolButton("Stable", icon: "gyroscope", color: .green, active: panel == .stabilization || vm.stabilizationEnabled) {
                vm.selectedEffectID = nil
                panel = panel == .stabilization ? nil : .stabilization
            }
            toolButton("Transition", icon: "arrow.left.arrow.right", color: .orange, active: panel == .transition || vm.clips.contains { $0.transition != nil }) {
                vm.selectedEffectID = nil
                panel = panel == .transition ? nil : .transition
            }
            toolButton("Mouvement", icon: "arrow.up.left.and.arrow.down.right", color: .cyan, active: panel == .motion || !vm.keyframes.isEmpty) {
                vm.selectedEffectID = nil
                panel = panel == .motion ? nil : .motion
            }
            }
            toolButton("Texte", icon: "textformat", color: .white, active: panel == .text || !vm.texts.isEmpty) {
                vm.selectedEffectID = nil
                panel = panel == .text ? nil : .text
            }
            toolButton("Look", icon: "camera.filters", color: .purple, active: panel == .look || !vm.colorGrade.isNeutral) {
                vm.selectedEffectID = nil
                panel = panel == .look ? nil : .look
            }
            if advanced {
            toolButton("Rendu", icon: "sparkles", color: .cyan, active: panel == .render) {
                vm.selectedEffectID = nil
                panel = panel == .render ? nil : .render
            }
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
        } else if panel == .sounds {
            panelContainer(title: "Sons", icon: "speaker.wave.3.fill") { soundsPanel }
        } else if panel == .style {
            panelContainer(title: "Style", icon: "wand.and.stars") { stylePanel }
        } else if panel == .render {
            panelContainer(title: "Rendu", icon: "sparkles") { renderPanel }
        } else if panel == .transition {
            panelContainer(title: "Transition", icon: "arrow.left.arrow.right") { transitionPanel }
        } else if panel == .motion {
            panelContainer(title: "Mouvement", icon: "arrow.up.left.and.arrow.down.right") { motionPanel }
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
        VStack(spacing: 14) {
            if !vm.hasClip {
                Button { vm.showImporter = true } label: {
                    Label("Importer mes clips", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.accent))
                        .foregroundColor(.white)
                }
                Text("Choisis une ou plusieurs vidéos de jeu.")
                    .font(.footnote)
                    .foregroundColor(Theme.textSecondary)
            } else {
                Text("3 étapes pour un montage qui claque")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Theme.textSecondary)
                HStack(spacing: 10) {
                    hubStep("1", "Style", icon: "wand.and.stars", done: vm.appliedStyleID != nil) { panel = .style }
                    hubStep("2", "Musique", icon: "music.note", done: vm.musicName != nil) { panel = .music }
                    hubStep("3", "Exporter", icon: "square.and.arrow.up", done: false) { panel = .render }
                }
                if !advanced {
                    Text("Besoin de plus ? Touche la baguette en haut pour le mode avancé.")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(.top, 18)
        .padding(.horizontal, 24)
    }

    private func hubStep(_ number: String, _ title: String, icon: String, done: Bool, action: @escaping () -> Void) -> some View {
        Button { haptic(); vm.selectedEffectID = nil; action() } label: {
            VStack(spacing: 6) {
                Image(systemName: done ? "checkmark.circle.fill" : icon)
                    .font(.title2)
                    .foregroundColor(done ? .green : Theme.accent)
                Text("\(number). \(title)")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
        }
    }

    private var soundsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Touche un son pour le poser à la tête de lecture.")
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SoundKind.allCases) { kind in
                        Button { haptic(); vm.addSound(kind) } label: {
                            VStack(spacing: 4) {
                                Image(systemName: kind.icon).font(.title3)
                                Text(kind.title).font(.caption2.weight(.semibold))
                            }
                            .frame(width: 74)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
                            .foregroundColor(.mint)
                        }
                    }
                }
            }
            if let mark = vm.selectedSound {
                let id = mark.id
                Text(SoundKind(rawValue: mark.kind)?.title ?? "Son")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                sliderRow(label: "Volume",
                          value: Binding(get: { mark.volume }, set: { v in vm.updateSound(id: id) { $0.volume = v } }),
                          range: 0.05...1, display: String(format: "%.0f %%", mark.volume * 100))
                sliderRow(label: "Instant",
                          value: Binding(get: { mark.time }, set: { v in vm.updateSound(id: id) { $0.time = vm.snap(v) } }),
                          range: 0...max(vm.duration, 0.5), display: String(format: "%.1f s", mark.time))
                actionButton("Supprimer ce son", icon: "trash", tint: .red) { vm.removeSound(id: id) }
            }
            actionButton("Sur chaque temps fort : Impact", icon: "metronome", tint: .mint) { vm.addSoundsOnBeats(.impact) }
            actionButton("Sur chaque temps fort : Whoosh", icon: "metronome", tint: .mint) { vm.addSoundsOnBeats(.whoosh) }
            if !vm.sounds.isEmpty {
                Text(String(vm.sounds.count) + " sons posés")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
                Button("Tout retirer") { haptic(); vm.clearSounds() }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.red)
            }
        }
    }

    private var stylePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Un point de départ : tout reste modifiable ensuite, effet par effet.")
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(StylePreset.all) { style in
                        let selected = vm.appliedStyleID == style.id
                        Button { haptic(); vm.applyStyle(style) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Image(systemName: style.icon).font(.title3)
                                Text(style.name).font(.subheadline.weight(.bold))
                                Text(style.blurb).font(.caption2).lineLimit(3)
                                    .multilineTextAlignment(.leading)
                            }
                            .frame(width: 130, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 14).fill(selected ? Theme.accent : Color.white.opacity(0.08)))
                            .foregroundColor(selected ? .white : Theme.textSecondary)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                if let url = templateURL {
                    ShareLink(item: url) {
                        Label("Partager mon style", systemImage: "square.and.arrow.up")
                            .font(.caption.weight(.semibold))
                    }
                }
                Button { showTemplatePicker = true } label: {
                    Label("Importer un style", systemImage: "square.and.arrow.down")
                        .font(.caption.weight(.semibold))
                }
                Spacer()
                if vm.appliedStyleID != nil {
                    Button("Retirer le style") { haptic(); vm.clearStyle() }
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.red)
                }
            }
        }
        .onAppear { templateURL = vm.styleTemplateFile() }
        .onChange(of: vm.effects) { _ in templateURL = vm.styleTemplateFile() }
        .fileImporter(isPresented: $showTemplatePicker, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            vm.importStyleTemplate(from: url)
        }
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
            } else if effect.type == .sparkles || effect.type == .ring {
                sliderRow(
                    label: effect.type == .ring ? "Éclat" : "Quantité",
                    value: binding(id, get: { $0.intensity }, set: { $0.intensity = $1 }),
                    range: 0.3...2.5,
                    display: String(format: "%.0f %%", effect.intensity * 100)
                )
                if effect.type == .ring {
                    sliderRow(
                        label: "Pente",
                        value: binding(id, get: { $0.tilt }, set: { $0.tilt = $1 }),
                        range: 0.1...1,
                        display: String(format: "%.0f %%", effect.tilt * 100)
                    )
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(TextOverlay.palette.enumerated()), id: \.offset) { index, entry in
                            chip(entry.name, selected: effect.colorIndex == index, tint: .cyan) {
                                vm.updateEffect(id: id) { $0.colorIndex = index }
                            }
                        }
                    }
                }
            } else if effect.type == .chroma {
                sliderRow(
                    label: "Écart",
                    value: binding(id, get: { $0.intensity }, set: { $0.intensity = $1 }),
                    range: 0.003...0.04,
                    display: String(format: "%.1f %%", effect.intensity * 100)
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
            HStack(spacing: 8) {
                rampButton("Hero time", icon: "bolt.horizontal.fill") { vm.addHeroTime() }
                rampButton("Ralenti doux", icon: "wind") { vm.addSoftSlow() }
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

    // MARK: Transitions entre clips

    private var transitionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if vm.currentIndex == 0 {
                Text(vm.clips.count > 1
                     ? "Choisis un clip après le premier (barre des clips) : la transition se place à son entrée."
                     : "Ajoute ou scinde un clip pour pouvoir placer une transition entre deux clips.")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            } else {
                Text("Transition à l'entrée du clip " + String(vm.currentIndex + 1))
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip("Aucune", selected: vm.currentTransition == nil, tint: .orange) { vm.setTransition(type: nil) }
                        ForEach(Array(CutTransition.names.enumerated()), id: \.offset) { index, name in
                            chip(name, selected: vm.currentTransition?.type == index, tint: .orange) {
                                haptic()
                                vm.setTransition(type: index)
                            }
                        }
                    }
                }
                if let transition = vm.currentTransition {
                    sliderRow(label: "Durée",
                              value: Binding(get: { transition.duration }, set: { vm.setTransitionDuration($0) }),
                              range: 0.1...1.0, display: String(format: "%.2f s", transition.duration))
                }
            }
        }
    }

    // MARK: Mouvement (images clés)

    private var motionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(vm.keyframes.enumerated()), id: \.element.id) { index, frame in
                        chip("K" + String(index + 1), selected: frame.id == vm.selectedKeyframeID, tint: .cyan) {
                            vm.selectKeyframe(id: frame.id)
                        }
                    }
                    chip("+ Image clé ici", selected: false) { haptic(); vm.addKeyframe() }
                }
            }
            if vm.selectedKeyframe == nil {
                Text("Ajoute des images clés à différents moments : VYRO anime le zoom, la position et la rotation entre elles.")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }
            if let frame = vm.selectedKeyframe {
                let id = frame.id
                sliderRow(label: "Zoom",
                          value: Binding(get: { frame.scale }, set: { v in vm.updateKeyframe(id: id) { $0.scale = v } }),
                          range: 1...3, display: String(format: "x%.2f", frame.scale))
                sliderRow(label: "Horiz.",
                          value: Binding(get: { frame.x }, set: { v in vm.updateKeyframe(id: id) { $0.x = v } }),
                          range: -0.5...0.5, display: String(format: "%+.0f %%", frame.x * 100))
                sliderRow(label: "Vertic.",
                          value: Binding(get: { frame.y }, set: { v in vm.updateKeyframe(id: id) { $0.y = v } }),
                          range: -0.5...0.5, display: String(format: "%+.0f %%", frame.y * 100))
                sliderRow(label: "Angle",
                          value: Binding(get: { frame.rotation }, set: { v in vm.updateKeyframe(id: id) { $0.rotation = v } }),
                          range: -45...45, display: String(format: "%+.0f°", frame.rotation))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(Keyframe.easeNames.enumerated()), id: \.offset) { index, name in
                            chip(name, selected: frame.ease == index, tint: .yellow) { vm.updateKeyframe(id: id) { $0.ease = index } }
                        }
                    }
                }
                HStack {
                    Text("La courbe règle le passage vers l'image clé suivante.")
                        .font(.caption2)
                        .foregroundColor(Theme.textSecondary)
                    Spacer()
                    Button(role: .destructive) { vm.removeKeyframe(id: id) } label: { Image(systemName: "trash") }
                }
            }
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

    private var subtitleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sous-titres automatiques")
                .font(.caption.weight(.semibold))
                .foregroundColor(Theme.textSecondary)
            HStack(spacing: 8) {
                ForEach(Array(SubtitleGenerator.languages.enumerated()), id: \.offset) { _, entry in
                    chip(entry.name, selected: vm.subtitleLanguage == entry.code, tint: .mint) { vm.subtitleLanguage = entry.code }
                }
            }
            HStack(spacing: 8) {
                chip("Phrases", selected: !vm.subtitleWordByWord && !vm.subtitleKaraoke, tint: .mint) {
                    vm.subtitleWordByWord = false; vm.subtitleKaraoke = false
                }
                chip("Karaoké", selected: vm.subtitleKaraoke, tint: .mint) {
                    vm.subtitleWordByWord = false; vm.subtitleKaraoke = true
                }
                chip("Mot par mot", selected: vm.subtitleWordByWord, tint: .mint) {
                    vm.subtitleWordByWord = true; vm.subtitleKaraoke = false
                }
            }
            if vm.isTranscribing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Transcription en cours…").font(.caption).foregroundColor(Theme.textSecondary)
                }
            } else {
                actionButton(vm.subtitleCount > 0 ? "Regénérer les sous-titres" : "Générer les sous-titres",
                             icon: "captions.bubble", tint: .mint) { vm.generateSubtitles() }
            }
            if vm.subtitleCount > 0 {
                Text(String(vm.subtitleCount) + " sous-titres. Style de tous les sous-titres :")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(TextOverlay.styleNames.enumerated()), id: \.offset) { index, name in
                            chip(name, selected: false) { vm.updateAllSubtitles { $0.style = index } }
                        }
                        ForEach(Array(TextOverlay.fontNames.enumerated()), id: \.offset) { index, name in
                            chip(name, selected: false, tint: .mint) { vm.updateAllSubtitles { $0.font = index } }
                        }
                    }
                }
                HStack(spacing: 10) {
                    ForEach(Array(TextOverlay.palette.enumerated()), id: \.offset) { index, entry in
                        Button { vm.updateAllSubtitles { $0.colorIndex = index } } label: {
                            Circle().fill(Color(red: entry.r, green: entry.g, blue: entry.b)).frame(width: 26, height: 26)
                        }
                    }
                    Spacer()
                    Button(role: .destructive) { vm.removeSubtitles() } label: { Image(systemName: "trash") }
                }
            }
        }
    }

    private var textPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            subtitleSection
            Divider().background(Color.white.opacity(0.1))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(vm.texts.filter { $0.subtitle != true }.enumerated()), id: \.element.id) { index, item in
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
                sliderRow(label: "Angle",
                          value: Binding(get: { item.rotation ?? 0 }, set: { v in vm.updateText(id: id) { $0.rotation = abs(v) < 2 ? nil : v } }),
                          range: -45...45, display: String(format: "%+.0f°", item.rotation ?? 0))
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
            stickerSection
        }
    }

    private var stickerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().background(Color.white.opacity(0.1))
            Text("Images et masques")
                .font(.caption.weight(.semibold))
                .foregroundColor(Theme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(vm.stickers.enumerated()), id: \.element.id) { index, item in
                        chip((item.kind == 0 ? "Image " : "Masque ") + String(index + 1),
                             selected: item.id == vm.selectedStickerID, tint: .orange) { vm.selectedStickerID = item.id }
                    }
                    PhotosPicker(selection: $stickerPick, matching: .images) {
                        Text("+ Image")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                            .foregroundColor(Theme.textSecondary)
                    }
                    chip("+ Masque flou", selected: false) { vm.addMask(kind: 1) }
                    chip("+ Masque noir", selected: false) { vm.addMask(kind: 2) }
                }
            }
            .onChange(of: stickerPick) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) { vm.addSticker(data: data) }
                    stickerPick = nil
                }
            }
            if let item = vm.selectedSticker {
                let id = item.id
                sliderRow(label: "Début",
                          value: Binding(get: { item.start }, set: { v in vm.updateSticker(id: id) { $0.start = v } }),
                          range: 0...max(vm.duration - 0.3, 0.5), display: String(format: "%.1f s", item.start))
                sliderRow(label: "Durée",
                          value: Binding(get: { item.duration }, set: { v in vm.updateSticker(id: id) { $0.duration = v } }),
                          range: 0.3...max(vm.duration, 1), display: String(format: "%.1f s", item.duration))
                sliderRow(label: "Largeur",
                          value: Binding(get: { item.size }, set: { v in vm.updateSticker(id: id) { $0.size = v } }),
                          range: 0.05...1, display: String(format: "%.0f %%", item.size * 100))
                if item.kind != 0 {
                    sliderRow(label: "Hauteur",
                              value: Binding(get: { item.aspect }, set: { v in vm.updateSticker(id: id) { $0.aspect = v } }),
                              range: 0.05...2, display: String(format: "%.0f %%", item.aspect * 100))
                }
                sliderRow(label: "Gauche",
                          value: Binding(get: { item.x }, set: { v in vm.updateSticker(id: id) { $0.x = v } }),
                          range: 0...1, display: String(format: "%.0f %%", item.x * 100))
                sliderRow(label: "Haut",
                          value: Binding(get: { item.y }, set: { v in vm.updateSticker(id: id) { $0.y = v } }),
                          range: 0...1, display: String(format: "%.0f %%", item.y * 100))
                if item.kind == 0 {
                    sliderRow(label: "Angle",
                              value: Binding(get: { item.rotation ?? 0 }, set: { v in vm.updateSticker(id: id) { $0.rotation = abs(v) < 2 ? nil : v } }),
                              range: -90...90, display: String(format: "%+.0f°", item.rotation ?? 0))
                    sliderRow(label: "Opacité",
                              value: Binding(get: { item.opacity ?? 1 }, set: { v in vm.updateSticker(id: id) { $0.opacity = v > 0.98 ? nil : v } }),
                              range: 0.1...1, display: String(format: "%.0f %%", (item.opacity ?? 1) * 100))
                }
                HStack {
                    Spacer()
                    Button(role: .destructive) { vm.removeSticker(id: id) } label: { Image(systemName: "trash") }
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
            sliderRow(label: "Teinte ciné",
                      value: Binding(get: { vm.colorGrade.tint ?? 0 }, set: { var g = vm.colorGrade; g.tint = $0; vm.setColorGrade(g) }),
                      range: 0...1, display: String(format: "%.0f %%", (vm.colorGrade.tint ?? 0) * 100))
            sliderRow(label: "Pellicule",
                      value: Binding(get: { vm.colorGrade.fade ?? 0 }, set: { var g = vm.colorGrade; g.fade = $0; vm.setColorGrade(g) }),
                      range: 0...1, display: String(format: "%.0f %%", (vm.colorGrade.fade ?? 0) * 100))
            sliderRow(label: "Grain",
                      value: Binding(get: { vm.colorGrade.grain ?? 0 }, set: { var g = vm.colorGrade; g.grain = $0; vm.setColorGrade(g) }),
                      range: 0...1, display: String(format: "%.0f %%", (vm.colorGrade.grain ?? 0) * 100))
            sliderRow(label: "Halo",
                      value: Binding(get: { vm.colorGrade.bloom ?? 0 }, set: { var g = vm.colorGrade; g.bloom = $0; vm.setColorGrade(g) }),
                      range: 0...1, display: String(format: "%.0f %%", (vm.colorGrade.bloom ?? 0) * 100))
            sliderRow(label: "Bandes",
                      value: Binding(get: { vm.colorGrade.bars ?? 0 }, set: { var g = vm.colorGrade; g.bars = $0; vm.setColorGrade(g) }),
                      range: 0...0.2, display: String(format: "%.0f %%", (vm.colorGrade.bars ?? 0) * 500))
        }
    }

    // MARK: Musique

    private var musicPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if vm.musicName == nil {
                Text("Ajoute un morceau : VYRO détecte son rythme, l'affiche sur la timeline et aimante tes effets dessus.")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
                actionButton("Choisir un morceau", icon: "music.note.list", tint: .mint) { pickingMusic = true; showFilePicker = true }
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
                    actionButton("Changer", icon: "arrow.triangle.2.circlepath", tint: Theme.accent) { pickingMusic = true; showFilePicker = true }
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
        if vm.isExporting || vm.isAnalyzing || vm.isImporting {
            ZStack {
                Color.black.opacity(0.65).ignoresSafeArea()
                VStack(spacing: 14) {
                    if vm.isImporting && !vm.isExporting && !vm.isAnalyzing {
                        ProgressView().tint(Theme.accent)
                        Text("Import de la vidéo…\nUne vidéo stockée sur iCloud peut prendre un moment.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white)
                    } else {
                        ProgressView(value: vm.isExporting ? vm.exportProgress : vm.analysisProgress)
                            .progressViewStyle(.linear)
                            .tint(Theme.accent)
                            .frame(width: 220)
                        Text(vm.isExporting ? "Export en cours…\nNe quitte pas l'app pendant l'export." : "Analyse du mouvement…")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white)
                        if vm.isExporting {
                            Button("Annuler l'export") { vm.cancelExport() }
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
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
    var onSelectKeyframe: (UUID) -> Void
    var onSelectSound: (UUID) -> Void
    /// Mode simple : une seule piste pour tous les effets, plus texte et vitesse.
    var advanced = true

    private var laneCount: Int { advanced ? 8 : 4 }
    private let laneHeight: CGFloat = 24
    private let laneSpacing: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let total = max(vm.duration, 0.01)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10).fill(Theme.surface)

                VStack(spacing: laneSpacing) {
                    if advanced {
                        effectLane([.zoom], color: Theme.accent, icon: "plus.magnifyingglass", width: width, total: total)
                        effectLane([.shake], color: Theme.accentBlue, icon: "waveform.path", width: width, total: total)
                        effectLane([.glitch], color: .pink, icon: "square.stack.3d.down.right", width: width, total: total)
                        effectLane([.flash, .glow, .sparkles, .ring, .chroma], color: Color(white: 0.85), icon: "bolt.fill", width: width, total: total)
                        speedLane(width: width, total: total)
                        textLane(width: width, total: total)
                        keyframeLane(width: width, total: total)
                        soundLane(width: width, total: total)
                    } else {
                        effectLane([.zoom, .shake, .glitch, .flash, .glow, .sparkles, .ring, .chroma], color: Theme.accent, icon: "burst.fill", width: width, total: total)
                        speedLane(width: width, total: total)
                        textLane(width: width, total: total)
                        soundLane(width: width, total: total)
                    }
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
        .frame(height: laneHeight * CGFloat(laneCount) + laneSpacing * CGFloat(laneCount - 1) + 16)
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

    private func keyframeLane(width: CGFloat, total: Double) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.04))
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10))
                .foregroundColor(Color.cyan.opacity(0.5))
                .padding(.leading, 6)
            ForEach(vm.keyframes) { frame in
                Image(systemName: "diamond.fill")
                    .font(.system(size: 14))
                    .foregroundColor(frame.id == vm.selectedKeyframeID ? .white : .cyan)
                    .offset(x: CGFloat(frame.time / total) * width - 7)
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onEnded { value in
                                let time = frame.time + Double(value.translation.width / width) * total
                                vm.updateKeyframe(id: frame.id) { $0.time = vm.snap(time) }
                                onSelectKeyframe(frame.id)
                            }
                    )
                    .onTapGesture { onSelectKeyframe(frame.id) }
            }
        }
        .frame(height: laneHeight)
        .clipped()
    }

    private func soundLane(width: CGFloat, total: Double) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.04))
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 10))
                .foregroundColor(Color.mint.opacity(0.5))
                .padding(.leading, 6)
            ForEach(vm.sounds) { mark in
                let selected = mark.id == vm.selectedSoundID
                Capsule()
                    .fill(selected ? Color.mint : Color.mint.opacity(0.55))
                    .frame(width: selected ? 9 : 6, height: laneHeight - 5)
                    .offset(x: CGFloat(mark.time / total) * width - 3)
                    .contentShape(Rectangle().inset(by: -6))
                    .onTapGesture { onSelectSound(mark.id) }
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
    @State private var saveMessage: String?
    @State private var saving = false

    private func saveToPhotos(_ url: URL) {
        saving = true
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    saving = false
                    saveMessage = "Autorise l'accès à Photos dans Réglages pour enregistrer."
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, error in
                DispatchQueue.main.async {
                    saving = false
                    saveMessage = success ? "Enregistrée dans Photos." : "Enregistrement impossible : " + (error?.localizedDescription ?? "erreur")
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(Theme.accent)
            Text("Export terminé")
                .font(.title2.weight(.bold))
                .foregroundColor(Theme.textPrimary)
            if let url {
                Button { saveToPhotos(url) } label: {
                    Label(saving ? "Enregistrement…" : "Enregistrer dans Photos", systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent))
                        .foregroundColor(.white)
                }
                .disabled(saving || saveMessage == "Enregistrée dans Photos.")
                if let saveMessage {
                    Text(saveMessage)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundColor(Theme.textSecondary)
                }
                ShareLink(item: url) {
                    Label("Partager", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.1)))
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
