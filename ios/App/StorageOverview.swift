import SwiftUI

struct ProjectStorageUsage {
    var media: Int64 = 0
    var unusedMedia: Int64 = 0
    var cache: Int64 = 0
    var completed: Int64 = 0
}
enum ProjectStorageInspector {
    static func bytes(_ urls: [URL]) -> Int64 {
        var seen = Set<String>(), total: Int64 = 0
        for url in urls {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let device = attributes?[.systemNumber] as? NSNumber, let inode = attributes?[.systemFileNumber] as? NSNumber {
                guard seen.insert("\(device.uint64Value):\(inode.uint64Value)").inserted else { continue }
            }
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
    static func files(_ root: URL) -> [URL] {
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { return [] }
        var result: [URL] = []
        for case let url as URL in iterator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { iterator.skipDescendants(); continue }
            if values?.isRegularFile == true { result.append(url) }
        }
        return result
    }
    static func inspect(project: Project, directory: URL, jobs: URL) throws -> ProjectStorageUsage {
        let media = files(directory.appendingPathComponent("Media"))
        let exports = files(jobs.appendingPathComponent(project.id.uuidString))
        let cache = exports.filter {
            $0.lastPathComponent == "journal.json" || $0.lastPathComponent.range(of: "^chunk-[0-9]+\\.mp4$", options: .regularExpression) != nil
                || $0.lastPathComponent.hasSuffix(".partial.mp4")
        }
        return ProjectStorageUsage(media: bytes(media), unusedMedia: bytes(try ManagedMediaCleanup.candidates(project: project, directory: directory)),
            cache: bytes(cache), completed: bytes(exports.filter { $0.pathComponents.contains("Completed") && !$0.lastPathComponent.hasSuffix(".partial.mp4") }))
    }
}

struct StorageOverview: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var action: Int?
    var body: some View {
        NavigationStack {
            Form {
                Section("このプロジェクトの端末内保存") {
                    LabeledContent("コピーした動画・写真", value: bytes(store.storageUsage.media))
                    LabeledContent("うち現在使っていない素材", value: bytes(store.storageUsage.unusedMedia))
                    LabeledContent("書き出しの処理用キャッシュ", value: bytes(store.storageUsage.cache))
                    LabeledContent("アプリ内の完成ファイル", value: bytes(store.storageUsage.completed))
                }
                Section {
                    Button("使っていないコピー済み素材を削除", role: .destructive) { action = 0 }
                    Button("処理用キャッシュを削除", role: .destructive) { action = 1 }
                    Button("アプリ内の完成ファイルを削除", role: .destructive) { action = 2 }
                } header: { Text("容量を整理") } footer: {
                    Text("使用中の素材と元ファイルは残ります。")
                }
                Section("キャッシュの自動整理") {
                    Text("処理用キャッシュは直近2回分を保持します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(store.busy || store.exporting)
            .navigationTitle("保存容量を整理")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
            .task { await store.refreshStorage() }
            .confirmationDialog("削除する内容を確認してください", isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }), titleVisibility: .visible) {
                Button(action == 0 ? "未使用のコピー済み素材を削除" : action == 1 ? "処理用キャッシュを削除" : "アプリ内の完成ファイルを削除", role: .destructive) {
                    let selected = action; action = nil
                    Task {
                        if selected == 0 { await store.removeUnusedMedia() }
                        else if selected == 1 { await store.clearExportCache() }
                        else { await store.clearCompletedFiles() }
                        await store.refreshStorage()
                    }
                }
                Button("キャンセル", role: .cancel) { action = nil }
            } message: { Text(action == 0 ? "現在使っていない端末内のコピーだけを削除します。" : action == 1 ? "編集内容・入力素材・完成品は残ります。次回は処理し直します。" : "アプリ内の完成動画・チャプター・JPEGを削除します。外部へ保存したコピーは残ります。") }
        }
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}
