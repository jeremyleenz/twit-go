import AVFoundation
import CryptoKit
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
        /// `URLSession` resume data contains its old request URL. If that target has expired,
        /// retry the just-resolved enclosure once as a new task rather than retrying it again.
        let freshFallback: ResolvedRepresentation?
    }

    private struct RetainedPartial {
        let data: Data
        let validators: RepresentationValidators
    }

    private var activeTransfers: [String: ActiveTransfer] = [:]
    private var pausingTaskIdentifiers = Set<Int>()
    private var resumeAfterPause: [String: String] = [:]
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
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
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
            self.guardOnMain {
                tasks.compactMap { $0 as? URLSessionDownloadTask }.forEach { task in
                    guard let id = task.taskDescription else { return }
                    self.activeTransfers[id] = ActiveTransfer(
                        task: task,
                        validators: self.savedValidators(for: id),
                        freshFallback: nil
                    )
                    IosMediaRuntime.shared.reportDownloadQueued(downloadId: id)
                }
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
        guardOnMain { self.enqueueDownload(downloadId: downloadId, originalEnclosureUrl: originalEnclosureUrl) }
        guard Thread.isMainThread else { return }
        removeDownload(downloadId)
        UserDefaults.standard.set(originalEnclosureUrl, forKey: originalKey(downloadId))
        resolveAndStart(downloadId: downloadId, originalEnclosureUrl: originalEnclosureUrl)
    }

    func pauseDownload(downloadId: String) {
        guardOnMain { self.pauseDownload(downloadId: downloadId) }
        guard Thread.isMainThread else { return }
        if pendingResolutions.removeValue(forKey: downloadId) != nil {
            IosMediaRuntime.shared.reportDownloadPaused(downloadId: downloadId)
            return
        }
        guard let transfer = activeTransfers[downloadId] else { return }
        let task = transfer.task
        guard !pausingTaskIdentifiers.contains(task.taskIdentifier) else { return }
        pausingTaskIdentifiers.insert(task.taskIdentifier)
        task.cancel(byProducingResumeData: { resumeData in
            DispatchQueue.main.async {
                guard self.isCurrent(task, for: downloadId) else { return }
                if let resumeData {
                    if !self.saveRetainedPartial(resumeData, validators: transfer.validators, for: downloadId) {
                        self.clearRetainedPartial(for: downloadId)
                    }
                } else {
                    self.clearRetainedPartial(for: downloadId)
                }
                self.activeTransfers[downloadId] = nil
                self.pausingTaskIdentifiers.remove(task.taskIdentifier)
                if let originalEnclosureUrl = self.resumeAfterPause.removeValue(forKey: downloadId) {
                    self.resolveAndStart(downloadId: downloadId, originalEnclosureUrl: originalEnclosureUrl)
                } else {
                    IosMediaRuntime.shared.reportDownloadPaused(downloadId: downloadId)
                }
            }
        })
    }

    func resumeDownload(downloadId: String, originalEnclosureUrl: String) {
        guardOnMain { self.resumeDownload(downloadId: downloadId, originalEnclosureUrl: originalEnclosureUrl) }
        guard Thread.isMainThread else { return }
        if let transfer = activeTransfers[downloadId], pausingTaskIdentifiers.contains(transfer.task.taskIdentifier) {
            resumeAfterPause[downloadId] = originalEnclosureUrl
            return
        }
        guard activeTransfers[downloadId] == nil else { return }
        UserDefaults.standard.set(originalEnclosureUrl, forKey: originalKey(downloadId))
        resolveAndStart(downloadId: downloadId, originalEnclosureUrl: originalEnclosureUrl)
    }

    func deleteDownload(downloadId: String) {
        guardOnMain { self.deleteDownload(downloadId: downloadId) }
        guard Thread.isMainThread else { return }
        removeDownload(downloadId)
    }

    func reconcileDownload(downloadId: String) {
        guardOnMain { self.reconcileDownload(downloadId: downloadId) }
        guard Thread.isMainThread else { return }
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
                let freshFallback: ResolvedRepresentation?
                if let retained, self.canSafelyResume(retained, against: resolved.validators) {
                    task = self.session.downloadTask(withResumeData: retained.data)
                    freshFallback = resolved
                } else {
                    self.clearRetainedPartial(for: downloadId)
                    task = self.session.downloadTask(with: resolved.url)
                    freshFallback = nil
                }
                task.taskDescription = downloadId
                self.saveValidators(resolved.validators, for: downloadId)
                self.activeTransfers[downloadId] = ActiveTransfer(
                    task: task,
                    validators: resolved.validators,
                    freshFallback: freshFallback
                )
                task.resume()
            }
        }
    }

    private func startFreshTransfer(downloadId: String, resolved: ResolvedRepresentation) {
        let task = session.downloadTask(with: resolved.url)
        task.taskDescription = downloadId
        saveValidators(resolved.validators, for: downloadId)
        activeTransfers[downloadId] = ActiveTransfer(
            task: task,
            validators: resolved.validators,
            freshFallback: nil
        )
        IosMediaRuntime.shared.reportDownloadQueued(downloadId: downloadId)
        task.resume()
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
        guardOnMain {
            self.urlSession(
                session,
                downloadTask: downloadTask,
                didWriteData: bytesWritten,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpectedToWrite: totalBytesExpectedToWrite
            )
        }
        guard Thread.isMainThread else { return }
        guard let id = currentDownloadID(for: downloadTask) else { return }
        IosMediaRuntime.shared.reportDownloadProgress(
            downloadId: id,
            bytesDownloaded: totalBytesWritten,
            totalBytes: totalBytesExpectedToWrite
        )
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guardOnMain { self.urlSession(session, downloadTask: downloadTask, didFinishDownloadingTo: location) }
        guard Thread.isMainThread else { return }
        guard let id = currentDownloadID(for: downloadTask),
              let transfer = activeTransfers[id],
              let response = downloadTask.response as? HTTPURLResponse else { return }
        guard (200...299).contains(response.statusCode) else {
            activeTransfers[id] = nil
            if shouldRetryFreshTarget(response.statusCode), retryFreshTarget(downloadId: id, transfer: transfer) {
                return
            }
            IosMediaRuntime.shared.reportDownloadFailed(downloadId: id)
            return
        }
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
        guardOnMain { self.urlSession(session, task: task, didCompleteWithError: error) }
        guard Thread.isMainThread else { return }
        guard let downloadTask = task as? URLSessionDownloadTask,
              let id = currentDownloadID(for: downloadTask),
              let transfer = activeTransfers[id] else { return }
        if pausingTaskIdentifiers.contains(task.taskIdentifier) {
            return
        }
        activeTransfers[id] = nil
        guard let error else { return }

        if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
           !saveRetainedPartial(resumeData, validators: transfer.validators, for: id) {
            clearRetainedPartial(for: id)
        }

        if let response = downloadTask.response as? HTTPURLResponse,
           shouldRetryFreshTarget(response.statusCode),
           retryFreshTarget(downloadId: id, transfer: transfer) {
            return
        }
        IosMediaRuntime.shared.reportDownloadFailed(downloadId: id)
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

    private func shouldRetryFreshTarget(_ statusCode: Int) -> Bool {
        // A signed CDN target can become unauthorized or disappear while the stable
        // enclosure redirect remains usable. Other HTTP failures remain user-visible.
        [401, 403, 404, 410].contains(statusCode)
    }

    private func retryFreshTarget(downloadId: String, transfer: ActiveTransfer) -> Bool {
        guard let fallback = transfer.freshFallback else { return false }
        // Resume data cannot be retargeted. It is stale only for this server-response path.
        clearRetainedPartial(for: downloadId)
        startFreshTransfer(downloadId: downloadId, resolved: fallback)
        return true
    }

    /// Kotlin UI commands, redirect completions, and URLSession delegates all enter this
    /// serial executor before reading or mutating transfer dictionaries.
    private func guardOnMain(_ operation: @escaping () -> Void) {
        guard !Thread.isMainThread else { return }
        DispatchQueue.main.sync(execute: operation)
    }

    private func retainedPartial(for downloadId: String) -> RetainedPartial? {
        let currentURL = resumeDataURL(for: downloadId)
        if let current = try? Data(contentsOf: currentURL) {
            return retainedPartial(current, downloadId: downloadId)
        }

        for legacyURL in legacyResumeDataURLs(for: downloadId) {
            guard let legacy = try? Data(contentsOf: legacyURL) else { continue }
            do {
                try legacy.write(to: currentURL, options: .atomic)
                try fileManager.removeItem(at: legacyURL)
            } catch {
                // The source remains intact. Use it for this attempt and retry migration later.
            }
            return retainedPartial(legacy, downloadId: downloadId)
        }
        return nil
    }

    private func retainedPartial(_ data: Data, downloadId: String) -> RetainedPartial? {
        guard let validators = savedValidatorsOrNil(for: downloadId) else { return nil }
        return RetainedPartial(data: data, validators: validators)
    }

    @discardableResult
    private func saveRetainedPartial(_ data: Data, validators: RepresentationValidators, for downloadId: String) -> Bool {
        do {
            try data.write(to: resumeDataURL(for: downloadId), options: .atomic)
            saveValidators(validators, for: downloadId)
            return true
        } catch {
            return false
        }
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
        legacyResumeDataURLs(for: downloadId).forEach { try? fileManager.removeItem(at: $0) }
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
        resumeAfterPause[id] = nil
        if let transfer = activeTransfers[id] {
            pausingTaskIdentifiers.remove(transfer.task.taskIdentifier)
            transfer.task.cancel()
        }
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
    private func legacyResumeDataURLs(for id: String) -> [URL] {
        [safeLegacyFileName(id), legacyFileName(id)].map {
            downloadDirectory.appendingPathComponent("resume-" + $0)
        }
    }
    private func fileName(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
    private func safeLegacyFileName(_ id: String) -> String {
        legacyFileName(id)
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    private func legacyFileName(_ id: String) -> String { Data(id.utf8).base64EncodedString() }
}

private extension CMTime {
    init(milliseconds: Int64) { self.init(value: milliseconds, timescale: 1_000) }
    var milliseconds: Int64 {
        guard isNumeric, seconds.isFinite else { return 0 }
        return Int64((seconds * 1_000).rounded())
    }
}
