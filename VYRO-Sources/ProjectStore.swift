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
