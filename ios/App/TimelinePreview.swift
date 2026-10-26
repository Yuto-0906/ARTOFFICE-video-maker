import AVKit
import SwiftUI

@MainActor final class TimelinePlayback: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var current: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var loading = true
    @Published private(set) var error: String?
    private var composition: RenderComposition?
    private var observer: Any?
    private var statusObserver: NSKeyValueObservation?
    private var generation = UUID()

    func load(project: Project, directory: URL) async {
        stop(); loading = true; error = nil
        let operation = generation
        do {
            let timeline = try Timeline(project)
            guard let end = timeline.chunks(rate: project.frameRate).last?.end else { throw AppError.message("動画を追加してください。") }
            let budget = DeviceBudget.current()
            let prepared = try await CompositionBuilder.build(project: project, directory: directory, previewHeight: Int(budget.previewHeight))
            try Task.checkCancellation()
            guard generation == operation else { return }
            let item = AVPlayerItem(asset: prepared.asset)
            item.videoComposition = prepared.video; item.audioMix = prepared.audio
            item.preferredForwardBufferDuration = 2
            item.preferredMaximumResolution = prepared.video.renderSize
            item.forwardPlaybackEndTime = CMTime(ticks: end)
            composition = prepared // Keep source security scopes for the whole playback.
            let player = AVPlayer(playerItem: item)
            player.actionAtItemEnd = .pause
            self.player = player; duration = Clock.seconds(end)
            statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                let message = item.error?.localizedDescription ?? "プレビューを再生できません。素材を確認してください。"
                Task { @MainActor [weak self] in
                    guard let self, self.generation == operation else { return }
                    self.player?.pause(); self.error = message
                }
            }
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
                guard let self, self.generation == operation, time.isNumeric else { return }; self.current = time.seconds
            }
            loading = false
        } catch {
            guard generation == operation else { return }
            loading = false
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
    func seek(_ seconds: Double) {
        let time = min(max(0, seconds), max(0, duration - 0.001))
        player?.pause()
        player?.seek(to: CMTime(seconds: time, preferredTimescale: Clock.scale), toleranceBefore: .zero, toleranceAfter: .zero)
        current = time
    }
    func play() {
        if current >= duration - 0.05 { seek(0) }
        player?.play()
    }
    func pause() { player?.pause() }
    func stop() {
        generation = UUID()
        statusObserver = nil
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil; player?.replaceCurrentItem(with: nil); player = nil
        composition = nil; current = 0; duration = 0
    }
}

struct TimelinePreview: View {
    let project: Project
    let directory: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var playback = TimelinePlayback()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if playback.loading {
                        ProgressView("プレビューを準備しています").frame(maxWidth: .infinity, minHeight: 180)
                    } else if let error = playback.error {
                        ContentUnavailableView("プレビューを開けません", systemImage: "exclamationmark.triangle", description: Text(error))
                    } else {
                        VideoPlayer(player: playback.player).aspectRatio(16 / 9, contentMode: .fit).background(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        Text("\(Clock.text(Clock.ticks(playback.current), precise: true)) / \(Clock.text(Clock.ticks(playback.duration), precise: true))")
                            .font(.system(.subheadline, design: .monospaced)).frame(maxWidth: .infinity)
                        Slider(value: Binding(get: { min(playback.duration, max(0, playback.current)) }, set: { playback.seek($0) }), in: 0...max(0.01, playback.duration))
                            .accessibilityLabel("完成動画の再生位置")
                        HStack {
                            Button("10秒戻る", systemImage: "gobackward.10") { playback.seek(playback.current - 10) }.labelStyle(.iconOnly)
                            Spacer()
                            Button("再生", systemImage: "play.fill") { playback.play() }
                            Button("停止", systemImage: "pause.fill") { playback.pause() }
                            Spacer()
                            Button("10秒進む", systemImage: "goforward.10") { playback.seek(playback.current + 10) }.labelStyle(.iconOnly)
                        }.buttonStyle(.bordered).controlSize(.large)
                        Text("タイトル・映像・音声のつながりを確認できます。表示は軽い解像度に調整しています。完成動画は選択した画質で書き出します。")
                            .font(.caption).foregroundStyle(.secondary)
                        if let timeline = try? Timeline(project) {
                            GroupBox("バンドへ移動") {
                                VStack(spacing: 0) {
                                    ForEach(timeline.segments.filter(\.isBandHead), id: \.index) { segment in
                                        Button { playback.seek(Clock.seconds(segment.start)); playback.play() } label: {
                                            HStack {
                                                Text(segment.clip.bandName).multilineTextAlignment(.leading)
                                                Spacer()
                                                Text(Clock.text(segment.start)).font(.system(.caption, design: .monospaced))
                                            }.frame(maxWidth: .infinity, minHeight: 44)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }.padding().frame(maxWidth: 1000).frame(maxWidth: .infinity)
            }
            .navigationTitle("仕上がりを確認")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
        }
        .task { await playback.load(project: project, directory: directory) }
        .onDisappear { playback.stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { playback.pause() } }
    }
}
