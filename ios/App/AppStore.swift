import AVFoundation
import CoreTransferable
import Combine
import PhotosUI
import SwiftUI

@MainActor final class AppStore: ObservableObject {
    @Published var projects: [Project] = []
    @Published var project = Project()
    @Published var active = false
    @Published var busy = false
    @Published var message: String?
    @Published var saveStatus = "保存済み"
    @Published var importStatus = ""
    @Published var exporting = false
    @Published var progress = 0.0
    @Published var exportStatus = ""
    @Published var exportedFiles: [URL] = []
    @Published private(set) var diagnosticFile: URL?
    @Published var storageBytes: Int64 = 0
    @Published var storageUsage = ProjectStorageUsage()
    @Published var saveFeedback: String?
    @Published var showingSaveToast = false
    private var feedbackTask: Task<Void, Never>?
    let root: URL
    let jobs: URL
    let repository: ProjectRepository
    private var saveTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var control: ExportControl?
    private var outputLease: FolderLease?
    private var revision = 0
    init() {
        _ = RuntimePressure.shared
        var support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ARTOFFICE", isDirectory: true)
        #if DEBUG
        if let seed = ProcessInfo.processInfo.environment["ARTOFFICE_UI_TEST_ROOT"], let id = UUID(uuidString: seed) {
            support = support.appendingPathComponent("UITests", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
        }
        #endif
        root = support.appendingPathComponent("Projects", isDirectory: true)
        jobs = support.appendingPathComponent("ExportJobs", isDirectory: true)
        repository = ProjectRepository(root: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
    }
    var directory: URL { root.appendingPathComponent(project.id.uuidString) }
    var timeline: Timeline? { try? Timeline(project) }
    func refresh() async { projects = await repository.list() }
    func create() async {
        do {
            let fresh = Project(); try await repository.save(fresh); project = fresh; active = true
            feedbackTask?.cancel(); saveFeedback = nil; showingSaveToast = false
            exportedFiles = []; outputLease = nil; diagnosticFile = nil; exportStatus = ""
        }
        catch { message = error.localizedDescription }
    }
    func open(_ project: Project) async {
        do {
            let loaded = try await repository.load(project.id)
            self.project = loaded.project; active = true; exportedFiles = []; saveStatus = "保存済み"
            feedbackTask?.cancel(); saveFeedback = nil; showingSaveToast = false
            let cacheDirectory = jobs.appendingPathComponent(project.id.uuidString)
            _ = try? await Task.detached { try ExportCacheStorage.remove(projectDirectory: cacheDirectory, partialOnly: true) }.value
            outputLease = nil; diagnosticFile = nil; exportStatus = ""
            storageBytes = await repository.allocatedBytes(project.id)
            if loaded.recovered { message = "直前の正常な保存データから復旧しました。内容を確認してください。" }
            let jobs = self.jobs
            var completed: ExportHistory.Loaded?
            do {
                let finished = try await Task.detached { try ExportHistory.latest(jobsRoot: jobs, projectID: project.id) }.value
                completed = finished
                exportedFiles = finished?.files ?? []; outputLease = finished?.lease
            } catch { message = error.localizedDescription }
            let attempt = ExportHistory.attempt(jobsRoot: jobs, project: loaded.project, completed: completed)
            diagnosticFile = attempt.report ?? completed?.files.first(where: { $0.pathExtension == "json" })
            if attempt.unfinished {
                exportStatus = "前回の書き出しは完了していません。保存した編集内容から再実行でき，処理済みの区間は再利用します。"
            }
        } catch { message = error.localizedDescription }
    }
    func close() async {
        do { try await flush(); active = false; outputLease = nil; diagnosticFile = nil; await refresh() }
        catch { message = "保存できなかったため，編集画面を開いたままにしています。\n" + error.localizedDescription }
    }
    func changed() {
        guard active else { return }
        feedbackTask?.cancel(); saveFeedback = nil; showingSaveToast = false
        saveStatus = "保存待ち"; saveTask?.cancel(); revision += 1
        let token = revision
        var snapshot = project; snapshot.modifiedAt = Date()
        saveTask = Task {
            do {
                try await Task.sleep(nanoseconds: 350_000_000); try Task.checkCancellation()
                saveStatus = "保存中"
                try await repository.save(snapshot, revision: token)
                if token == revision { saveStatus = "保存済み" }
            } catch is CancellationError {} catch {
                if token == revision { saveStatus = "保存失敗"; message = error.localizedDescription }
            }
        }
    }
    func flush() async throws {
        guard active else { return }
        saveTask?.cancel(); revision += 1
        var snapshot = project; snapshot.modifiedAt = Date()
        do { try await repository.save(snapshot, revision: revision); saveStatus = "保存済み" }
        catch { saveStatus = "保存失敗"; throw error }
    }
    func saveNow() async {
        do {
            try await flush(); feedbackTask?.cancel(); saveFeedback = "保存しました"; showingSaveToast = true
            feedbackTask = Task { try? await Task.sleep(nanoseconds: 2_000_000_000); if !Task.isCancelled { showingSaveToast = false } }
        } catch { message = error.localizedDescription }
    }
    func refreshStorage() async {
        let snapshot = project, directory = self.directory, jobs = self.jobs
        do {
            let value = try await Task.detached { try ProjectStorageInspector.inspect(project: snapshot, directory: directory, jobs: jobs) }.value
            if project.id == snapshot.id { storageUsage = value; storageBytes = await repository.allocatedBytes(snapshot.id) }
        } catch { message = error.localizedDescription }
    }
    func importFolder(_ folder: URL, copy: Bool) async {
        guard !busy, !exporting else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        busy = true; importStatus = "フォルダー内の動画を探しています。クラウドの場合は接続を確認しています。"
        do {
            var bookmark: Data?
            if !copy { bookmark = try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) }
            let urls = try await Task.detached { try FolderVideoImport.scan(folder) }.value
            busy = false
            await importVideos(urls, copy: copy, folderBookmark: bookmark)
        } catch { busy = false; importStatus = ""; message = error.localizedDescription }
    }
    func removeClip(_ id: UUID, deleteCopy: Bool) async {
        guard !busy, !exporting, let clip = project.clips.first(where: { $0.id == id }) else { return }
        busy = true; defer { busy = false }
        let previous = project
        project.removeClip(id)
        do { try await flush() } catch { project = previous; message = error.localizedDescription; return }
        if deleteCopy, let path = clip.source.relativePath {
            do { _ = try await repository.removeUnusedMedia(project.id, onlyPaths: [path]) }
            catch { message = error.localizedDescription }
        }
        await refreshStorage()
    }
    func removeUnusedMedia() async {
        guard !busy, !exporting else { return }
        busy = true; defer { busy = false }
        do {
            try await flush()
            let count = try await repository.removeUnusedMedia(project.id)
            message = count == 0 ? "削除できる未使用素材はありません。" : "未使用の素材を\(count)ファイル整理しました。"
            await refreshStorage()
        } catch { message = error.localizedDescription }
    }
    func duplicate(_ value: Project) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { _ = try await repository.duplicate(value); await refresh() } catch { message = error.localizedDescription }
    }
    func delete(_ value: Project) async {
        do {
            try await repository.remove(value.id)
            let jobDirectory = jobs.appendingPathComponent(value.id.uuidString)
            if FileManager.default.fileExists(atPath: jobDirectory.path) { try FileManager.default.removeItem(at: jobDirectory) }
            await refresh()
        } catch { message = error.localizedDescription }
    }
    func importVideos(_ urls: [URL], copy: Bool, relink: UUID? = nil, ownedTemporary: Bool = false, selectionIdentity: String? = nil, folderBookmark: Data? = nil) async {
        guard !busy, !exporting else { return }
        busy = true; defer { busy = false; importStatus = "" }
        let directory = self.directory
        var errors: [String] = []
        let ordered = urls.sorted {
            let a = Naming.parse($0.lastPathComponent)?.order ?? Int.max, b = Naming.parse($1.lastPathComponent)?.order ?? Int.max
            return a == b ? $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending : a < b
        }
        for (index, url) in ordered.enumerated() {
            importStatus = "動画を取り込んでいます（\(index + 1)/\(urls.count)）"
            do {
                let existing: Set<String> = relink == nil ? Set(project.clips.compactMap(\.source.importIdentity)) : []
                let minimumDuration = relink.flatMap { id in project.clips.first(where: { $0.id == id })?.end } ?? 0
                let clip = try await Task.detached(priority: .userInitiated) {
                    try await MediaFiles.importVideo(url, copy: copy, directory: directory, ownedTemporary: ownedTemporary,
                                                    selectionIdentity: selectionIdentity, existingIDs: existing, minimumDuration: minimumDuration, folderBookmark: folderBookmark)
                }.value
                if let id = relink, let i = project.clips.firstIndex(where: { $0.id == id }) {
                    guard clip.source.duration >= project.clips[i].end else { throw AppError.message("元のカット範囲より短い動画です。対応する素材を選んでください。") }
                    project.clips[i].source = clip.source
                } else {
                    if project.clips.isEmpty { project.frameRate = .suggested(clip.source.nominalFPS); project.selectedClip = clip.id }
                    project.clips.append(clip)
                }
                // Commit after each file，so a later multi-gigabyte copy cannot erase the
                // already imported clips if the app is interrupted.
                try await flush()
            } catch { errors.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        do { try await flush(); storageBytes = await repository.allocatedBytes(project.id) } catch { errors.append(error.localizedDescription) }
        if !errors.isEmpty { message = errors.joined(separator: "\n") }
    }
    func importPhotosVideos(_ items: [PhotosPickerItem]) async {
        for (i, item) in items.enumerated() {
            guard !busy, !exporting else { return }
            importStatus = "写真から取得しています（\(i + 1)/\(items.count)）"; busy = true
            do {
                if let movie = try await item.loadTransferable(type: PickedMedia.self) {
                    busy = false
                    await importVideos([movie.url], copy: true, ownedTemporary: true,
                                       selectionIdentity: item.itemIdentifier.map { "photos:\($0)" })
                    try? FileManager.default.removeItem(at: movie.url.deletingLastPathComponent())
                } else { busy = false; message = "写真から動画を取得できませんでした。" }
            } catch { busy = false; message = error.localizedDescription }
        }
        importStatus = ""
    }
    func importPhoto(_ url: URL) async {
        guard !busy, !exporting else { return }; busy = true; defer { busy = false }
        let directory = self.directory
        do {
            project.thumbnail = try await Task.detached { try MediaFiles.importPhoto(url, directory: directory) }.value
            try await flush()
        } catch { message = error.localizedDescription }
    }
    func startExport(destination: URL?) {
        guard !exporting, !busy else { return }
        let snapshot = project, directory = self.directory, jobs = self.jobs
        outputLease = destination.map { FolderLease($0) }
        let control = ExportControl(); self.control = control
        exporting = true; progress = 0; exportedFiles = []; diagnosticFile = nil
        exportStatus = "書き出しを準備しています"; UIApplication.shared.isIdleTimerDisabled = true
        exportTask = Task {
            defer {
                exporting = false; UIApplication.shared.isIdleTimerDisabled = false; self.control = nil
                diagnosticFile = ExportHistory.attempt(jobsRoot: jobs, project: snapshot, completed: nil).report
            }
            do {
                try await flush()
                let files = try await Task.detached(priority: .userInitiated) {
                    try await ExportEngine.run(project: snapshot, directory: directory, jobsRoot: jobs, destination: destination,
                        control: control) { progress, status in
                            Task { @MainActor in self.progress = progress; self.exportStatus = status }
                        }
                }.value
                exportedFiles = files; exportStatus = "書き出しが完了しました"
            } catch is CancellationError { exportStatus = "中断しました。完了した区間は次回の書き出しで再利用します。" }
            catch { exportStatus = "書き出しを完了できませんでした。処理済み区間は保持されています。"; message = error.localizedDescription }
        }
    }
    func cancelExport() { control?.cancel() }
    func backgrounded() {
        Task { do { try await flush() } catch { saveStatus = "保存失敗"; message = error.localizedDescription } }
        // Deterministic checkpoints on iOS 17; never rely on an unlimited background assertion.
        if exporting { control?.cancel() }
    }
    func clearCompletedFiles() async {
        guard !exporting, !busy else { return }
        busy = true; defer { busy = false }
        let jobs = self.jobs, id = project.id
        exportedFiles = []; outputLease = nil
        do {
            try await Task.detached { try ExportHistory.removeInternalCompleted(jobsRoot: jobs, projectID: id) }.value
            exportStatus = "アプリ内の完成ファイルを削除しました。編集内容と素材は残っています。"
            let finished = try await Task.detached { try ExportHistory.latest(jobsRoot: jobs, projectID: id) }.value
            exportedFiles = finished?.files ?? []; outputLease = finished?.lease
            diagnosticFile = ExportHistory.attempt(jobsRoot: jobs, project: project, completed: finished).report
                ?? finished?.files.first(where: { $0.pathExtension == "json" })
        } catch { message = error.localizedDescription }
    }
    func clearExportCache() async {
        guard !exporting, !busy else { return }
        busy = true; defer { busy = false }
        let directory = jobs.appendingPathComponent(project.id.uuidString)
        do {
            _ = try await Task.detached { try ExportCacheStorage.remove(projectDirectory: directory) }.value
            exportStatus = "処理用キャッシュを削除しました。編集内容・素材・完成品は残っています。"
            await refreshStorage()
        } catch { message = error.localizedDescription }
    }
}

struct PickedPhoto: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { file in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let dest = directory.appendingPathComponent(file.file.lastPathComponent)
            try FileManager.default.copyItem(at: file.file, to: dest)
            return PickedPhoto(url: dest)
        }
    }
}
