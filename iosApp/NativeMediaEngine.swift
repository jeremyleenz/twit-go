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
    private struct RepresentationValidators {
        let eTag: String?
        let length: Int64?
    }

    private struct ResolvedRepresentation {
        let url: URL
        let validators: RepresentationValidators
    }

    private struct ActiveTransfer {
        let task: URLSessionDownloadTask
        let validators: RepresentationValidators
    }

    private struct RetainedPartial {
        let data: Data
        let validators: RepresentationValidators
    }

    private var activeTransfers: [String: ActiveTransfer] = [:]
    private var pausingTaskIdentifiers = Set<Int>()
    private var pendingResolutions: [String: UUID] = [:]
    private var currentDownloadID: String?
    private var timeObserver: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var wantsPlayback = false
    private var nativePlaybackActive = false

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private enum Key {
        static let playbackURL = "media.playback.url"
        static let playbackTitle = "media.playback.title"
        static let playbackDownloadID = "media.playback.download-id"
        static let playbackPosition = "media.playback.position"
        static let originalPrefix = "media.download.original."
        static let pathPrefix = "media.download.path."
        static let resumeETagPrefix = "media.download.resume.etag."
        static let resumeLengthPrefix = "media.download.resume.length."
    }

    private override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 1),
            queue: .main
        ) { [weak self] _ in
            guard let self, self.player.timeControlStatus == .playing else { return }
            self.savePlaybackProgress()
            IosMediaRuntime.shared.reportPlaybackPlaying(positionMs: self.player.currentTime().milliseconds)
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard let self, self.currentDownloadID != nil else { return }
            switch player.timeControlStatus {
            case .playing:
                self.nativePlaybackActive = true
                IosMediaRuntime.shared.reportPlaybackPlaying(positionMs: player.currentTime().milliseconds)
            case .waitingToPlayAtSpecifiedRate:
                if self.wantsPlayback {
                    self.nativePlaybackActive = true
                    IosMediaRuntime.shared.reportPlaybackLoading(positionMs: player.currentTime().milliseconds)
                }
            case .paused:
                if self.nativePlaybackActive {
                    self.nativePlaybackActive = false
                    IosMediaRuntime.shared.reportPlaybackPaused(positionMs: player.currentTime().milliseconds)
                }
            @unknown default:
                break
            }
        }
        _ = session
        restorePlayback()
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            tasks.compactMap { $0 as? URLSessionDownloadTask }.forEach { task in
                guard let id = task.taskDescription else { return }
                self.activeTransfers[id] = ActiveTransfer(task: task, validators: self.savedValidators(for: id))
                IosMediaRuntime.shared.reportDownloadQueued(downloadId: id)
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    func loadPlayback(downloadId: String, originalEnclosureUrl: String, title: String, startPositionMs: Int64) {
        currentDownloadID = downloadId
        wantsPlayback = false
        nativePlaybackActive = false
        UserDefaults.standard.set(originalEnclosureUrl, forKey: Key.playbackURL)
        UserDefaults.standard.set(title, forKey: Key.playbackTitle)
        UserDefaults.standard.set(downloadId, forKey: Key.playbackDownloadID)
        let url = completedFile(forDownloadID: downloadId) ?? URL(string: originalEnclosureUrl)
        guard let url else {
            IosMediaRuntime.shared.reportPlaybackFailed()
            return
        }
        player.pause()
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                guard let self, self.player.currentItem === observedItem else { return }
                switch observedItem.status {
                case .readyToPlay:
                    self.player.seek(to: CMTime(milliseconds: startPositionMs)) { [weak self] _ in
                        guard let self, self.player.currentItem === observedItem else { return }
                        if self.wantsPlayback {
                            self.player.play()
                        } else {
                            IosMediaRuntime.shared.reportPlaybackReady(positionMs: self.player.currentTime().milliseconds)
                        }
                    }
                case .failed:
                    self.wantsPlayback = false
                    self.nativePlaybackActive = false
                    IosMediaRuntime.shared.reportPlaybackFailed()
                default:
                    break
                }
            }
        }
    }

    func play() {
        wantsPlayback = true
        guard let item = player.currentItem else {
            IosMediaRuntime.shared.reportPlaybackFailed()
            return
        }
        switch item.status {
        case .readyToPlay: player.play()
        case .failed: IosMediaRuntime.shared.reportPlaybackFailed()
        default: break
        }
    }

    func pause() {
        wantsPlayback = false
        nativePlaybackActive = false
        player.pause()
        savePlaybackProgress()
        if player.currentItem?.status == .readyToPlay {
            IosMediaRuntime.shared.reportPlaybackPaused(positionMs: player.currentTime().milliseconds)
        }
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
        wantsPlayback = false
        nativePlaybackActive = false
        currentDownloadID = nil
        itemStatusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        UserDefaults.standard.removeObject(forKey: Key.playbackURL)
        UserDefaults.standard.removeObject(forKey: Key.playbackTitle)
        UserDefaults.standard.removeObject(forKey: Key.playbackDownloadID)
        UserDefaults.standard.removeObject(forKey: Key.playbackPosition)
    }

    func enqueueDownload(downloadId: String, originalEnclosureUrl: String) {
        removeDownload(downloadId)
        UserDefaults.standard.set(originalEnclosureUrl, forKey: originalKey(downloadId))
        resolveAndStart(downloadId: downloadId, originalEnclosureUrl: originalEnclosureUrl)
    }

    func pauseDownload(downloadId: String) {
        if pendingResolutions.removeValue(forKey: downloadId) != nil {
            IosMediaRuntime.shared.reportDownloadPaused(downloadId: downloadId)
            return
        }
        guard let transfer = activeTransfers[downloadId] else { return }
        let task = transfer.task
        pausingTaskIdentifiers.insert(task.taskIdentifier)
        task.cancel(byProducingResumeData: { resumeData in
            DispatchQueue.main.async {
                guard self.isCurrent(task, for: downloadId) else { return }
                if let resumeData {
                    self.saveRetainedPartial(resumeData, validators: transfer.validators, for: downloadId)
                } else {
                    self.clearRetainedPartial(for: downloadId)
                }
                self.activeTransfers[downloadId] = nil
                self.pausingTaskIdentifiers.remove(task.taskIdentifier)
                IosMediaRuntime.shared.reportDownloadPaused(downloadId: downloadId)
            }
        })
    }

    func resumeDownload(downloadId: String, originalEnclosureUrl: String) {
        guard activeTransfers[downloadId] == nil else { return }
        UserDefaults.standard.set(originalEnclosureUrl, forKey: originalKey(downloadId))
        resolveAndStart(downloadId: downloadId, originalEnclosureUrl: originalEnclosureUrl)
    }

    func deleteDownload(downloadId: String) { removeDownload(downloadId) }

    func reconcileDownload(downloadId: String) {
        if let file = completedFile(forDownloadID: downloadId) {
            let size = ((try? fileManager.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? 0
            IosMediaRuntime.shared.reportDownloadCompleted(downloadId: downloadId, bytesDownloaded: size)
        } else if activeTransfers[downloadId] != nil || pendingResolutions[downloadId] != nil {
            IosMediaRuntime.shared.reportDownloadQueued(downloadId: downloadId)
        } else if retainedPartial(for: downloadId) != nil {
            IosMediaRuntime.shared.reportDownloadPaused(downloadId: downloadId)
        } else {
            IosMediaRuntime.shared.reportDownloadFailed(downloadId: downloadId)
        }
    }

    private func resolveAndStart(downloadId: String, originalEnclosureUrl: String) {
        guard let original = URL(string: originalEnclosureUrl), original.scheme == "https" else {
            IosMediaRuntime.shared.reportDownloadFailed(downloadId: downloadId)
            return
        }
        let token = UUID()
        pendingResolutions[downloadId] = token
        IosMediaRuntime.shared.reportDownloadQueued(downloadId: downloadId)
        resolveRedirect(for: original) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.pendingResolutions[downloadId] == token else { return }
                self.pendingResolutions[downloadId] = nil
                guard case let .success(resolved) = result else {
                    IosMediaRuntime.shared.reportDownloadFailed(downloadId: downloadId)
                    return
                }
                let retained = self.retainedPartial(for: downloadId)
                let task: URLSessionDownloadTask
                if let retained, self.canSafelyResume(retained, against: resolved.validators) {
                    self.clearResumeData(for: downloadId)
                    task = self.session.downloadTask(withResumeData: retained.data)
                } else {
                    self.clearRetainedPartial(for: downloadId)
                    task = self.session.downloadTask(with: resolved.url)
                }
                task.taskDescription = downloadId
                self.saveValidators(resolved.validators, for: downloadId)
                self.activeTransfers[downloadId] = ActiveTransfer(task: task, validators: resolved.validators)
                task.resume()
            }
        }
    }

    private func resolveRedirect(for originalURL: URL, completion: @escaping (Result<ResolvedRepresentation, Error>) -> Void) {
        var request = URLRequest(url: originalURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession(configuration: .ephemeral).dataTask(with: request) { _, response, error in
            if let error { completion(.failure(error)); return }
            guard let resolved = response?.url,
                  resolved.scheme == "https",
                  let http = response as? HTTPURLResponse else {
                completion(.failure(URLError(.badServerResponse)))
                return
            }
            let length = response?.expectedContentLength ?? -1
            completion(.success(ResolvedRepresentation(
                url: resolved,
                validators: RepresentationValidators(
                    eTag: http.value(forHTTPHeaderField: "ETag"),
                    length: length >= 0 ? length : nil,
                ),
            )))
        }.resume()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = currentDownloadID(for: downloadTask) else { return }
        IosMediaRuntime.shared.reportDownloadProgress(
            downloadId: id,
            bytesDownloaded: totalBytesWritten,
            totalBytes: totalBytesExpectedToWrite
        )
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = currentDownloadID(for: downloadTask),
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
            clearRetainedPartial(for: id)
            IosMediaRuntime.shared.reportDownloadCompleted(downloadId: id, bytesDownloaded: size)
        } catch {
            IosMediaRuntime.shared.reportDownloadFailed(downloadId: id)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let downloadTask = task as? URLSessionDownloadTask,
              let id = currentDownloadID(for: downloadTask) else { return }
        DispatchQueue.main.async {
            if self.pausingTaskIdentifiers.contains(task.taskIdentifier) {
                return
            }
            self.activeTransfers[id] = nil
            if error != nil { IosMediaRuntime.shared.reportDownloadFailed(downloadId: id) }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }

    private func currentDownloadID(for task: URLSessionDownloadTask) -> String? {
        guard let id = task.taskDescription,
              activeTransfers[id]?.task.taskIdentifier == task.taskIdentifier else { return nil }
        return id
    }

    private func isCurrent(_ task: URLSessionDownloadTask, for downloadId: String) -> Bool {
        activeTransfers[downloadId]?.task.taskIdentifier == task.taskIdentifier
    }

    private func retainedPartial(for downloadId: String) -> RetainedPartial? {
        guard let data = try? Data(contentsOf: resumeDataURL(for: downloadId)),
              let validators = savedValidatorsOrNil(for: downloadId) else { return nil }
        return RetainedPartial(data: data, validators: validators)
    }

    private func saveRetainedPartial(_ data: Data, validators: RepresentationValidators, for downloadId: String) {
        try? data.write(to: resumeDataURL(for: downloadId), options: .atomic)
        saveValidators(validators, for: downloadId)
    }

    private func canSafelyResume(_ retained: RetainedPartial, against latest: RepresentationValidators) -> Bool {
        guard let savedETag = retained.validators.eTag,
              let latestETag = latest.eTag,
              let savedLength = retained.validators.length,
              let latestLength = latest.length else { return false }
        return savedETag == latestETag && savedLength == latestLength
    }

    private func savedValidators(for downloadId: String) -> RepresentationValidators {
        savedValidatorsOrNil(for: downloadId) ?? RepresentationValidators(eTag: nil, length: nil)
    }

    private func savedValidatorsOrNil(for downloadId: String) -> RepresentationValidators? {
        guard let eTag = UserDefaults.standard.string(forKey: Key.resumeETagPrefix + downloadId),
              let length = UserDefaults.standard.object(forKey: Key.resumeLengthPrefix + downloadId) as? NSNumber else { return nil }
        return RepresentationValidators(eTag: eTag, length: length.int64Value)
    }

    private func saveValidators(_ validators: RepresentationValidators, for downloadId: String) {
        if let eTag = validators.eTag, let length = validators.length {
            UserDefaults.standard.set(eTag, forKey: Key.resumeETagPrefix + downloadId)
            UserDefaults.standard.set(length, forKey: Key.resumeLengthPrefix + downloadId)
        } else {
            UserDefaults.standard.removeObject(forKey: Key.resumeETagPrefix + downloadId)
            UserDefaults.standard.removeObject(forKey: Key.resumeLengthPrefix + downloadId)
        }
    }

    private func clearResumeData(for downloadId: String) {
        try? fileManager.removeItem(at: resumeDataURL(for: downloadId))
    }

    private func clearRetainedPartial(for downloadId: String) {
        clearResumeData(for: downloadId)
        UserDefaults.standard.removeObject(forKey: Key.resumeETagPrefix + downloadId)
        UserDefaults.standard.removeObject(forKey: Key.resumeLengthPrefix + downloadId)
    }

    private var downloadDirectory: URL {
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TWiTGoMedia", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func removeDownload(_ id: String) {
        pendingResolutions[id] = nil
        activeTransfers[id]?.task.cancel()
        activeTransfers[id] = nil
        clearRetainedPartial(for: id)
        if let path = UserDefaults.standard.string(forKey: pathKey(id)) { try? fileManager.removeItem(atPath: path) }
        UserDefaults.standard.removeObject(forKey: originalKey(id))
        UserDefaults.standard.removeObject(forKey: pathKey(id))
    }

    private func completedFile(forDownloadID id: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: pathKey(id)), fileManager.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func restorePlayback() {
        guard let url = UserDefaults.standard.string(forKey: Key.playbackURL),
              let title = UserDefaults.standard.string(forKey: Key.playbackTitle),
              let downloadID = UserDefaults.standard.string(forKey: Key.playbackDownloadID) else { return }
        let position = Int64(UserDefaults.standard.double(forKey: Key.playbackPosition) * 1_000)
        IosMediaRuntime.shared.restorePlayback(downloadId: downloadID, originalEnclosureUrl: url, title: title, positionMs: position)
        loadPlayback(downloadId: downloadID, originalEnclosureUrl: url, title: title, startPositionMs: position)
    }

    private func savePlaybackProgress() {
        guard currentDownloadID != nil else { return }
        UserDefaults.standard.set(Double(player.currentTime().milliseconds) / 1_000, forKey: Key.playbackPosition)
    }

    private func originalKey(_ id: String) -> String { Key.originalPrefix + id }
    private func pathKey(_ id: String) -> String { Key.pathPrefix + id }
    private func resumeDataURL(for id: String) -> URL {
        downloadDirectory.appendingPathComponent("resume-" + fileName(id))
    }
    private func fileName(_ id: String) -> String { Data(id.utf8).base64EncodedString() }
}

private extension CMTime {
    init(milliseconds: Int64) { self.init(value: milliseconds, timescale: 1_000) }
    var milliseconds: Int64 {
        guard isNumeric, seconds.isFinite else { return 0 }
        return Int64((seconds * 1_000).rounded())
    }
}
