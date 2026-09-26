import AVFoundation
import Foundation
import MediaPlayer
import UIKit
import TWiTShared

final class NativeMediaAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == NativeMediaEngine.sessionID else {
            completionHandler()
            return
        }
        NativeMediaEngine.shared.backgroundCompletionHandler = completionHandler
    }
}

/** AVFoundation implementation called by the Kotlin iOS adapters. */
final class NativeMediaEngine: NSObject, IosNativeMediaEngine, URLSessionDownloadDelegate {
    static let shared = NativeMediaEngine()
    static let sessionID = "com.example.twitgo.media-download"

    var backgroundCompletionHandler: (() -> Void)?
    private let player = AVPlayer()
    private let fileManager = FileManager.default
    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    private var pausingDownloads = Set<String>()
    private var currentURL: String?
    private var currentTitle: String?
    private var timeObserver: Any?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private enum Key {
        static let playbackURL = "media.playback.url"
        static let playbackTitle = "media.playback.title"
        static let playbackPosition = "media.playback.position"
        static let originalPrefix = "media.download.original."
        static let pathPrefix = "media.download.path."
    }

    private override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 1),
            queue: .main
        ) { [weak self] _ in
            self?.savePlaybackProgress()
            IosMediaRuntime.shared.reportPlaybackPlaying(positionMs: self?.player.currentTime().milliseconds ?? 0)
        }
        _ = session
        restorePlayback()
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            tasks.compactMap { $0 as? URLSessionDownloadTask }.forEach { task in
                guard let id = task.taskDescription else { return }
                self.activeTasks[id] = task
                IosMediaRuntime.shared.reportDownloadQueued(downloadId: id)
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    func loadPlayback(originalEnclosureUrl: String, title: String, startPositionMs: Int64) {
        currentURL = originalEnclosureUrl
        currentTitle = title
        UserDefaults.standard.set(originalEnclosureUrl, forKey: Key.playbackURL)
        UserDefaults.standard.set(title, forKey: Key.playbackTitle)
        let url = completedFile(forOriginalURL: originalEnclosureUrl) ?? URL(string: originalEnclosureUrl)
        guard let url else {
            IosMediaRuntime.shared.reportPlaybackFailed()
            return
        }
        player.pause()
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.seek(to: CMTime(milliseconds: startPositionMs)) { _ in
            IosMediaRuntime.shared.reportPlaybackReady(positionMs: startPositionMs)
        }
    }

    func play() {
        player.play()
        IosMediaRuntime.shared.reportPlaybackPlaying(positionMs: player.currentTime().milliseconds)
    }

    func pause() {
        player.pause()
        savePlaybackProgress()
        IosMediaRuntime.shared.reportPlaybackPaused(positionMs: player.currentTime().milliseconds)
    }

    func seekTo(positionMs: Int64) {
        player.seek(to: CMTime(milliseconds: positionMs)) { [weak self] _ in
            guard let self else { return }
            self.savePlaybackProgress()
            IosMediaRuntime.shared.reportPlaybackPaused(positionMs: self.player.currentTime().milliseconds)
        }
    }

    func setSpeed(speed: Float) { player.rate = speed }

    func stopPlayback() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        UserDefaults.standard.removeObject(forKey: Key.playbackURL)
        UserDefaults.standard.removeObject(forKey: Key.playbackTitle)
        UserDefaults.standard.removeObject(forKey: Key.playbackPosition)
    }

    func enqueueDownload(downloadId: String, originalEnclosureUrl: String) {
        removeDownload(downloadId)
        UserDefaults.standard.set(originalEnclosureUrl, forKey: originalKey(downloadId))
        resolveAndStart(downloadId: downloadId, originalEnclosureUrl: originalEnclosureUrl)
    }

    func pauseDownload(downloadId: String) {
        guard let task = activeTasks[downloadId] else { return }
        // Retained URLSession resume data is deliberately never reused. A later resume
        // resolves the original enclosure and starts a fresh validated representation.
        pausingDownloads.insert(downloadId)
        task.cancel(byProducingResumeData: { _ in
            DispatchQueue.main.async {
                self.activeTasks[downloadId] = nil
                IosMediaRuntime.shared.reportDownloadPaused(downloadId: downloadId)
            }
        })
    }

    func resumeDownload(downloadId: String, originalEnclosureUrl: String) {
        guard activeTasks[downloadId] == nil else { return }
        UserDefaults.standard.set(originalEnclosureUrl, forKey: originalKey(downloadId))
        resolveAndStart(downloadId: downloadId, originalEnclosureUrl: originalEnclosureUrl)
    }

    func deleteDownload(downloadId: String) { removeDownload(downloadId) }

    private func resolveAndStart(downloadId: String, originalEnclosureUrl: String) {
        guard let original = URL(string: originalEnclosureUrl), original.scheme == "https" else {
            IosMediaRuntime.shared.reportDownloadFailed(downloadId: downloadId)
            return
        }
        IosMediaRuntime.shared.reportDownloadQueued(downloadId: downloadId)
        resolveRedirect(for: original) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                guard case let .success(resolved) = result else {
                    IosMediaRuntime.shared.reportDownloadFailed(downloadId: downloadId)
                    return
                }
                let task = self.session.downloadTask(with: resolved)
                task.taskDescription = downloadId
                self.activeTasks[downloadId] = task
                task.resume()
            }
        }
    }

    private func resolveRedirect(for originalURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        var request = URLRequest(url: originalURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession(configuration: .ephemeral).dataTask(with: request) { _, response, error in
            if let error { completion(.failure(error)); return }
            guard let resolved = response?.url, resolved.scheme == "https" else {
                completion(.failure(URLError(.badServerResponse)))
                return
            }
            completion(.success(resolved))
        }.resume()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = downloadTask.taskDescription else { return }
        IosMediaRuntime.shared.reportDownloadProgress(
            downloadId: id,
            bytesDownloaded: totalBytesWritten,
            totalBytes: totalBytesExpectedToWrite
        )
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription,
              let response = downloadTask.response as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else { return }
        let size = ((try? fileManager.attributesOfItem(atPath: location.path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard size > 0, response.expectedContentLength <= 0 || size == response.expectedContentLength else {
            IosMediaRuntime.shared.reportDownloadFailed(downloadId: id)
            return
        }
        let destination = downloadDirectory.appendingPathComponent(fileName(id))
        do {
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: location, to: destination)
            UserDefaults.standard.set(destination.path, forKey: pathKey(id))
            IosMediaRuntime.shared.reportDownloadCompleted(downloadId: id, bytesDownloaded: size)
        } catch {
            IosMediaRuntime.shared.reportDownloadFailed(downloadId: id)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        DispatchQueue.main.async {
            self.activeTasks[id] = nil
            if self.pausingDownloads.remove(id) != nil {
                IosMediaRuntime.shared.reportDownloadPaused(downloadId: id)
                return
            }
            if error != nil { IosMediaRuntime.shared.reportDownloadFailed(downloadId: id) }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }

    private var downloadDirectory: URL {
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TWiTGoMedia", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func removeDownload(_ id: String) {
        activeTasks[id]?.cancel()
        activeTasks[id] = nil
        if let path = UserDefaults.standard.string(forKey: pathKey(id)) { try? fileManager.removeItem(atPath: path) }
        UserDefaults.standard.removeObject(forKey: originalKey(id))
        UserDefaults.standard.removeObject(forKey: pathKey(id))
    }

    private func completedFile(forOriginalURL original: String) -> URL? {
        UserDefaults.standard.dictionaryRepresentation().first { key, value in
            key.hasPrefix(Key.originalPrefix) && value as? String == original
        }.flatMap { entry in
            let id = String(entry.key.dropFirst(Key.originalPrefix.count))
            guard let path = UserDefaults.standard.string(forKey: pathKey(id)), fileManager.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    private func restorePlayback() {
        guard let url = UserDefaults.standard.string(forKey: Key.playbackURL),
              let title = UserDefaults.standard.string(forKey: Key.playbackTitle) else { return }
        let position = Int64(UserDefaults.standard.double(forKey: Key.playbackPosition) * 1_000)
        IosMediaRuntime.shared.restorePlayback(originalEnclosureUrl: url, title: title, positionMs: position)
        loadPlayback(originalEnclosureUrl: url, title: title, startPositionMs: position)
    }

    private func savePlaybackProgress() {
        guard currentURL != nil else { return }
        UserDefaults.standard.set(Double(player.currentTime().milliseconds) / 1_000, forKey: Key.playbackPosition)
    }

    private func originalKey(_ id: String) -> String { Key.originalPrefix + id }
    private func pathKey(_ id: String) -> String { Key.pathPrefix + id }
    private func fileName(_ id: String) -> String { Data(id.utf8).base64EncodedString() }
}

private extension CMTime {
    init(milliseconds: Int64) { self.init(value: milliseconds, timescale: 1_000) }
    var milliseconds: Int64 {
        guard isNumeric, seconds.isFinite else { return 0 }
        return Int64((seconds * 1_000).rounded())
    }
}
