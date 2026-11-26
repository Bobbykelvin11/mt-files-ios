import Foundation

/// URLSession download with live progress.
final class Downloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var progress: Double = 0
    @Published var isDownloading = false
    @Published var statusText = ""

    private var continuation: CheckedContinuation<(URL, String), Error>?
    private lazy var session: URLSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var task: URLSessionDownloadTask?

    func download(_ url: URL) async throws -> (file: URL, suggestedName: String) {
        await MainActor.run {
            self.progress = 0
            self.statusText = "Starting…"
            self.isDownloading = true
        }
        do {
            let result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(URL, String), Error>) in
                self.continuation = cont
                var req = URLRequest(url: url)
                req.setValue("IPAStudio/1.0", forHTTPHeaderField: "User-Agent")
                let t = session.downloadTask(with: req)
                self.task = t
                t.resume()
            }
            await MainActor.run { self.isDownloading = false }
            return (result.0, result.1)
        } catch {
            await MainActor.run { self.isDownloading = false }
            throw error
        }
    }

    func cancel() { task?.cancel() }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        DispatchQueue.main.async {
            if totalBytesExpectedToWrite > 0 {
                self.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                self.statusText = "\(formatBytes(totalBytesWritten)) of \(formatBytes(totalBytesExpectedToWrite))"
            } else {
                self.statusText = formatBytes(totalBytesWritten)
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let name = downloadTask.response?.suggestedFilename ?? downloadTask.originalRequest?.url?.lastPathComponent ?? "download.ipa"
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)-\(name)")
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw StudioError.message("Server returned HTTP \(http.statusCode)")
            }
            try FileManager.default.moveItem(at: location, to: dest)
            continuation?.resume(returning: (dest, name))
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
