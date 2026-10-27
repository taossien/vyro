//
//  SubtitleGenerator.swift
//  Sous-titres automatiques : reconnaissance vocale (sur l'appareil quand c'est possible),
//  mots horodatés regroupés en phrases courtes.
//

import Foundation
import AVFoundation
import Speech

enum SubtitleError: LocalizedError {
    case notAuthorized
    case unavailable
    case noAudio
    case noSpeech(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Autorise la reconnaissance vocale dans Réglages pour générer les sous-titres."
        case .unavailable: return "La reconnaissance vocale n'est pas disponible pour cette langue sur cet appareil."
        case .noAudio: return "Ce montage ne contient pas de son à transcrire."
        case .noSpeech(let detail): return "Aucune parole détectée. " + detail
        case .failed(let detail): return "Transcription impossible : " + detail
        }
    }
}

struct SpokenWord {
    let text: String
    let start: Double
    let duration: Double
    var end: Double { start + duration }
}

struct SubtitleChunk {
    let text: String
    let start: Double
    let end: Double
}

enum SubtitleGenerator {
    static let languages: [(name: String, code: String)] = [("Français", "fr-FR"), ("English", "en-US")]

    static func authorize() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Extrait la piste son d'un montage dans un fichier .m4a temporaire.
    static func exportAudio(of asset: AVAsset) async throws -> URL {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("VYRO-voice-" + UUID().uuidString + ".m4a")
        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw SubtitleError.noAudio
        }
        session.outputURL = output
        session.outputFileType = .m4a
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else { throw SubtitleError.noAudio }
        return output
    }

    static func transcribe(audio url: URL, language: String) async throws -> [SpokenWord] {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable else {
            throw SubtitleError.unavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            _ = recognizer.recognitionTask(with: request) { result, error in
                if finished { return }
                if let result, result.isFinal {
                    finished = true
                    let words = result.bestTranscription.segments
                        .filter { !$0.substring.trimmingCharacters(in: .whitespaces).isEmpty }
                        .map { SpokenWord(text: $0.substring, start: $0.timestamp, duration: $0.duration) }
                    continuation.resume(returning: words)
                } else if let error {
                    finished = true
                    continuation.resume(throwing: SubtitleError.failed(error.localizedDescription))
                }
            }
        }
    }

    /// Regroupe les mots en sous-titres courts : 4 mots au plus, 26 signes au plus, coupure sur les pauses.
    static func chunk(_ words: [SpokenWord]) -> [SubtitleChunk] {
        var chunks: [SubtitleChunk] = []
        var current: [SpokenWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
            chunks.append(SubtitleChunk(text: text, start: first.start, end: last.end))
            current = []
        }

        for word in words {
            if let last = current.last {
                let pause = word.start - last.end
                let length = current.map(\.text).joined(separator: " ").count + word.text.count + 1
                if pause > 0.45 || current.count >= 4 || length > 26 { flush() }
            }
            current.append(word)
            if let last = current.last, last.text.hasSuffix(".") || last.text.hasSuffix("?") || last.text.hasSuffix("!") {
                flush()
            }
        }
        flush()

        // Un sous-titre reste affiché jusqu'au suivant (au plus 0,6 s de plus), et au moins 0,4 s.
        var result: [SubtitleChunk] = []
        for (index, item) in chunks.enumerated() {
            var end = item.end + 0.2
            if index + 1 < chunks.count { end = min(end, chunks[index + 1].start) }
            end = max(end, item.start + 0.4)
            result.append(SubtitleChunk(text: item.text, start: item.start, end: end))
        }
        return result
    }
}
