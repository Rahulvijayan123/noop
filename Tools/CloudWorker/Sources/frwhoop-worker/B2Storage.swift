
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Private object storage access (Backblaze B2 native API) for immutable raw inputs.
///
/// The worker only needs reads: the phone owns writes through the edge ingest
/// path. Authorization is cached and re-established lazily on 401.
final class B2Storage {
    struct Error: Swift.Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private let keyID: String
    private let applicationKey: String
    private let bucket: String
    private var session: URLSession
    private var auth: (apiUrl: String, token: String, downloadURL: String, validUntil: Date)?

    init(keyID: String, applicationKey: String, bucket: String) {
        self.keyID = keyID
        self.applicationKey = applicationKey
        self.bucket = bucket
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: cfg)
    }

    private func authorize() throws -> (apiUrl: String, token: String, downloadURL: String, validUntil: Date) {
        if let a = auth, a.validUntil > Date() { return a }
        let basic = Data("\(keyID):\(applicationKey)".utf8).base64EncodedString()
        var req = URLRequest(url: URL(string: "https://api.backblazeb2.com/b2api/v3/b2_authorize_account")!)
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        let (dataOpt, respOpt, err) = session.synchronous(req)
        if let err { throw Error(message: "b2 authorize failed: \(err)") }
        guard let data = dataOpt else { throw Error(message: "b2 authorize: empty body") }
        guard let http = respOpt as? HTTPURLResponse, http.statusCode == 200 else {
            throw Error(message: "b2 authorize HTTP \((respOpt as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apiInfo = obj["apiInfo"] as? [String: Any],
              let storageApi = apiInfo["storageApi"] as? [String: Any],
              let apiUrl = storageApi["apiUrl"] as? String,
              let downloadURL = storageApi["downloadUrl"] as? String,
              let token = obj["authorizationToken"] as? String else {
            throw Error(message: "b2 authorize: malformed response")
        }
        // Tokens live ~24h; refresh after 12h.
        let until = Date().addingTimeInterval(12 * 3600)
        auth = (apiUrl, token, downloadURL, until)
        return (apiUrl, token, downloadURL, until)
    }

    /// Download one object; returns the exact wire bytes.
    func download(objectKey: String) throws -> Data {
        let a = try authorize()
        guard let url = URL(string: "\(a.downloadURL)/file/\(bucket)/\(objectKey)") else {
            throw Error(message: "invalid object key")
        }
        var req = URLRequest(url: url)
        req.setValue(a.token, forHTTPHeaderField: "Authorization")
        let (dataOpt, respOpt, err) = session.synchronous(req)
        if let err { throw Error(message: "b2 download \(objectKey) failed: \(err)") }
        guard let http = respOpt as? HTTPURLResponse else { throw Error(message: "b2 download: no response") }
        if http.statusCode == 404 {
            throw Error(message: "object_missing")
        }
        guard http.statusCode == 200, let data = dataOpt else {
            if http.statusCode == 401 { auth = nil }
            throw Error(message: "b2 download HTTP \(http.statusCode)")
        }
        return data
    }
}

extension URLSession {
    /// Foundation on Linux has no synchronous helper; drive one request on a
    /// fresh semaphore with a lock-protected result box.
    func synchronous(_ request: URLRequest) -> (Data?, URLResponse?, Error?) {
        final class Box: @unchecked Sendable {
            var out: (Data?, URLResponse?, Error?)?
            let lock = NSLock()
            func set(_ v: (Data?, URLResponse?, Error?)) {
                lock.lock(); defer { lock.unlock() }
                out = v
            }
            func get() -> (Data?, URLResponse?, Error?)? {
                lock.lock(); defer { lock.unlock() }
                return out
            }
        }
        let sem = DispatchSemaphore(value: 0)
        let box = Box()
        let task = self.dataTask(with: request) { d, r, e in
            box.set((d, r, e))
            sem.signal()
        }
        task.resume()
        sem.wait()
        return box.get() ?? (nil, nil, nil)
    }
}
