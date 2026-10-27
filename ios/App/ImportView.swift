import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private struct MediaPickerRequest: Identifiable {
    let id = UUID()
    var folder = false
    var multiple = true
}
private struct MediaDocumentPicker: UIViewControllerRepresentable {
    let request: MediaPickerRequest
    let selected: ([URL]) -> Void
    let cancelled: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(selected: selected, cancelled: cancelled) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: request.folder ? [.folder] : [.movie], asCopy: false)
        picker.allowsMultipleSelection = request.multiple; picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let selected: ([URL]) -> Void
        let cancelled: () -> Void
        init(selected: @escaping ([URL]) -> Void, cancelled: @escaping () -> Void) { self.selected = selected; self.cancelled = cancelled }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { selected(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { cancelled() }
    }
}

struct ImportView: View {
    @EnvironmentObject private var store: AppStore
    var edit: (UUID) -> Void
    @State private var request: MediaPickerRequest?
    @State private var copy = true
    @State private var photos: [PhotosPickerItem] = []
    @State private var relink: UUID?
    @State private var inspection: Clip?
    @State private var removal: Clip?
    @State private var editMode: EditMode = .inactive
    @FocusState private var eventNameFocused: Bool

    var body: some View {
        List {
            Section("イベント") {
                HStack {
                    TextField("イベント名", text: $store.project.name).accessibilityIdentifier("eventName")
                        .autocorrectionDisabled().focused($eventNameFocused).submitLabel(.done).onSubmit { eventNameFocused = false }
                    if !store.project.name.isEmpty {
                        Button("イベント名を消去", systemImage: "xmark.circle.fill") { store.project.name = ""; eventNameFocused = true }
                            .labelStyle(.iconOnly).frame(width: 44, height: 44).accessibilityIdentifier("clearEventName")
                    }
                }
            }
            Section {
                Button { relink = nil; request = MediaPickerRequest(folder: true, multiple: false) } label: {
                    Label("フォルダー内の動画をまとめて追加", systemImage: "folder.badge.plus").frame(minHeight: 44)
                }.accessibilityIdentifier("importVideoFolder")
                Button { relink = nil; request = MediaPickerRequest() } label: {
                    Label("動画をまとめて選択", systemImage: "doc.on.doc").frame(minHeight: 44)
                }.accessibilityIdentifier("importVideoFiles")
                PhotosPicker(selection: $photos, maxSelectionCount: 100, matching: .videos, preferredItemEncoding: .current) {
                    Label("写真ライブラリから追加", systemImage: "photo.on.rectangle.angled").frame(minHeight: 44)
                }
                Toggle("素材を端末内にコピーして保持", isOn: $copy)
            } header: { Text("動画を追加") } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Box・Google Driveも「ファイル」の場所から選べます。各アプリをインストールして「ファイル」で有効にしてください。フォルダー選択に対応しない提供元では，動画の複数選択を使えます。")
                    Text(copy ? "クラウドの動画は取得後に端末へコピーします。使い終わったコピーは右上の「容量」から削除できます。" : "ファイルを参照し，重複保存を減らします。クラウドや外部ドライブに再アクセスできる必要があります。写真ライブラリの動画はコピーします。")
                }
            }
            Section {
                if store.project.clips.isEmpty {
                    Text("まず動画を追加してください。内容を再生してから，表示名・バンド名・出演順を整えられます。元のファイル名はそのままで使えます。")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.project.arrangedGroups) { group in
                    ImportedBandRow(group: group, inspect: { inspection = $0 }, edit: edit,
                        relink: { relink = $0; request = MediaPickerRequest(multiple: false) }, remove: { removal = $0 })
                }.onMove { store.project.moveGroups(from: $0, to: $1) }
            } header: {
                HStack {
                    Text("動画一覧・出演順")
                    Spacer()
                    if !store.project.clips.isEmpty {
                        Menu {
                            Button(editMode.isEditing ? "並べ替えを完了" : "ドラッグで並べ替え") { editMode = editMode.isEditing ? .inactive : .active }
                            Button("表示名の番号順に並べ替え") { store.project.sortGroupsByDisplayName() }
                        } label: { Label("並べ替え", systemImage: "arrow.up.arrow.down").frame(minHeight: 44) }
                    }
                }
            }
        }
        .buttonStyle(.borderless).environment(\.editMode, $editMode)
        .sheet(item: $request) { selectedRequest in
            MediaDocumentPicker(request: selectedRequest, selected: { urls in
                request = nil
                Task {
                    if selectedRequest.folder, let folder = urls.first { await store.importFolder(folder, copy: copy) }
                    else { await store.importVideos(urls, copy: copy, relink: relink) }
                }
            }, cancelled: { request = nil })
        }
        .sheet(item: $inspection) { clip in
            NavigationStack {
                ClipEditor(id: clip.id).navigationTitle("動画を確認・整理").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { Task { do { try await store.flush(); inspection = nil } catch { store.message = error.localizedDescription } } } } }
            }
        }
        .confirmationDialog("動画を一覧から外しますか？", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            Button("一覧から外す（コピーは残す）") { if let clip = removal { Task { await store.removeClip(clip.id, deleteCopy: false) } }; removal = nil }
            if removal?.source.relativePath != nil {
                Button("一覧から外して端末のコピーも削除", role: .destructive) { if let clip = removal { Task { await store.removeClip(clip.id, deleteCopy: true) } }; removal = nil }
            }
            Button("キャンセル", role: .cancel) { removal = nil }
        } message: { Text("Box・Google Drive・写真ライブラリなどの元動画は削除しません。別の編集箇所で使っているコピーも残します。") }
        .onChange(of: photos) { _, items in guard !items.isEmpty else { return }; Task { await store.importPhotosVideos(items); photos = [] } }
    }
}

private struct ImportedBandRow: View {
    @EnvironmentObject private var store: AppStore
    let group: ClipGroup
    let inspect: (Clip) -> Void
    let edit: (UUID) -> Void
    let relink: (UUID) -> Void
    let remove: (Clip) -> Void
    private var position: Int { store.project.arrangedGroups.firstIndex(where: { $0.id == group.id }) ?? 0 }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("\(position + 1)").font(.headline.monospacedDigit()).padding(8).background(Color.accentColor.opacity(0.12), in: Circle())
                Text(group.clips[0].bandName).font(.headline)
                Spacer()
                if group.clips.count > 1 { Text("\(group.clips.count)本を連結").font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(group.clips) { clip in
                VStack(alignment: .leading, spacing: 8) {
                    Text(clip.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text("\(Clock.text(clip.duration))・\(clip.source.width)×\(clip.source.height)\(clip.source.hasAudio ? "" : "・音声なし")\(clip.source.isHDR ? "・HDR" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("内容を確認・名前を変更", systemImage: "play.rectangle") { inspect(clip) }
                        .frame(minHeight: 44).accessibilityIdentifier("inspect-" + clip.id.uuidString)
                    HStack {
                        Button("カット", systemImage: "scissors") { edit(clip.id) }.frame(minHeight: 44)
                        Spacer()
                        operations(for: clip)
                    }
                }
            }
            HStack {
                Button("出演順を前へ", systemImage: "arrow.up") { store.project.moveGroup(position, by: -1) }.disabled(position == 0)
                Spacer()
                Button("出演順を後へ", systemImage: "arrow.down") { store.project.moveGroup(position, by: 1) }.disabled(position + 1 == store.project.groups.count)
            }.font(.caption).frame(minHeight: 44)
        }.padding(.vertical, 8)
    }
    private func operations(for clip: Clip) -> some View {
        Menu {
            if let index = store.project.clips.firstIndex(where: { $0.id == clip.id }), index > 0 {
                Button(clip.joinPrevious ? "前の動画との連結を解除" : "前の動画と同じバンドに連結") { store.project.clips[index].joinPrevious.toggle() }
            }
            if group.clips.count > 1 {
                Button("連結内で前へ移動") { store.project.movePart(clip.id, by: -1) }.disabled(group.clips.first?.id == clip.id)
                Button("連結内で後へ移動") { store.project.movePart(clip.id, by: 1) }.disabled(group.clips.last?.id == clip.id)
            }
            Button("素材を選び直す") { relink(clip.id) }
            Button("一覧から外す・コピーを削除", role: .destructive) { remove(clip) }
        } label: { Label("操作", systemImage: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
    }
}
