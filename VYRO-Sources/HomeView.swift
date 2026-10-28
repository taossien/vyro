//
//  HomeView.swift
//  Écran d'accueil : logo VYRO, liste des projets, création.
//

import SwiftUI

struct HomeView: View {
    @State private var projects: [ProjectModel] = []
    @State private var showNewProject = false
    @State private var renaming: ProjectModel?
    @State private var newName = ""

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
                                HStack(spacing: 12) {
                                    thumbnail(for: project)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(project.name)
                                            .foregroundColor(Theme.textPrimary)
                                        let count = project.tracks.first?.clips.count ?? 0
                                        Text((count > 0 ? String(count) + (count > 1 ? " clips · " : " clip · ") : "")
                                            + project.modificationDate.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption)
                                            .foregroundColor(Theme.textSecondary)
                                    }
                                }
                            }
                            .listRowBackground(Theme.surface)
                            .contextMenu {
                                Button {
                                    newName = project.name
                                    renaming = project
                                } label: { Label("Renommer", systemImage: "pencil") }
                                Button {
                                    duplicate(project)
                                } label: { Label("Dupliquer", systemImage: "plus.square.on.square") }
                                Button(role: .destructive) {
                                    if let index = projects.firstIndex(where: { $0.id == project.id }) {
                                        deleteProjects(at: IndexSet(integer: index))
                                    }
                                } label: { Label("Supprimer", systemImage: "trash") }
                            }
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
                // La miniature du projet qu'on vient de quitter s'écrit juste après.
                Task {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    projects = ProjectStore.loadAll()
                }
            }
            .alert("Renommer le projet", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Nom", text: $newName)
                Button("Annuler", role: .cancel) { renaming = nil }
                Button("OK") { applyRename() }
            }
        }
    }

    @ViewBuilder
    private func thumbnail(for project: ProjectModel) -> some View {
        Group {
            if let image = ProjectStore.thumbnail(for: project.id) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.06)
                    Image(systemName: "film").foregroundColor(Theme.textSecondary)
                }
            }
        }
        .frame(width: 44, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func applyRename() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var project = renaming, !trimmed.isEmpty else { renaming = nil; return }
        project.name = trimmed
        project.modificationDate = Date()
        try? ProjectStore.save(project)
        renaming = nil
        projects = ProjectStore.loadAll()
    }

    private func duplicate(_ project: ProjectModel) {
        var copy = project
        copy.id = UUID()
        copy.name = project.name + " (copie)"
        copy.creationDate = Date()
        copy.modificationDate = Date()
        try? ProjectStore.save(copy)
        ProjectStore.copyThumbnail(from: project.id, to: copy.id)
        projects = ProjectStore.loadAll()
    }

    private func deleteProjects(at offsets: IndexSet) {
        for index in offsets {
            ProjectStore.delete(id: projects[index].id)
        }
        projects.remove(atOffsets: offsets)
        ProjectStore.cleanupUnusedMedia()
    }
}
