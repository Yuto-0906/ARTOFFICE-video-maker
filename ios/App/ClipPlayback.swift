import AVKit
import SwiftUI

@MainActor enum PlaybackAudio {
    private static var owner: UUID?
    static func activate(owner: UUID) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .moviePlayback)
        try session.setActive(true)
        self.owner = owner
    }
    static func release(owner: UUID) {
        guard self.owner == owner else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        self.owner = nil
    }
}

struct EmbeddedMoviePlayer: UIViewControllerRepresentable {
    let player: AVPlayer?
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = false; controller.videoGravity = .resizeAspect
        controller.player = player
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}

@MainActor final class PlaybackModel: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var current = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var lease: SourceLease?
    private var observer: Any?
    private var stateObserver: NSKeyValueObservation?
    private var itemObserver: NSKeyValueObservation?
    private var generation = UUID()
    private var start: Double = 0
    private var end: Double = 0
    private var duration: Double = 0
    func load(_ clip: Clip, directory: URL) async {
        stop(); error = nil; loading = true
        let operation = generation
        do {
            let source = clip.source
            let access = try await Task.detached { try SourceLease(source: source, projectDirectory: directory) }.value
            try Task.checkCancellation()
            guard generation == operation else { return }
            let item = AVPlayerItem(url: access.url), budget = DeviceBudget.current()
            item.preferredForwardBufferDuration = 2
            item.preferredMaximumResolution = CGSize(width: budget.previewHeight * 16 / 9, height: budget.previewHeight)
            let player = AVPlayer(playerItem: item)
            player.isMuted = false; player.volume = 1; player.actionAtItemEnd = .pause
            lease = access; self.player = player; duration = Clock.seconds(clip.source.duration)
            updateRange(clip); seek(Clock.seconds(clip.start))
            stateObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in guard let self, self.generation == operation else { return }; self.isPlaying = self.player?.timeControlStatus != .paused && self.player != nil }
            }
            itemObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                let message = item.error?.localizedDescription ?? "動画を再生できません。素材を選び直してください。"
                Task { @MainActor [weak self] in guard let self, self.generation == operation else { return }; self.pause(); self.error = message }
            }
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] value in
                guard let self, self.generation == operation, value.isNumeric else { return }; self.current = value.seconds
            }
            loading = false
        } catch {
            guard generation == operation else { return }
            stop(); if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
    func updateRange(_ clip: Clip) {
        start = Clock.seconds(clip.start); end = Clock.seconds(clip.end)
        player?.currentItem?.forwardPlaybackEndTime = CMTime(ticks: clip.end)
    }
    func seek(_ seconds: Double) {
        pause(); current = min(max(0, seconds), max(0, duration - 0.001))
        player?.seek(to: CMTime(seconds: current, preferredTimescale: Clock.scale), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func play() {
        guard let player else { return }
        do { try PlaybackAudio.activate(owner: generation) }
        catch { self.error = error.localizedDescription; return }
        if current >= end - 0.02 { seek(start) }
        player.isMuted = false; player.volume = 1; player.play(); isPlaying = true
    }
    func pause() { player?.pause(); isPlaying = false }
    func toggle() { if isPlaying { pause() } else { play() } }
    func step(_ frames: Int) { pause(); player?.currentItem?.step(byCount: frames) }
    func stop() {
        pause(); PlaybackAudio.release(owner: generation); generation = UUID()
        stateObserver = nil; itemObserver = nil
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil; player?.replaceCurrentItem(with: nil); player = nil; lease = nil; current = 0; loading = false
    }
}
