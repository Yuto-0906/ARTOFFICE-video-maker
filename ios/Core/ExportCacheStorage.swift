import Foundation

enum ExportCacheStorage {
    static func remove(projectDirectory: URL, keeping: Set<String> = [], partialOnly: Bool = false) throws -> Int {
        guard FileManager.default.fileExists(atPath: projectDirectory.path) else { return 0 }
        let expected = projectDirectory.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path + "/" + projectDirectory.lastPathComponent
        guard projectDirectory.resolvingSymlinksInPath().standardizedFileURL.path == expected else { throw AppError.message("処理用キャッシュの場所を確認できません。") }
        var targets: [URL] = []
        for job in try FileManager.default.contentsOfDirectory(at: projectDirectory, includingPropertiesForKeys: [.isDirectoryKey]) {
            guard job.lastPathComponent.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { continue }
            let base = expected + "/" + job.lastPathComponent
            guard job.resolvingSymlinksInPath().standardizedFileURL.path == base else { throw AppError.message("処理用キャッシュの場所を確認できません。") }
            for file in try FileManager.default.contentsOfDirectory(at: job, includingPropertiesForKeys: [.isRegularFileKey]) {
                let partial = file.lastPathComponent.range(of: "^chunk-[0-9]+\\.partial\\.mp4$", options: .regularExpression) != nil
                let cached = file.lastPathComponent.range(of: "^chunk-[0-9]+\\.mp4$", options: .regularExpression) != nil || file.lastPathComponent == "journal.json"
                guard partial || (!partialOnly && !keeping.contains(job.lastPathComponent) && cached) else { continue }
                guard file.resolvingSymlinksInPath().standardizedFileURL.path == base + "/" + file.lastPathComponent,
                      (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw AppError.message("処理用ファイルを確認できません。") }
                targets.append(file)
            }
            let completed = job.appendingPathComponent("Completed")
            if FileManager.default.fileExists(atPath: completed.path) {
                guard completed.resolvingSymlinksInPath().standardizedFileURL.path == base + "/Completed" else { throw AppError.message("完成品の保存場所を確認できません。") }
                for file in try FileManager.default.contentsOfDirectory(at: completed, includingPropertiesForKeys: [.isRegularFileKey])
                    where file.lastPathComponent.hasPrefix(".") && file.lastPathComponent.hasSuffix(".partial.mp4") {
                    guard file.resolvingSymlinksInPath().standardizedFileURL.path == base + "/Completed/" + file.lastPathComponent,
                          (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw AppError.message("未完了ファイルを確認できません。") }
                    targets.append(file)
                }
            }
        }
        for file in targets { try FileManager.default.removeItem(at: file) }
        return targets.count
    }
    static func retainRecent(projectDirectory: URL, currentJob: String) throws {
        let jobs = try FileManager.default.contentsOfDirectory(at: projectDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != currentJob && $0.lastPathComponent.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }
        let previous = jobs.max {
            ((try? $0.appendingPathComponent("performance.json").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? $1.appendingPathComponent("performance.json").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        var keep: Set<String> = [currentJob]
        if let previous { keep.insert(previous.lastPathComponent) }
        _ = try remove(projectDirectory: projectDirectory, keeping: keep)
    }
}
