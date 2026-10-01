
import Foundation
import CCrypto
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Private object storage access (Backblaze B2 native API) for immutable
/// raw inputs and derived archives. Reads for raw inputs; writes only for
/// the derived-result archive lane. Authorization is cached and
/// re-established lazily on expiry/401.
final class B2Storage {
    struct Error: Swift.Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private let keyID: String
    private let applicationKey: String
    private let bucket: String

    /// The bucket this worker writes derived archives into. Exposed so lanes can
    /// pass the exact bucket to the DB completion contracts instead of hardcoding.
    var bucketName: String { bucket }
    private let session: URLSession
    private var auth: (apiUrl: String, token: String, downloadURL: String, accountID: String, validUntil: Date)?
    private var bucketID: String?

    init(keyID: String, applicationKey: String, bucket: String) {
        self.keyID = keyID
        self.applicationKey = applicationKey
        self.bucket = bucket
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: cfg)
    }

    private func authorize() throws -> (apiUrl: String, token: String, downloadURL: String, accountID: String, validUntil: Date) {
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
              let token = obj["authorizationToken"] as? String,
              let account = obj["accountId"] as? String else {
            throw Error(message: "b2 authorize: malformed response")
        }
        // Tokens live ~24h; refresh after 12h.
        let until = Date().addingTimeInterval(12 * 3600)
        auth = (apiUrl, token, downloadURL, account, until)
        return (apiUrl, token, downloadURL, account, until)
    }

    /// Resolve the bucket id once (needed for uploads).
    private func resolveBucketID() throws -> String {
        if let b = bucketID { return b }
        let a = try authorize()
        var req = URLRequest(url: URL(string: "\(a.apiUrl)/b2api/v3/b2_list_buckets")!)
        req.httpMethod = "POST"
        req.setValue(a.token, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{\"accountId\":\"\(a.accountID)\",\"bucketName\":\"\(bucket)\"}".utf8)
        let (dataOpt, respOpt, err) = session.synchronous(req)
        if let err { throw Error(message: "b2 list_buckets failed: \(err)") }
        guard let data = dataOpt, let http = respOpt as? HTTPURLResponse, http.statusCode == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let buckets = obj["buckets"] as? [[String: Any]], let first = buckets.first,
              let id = first["bucketId"] as? String else {
            throw Error(message: "b2 list_buckets: malformed response")
        }
        bucketID = id
        return id
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
            // A typed error the lanes can classify. Previously this threw
            // B2Storage.Error(message: "object_missing"), so the
            // `catch let e as WorkerError { if case .objectMissing }` branches in
            // ProjectionLane/VerificationLane were dead code and a not-yet-arrived
            // object was reported as a generic failure.
            throw WorkerError.objectMissing
        }
        guard http.statusCode == 200, let data = dataOpt else {
            if http.statusCode == 401 { auth = nil }
            throw Error(message: "b2 download HTTP \(http.statusCode)")
        }
        return data
    }

    /// Upload one object as a single part.
    func upload(objectKey: String, bytes: Data, contentType: String) throws {
        let a = try authorize()
        let bid = try resolveBucketID()
        var req = URLRequest(url: URL(string: "\(a.apiUrl)/b2api/v3/b2_get_upload_url")!)
        req.httpMethod = "POST"
        req.setValue(a.token, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{\"bucketId\":\"\(bid)\"}".utf8)
        let (authData, authResp, authErr) = session.synchronous(req)
        if let authErr { throw Error(message: "b2 get_upload_url failed: \(authErr)") }
        guard let authBody = authData, let http = authResp as? HTTPURLResponse, http.statusCode == 200,
              let obj = (try? JSONSerialization.jsonObject(with: authBody)) as? [String: Any],
              let uploadURL = obj["uploadUrl"] as? String,
              let uploadToken = obj["authorizationToken"] as? String else {
            throw Error(message: "b2 get_upload_url: malformed response")
        }
        var put = URLRequest(url: URL(string: uploadURL)!)
        put.httpMethod = "POST"
        put.setValue(uploadToken, forHTTPHeaderField: "Authorization")
        put.setValue(String(bytes.count), forHTTPHeaderField: "Content-Length")
        put.setValue(contentType, forHTTPHeaderField: "Content-Type")
        put.setValue(objectKey, forHTTPHeaderField: "X-Bz-File-Name")
        put.setValue(sha1Hex(bytes), forHTTPHeaderField: "X-Bz-Content-Sha1")
        put.httpBody = bytes
        let (_, putResp, putErr) = session.synchronous(put)
        if let putErr { throw Error(message: "b2 upload failed: \(putErr)") }
        guard let putHttp = putResp as? HTTPURLResponse, (200..<300).contains(putHttp.statusCode) else {
            throw Error(message: "b2 upload HTTP \((putResp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
    }
}

private func sha1Hex(_ data: Data) -> String {
    var digest = [UInt8](repeating: 0, count: 20)
    data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
        _ = SHA1(ptr.baseAddress, ptr.count, &digest)
    }
    return digest.map { String(format: "%02x", $0) }.joined()
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
