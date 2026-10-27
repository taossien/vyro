//
//  ProjectStore.swift
//  Sauvegarde/chargement des projets (JSON) et gestion des fichiers médias.
//

import Foundation
import AVFoundation
import UIKit

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
        try? FileManager.default.removeItem(at: thumbnailURL(for: id))
    }

    // MARK: Miniatures

    static func thumbnailURL(for id: UUID) -> URL {
        projectsDirectory.appendingPathComponent(id.uuidString + ".jpg")
    }

    static func thumbnail(for id: UUID) -> UIImage? {
        UIImage(contentsOfFile: thumbnailURL(for: id).path)
    }

    static func copyThumbnail(from source: UUID, to destination: UUID) {
        try? FileManager.default.removeItem(at: thumbnailURL(for: destination))
        try? FileManager.default.copyItem(at: thumbnailURL(for: source), to: thumbnailURL(for: destination))
    }

    /// Image du premier clip (là où commence le montage), enregistrée en JPEG.
    static func updateThumbnail(for project: ProjectModel) async {
        guard let clip = project.tracks.first?.clips.first else { return }
        let asset = AVURLAsset(url: mediaDirectory.appendingPathComponent(clip.mediaFileName))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 360)
        let time = CMTime(seconds: (clip.trimIn ?? 0) + 0.3, preferredTimescale: 600)
        guard let cg = try? await generator.image(at: time).image,
              let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.8) else { return }
        try? data.write(to: thumbnailURL(for: project.id), options: .atomic)
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

    // MARK: Rythme (temps forts d'un morceau)

    static func saveBeats(_ beats: [Double], for mediaFileName: String) {
        guard let encoded = try? JSONEncoder().encode(beats) else { return }
        try? encoded.write(to: mediaDirectory.appendingPathComponent(mediaFileName + ".beats.json"), options: .atomic)
    }

    static func loadBeats(for mediaFileName: String) -> [Double]? {
        guard let data = try? Data(contentsOf: mediaDirectory.appendingPathComponent(mediaFileName + ".beats.json")) else { return nil }
        return try? JSONDecoder().decode([Double].self, from: data)
    }

    // MARK: Stabilisation (données calculées, stockées à côté du média)

    private static func stabilizationURL(for mediaFileName: String) -> URL {
        mediaDirectory.appendingPathComponent(mediaFileName + ".stab.json")
    }

    static func saveStabilization(_ data: StabilizationData, for mediaFileName: String) {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: stabilizationURL(for: mediaFileName), options: .atomic)
    }

    static func loadStabilization(for mediaFileName: String) -> StabilizationData? {
        guard let data = try? Data(contentsOf: stabilizationURL(for: mediaFileName)) else { return nil }
        return try? JSONDecoder().decode(StabilizationData.self, from: data)
    }
}
