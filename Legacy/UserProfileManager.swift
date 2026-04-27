import Foundation

enum UserProfileManager {
    private static var profilesDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("SpiceHarvester/profiles", isDirectory: true)
    }

    static func profilesDirectoryURL() -> URL {
        ensureDirectory()
        return profilesDirectory
    }

    static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
    }

    static func loadUserProfiles() -> [PreprocessingProfile] {
        ensureDirectory()
        let dir = profilesDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" }) else { return [] }

        let decoder = JSONDecoder()
        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let stored = try? decoder.decode(StoredProfile.self, from: data)
            else { return nil }
            return stored.toProfile()
        }
    }

    static func saveProfile(_ profile: PreprocessingProfile) {
        ensureDirectory()
        let stored = StoredProfile(from: profile)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        let fileURL = profilesDirectory.appendingPathComponent("\(profile.id).json")
        try? data.write(to: fileURL, options: .atomic)
    }

    static func deleteProfile(id: String) {
        let fileURL = profilesDirectory.appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - Codable wrapper (PreprocessingProfile itself uses CGFloat which needs bridging)

private struct StoredProfile: Codable {
    let id: String
    let displayName: String
    let normalizeWhitespace: Bool
    let deduplicatePageHeaders: Bool
    let smartChunking: Bool
    let useVision: Bool
    let useOpenDataLoader: Bool
    let useEmbeddingDedup: Bool?
    let embeddingSimilarityThreshold: Double?
    let ocrResolutionWidth: Double
    let visionResolutionWidth: Double
    let visionPageBatchSize: Int
    let tokenRatio: Double
    let defaultPrompt: String
    let defaultContinuationPrompt: String

    init(from profile: PreprocessingProfile) {
        id = profile.id
        displayName = profile.displayName
        normalizeWhitespace = profile.normalizeWhitespace
        deduplicatePageHeaders = profile.deduplicatePageHeaders
        smartChunking = profile.smartChunking
        useVision = profile.useVision
        useOpenDataLoader = profile.useOpenDataLoader
        useEmbeddingDedup = profile.useEmbeddingDedup
        embeddingSimilarityThreshold = profile.embeddingSimilarityThreshold
        ocrResolutionWidth = Double(profile.ocrResolutionWidth)
        visionResolutionWidth = Double(profile.visionResolutionWidth)
        visionPageBatchSize = profile.visionPageBatchSize
        tokenRatio = profile.tokenRatio
        defaultPrompt = profile.defaultPrompt
        defaultContinuationPrompt = profile.defaultContinuationPrompt
    }

    func toProfile() -> PreprocessingProfile {
        PreprocessingProfile(
            id: id,
            displayName: displayName,
            normalizeWhitespace: normalizeWhitespace,
            deduplicatePageHeaders: deduplicatePageHeaders,
            smartChunking: smartChunking,
            useVision: useVision,
            useOpenDataLoader: useOpenDataLoader,
            useEmbeddingDedup: useEmbeddingDedup ?? false,
            embeddingSimilarityThreshold: embeddingSimilarityThreshold ?? 0.95,
            ocrResolutionWidth: CGFloat(ocrResolutionWidth),
            visionResolutionWidth: CGFloat(visionResolutionWidth),
            visionPageBatchSize: visionPageBatchSize,
            tokenRatio: tokenRatio,
            defaultPrompt: defaultPrompt,
            defaultContinuationPrompt: defaultContinuationPrompt
        )
    }
}
