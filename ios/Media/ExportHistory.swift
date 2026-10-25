import Foundation

final class FolderLease {
    let url: URL
    private let scoped: Bool
    init(_ url: URL) { self.url = url; scoped = url.startAccessingSecurityScopedResource() }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

struct CompletedExport: Codable {
    var createdAt: Date
    var fileNames: [String]
    var destinationBookmark: Data?
    var hasSafeNames: Bool {
        !fileNames.isEmpty && fileNames.allSatisfy { name in
            !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
                && !name.contains(":") && ["mp4", "txt", "jpg"].contains((name as NSString).pathExtension)
        }
    }
}

enum ExportHistory {
    struct Loaded {
        var files: [URL]
        var lease: FolderLease?
        var job: URL
        var createdAt: Date
    }
    struct Attempt {
        var report: URL?
        var unfinished: Bool
    }
    private struct AttemptSummary: Decodable {
        var status: String?
        var startedAt: Date?
    }
    static func removeInternalCompleted(jobsRoot: URL, projectID: UUID) throws {
        let project = jobsRoot.appendingPathComponent(projectID.uuidString)
        guard FileManager.default.fileExists(atPath: project.path) else { return }
        let base = jobsRoot.resolvingSymlinksInPath().standardizedFileURL.path
        guard project.resolvingSymlinksInPath().standardizedFileURL.path == base + "/" + projectID.uuidString else {
            throw AppError.message("完成ファイルの保存場所を確認できません。削除を中止しました。")
        }
        var directories: [URL] = [], receipts: [URL] = []
        let entries = try FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: [.isDirectoryKey])
        // Validate every target before removing any files. Source media lives in Projects，
        // while external destinations are never used as removal targets.
        for job in entries where job.lastPathComponent.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil {
            guard (try? job.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let expected = base + "/" + projectID.uuidString + "/" + job.lastPathComponent
            guard job.resolvingSymlinksInPath().standardizedFileURL.path == expected else {
                throw AppError.message("完成ファイルの保存場所を確認できません。削除を中止しました。")
            }
            let completed = job.appendingPathComponent("Completed")
            if FileManager.default.fileExists(atPath: completed.path) {
                guard completed.resolvingSymlinksInPath().standardizedFileURL.path == expected + "/Completed" else {
                    throw AppError.message("完成ファイルの保存場所を確認できません。削除を中止しました。")
                }
                directories.append(completed)
            }
            for url in try FileManager.default.contentsOfDirectory(at: job, includingPropertiesForKeys: nil)
                where url.lastPathComponent.hasPrefix("result-") && url.pathExtension == "json" {
                if let data = try? Data(contentsOf: url), let record = try? JSONDecoder().decode(CompletedExport.self, from: data),
                   record.hasSafeNames, record.destinationBookmark == nil { receipts.append(url) }
            }
        }
        for url in directories + receipts { try FileManager.default.removeItem(at: url) }
    }
    static func attempt(jobsRoot: URL, project: Project, completed: Loaded?) -> Attempt {
        guard let key = try? ExportEngine.key(project) else { return Attempt(report: nil, unfinished: false) }
        let job = jobsRoot.appendingPathComponent(project.id.uuidString).appendingPathComponent(key)
        let report = job.appendingPathComponent("performance.json")
        guard FileManager.default.isReadableFile(atPath: report.path) else { return Attempt(report: nil, unfinished: false) }
        guard let data = try? Data(contentsOf: report), let summary = try? JSONDecoder().decode(AttemptSummary.self, from: data) else {
            return Attempt(report: report, unfinished: false)
        }
        // A committed result wins if writing the final diagnostic was interrupted.
        let committed = completed.map { value in
            value.job == job && summary.startedAt.map { value.createdAt >= $0 } == true
        } ?? false
        return Attempt(report: report, unfinished: !committed && ["running", "failed", "cancelled"].contains(summary.status ?? ""))
    }
    static func record(files: [URL], job: URL, destination: URL?) throws {
        let bookmark = try destination?.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let record = CompletedExport(createdAt: Date(), fileNames: files.map(\.lastPathComponent), destinationBookmark: bookmark)
        guard record.hasSafeNames else { throw AppError.message("完成ファイル名を記録できません。") }
        try JSONEncoder().encode(record).write(to: job.appendingPathComponent("result-\(UUID().uuidString).json"), options: .atomic)
    }
    static func latest(jobsRoot: URL, projectID: UUID) throws -> Loaded? {
        let project = jobsRoot.appendingPathComponent(projectID.uuidString)
        guard FileManager.default.fileExists(atPath: project.path) else { return nil }
        let jobs = try FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: [.isDirectoryKey])
        var candidates: [(record: CompletedExport, job: URL)] = []
        for job in jobs where (try? job.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            for url in try FileManager.default.contentsOfDirectory(at: job, includingPropertiesForKeys: nil)
                where url.lastPathComponent.hasPrefix("result-") && url.pathExtension == "json" {
                if let data = try? Data(contentsOf: url), let record = try? JSONDecoder().decode(CompletedExport.self, from: data), record.hasSafeNames {
                    candidates.append((record, job))
                }
            }
        }
        guard let last = candidates.max(by: { $0.record.createdAt < $1.record.createdAt }) else { return nil }
        let directory: URL
        var lease: FolderLease?
        if let bookmark = last.record.destinationBookmark {
            var stale = false
            directory = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, bookmarkDataIsStale: &stale)
            lease = FolderLease(directory)
        } else { directory = last.job.appendingPathComponent("Completed") }
        let files = last.record.fileNames.map { directory.appendingPathComponent($0) }
        guard files.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) }) else {
            throw AppError.message("前回の完成ファイルを開けません。外部の保存先を使った場合はドライブを接続してください。")
        }
        let report = last.job.appendingPathComponent("performance.json")
        return Loaded(files: files + (FileManager.default.isReadableFile(atPath: report.path) ? [report] : []),
                      lease: lease, job: last.job, createdAt: last.record.createdAt)
    }
}
