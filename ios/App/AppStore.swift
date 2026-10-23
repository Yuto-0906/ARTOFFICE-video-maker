import AVFoundation
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
    @Published var storageBytes: Int64 = 0
    let root: URL
    let jobs: URL
    let repository: ProjectRepository
    private var saveTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var control: ExportControl?
    private var revision = 0
    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ARTOFFICE", isDirectory: true)
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
        do { let fresh = Project(); try await repository.save(fresh); project = fresh; active = true; exportedFiles = [] }
        catch { message = error.localizedDescription }
    }
    func open(_ project: Project) async {
        do {
            let loaded = try await repository.load(project.id)
            self.project = loaded.project; active = true; exportedFiles = []; saveStatus = "保存済み"
            storageBytes = await repository.allocatedBytes(project.id)
            if loaded.recovered { message = "直前の正常な保存データから復旧しました。内容を確認してください。" }
        } catch { message = error.localizedDescription }
    }
    func close() async {
        do { try await flush(); active = false; await refresh() }
        catch { message = "保存できなかったため，編集画面を開いたままにしています。\n" + error.localizedDescription }
    }
    func changed() {
        guard active else { return }
        saveStatus = "保存待ち"; saveTask?.cancel(); revision += 1
        let token = revision
        var snapshot = project; snapshot.modifiedAt = Date()
        saveTask = Task {
            do {
                try await Task.sleep(nanoseconds: 350_000_000); try Task.checkCancellation()
                saveStatus = "保存中"
                try await repository.save(snapshot)
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
        try await repository.save(snapshot); saveStatus = "保存済み"
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
    func importVideos(_ urls: [URL], copy: Bool, relink: UUID? = nil) async {
        guard !busy, !exporting else { return }
        busy = true; defer { busy = false; importStatus = "" }
        let directory = self.directory
        var added: [Clip] = [], errors: [String] = []
        for (index, url) in urls.enumerated() {
            importStatus = "動画を取り込んでいます（\(index + 1)/\(urls.count)）"
            do {
                let clip = try await Task.detached(priority: .userInitiated) {
                    try await MediaFiles.importVideo(url, copy: copy, directory: directory)
                }.value
                if let id = relink, let i = project.clips.firstIndex(where: { $0.id == id }) {
                    guard clip.source.duration >= project.clips[i].end else { throw AppError.message("元のカット範囲より短い動画です。対応する素材を選んでください。") }
                    project.clips[i].source = clip.source
                } else { added.append(clip) }
            } catch { errors.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        added.sort {
            let a = Naming.parse($0.source.fileName)?.order ?? Int.max, b = Naming.parse($1.source.fileName)?.order ?? Int.max
            return a == b ? $0.source.fileName.localizedStandardCompare($1.source.fileName) == .orderedAscending : a < b
        }
        let wasEmpty = project.clips.isEmpty
        project.clips += added
        if wasEmpty, let first = added.first { project.frameRate = .suggested(first.source.nominalFPS); project.selectedClip = first.id }
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
                    await importVideos([movie.url], copy: true)
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
        let control = ExportControl(); self.control = control
        exporting = true; progress = 0; exportedFiles = []
        exportStatus = "書き出しを準備しています"; UIApplication.shared.isIdleTimerDisabled = true
        exportTask = Task {
            defer { exporting = false; UIApplication.shared.isIdleTimerDisabled = false; self.control = nil }
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
    func clearExportCache() async {
        guard !exporting else { return }
        let directory = jobs.appendingPathComponent(project.id.uuidString)
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                // Completed files can be the user's only copy. Delete only chunks/journals，not Completed/.
                let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                for job in entries {
                    let files = try FileManager.default.contentsOfDirectory(at: job, includingPropertiesForKeys: nil)
                    for url in files where url.pathExtension == "mp4" || url.lastPathComponent == "journal.json" {
                        try FileManager.default.removeItem(at: url)
                    }
                }
            }
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
