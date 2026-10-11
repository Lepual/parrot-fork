import Foundation
import Hub

enum Engine: String, Codable {
    case whisperKit
    case parakeet
}

struct TranscriptionModel: Codable {
    let id: String
    let displayName: String
    let engine: Engine
    /// Engine-specific identifier (e.g. "openai_whisper-base.en" for WhisperKit).
    let whisperKitID: String?
    let sizeMB: Int
    let languages: [String]
    let recommended: Bool
}

extension TranscriptionModel {
    /// Matches the hardcoded default in WhisperKit's own `setupModels` — it's
    /// where `parrot models download` puts everything.
    static let hubRepo = "argmaxinc/whisperkit-coreml"

    /// Local folder where this model would live if already downloaded, per
    /// WhisperKit/Hub's default cache location. `nil` for non-WhisperKit
    /// engines (there's only one engine today, but Parakeet is planned).
    var localFolder: URL? {
        guard let whisperKitID else { return nil }
        return HubApi().localRepoLocation(Hub.Repo(id: Self.hubRepo)).appending(path: whisperKitID)
    }

    var isDownloaded: Bool {
        guard let localFolder else { return false }
        return FileManager.default.fileExists(atPath: localFolder.path)
    }
}

struct ModelsManifest: Codable {
    let models: [TranscriptionModel]
}
