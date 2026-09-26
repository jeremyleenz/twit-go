import Foundation
import UIKit

final class MediaProbeAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == DownloadProbeManager.sessionID else { completionHandler(); return }
        DownloadProbeManager.shared.backgroundCompletionHandler = completionHandler
    }
}

final class DownloadProbeManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = DownloadProbeManager()
    static let sessionID = "com.example.twitgo.media-probe-download"

    @Published private(set) var status = "No download"
    var backgroundCompletionHandler: (() -> Void)?
    private var activeTask: URLSessionDownloadTask?
    private var originalURL: URL?
    private var resolvingOriginalURL = false
    private var stoppingForResume = false
    private let fileManager = FileManager.default

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var storageDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("MediaProbe", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private var resumeFile: URL { storageDirectory.appendingPathComponent("resume.data") }

    var localFileURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: "mediaProbe.downloadedPath"),
              fileManager.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    override private init() {
        super.init()
        if let saved = UserDefaults.standard.string(forKey: "mediaProbe.downloadOriginalURL") {
            originalURL = URL(string: saved)
        }
        _ = session
        session.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.activeTask == nil { self.activeTask = tasks.first as? URLSessionDownloadTask }
                if self.activeTask != nil { self.status = "Background transfer running" }
                else if self.localFileURL != nil { self.status = "Download complete · local file ready" }
                else if self.fileManager.fileExists(atPath: self.resumeFile.path) { self.status = "Stopped · partial data retained" }
            }
        }
    }

    func start(_ urlString: String) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https" else { status = "Use an HTTPS enclosure URL."; return }
        guard activeTask == nil, !resolvingOriginalURL else { status = "A transfer is already running."; return }
        originalURL = url
        if let existing = localFileURL { try? fileManager.removeItem(at: existing) }
        UserDefaults.standard.removeObject(forKey: "mediaProbe.downloadedPath")
        UserDefaults.standard.set(url.absoluteString, forKey: "mediaProbe.downloadOriginalURL")
        try? fileManager.removeItem(at: resumeFile)
        resolvingOriginalURL = true
        status = "Resolving enclosure redirect"
        resolveRedirect(for: url) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.resolvingOriginalURL = false
                switch result {
                case let .success(resolvedURL):
                    self.activeTask = self.session.downloadTask(with: resolvedURL)
                    self.activeTask?.resume()
                    self.status = "Downloading from original enclosure"
                case let .failure(error):
                    let nsError = error as NSError
                    self.status = "Could not resolve enclosure (\(nsError.domain):\(nsError.code))"
                }
            }
        }
    }

    func stopKeepingPartial() {
        guard let task = activeTask else { return }
        stoppingForResume = true
        task.cancel(byProducingResumeData: { [weak self] data in
            DispatchQueue.main.async {
                guard let self else { return }
                if let data { try? data.write(to: self.resumeFile, options: .atomic) }
                self.activeTask = nil
                self.status = data == nil ? "Stopped · no resume data; retry starts over" : "Stopped · partial data retained"
            }
        })
    }

    func resume() {
        guard activeTask == nil, let originalURL else { return }
        if let data = try? Data(contentsOf: resumeFile) {
            activeTask = session.downloadTask(withResumeData: data)
            status = "Resuming saved transfer"
        } else {
            activeTask = session.downloadTask(with: originalURL)
            status = "Retrying from original enclosure"
        }
        activeTask?.resume()
    }

    /**
     * Resolve on every fresh attempt so the background task receives a current
     * CDN URL, while originalURL remains the only persisted media identity.
     */
    private func resolveRedirect(for originalURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        var request = URLRequest(url: originalURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 30
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        URLSession(configuration: configuration).dataTask(with: request) { _, response, error in
            if let error { completion(.failure(error)); return }
            guard let resolvedURL = response?.url, resolvedURL.scheme == "https" else {
                completion(.failure(URLError(.badServerResponse)))
                return
            }
            completion(.success(resolvedURL))
        }.resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        DispatchQueue.main.async { [weak self] in
            let total = totalBytesExpectedToWrite > 0 ? String(totalBytesExpectedToWrite) : "?"
            self?.status = "Downloading · \(totalBytesWritten) / \(total) bytes"
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              let originalURL else {
            DispatchQueue.main.async { [weak self] in self?.status = "Download response was not usable" }
            return
        }
        let ext = originalURL.pathExtension.isEmpty ? "media" : originalURL.pathExtension
        let destination = storageDirectory.appendingPathComponent("offline.\(ext)")
        do {
            let size = (try fileManager.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0, response.expectedContentLength <= 0 || size == response.expectedContentLength else {
                DispatchQueue.main.async { [weak self] in self?.status = "Downloaded file failed length check" }
                return
            }
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: location, to: destination)
            try? fileManager.removeItem(at: resumeFile)
            UserDefaults.standard.set(destination.path, forKey: "mediaProbe.downloadedPath")
            DispatchQueue.main.async { [weak self] in self?.status = "Download complete · local file ready" }
        } catch {
            DispatchQueue.main.async { [weak self] in self?.status = "Could not save downloaded file" }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activeTask = nil
            if self.stoppingForResume { self.stoppingForResume = false; return }
            if let error {
                let nsError = error as NSError
                let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                if let data { try? data.write(to: self.resumeFile, options: .atomic) }
                let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
                let detail = "\(nsError.domain):\(nsError.code)" + (underlying.map { " / \($0.domain):\($0.code)" } ?? "")
                self.status = data == nil ? "Transfer failed (\(detail))" : "Transfer interrupted (\(detail)) · resume data saved"
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}
