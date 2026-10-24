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
