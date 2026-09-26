import SwiftUI
import AVKit
import MediaPlayer

struct MediaProbeView: View {
    @StateObject private var probe = MediaProbePlayer()
    @ObservedObject private var download = DownloadProbeManager.shared
    @State private var caseID = MediaProbeView.argument("-caseID") ?? UserDefaults.standard.string(forKey: "mediaProbe.caseID") ?? "Hands-On Android C"
    @State private var source = MediaProbeView.argument("-mediaURL") ?? UserDefaults.standard.string(forKey: "mediaProbe.originalURL") ?? "https://pdst.fm/e/pscrb.fm/rss/p/mgln.ai/e/294/cdn.twit.tv/audio/hoai/hoai_C/hoai_C.mp3"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("TWiT Go").font(.largeTitle.bold())
                Text("Media sample").font(.headline)
                ProbePlayerController(player: probe.player)
                    .frame(height: 230)
                TextField("Case ID", text: $caseID)
                    .textFieldStyle(.roundedBorder)
                TextField("Original RSS enclosure URL", text: $source)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Load (paused)") { probe.load(source, title: caseID) }
                    Button("Play") { probe.play() }
                    Button("Pause") { probe.pause() }
                    Button("Seek +30s") { probe.seekForward() }
                }
                .buttonStyle(.bordered)
                HStack {
                    Button("Download") { download.start(source) }
                    Button("Stop, keep partial") { download.stopKeepingPartial() }
                    Button("Resume download") { download.resume() }
                }
                .buttonStyle(.bordered)
                Button("Play downloaded") {
                    guard let file = download.localFileURL else { return }
                    probe.loadLocal(file, title: caseID)
                    probe.play()
                }
                .buttonStyle(.bordered)
                Text(download.status).font(.caption.monospaced())
                Text(probe.status).font(.caption.monospaced())
                Text("Use the video controls for Picture in Picture. Lock the phone or use Control Center for background controls.")
                    .font(.caption)
            }
            .padding()
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-autoPlayMediaSpike") {
                probe.load(source, title: caseID)
                probe.play()
            }
            if ProcessInfo.processInfo.arguments.contains("-autoDownloadMediaSpike") {
                download.start(source)
            }
        }
    }

    private static func argument(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }
}

private struct ProbePlayerController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
    }
}

private final class MediaProbePlayer: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var status = "idle"
    private var title = "TWiT media probe"
    private var timeObserver: Any?
    private var notifications: [NSObjectProtocol] = []
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var itemObservation: NSKeyValueObservation?
    private var pendingResumeSeconds: Double?

    private enum ResumeKey {
        static let url = "mediaProbe.originalURL"
        static let title = "mediaProbe.caseID"
        static let seconds = "mediaProbe.positionSeconds"
    }

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] _ in
            self?.refreshStatus()
            self?.saveProgress()
        }
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] _ in
            self?.player.pause()
            self?.status = "audio interrupted · paused"
        })
        notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
            guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            self?.player.pause()
            self?.status = "output disconnected · paused"
        })
        let commands = MPRemoteCommandCenter.shared()
        remoteTargets.append((commands.playCommand, commands.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }))
        remoteTargets.append((commands.pauseCommand, commands.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }))
        remoteTargets.append((commands.changePlaybackPositionCommand, commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.player.seek(to: CMTime(seconds: event.positionTime, preferredTimescale: 600))
            return .success
        }))
        if let savedURL = UserDefaults.standard.string(forKey: ResumeKey.url) {
            load(savedURL, title: UserDefaults.standard.string(forKey: ResumeKey.title) ?? "TWiT media probe", restoring: true)
        }
    }

    deinit {
        saveProgress()
        itemObservation = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        notifications.forEach(NotificationCenter.default.removeObserver)
        remoteTargets.forEach { command, target in command.removeTarget(target) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func load(_ urlString: String, title: String, restoring: Bool = false) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https" else {
            status = "Use an HTTPS enclosure URL from the test matrix."
            return
        }
        self.title = title.isEmpty ? "TWiT media probe" : title
        let savedSeconds = restoring ? UserDefaults.standard.double(forKey: ResumeKey.seconds) : 0
        pendingResumeSeconds = restoring && savedSeconds.isFinite && savedSeconds > 0 ? savedSeconds : nil
        UserDefaults.standard.set(url.absoluteString, forKey: ResumeKey.url)
        UserDefaults.standard.set(self.title, forKey: ResumeKey.title)
        if !restoring { UserDefaults.standard.set(0, forKey: ResumeKey.seconds) }
        player.pause()
        itemObservation = nil
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.player.currentItem === item,
                      item.status == .readyToPlay,
                      let seconds = self.pendingResumeSeconds else { return }
                self.player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                                 toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self, self.player.currentItem === item else { return }
                        self.pendingResumeSeconds = nil
                        self.refreshStatus()
                        self.saveProgress()
                    }
                }
            }
        }
        status = "loading · paused"
        refreshStatus()
    }

    func play() {
        guard player.currentItem != nil else { status = "Load a case first."; return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            player.play()
            refreshStatus()
        } catch {
            status = "Audio session error: \(type(of: error))"
        }
    }

    func loadLocal(_ file: URL, title: String) {
        self.title = title.isEmpty ? "TWiT media probe" : title
        pendingResumeSeconds = nil
        itemObservation = nil
        player.pause()
        player.replaceCurrentItem(with: AVPlayerItem(url: file))
        status = "loading local file · paused"
    }

    func pause() { player.pause(); refreshStatus() }

    func seekForward() {
        let target = CMTimeAdd(player.currentTime(), CMTime(seconds: 30, preferredTimescale: 600))
        player.seek(to: target)
    }

    private func refreshStatus() {
        guard let item = player.currentItem else { return }
        if let error = item.error {
            status = "player error: \(type(of: error))"
            return
        }
        let phase: String
        switch item.status {
        case .readyToPlay: phase = "ready"
        case .failed: phase = "failed"
        default: phase = "loading"
        }
        let elapsed = player.currentTime().seconds.isFinite ? Int(player.currentTime().seconds) : 0
        let duration = item.duration.seconds.isFinite ? String(Int(item.duration.seconds)) : "?"
        status = "\(phase) · \(player.timeControlStatus == .playing ? "playing" : "paused") · \(elapsed)s / \(duration)s"
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: player.rate,
            MPMediaItemPropertyPlaybackDuration: item.duration.seconds.isFinite ? item.duration.seconds : 0,
        ]
    }

    private func saveProgress() {
        guard pendingResumeSeconds == nil, player.currentItem != nil else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return }
        let completed = player.currentItem?.duration.seconds ?? .nan
        let position = completed.isFinite && completed > 0 && seconds >= completed - 1 ? 0 : seconds
        UserDefaults.standard.set(position, forKey: ResumeKey.seconds)
    }
}
