import Foundation

enum ManagedMediaCleanup {
    static func candidates(project: Project, directory: URL, onlyPaths: Set<String>? = nil) throws -> [URL] {
        let media = directory.appendingPathComponent("Media")
        guard FileManager.default.fileExists(atPath: media.path) else { return [] }
        let expected = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/Media"
        guard media.resolvingSymlinksInPath().standardizedFileURL.path == expected else { throw AppError.message("素材の保存先を確認できないため，整理を中止しました。") }
        let retained = Set(project.clips.compactMap(\.source.relativePath) + [project.thumbnail?.relativePath].compactMap { $0 })
        var result: [URL] = []
        for url in try FileManager.default.contentsOfDirectory(at: media, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            let relative = "Media/" + url.lastPathComponent
            guard !retained.contains(relative), onlyPaths == nil || onlyPaths!.contains(relative) else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, url.resolvingSymlinksInPath().standardizedFileURL.path == expected + "/" + url.lastPathComponent else {
                throw AppError.message("素材の保存先を確認できないため，整理を中止しました。")
            }
            if values.isRegularFile == true { result.append(url) }
        }
        return result
    }
}

extension ProjectRepository {
    func removeUnusedMedia(_ id: UUID, onlyPaths: Set<String>? = nil) throws -> Int {
        let location = directory(id)
        guard location.resolvingSymlinksInPath().standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path + "/" + id.uuidString else {
            throw AppError.message("プロジェクトの保存先を確認できません。")
        }
        let project = try load(id).project
        let files = try ManagedMediaCleanup.candidates(project: project, directory: location, onlyPaths: onlyPaths)
        guard !files.isEmpty else { return 0 }
        // Commit a recoverable checkpoint that does not reference the files being removed.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project).write(to: location.appendingPathComponent("previous.json"), options: .atomic)
        for url in files { try FileManager.default.removeItem(at: url) }
        return files.count
    }
}
