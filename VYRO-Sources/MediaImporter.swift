//
//  MediaImporter.swift
//  Sélecteur de vidéos (PHPicker) et copie locale durable du fichier.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct MediaImporter: UIViewControllerRepresentable {
    var onPicked: ([URL]) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 10
        config.selection = .ordered
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
            let providers = results.map(\.itemProvider)
                .filter { $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }
            guard !providers.isEmpty else { return }

            var urls = [URL?](repeating: nil, count: providers.count)
            let lock = NSLock()
            let group = DispatchGroup()
            for (index, provider) in providers.enumerated() {
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                    defer { group.leave() }
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
                        lock.lock(); urls[index] = destination; lock.unlock()
                    } catch {
                        print("VYRO copie média erreur: " + error.localizedDescription)
                    }
                }
            }
            group.notify(queue: .main) {
                let picked = urls.compactMap { $0 }
                if !picked.isEmpty { self.parent.onPicked(picked) }
            }
        }
    }
}
