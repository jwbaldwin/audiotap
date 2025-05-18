import Foundation
import Combine

typealias ProgressHandler = (Double) -> Void

protocol AudioUploading {
    func upload(fileURL: URL, progress: @escaping ProgressHandler) async throws -> UploadResponse
}

struct UploadResponse: Codable {
    let data: UploadData
    
    struct UploadData: Codable {
        let uploadUrl: String
        
        enum CodingKeys: String, CodingKey {
            case uploadUrl = "upload_url"
        }
    }
}

enum UploadError: Error {
    case badStatus(Int)
    case decodingFailed
}

final class AudioUploader: NSObject, AudioUploading {
    private lazy var session: URLSession = {
        URLSession(configuration: .default,
                   delegate: self,
                   delegateQueue: nil)
    }()
    
    private var continuations = [Int: CheckedContinuation<UploadResponse, Error>]()
    private var progressHandlers = [Int: ProgressHandler]()
    private var payload = [Int: Data]()
    
    func upload(fileURL: URL,
                progress: @escaping ProgressHandler) async throws -> UploadResponse {
        let boundary = UUID().uuidString
        
        var request = URLRequest(url: AppConfig.uploadEndpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        let data = try createMultipartFormBody(fileURL: fileURL, boundary: boundary)
        
        let task = session.uploadTask(with: request, from: data)
        
        progressHandlers[task.taskIdentifier] = progress
        
        let kvo = task.progress.observe(\.fractionCompleted) { [weak self] prog, _ in
            if let progressHandler = self?.progressHandlers[task.taskIdentifier] {
                progressHandler(prog.fractionCompleted)
            }
        }
        
        // We need to hold this until task completes
        task.taskDescription = "\(kvo.hashValue)" // Store KVO token reference
        
        return try await withCheckedThrowingContinuation { cont in
            continuations[task.taskIdentifier] = cont
            task.resume()
        }
    }
}

extension AudioUploader: URLSessionDataDelegate {
    
    // Collect server response data
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        payload[dataTask.taskIdentifier, default: Data()].append(data)
    }
    
    // Resolve the async continuation and clean up
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        
        // Clean up stored handlers
        defer {
            progressHandlers.removeValue(forKey: task.taskIdentifier)
            payload.removeValue(forKey: task.taskIdentifier)
            
            // Also clean up KVO observer by releasing its reference
            task.taskDescription = nil
        }
        
        guard let cont = continuations.removeValue(forKey: task.taskIdentifier) else { return }
        
        if let error { cont.resume(throwing: error); return }
        
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(statusCode) else {
            cont.resume(throwing: UploadError.badStatus(statusCode)); return
        }
        
        let data = payload[task.taskIdentifier] ?? Data()
        do {
            let decoded = try JSONDecoder().decode(UploadResponse.self, from: data)
            cont.resume(returning: decoded)
        } catch {
            cont.resume(throwing: UploadError.decodingFailed)
        }
    }
}

private func createMultipartFormBody(fileURL: URL, boundary: String) throws -> Data {
    var body = Data()
    
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
    
    body.append(try Data(contentsOf: fileURL))
    body.append("\r\n".data(using: .utf8)!)
    
    body.append("--\(boundary)--\r\n".data(using: .utf8)!)
    
    return body
}
