// ModelDownloads.swift - the KB-Whisper models install.sh fetches, fetched
// from Settings > Dictation instead, with progress, into the repository's
// models folder.
//
// From the same Hugging Face URLs and against the same pinned sha256 as
// install.sh: a download goes to <model>.partial and becomes the model only
// once its checksum matches; one that does not is removed. Using a model is
// the Model picker's business (MODEL_PATH and a server restart).

import CryptoKit
import Foundation

struct WhisperModel: Identifiable {
    let size: String
    let sha256: String
    let bytes: Int64
    let note: String
    var id: String { size }
    var title: String { "KB-Whisper " + size }
    var url: URL { URL(string: "https://huggingface.co/KBLab/kb-whisper-\(size)/resolve/main/ggml-model-q5_0.bin")! }

    func path(in repository: String) -> String {
        (repository as NSString).appendingPathComponent("models/ggml-kb-whisper-\(size)-q5_0.bin")
    }

    /// As pinned in install.sh, where the checksums come from the LFS pointer files.
    static let all = [
        WhisperModel(size: "small", sha256: "6768836a51abc902e420c613153e6d418c90ea2774e913274d02ab23170225b7",
                     bytes: 175_209_680, note: "Fastest, and the least accurate."),
        WhisperModel(size: "medium", sha256: "7f8762e0ade9e0073674c0d5acae942a0b1ea98add9baa008ee89c94eaba43d0",
                     bytes: 539_212_484, note: "Fast and accurate."),
        WhisperModel(size: "large", sha256: "6d2863812d7410322bb7d8647a5c7260761300fa946714c9ed66d22bb30bcb19",
                     bytes: 1_081_140_203, note: "The most accurate; the default on Apple silicon."),
    ]
}

final class ModelDownloads: NSObject, ObservableObject, URLSessionDownloadDelegate {
    let repository: String
    /// Per model being fetched: how far, 0 to 1.
    @Published private(set) var progress: [String: Double] = [:]
    /// Per model: what became of the last attempt, while it matters.
    @Published private(set) var message: [String: String] = [:]
    private var session: URLSession!
    private var tasks: [Int: String] = [:]

    init(repository: String) {
        self.repository = repository
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    func isInstalled(_ model: WhisperModel) -> Bool {
        FileManager.default.fileExists(atPath: model.path(in: repository))
    }

    func download(_ model: WhisperModel) {
        guard progress[model.size] == nil else { return }
        let task = session.downloadTask(with: model.url)
        tasks[task.taskIdentifier] = model.size
        progress[model.size] = 0
        message[model.size] = nil
        task.resume()
    }

    func cancel(_ model: WhisperModel) {
        session.getAllTasks { all in
            for t in all where self.tasks[t.taskIdentifier] == model.size { t.cancel() }
        }
    }

    // MARK: URLSessionDownloadDelegate, on the main queue

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let size = tasks[downloadTask.taskIdentifier],
              let model = WhisperModel.all.first(where: { $0.size == size }) else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : model.bytes
        progress[size] = min(1, Double(totalBytesWritten) / Double(total))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let size = tasks[downloadTask.taskIdentifier],
              let model = WhisperModel.all.first(where: { $0.size == size }) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            message[size] = L("Download failed: %@", "HTTP \(http.statusCode)")
            return
        }
        // The file at `location` is gone once this returns: move it first.
        let final = model.path(in: repository), partial = final + ".partial"
        do {
            try FileManager.default.createDirectory(atPath: (final as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try? FileManager.default.removeItem(atPath: partial)
            try FileManager.default.moveItem(at: location, to: URL(fileURLWithPath: partial))
        } catch {
            message[size] = L("Download failed: %@", error.localizedDescription)
            return
        }
        progress[size] = 1
        message[size] = L("Checking…")
        DispatchQueue.global(qos: .utility).async {
            let ok = Self.sha256(of: partial) == model.sha256
            DispatchQueue.main.async {
                if ok, rename(partial, final) == 0 {
                    self.message[size] = nil
                } else {
                    try? FileManager.default.removeItem(atPath: partial)
                    self.message[size] = L("The download did not match its checksum and was removed.")
                }
                self.progress[size] = nil
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let size = tasks.removeValue(forKey: task.taskIdentifier) else { return }
        guard let error = error else { return }
        progress[size] = nil
        if (error as NSError).code != NSURLErrorCancelled {
            message[size] = L("Download failed: %@", error.localizedDescription)
        }
    }

    /// A file's sha256 in hex, read 4 MB at a time.
    static func sha256(of path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
